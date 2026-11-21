#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include "napi/native_api.h"
#include "multimedia/player_framework/native_avbuffer.h"
#include "multimedia/player_framework/native_avcodec_audiocodec.h"
#include "multimedia/player_framework/native_avformat.h"
#include "WatchAudioPlatform.h"

namespace {
constexpr int HEADER_BYTES = 44;
constexpr int FRAME_SAMPLES = 1024;
constexpr int64_t MAX_WAV_BYTES = INT32_MAX;
constexpr int MAX_PADDING_BYTES = 8192;

struct BufferEvent {
    bool input;
    uint32_t index;
    OH_AVBuffer* buffer;
};

struct Job {
    std::atomic<bool> cancelled{false};
    std::atomic<bool> running{false};
    std::atomic<int> progress{0};
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<BufferEvent> events;
    int error = 0;
    int rate = 16000;
    bool decode = false;
    std::string input;
    std::string output;
    int64_t expectedBytes = 0;
    int64_t resultBytes = 0;
    std::string failure;
    bool outputCreated = false;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
};

void Require(bool success, const char* message)
{
    if (!success) { throw std::runtime_error(message); }
}

struct File {
    int fd = -1;
    explicit File(int value) : fd(value) { Require(fd >= 0, "无法打开音频文件"); }
    ~File() { if (fd >= 0) { close(fd); } }
};

void ReadExact(int fd, void* buffer, size_t bytes)
{
    auto* target = static_cast<uint8_t*>(buffer);
    while (bytes > 0) {
        const ssize_t count = read(fd, target, bytes);
        Require(count > 0, "音频文件不完整");
        target += count;
        bytes -= count;
    }
}

void WriteExact(int fd, const void* buffer, size_t bytes)
{
    auto* source = static_cast<const uint8_t*>(buffer);
    while (bytes > 0) {
        const ssize_t count = write(fd, source, bytes);
        Require(count > 0, "音频文件写入失败");
        source += count;
        bytes -= count;
    }
}

uint32_t U32(const uint8_t* bytes)
{
    return uint32_t(bytes[0]) | (uint32_t(bytes[1]) << 8) |
        (uint32_t(bytes[2]) << 16) | (uint32_t(bytes[3]) << 24);
}

void Set32(uint8_t* bytes, uint32_t value)
{
    for (int i = 0; i < 4; i++) { bytes[i] = uint8_t(value >> (i * 8)); }
}

std::array<uint8_t, HEADER_BYTES> WavHeader(int rate, uint32_t bytes)
{
    std::array<uint8_t, HEADER_BYTES> h{};
    memcpy(h.data(), "RIFF", 4);
    memcpy(h.data() + 8, "WAVEfmt ", 8);
    memcpy(h.data() + 36, "data", 4);
    Set32(h.data() + 4, bytes + 36);
    Set32(h.data() + 16, 16);
    h[20] = 1; h[22] = 1; h[32] = 2; h[34] = 16;
    Set32(h.data() + 24, rate);
    Set32(h.data() + 28, rate * 2);
    Set32(h.data() + 40, bytes);
    return h;
}

void OnError(OH_AVCodec*, int32_t error, void* context)
{
    auto* job = static_cast<Job*>(context);
    std::lock_guard<std::mutex> guard(job->mutex);
    job->error = error == 0 ? -1 : error;
    job->wake.notify_all();
}

void OnFormat(OH_AVCodec*, OH_AVFormat* format, void* context)
{
    auto* job = static_cast<Job*>(context);
    if (!job->decode) { return; }
    int rate = 0, channels = 0, sample = 0;
    const bool valid = OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, &rate) &&
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, &channels) &&
        rate == job->rate && channels == 1 &&
        (!OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &sample) || sample == SAMPLE_S16LE);
    if (!valid) { OnError(nullptr, -1, context); }
}

void Enqueue(bool input, uint32_t index, OH_AVBuffer* buffer, void* context)
{
    auto* job = static_cast<Job*>(context);
    std::lock_guard<std::mutex> guard(job->mutex);
    if (job->events.size() >= 64) { job->error = -1; }
    else { job->events.push_back({input, index, buffer}); }
    job->wake.notify_all();
}

void OnInput(OH_AVCodec*, uint32_t index, OH_AVBuffer* buffer, void* context)
{
    Enqueue(true, index, buffer, context);
}

