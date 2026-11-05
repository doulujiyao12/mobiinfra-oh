#include "RecordingScreenCapture.h"
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {
int64_t MonotonicNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
struct Frame { bool mic; double timestampMs; double receivedMs; std::vector<uint8_t> data; };
// Audio only: video dimensions stay zero. Never bypass the system picker,
// suppress its indicator, or enable call/private-content capture strategies.
struct Session {
    std::atomic<int> references{1};
    std::mutex mutex, apiMutex;
    std::condition_variable changed;
    OH_AVScreenCapture *capture = nullptr;
    std::deque<Frame> frames;
    size_t queuedBytes = 0;
    uint64_t generation = 0;
    int64_t startedNs = 0, endedNs = 0;
    bool started = false, terminal = false, stopRequested = false, starting = false, stopping = false, mixed = false, stopScheduled = false;
    std::string error;
    void Retain() { ++references; }
    void Release() { if (--references == 0) delete this; }
    void End(OH_AVScreenCapture *expected = nullptr, uint64_t expectedGeneration = 0) {
        std::lock_guard<std::mutex> api(apiMutex);
        OH_AVScreenCapture *old;
        { std::lock_guard<std::mutex> lock(mutex);
          if (expected && (capture != expected || generation != expectedGeneration)) return;
          old = capture; capture = nullptr; terminal = true;
          if (startedNs && !endedNs) endedNs = MonotonicNs(); }
        if (old) { OH_AVScreenCapture_StopScreenCapture(old); OH_AVScreenCapture_Release(old); }
    }
    // Stop/Release cannot run inside an SDK callback. Retain the session until
    // cleanup finishes even if the UI timer is suspended. An old callback must
    // never stop a subsequent recording using the same session.
    void EndLater(OH_AVScreenCapture *expected) {
        if (stopScheduled) return;
        stopScheduled = true; Retain();
        const uint64_t epoch = generation;
        try { std::thread([this, expected, epoch] { End(expected, epoch); Release(); }).detach(); }
        catch (...) { Release(); }
    }
};
void ErrorCallback(OH_AVScreenCapture *capture, int32_t code, void *data) {
    auto &s = *static_cast<Session *>(data);
    std::lock_guard<std::mutex> lock(s.mutex);
    if (s.capture != capture) return;
    s.error = "SYSTEM_AUDIO_ERROR:" + std::to_string(code); s.terminal = true; s.changed.notify_all(); s.EndLater(capture);
}
void StateCallback(OH_AVScreenCapture *capture, OH_AVScreenCaptureStateCode state, void *data) {
    auto &s = *static_cast<Session *>(data);
    std::lock_guard<std::mutex> lock(s.mutex);
    if (s.capture != capture) return;
    if (state == OH_SCREEN_CAPTURE_STATE_STARTED) {
        s.started = true;
        if (!s.startedNs) s.startedNs = MonotonicNs();
    }
    else if (state == OH_SCREEN_CAPTURE_STATE_CANCELED) { s.error = "SYSTEM_AUDIO_CANCELLED"; s.terminal = true; }
    else if (state == OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER || state == OH_SCREEN_CAPTURE_STATE_INTERRUPTED_BY_OTHER ||
        state == OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL || state == OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER_SWITCHES) s.terminal = true;
    else if (state == OH_SCREEN_CAPTURE_STATE_ENTER_PRIVATE_SCENE) {
        s.error = "SYSTEM_AUDIO_PROTECTED"; s.terminal = true;
    } else if (s.mixed && (state == OH_SCREEN_CAPTURE_STATE_MIC_UNAVAILABLE || state == OH_SCREEN_CAPTURE_STATE_MIC_MUTED_BY_USER)) {
        s.error = "SYSTEM_AUDIO_MIC_UNAVAILABLE"; s.terminal = true;
    }
    s.changed.notify_all();
    if (s.terminal) s.EndLater(capture);
}
void DataCallback(OH_AVScreenCapture *capture, OH_AVBuffer *buffer, OH_AVScreenCaptureBufferType type,
    int64_t timestamp, void *data) {
    if (type != OH_SCREEN_CAPTURE_BUFFERTYPE_AUDIO_INNER && type != OH_SCREEN_CAPTURE_BUFFERTYPE_AUDIO_MIC) return;
    auto &s = *static_cast<Session *>(data);
    std::lock_guard<std::mutex> lock(s.mutex);
    if (s.capture != capture || s.terminal || s.stopRequested) return;
    OH_AVCodecBufferAttr attr{};
    auto *address = OH_AVBuffer_GetAddr(buffer);
    const int32_t capacity = OH_AVBuffer_GetCapacity(buffer);
    if (!address || OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK || attr.offset < 0 || attr.size < 0 ||
        attr.size % 2 != 0 || attr.offset > capacity || attr.size > capacity - attr.offset || timestamp < 0) {
        s.error = "SYSTEM_AUDIO_INVALID_BUFFER"; s.terminal = true; s.changed.notify_all(); s.EndLater(capture); return;
    }
    if (!attr.size) return;
    // Four seconds of two 16kHz mono PCM16 streams. Never grow without bound
    // or silently discard audio when the application cannot drain fast enough.
    if (s.queuedBytes + static_cast<size_t>(attr.size) > 256000) {
        s.error = "SYSTEM_AUDIO_BUFFER_OVERFLOW"; s.terminal = true; s.changed.notify_all(); s.EndLater(capture); return;
    }
    const int64_t receivedNs = MonotonicNs();
    if (!s.startedNs) s.startedNs = receivedNs;
    Frame frame{type == OH_SCREEN_CAPTURE_BUFFERTYPE_AUDIO_MIC, timestamp / 1000000.0,
        (receivedNs - s.startedNs) / 1000000.0, {}};
    frame.data.assign(address + attr.offset, address + attr.offset + attr.size);
    s.queuedBytes += frame.data.size(); s.frames.push_back(std::move(frame));
}
napi_value Undefined(napi_env env) { napi_value result; napi_get_undefined(env, &result); return result; }
void Property(napi_env env, napi_value object, const char *key, napi_value value) { napi_set_named_property(env, object, key, value); }
napi_value Batch(napi_env env, Session &s) {
    std::lock_guard<std::mutex> lock(s.mutex);
    napi_value result, array, value; napi_create_object(env, &result); napi_create_array_with_length(env, s.frames.size(), &array);
    uint32_t index = 0;
    for (auto &frame : s.frames) {
        napi_value item, bytes; void *destination = nullptr; napi_create_object(env, &item);
        napi_create_arraybuffer(env, frame.data.size(), &destination, &bytes);
        if (!destination) { napi_throw_error(env, nullptr, "SYSTEM_AUDIO_MEMORY"); return Undefined(env); }
        std::memcpy(destination, frame.data.data(), frame.data.size());
        Property(env, item, "data", bytes); napi_get_boolean(env, frame.mic, &value); Property(env, item, "mic", value);
        napi_create_double(env, frame.timestampMs, &value); Property(env, item, "timestampMs", value);
        napi_create_double(env, frame.receivedMs, &value); Property(env, item, "receivedMs", value);
        napi_set_element(env, array, index++, item);
    }
    s.frames.clear(); s.queuedBytes = 0;
    const double elapsedMs = s.startedNs ? ((s.endedNs ? s.endedNs : MonotonicNs()) - s.startedNs) / 1000000.0 : 0;
    napi_create_double(env, elapsedMs, &value); Property(env, result, "elapsedMs", value);
    Property(env, result, "frames", array); napi_get_boolean(env, s.terminal, &value); Property(env, result, "stopped", value);
    napi_create_string_utf8(env, s.error.c_str(), s.error.size(), &value); Property(env, result, "error", value); return result;
}
struct Work { napi_env env; napi_async_work work; napi_deferred deferred; Session *session; bool stop; std::string error; };
void Execute(napi_env, void *data) {
    auto &w = *static_cast<Work *>(data); auto &s = *w.session;
    if (w.stop) { s.End(); return; }
    {
        std::lock_guard<std::mutex> api(s.apiMutex);
        { std::lock_guard<std::mutex> lock(s.mutex);
          if (s.stopRequested) { w.error = "SYSTEM_AUDIO_CANCELLED"; return; } }
        OH_AVScreenCapture *capture = OH_AVScreenCapture_Create();
        { std::lock_guard<std::mutex> lock(s.mutex); s.capture = capture; }
        if (!capture) { w.error = "SYSTEM_AUDIO_CREATE"; return; }
        OH_AVScreenCaptureConfig config{};
        config.captureMode = OH_CAPTURE_HOME_SCREEN; config.dataType = OH_ORIGINAL_STREAM;
        config.audioInfo.innerCapInfo = {16000, 1, OH_ALL_PLAYBACK};
        if (s.mixed) config.audioInfo.micCapInfo = {16000, 1, OH_MIC};
        config.videoInfo.videoCapInfo.videoFrameWidth = 0; config.videoInfo.videoCapInfo.videoFrameHeight = 0;
        config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
        int code = OH_AVScreenCapture_SetStateCallback(capture, StateCallback, &s);
        if (!code) code = OH_AVScreenCapture_SetErrorCallback(capture, ErrorCallback, &s);
        if (!code) code = OH_AVScreenCapture_SetDataCallback(capture, DataCallback, &s);
        if (!code) code = OH_AVScreenCapture_SetMicrophoneEnabled(capture, s.mixed);
        if (!code) code = OH_AVScreenCapture_Init(capture, config);
        if (!code) code = OH_AVScreenCapture_StartScreenCapture(capture);
        if (code) w.error = "SYSTEM_AUDIO_START:" + std::to_string(code);
    }
    if (w.error.empty()) {
        std::unique_lock<std::mutex> lock(s.mutex);
        if (!s.changed.wait_for(lock, std::chrono::seconds(90), [&s] { return s.started || s.terminal || s.stopRequested; }))
            w.error = "SYSTEM_AUDIO_AUTH_TIMEOUT";
        else if (!s.started || s.terminal || s.stopRequested) w.error = s.error.empty() ? "SYSTEM_AUDIO_CANCELLED" : s.error;
    }
    if (!w.error.empty()) s.End();
}
void Complete(napi_env env, napi_status status, void *data) {
    auto *w = static_cast<Work *>(data);
    { std::lock_guard<std::mutex> lock(w->session->mutex);
      if (!w->stop) w->session->starting = false; else w->session->stopping = false; }
    if (status != napi_ok && w->error.empty()) w->error = "SYSTEM_AUDIO_WORKER";
    if (!w->error.empty()) {
        napi_value message, error; napi_create_string_utf8(env, w->error.c_str(), w->error.size(), &message);
        napi_create_error(env, nullptr, message, &error); napi_reject_deferred(env, w->deferred, error);
    } else napi_resolve_deferred(env, w->deferred, w->stop ? Batch(env, *w->session) : Undefined(env));
    napi_delete_async_work(env, w->work); w->session->Release(); delete w;
}
napi_value Queue(napi_env env, Session *s, bool stop) {
    auto *w = new Work{env, nullptr, nullptr, s, stop, {}};
    s->Retain();
    napi_value promise, label; napi_create_promise(env, &w->deferred, &promise);
    napi_create_string_utf8(env, "RecordingScreenCapture", NAPI_AUTO_LENGTH, &label);
    if (napi_create_async_work(env, nullptr, label, Execute, Complete, w, &w->work) != napi_ok ||
        napi_queue_async_work(env, w->work) != napi_ok) {
        { std::lock_guard<std::mutex> lock(s->mutex); if (stop) s->stopping = false; else s->starting = false; }
        napi_value message, error; napi_create_string_utf8(env, "SYSTEM_AUDIO_WORKER", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error); napi_reject_deferred(env, w->deferred, error);
        if (stop) s->End();
        if (w->work) napi_delete_async_work(env, w->work); s->Release(); delete w;
    }
    return promise;
}
napi_value Start(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1]; void *data; bool mixed = false;
    napi_get_cb_info(env, info, &argc, args, nullptr, &data); auto *s = static_cast<Session *>(data);
    if (argc != 1 || napi_get_value_bool(env, args[0], &mixed) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Expected microphone flag"); return Undefined(env);
    }
    { std::lock_guard<std::mutex> lock(s->mutex);
      if (s->capture || s->starting || s->stopping) { napi_throw_error(env, nullptr, "SYSTEM_AUDIO_BUSY"); return Undefined(env); }
      ++s->generation; s->starting = true; s->started = false; s->terminal = false; s->stopRequested = false; s->mixed = mixed;
      s->error.clear(); s->frames.clear(); s->queuedBytes = 0; s->stopScheduled = false;
      s->startedNs = 0; s->endedNs = 0; }
    return Queue(env, s, false);
}
napi_value Read(napi_env env, napi_callback_info info) {
    size_t argc = 0; void *data; napi_get_cb_info(env, info, &argc, nullptr, nullptr, &data);
    return Batch(env, *static_cast<Session *>(data));
}
napi_value Stop(napi_env env, napi_callback_info info) {
    size_t argc = 0; void *data; napi_get_cb_info(env, info, &argc, nullptr, nullptr, &data); auto *s = static_cast<Session *>(data);
    { std::lock_guard<std::mutex> lock(s->mutex); s->stopRequested = true; s->stopping = true; s->changed.notify_all(); }
    return Queue(env, s, true);
}
} // namespace
void RegisterRecordingScreenCapture(napi_env env, napi_value exports) {
    auto *session = new Session();
    napi_property_descriptor props[] = {
        {"startRecordingScreen", nullptr, Start, nullptr, nullptr, nullptr, napi_default, session},
        {"readRecordingScreen", nullptr, Read, nullptr, nullptr, nullptr, napi_default, session},
        {"stopRecordingScreen", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, session},
    };
    napi_define_properties(env, exports, sizeof(props) / sizeof(props[0]), props);
    napi_add_env_cleanup_hook(env, [](void *data) { auto *s = static_cast<Session *>(data);
        { std::lock_guard<std::mutex> lock(s->mutex); s->stopRequested = true; s->changed.notify_all(); }
        s->End(); s->Release();
    }, session);
}
