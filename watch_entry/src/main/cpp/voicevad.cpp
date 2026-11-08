#include <cstdint>
#include <new>
#include "napi/native_api.h"
#include "webrtc/common_audio/vad/include/webrtc_vad.h"

namespace {
struct Detector {
    VadInst* vad = nullptr;
    int sampleRate = 16000;
};

void Finalize(napi_env, void* data, void*)
{
    auto* detector = static_cast<Detector*>(data);
    if (detector->vad != nullptr) { WebRtcVad_Free(detector->vad); }
    delete detector;
}

napi_value Fail(napi_env env, const char* message)
{
    napi_throw_error(env, nullptr, message);
    return nullptr;
}

napi_value Process(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_value receiver = nullptr;
    Detector* detector = nullptr;
    if (napi_get_cb_info(env, info, &argc, argv, &receiver, nullptr) != napi_ok ||
        napi_unwrap(env, receiver, reinterpret_cast<void**>(&detector)) != napi_ok ||
        detector == nullptr || detector->vad == nullptr) {
        return Fail(env, "人声检测器已关闭或不可用");
    }
    void* pcm = nullptr;
    size_t bytes = 0;
    if (argc != 1 || napi_get_arraybuffer_info(env, argv[0], &pcm, &bytes) != napi_ok ||
        bytes != static_cast<size_t>(detector->sampleRate / 50 * sizeof(int16_t))) {
        return Fail(env, "人声检测需要完整的 20 ms PCM 帧");
    }
    const int result = WebRtcVad_Process(detector->vad, detector->sampleRate,
        static_cast<const int16_t*>(pcm), bytes / sizeof(int16_t));
    if (result < 0) { return Fail(env, "人声检测失败，采集已停止"); }
    napi_value value = nullptr;
    napi_get_boolean(env, result != 0, &value);
    return value;
}

napi_value Close(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    napi_value receiver = nullptr;
    Detector* detector = nullptr;
    if (napi_get_cb_info(env, info, &argc, nullptr, &receiver, nullptr) != napi_ok ||
        napi_unwrap(env, receiver, reinterpret_cast<void**>(&detector)) != napi_ok || detector == nullptr) {
        return Fail(env, "无效的人声检测器");
    }
    if (detector->vad != nullptr) {
        WebRtcVad_Free(detector->vad);
        detector->vad = nullptr;
    }
    napi_value value = nullptr;
    napi_get_undefined(env, &value);
    return value;
}

napi_value Create(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    int32_t rate = 0;
    int32_t mode = -1;
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc != 2 ||
        napi_get_value_int32(env, argv[0], &rate) != napi_ok ||
        napi_get_value_int32(env, argv[1], &mode) != napi_ok ||
        (rate != 16000 && rate != 48000) || mode < 0 || mode > 3) {
        return Fail(env, "无效的人声检测配置");
    }
    auto* detector = new (std::nothrow) Detector();
    if (detector == nullptr) { return Fail(env, "人声检测内存不足"); }
    detector->vad = WebRtcVad_Create();
    detector->sampleRate = rate;
    if (detector->vad == nullptr || WebRtcVad_Init(detector->vad) != 0 ||
        WebRtcVad_set_mode(detector->vad, mode) != 0) {
        Finalize(env, detector, nullptr);
        return Fail(env, "无法初始化人声检测器");
    }
    napi_value object = nullptr;
    napi_property_descriptor methods[] = {
        {"process", nullptr, Process, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"close", nullptr, Close, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    if (napi_create_object(env, &object) != napi_ok ||
        napi_define_properties(env, object, 2, methods) != napi_ok ||
        napi_wrap(env, object, detector, Finalize, nullptr, nullptr) != napi_ok) {
        Finalize(env, detector, nullptr);
        return Fail(env, "无法创建人声检测器");
    }
    return object;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor method = {
        "createDetector", nullptr, Create, nullptr, nullptr, nullptr, napi_default, nullptr
    };
    napi_define_properties(env, exports, 1, &method);
    return exports;
}
} // namespace

static napi_module module = {1, 0, nullptr, Init, "voicevad", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterVoiceVad()
{
    napi_module_register(&module);
}