void OnOutput(OH_AVCodec*, uint32_t index, OH_AVBuffer* buffer, void* context)
{
    Enqueue(false, index, buffer, context);
}

// AAC-LC ADTS carries one complete access unit in each frame.
int ReadAdts(int fd, uint8_t* target, int capacity, int rate)
{
    Require(capacity >= 7, "音频输入缓冲区过小");
    const ssize_t first = read(fd, target, 1);
    Require(first >= 0, "读取音频失败");
    if (first == 0) { return 0; }
    ReadExact(fd, target + 1, 6);
    const int rateIndex = (target[2] >> 2) & 15;
    const int channels = ((target[2] & 1) << 2) | (target[3] >> 6);
    const int size = ((target[3] & 3) << 11) | (target[4] << 3) | (target[5] >> 5);
    Require(target[0] == 255 && (target[1] & 0xF6) == 0xF0 && (target[2] >> 6) == 1 &&
        rateIndex == (rate == 16000 ? 8 : 3) && channels == 1 && (target[6] & 3) == 0 &&
        size >= ((target[1] & 1) ? 7 : 9) && size <= capacity, "AAC 录音格式无效");
    ReadExact(fd, target + 7, size - 7);
    return size;
}

void Transcode(Job& job)
{
    File input(open(job.input.c_str(), O_RDONLY));
    struct stat stat{};
    Require(fstat(input.fd, &stat) == 0 && stat.st_size > 0 && stat.st_size <= MAX_WAV_BYTES,
        "录音大小无效");
    const int64_t inputBytes = stat.st_size;
    Require(job.decode || inputBytes == job.expectedBytes, "录音文件在处理前发生变化");
    if (!job.decode) {
        std::array<uint8_t, HEADER_BYTES> header{};
        ReadExact(input.fd, header.data(), header.size());
        Require(header == WavHeader(job.rate, inputBytes - HEADER_BYTES), "录音必须为单声道 16 位 WAV");
    }
    File output(open(job.output.c_str(), O_CREAT | O_EXCL | O_WRONLY, 0600));
    job.outputCreated = true;
    if (job.decode) {
        const auto header = WavHeader(job.rate, 0);
        WriteExact(output.fd, header.data(), header.size());
    }
    OH_AVCodec* codec = OH_AudioCodec_CreateByMime("audio/mp4a-latm", !job.decode);
    Require(codec != nullptr, "当前设备不支持 AAC 音频编码");
    bool started = false;
    try {
        const OH_AVCodecCallback callbacks{OnError, OnFormat, OnInput, OnOutput};
        Require(OH_AudioCodec_RegisterCallback(codec, callbacks, &job) == AV_ERR_OK, "初始化音频回调失败");
        OH_AVFormat* format = OH_AVFormat_Create();
        Require(format != nullptr, "音频格式初始化失败");
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, job.rate);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, 1);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
        if (job.decode) {
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_AAC_IS_ADTS, 1);
        } else {
            OH_AVFormat_SetLongValue(format, OH_MD_KEY_BITRATE, 48000);
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE, AAC_PROFILE_LC);
        }
        const auto configured = OH_AudioCodec_Configure(codec, format);
        OH_AVFormat_Destroy(format);
        Require(configured == AV_ERR_OK && OH_AudioCodec_Prepare(codec) == AV_ERR_OK, "设备不支持此 AAC 配置");
        Require(OH_AudioCodec_Start(codec) == AV_ERR_OK, "启动音频编码失败");
        started = true;
        bool inputEnd = false, outputEnd = false;
        int64_t consumed = job.decode ? 0 : HEADER_BYTES;
        int64_t samples = 0, written = 0;
        while (!outputEnd) {
            Require(!job.cancelled.load(), "音频处理已取消");
            BufferEvent event{};
            {
                std::unique_lock<std::mutex> lock(job.mutex);
                Require(job.wake.wait_for(lock, std::chrono::seconds(15), [&job] {
                    return job.cancelled.load() || job.error != 0 || !job.events.empty();
                }), "系统音频编码响应超时");
                Require(!job.cancelled.load(), "音频处理已取消");
                Require(job.error == 0, "系统音频编解码失败");
                event = job.events.front();
                job.events.pop_front();
            }
            uint8_t* address = OH_AVBuffer_GetAddr(event.buffer);
            const int capacity = OH_AVBuffer_GetCapacity(event.buffer);
            if (event.input) {
                Require(address != nullptr && capacity > 0, "音频缓冲区无效");
                if (inputEnd) { continue; }
                int size = 0;
                if (job.decode) { size = ReadAdts(input.fd, address, capacity, job.rate); }
                else {
                    size = int(std::min<int64_t>(FRAME_SAMPLES * 2, inputBytes - consumed));
                    Require(size <= capacity && size % 2 == 0, "音频采样长度无效");
                    ReadExact(input.fd, address, size);
                }
                inputEnd = size == 0;
                OH_AVCodecBufferAttr attr{};
                attr.size = size;
                attr.pts = samples * 1000000 / job.rate;
                attr.flags = inputEnd ? AVCODEC_BUFFER_FLAGS_EOS : AVCODEC_BUFFER_FLAGS_NONE;
                Require(OH_AVBuffer_SetBufferAttr(event.buffer, &attr) == AV_ERR_OK &&
                    OH_AudioCodec_PushInputBuffer(codec, event.index) == AV_ERR_OK, "提交音频数据失败");
                samples += job.decode ? FRAME_SAMPLES : size / 2;
                consumed += size;
                job.progress = int(std::min<int64_t>(99, consumed * 100 / inputBytes));
            } else {
                OH_AVCodecBufferAttr attr{};
                Require(OH_AVBuffer_GetBufferAttr(event.buffer, &attr) == AV_ERR_OK &&
                    attr.size >= 0 && attr.offset >= 0 && int64_t(attr.offset) + attr.size <= capacity &&
                    (attr.size == 0 || address != nullptr),
                    "系统返回的音频数据无效");
                if (attr.size > 0 && (attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) == 0) {
                    written += attr.size;
                    const int64_t limit = job.decode ? job.expectedBytes - HEADER_BYTES + MAX_PADDING_BYTES : MAX_WAV_BYTES;
                    Require(written <= limit, "还原录音长度异常");
                    WriteExact(output.fd, address + attr.offset, attr.size);
                }
                outputEnd = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
                Require(OH_AudioCodec_FreeOutputBuffer(codec, event.index) == AV_ERR_OK, "释放音频缓冲区失败");
            }
        }
        Require(written > 0, "音频编码未产生内容");
        if (job.decode) {
            // Retain encoder priming/padding so a word at either end is never truncated.
            Require(written >= job.expectedBytes - HEADER_BYTES && written % 2 == 0 &&
                written + HEADER_BYTES <= MAX_WAV_BYTES, "还原录音不完整");
            const auto header = WavHeader(job.rate, written);
            Require(lseek(output.fd, 0, SEEK_SET) == 0, "保存录音头失败");
            WriteExact(output.fd, header.data(), header.size());
        }
        Require(fsync(output.fd) == 0, "保存音频失败");
        job.resultBytes = written + (job.decode ? HEADER_BYTES : 0);
    } catch (...) {
        if (started) { OH_AudioCodec_Stop(codec); }
        OH_AudioCodec_Destroy(codec);
        throw;
    }
    OH_AudioCodec_Stop(codec);
    OH_AudioCodec_Destroy(codec);
    job.progress = 100;
}

std::shared_ptr<Job> Unwrap(napi_env env, napi_callback_info info, size_t* count, napi_value* args)
{
    napi_value self = nullptr;
    std::shared_ptr<Job>* wrapped = nullptr;
    if (napi_get_cb_info(env, info, count, args, &self, nullptr) != napi_ok ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&wrapped)) != napi_ok || wrapped == nullptr) {
        napi_throw_error(env, nullptr, "音频处理任务无效");
        return nullptr;
    }
    return *wrapped;
}

bool StringArg(napi_env env, napi_value arg, std::string& value)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, arg, nullptr, 0, &length) != napi_ok || length == 0 || length > 4096) {
        return false;
    }
    value.resize(length + 1);
    if (napi_get_value_string_utf8(env, arg, value.data(), value.size(), &length) != napi_ok) { return false; }
    value.resize(length);
    return value.find('\0') == std::string::npos;
}

void Execute(napi_env, void* context)
{
    auto& job = **static_cast<std::shared_ptr<Job>*>(context);
    try { Transcode(job); }
    catch (const std::exception& error) { job.failure = error.what(); }
    catch (...) { job.failure = "音频编码失败"; }
    if (!job.failure.empty() && job.outputCreated) { unlink(job.output.c_str()); }
}

void Complete(napi_env env, napi_status status, void* context)
{
    std::unique_ptr<std::shared_ptr<Job>> owner(static_cast<std::shared_ptr<Job>*>(context));
    Job& job = **owner;
    if (status != napi_ok && job.failure.empty()) { job.failure = "音频任务已结束"; }
    napi_value value = nullptr;
    if (job.failure.empty()) {
        napi_create_int64(env, job.resultBytes, &value);
        napi_resolve_deferred(env, job.deferred, value);
    } else {
        napi_value message = nullptr;
        napi_create_string_utf8(env, job.failure.c_str(), NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &value);
        napi_reject_deferred(env, job.deferred, value);
    }
    napi_delete_async_work(env, job.work);
}

napi_value Run(napi_env env, napi_callback_info info)
{
    size_t count = 5;
    napi_value args[5]{};
    auto job = Unwrap(env, info, &count, args);
    if (!job) { return nullptr; }
    if (job->running.exchange(true) || count != 5 ||
        !StringArg(env, args[0], job->input) || !StringArg(env, args[1], job->output) ||
        job->input == job->output ||
        napi_get_value_bool(env, args[2], &job->decode) != napi_ok ||
        napi_get_value_int32(env, args[3], &job->rate) != napi_ok ||
        napi_get_value_int64(env, args[4], &job->expectedBytes) != napi_ok ||
        (job->rate != 16000 && job->rate != 48000) ||
        job->expectedBytes <= HEADER_BYTES || job->expectedBytes > MAX_WAV_BYTES) {
        napi_throw_error(env, nullptr, "音频任务参数无效或已执行");
        return nullptr;
    }
    napi_value promise = nullptr, name = nullptr;
    auto owner = std::make_unique<std::shared_ptr<Job>>(job);
    napi_create_string_utf8(env, "WatchAudioCodec", NAPI_AUTO_LENGTH, &name);
    if (napi_create_promise(env, &job->deferred, &promise) != napi_ok ||
        napi_create_async_work(env, nullptr, name, Execute, Complete, owner.get(), &job->work) != napi_ok ||
        napi_queue_async_work(env, job->work) != napi_ok) {
        if (job->work) { napi_delete_async_work(env, job->work); }
        napi_throw_error(env, nullptr, "无法启动音频任务");
        return nullptr;
    }
    owner.release();
    return promise;
}

napi_value Cancel(napi_env env, napi_callback_info info)
{
    size_t count = 0;
    auto job = Unwrap(env, info, &count, nullptr);
    if (!job) { return nullptr; }
    job->cancelled = true;
    job->wake.notify_all();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value Progress(napi_env env, napi_callback_info info)
{
    size_t count = 0;
    auto job = Unwrap(env, info, &count, nullptr);
    if (!job) { return nullptr; }
    napi_value result;
    napi_create_int32(env, job->progress.load(), &result);
    return result;
}

void Finalize(napi_env, void* data, void*)
{
    auto* job = static_cast<std::shared_ptr<Job>*>(data);
    (*job)->cancelled = true;
    (*job)->wake.notify_all();
    delete job;
}

napi_value Create(napi_env env, napi_callback_info)
{
    auto wrapped = std::make_unique<std::shared_ptr<Job>>(std::make_shared<Job>());
    napi_value object = nullptr;
    const napi_property_descriptor methods[] = {
        {"run", nullptr, Run, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"progress", nullptr, Progress, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    if (napi_create_object(env, &object) != napi_ok ||
        napi_define_properties(env, object, 3, methods) != napi_ok ||
        napi_wrap(env, object, wrapped.get(), Finalize, nullptr, nullptr) != napi_ok) {
        napi_throw_error(env, nullptr, "无法创建音频任务");
        return nullptr;
    }
    wrapped.release();
    return object;
}

napi_value Init(napi_env env, napi_value exports)
{
    const napi_property_descriptor method = {
        "createAudioCodecJob", nullptr, Create, nullptr, nullptr, nullptr, napi_default, nullptr
    };
    napi_define_properties(env, exports, 1, &method);
    return exports;
}
} // namespace

static napi_module module = {1, 0, nullptr, Init, "watchaudio", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterWatchAudioCodec()
{
    napi_module_register(&module);
}
