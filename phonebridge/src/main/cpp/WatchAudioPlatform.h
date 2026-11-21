#pragma once
#include <dlfcn.h>
#include <stdexcept>
#include "multimedia/player_framework/native_avbuffer.h"
#include "multimedia/player_framework/native_avcodec_audiocodec.h"
#include "multimedia/player_framework/native_avformat.h"

namespace {
// Optional codec capabilities must not prevent the recording application from loading.
struct MediaLibrary {
    void* handle;
    explicit MediaLibrary(const char* name) : handle(dlopen(name, RTLD_NOW | RTLD_LOCAL))
    {
        if (!handle) { throw std::runtime_error("当前设备未提供系统音频编码器"); }
    }
    ~MediaLibrary() { dlclose(handle); }
};

struct MediaApi {
    MediaLibrary core{"libnative_media_core.so"};
    MediaLibrary base{"libnative_media_codecbase.so"};
    MediaLibrary audio{"libnative_media_acodec.so"};
    decltype(&::OH_AVFormat_Create) OH_AVFormat_Create = nullptr;
    decltype(&::OH_AVFormat_Destroy) OH_AVFormat_Destroy = nullptr;
    decltype(&::OH_AVFormat_SetIntValue) OH_AVFormat_SetIntValue = nullptr;
    decltype(&::OH_AVFormat_SetLongValue) OH_AVFormat_SetLongValue = nullptr;
    decltype(&::OH_AVFormat_GetIntValue) OH_AVFormat_GetIntValue = nullptr;
    decltype(&::OH_AudioCodec_CreateByMime) OH_AudioCodec_CreateByMime = nullptr;
    decltype(&::OH_AudioCodec_RegisterCallback) OH_AudioCodec_RegisterCallback = nullptr;
    decltype(&::OH_AudioCodec_Configure) OH_AudioCodec_Configure = nullptr;
    decltype(&::OH_AudioCodec_Prepare) OH_AudioCodec_Prepare = nullptr;
    decltype(&::OH_AudioCodec_Start) OH_AudioCodec_Start = nullptr;
    decltype(&::OH_AudioCodec_Stop) OH_AudioCodec_Stop = nullptr;
    decltype(&::OH_AudioCodec_Destroy) OH_AudioCodec_Destroy = nullptr;
    decltype(&::OH_AudioCodec_PushInputBuffer) OH_AudioCodec_PushInputBuffer = nullptr;
    decltype(&::OH_AudioCodec_FreeOutputBuffer) OH_AudioCodec_FreeOutputBuffer = nullptr;
    decltype(&::OH_AVBuffer_GetAddr) OH_AVBuffer_GetAddr = nullptr;
    decltype(&::OH_AVBuffer_GetCapacity) OH_AVBuffer_GetCapacity = nullptr;
    decltype(&::OH_AVBuffer_GetBufferAttr) OH_AVBuffer_GetBufferAttr = nullptr;
    decltype(&::OH_AVBuffer_SetBufferAttr) OH_AVBuffer_SetBufferAttr = nullptr;
    const char** OH_MD_KEY_AUD_SAMPLE_RATE = nullptr;
    const char** OH_MD_KEY_AUD_CHANNEL_COUNT = nullptr;
    const char** OH_MD_KEY_AUDIO_SAMPLE_FORMAT = nullptr;
    const char** OH_MD_KEY_AAC_IS_ADTS = nullptr;
    const char** OH_MD_KEY_BITRATE = nullptr;
    const char** OH_MD_KEY_PROFILE = nullptr;

    MediaApi()
    {
        OH_AVFormat_Create = reinterpret_cast<decltype(OH_AVFormat_Create)>(dlsym(core.handle, "OH_AVFormat_Create"));
        OH_AVFormat_Destroy = reinterpret_cast<decltype(OH_AVFormat_Destroy)>(dlsym(core.handle, "OH_AVFormat_Destroy"));
        OH_AVFormat_SetIntValue = reinterpret_cast<decltype(OH_AVFormat_SetIntValue)>(dlsym(core.handle, "OH_AVFormat_SetIntValue"));
        OH_AVFormat_SetLongValue = reinterpret_cast<decltype(OH_AVFormat_SetLongValue)>(dlsym(core.handle, "OH_AVFormat_SetLongValue"));
        OH_AVFormat_GetIntValue = reinterpret_cast<decltype(OH_AVFormat_GetIntValue)>(dlsym(core.handle, "OH_AVFormat_GetIntValue"));
        OH_AudioCodec_CreateByMime = reinterpret_cast<decltype(OH_AudioCodec_CreateByMime)>(dlsym(audio.handle, "OH_AudioCodec_CreateByMime"));
        OH_AudioCodec_RegisterCallback = reinterpret_cast<decltype(OH_AudioCodec_RegisterCallback)>(dlsym(audio.handle, "OH_AudioCodec_RegisterCallback"));
        OH_AudioCodec_Configure = reinterpret_cast<decltype(OH_AudioCodec_Configure)>(dlsym(audio.handle, "OH_AudioCodec_Configure"));
        OH_AudioCodec_Prepare = reinterpret_cast<decltype(OH_AudioCodec_Prepare)>(dlsym(audio.handle, "OH_AudioCodec_Prepare"));
        OH_AudioCodec_Start = reinterpret_cast<decltype(OH_AudioCodec_Start)>(dlsym(audio.handle, "OH_AudioCodec_Start"));
        OH_AudioCodec_Stop = reinterpret_cast<decltype(OH_AudioCodec_Stop)>(dlsym(audio.handle, "OH_AudioCodec_Stop"));
        OH_AudioCodec_Destroy = reinterpret_cast<decltype(OH_AudioCodec_Destroy)>(dlsym(audio.handle, "OH_AudioCodec_Destroy"));
        OH_AudioCodec_PushInputBuffer = reinterpret_cast<decltype(OH_AudioCodec_PushInputBuffer)>(dlsym(audio.handle, "OH_AudioCodec_PushInputBuffer"));
        OH_AudioCodec_FreeOutputBuffer = reinterpret_cast<decltype(OH_AudioCodec_FreeOutputBuffer)>(dlsym(audio.handle, "OH_AudioCodec_FreeOutputBuffer"));
        OH_AVBuffer_GetAddr = reinterpret_cast<decltype(OH_AVBuffer_GetAddr)>(dlsym(core.handle, "OH_AVBuffer_GetAddr"));
        OH_AVBuffer_GetCapacity = reinterpret_cast<decltype(OH_AVBuffer_GetCapacity)>(dlsym(core.handle, "OH_AVBuffer_GetCapacity"));
        OH_AVBuffer_GetBufferAttr = reinterpret_cast<decltype(OH_AVBuffer_GetBufferAttr)>(dlsym(core.handle, "OH_AVBuffer_GetBufferAttr"));
        OH_AVBuffer_SetBufferAttr = reinterpret_cast<decltype(OH_AVBuffer_SetBufferAttr)>(dlsym(core.handle, "OH_AVBuffer_SetBufferAttr"));
        OH_MD_KEY_AUD_SAMPLE_RATE = reinterpret_cast<const char**>(dlsym(base.handle, "OH_MD_KEY_AUD_SAMPLE_RATE"));
        OH_MD_KEY_AUD_CHANNEL_COUNT = reinterpret_cast<const char**>(dlsym(base.handle, "OH_MD_KEY_AUD_CHANNEL_COUNT"));
        OH_MD_KEY_AUDIO_SAMPLE_FORMAT = reinterpret_cast<const char**>(dlsym(base.handle, "OH_MD_KEY_AUDIO_SAMPLE_FORMAT"));
        OH_MD_KEY_AAC_IS_ADTS = reinterpret_cast<const char**>(dlsym(base.handle, "OH_MD_KEY_AAC_IS_ADTS"));
        OH_MD_KEY_BITRATE = reinterpret_cast<const char**>(dlsym(base.handle, "OH_MD_KEY_BITRATE"));
        OH_MD_KEY_PROFILE = reinterpret_cast<const char**>(dlsym(base.handle, "OH_MD_KEY_PROFILE"));
        if (
            !OH_AVFormat_Create ||
            !OH_AVFormat_Destroy ||
            !OH_AVFormat_SetIntValue ||
            !OH_AVFormat_SetLongValue ||
            !OH_AVFormat_GetIntValue ||
            !OH_AudioCodec_CreateByMime ||
            !OH_AudioCodec_RegisterCallback ||
            !OH_AudioCodec_Configure ||
            !OH_AudioCodec_Prepare ||
            !OH_AudioCodec_Start ||
            !OH_AudioCodec_Stop ||
            !OH_AudioCodec_Destroy ||
            !OH_AudioCodec_PushInputBuffer ||
            !OH_AudioCodec_FreeOutputBuffer ||
            !OH_AVBuffer_GetAddr ||
            !OH_AVBuffer_GetCapacity ||
            !OH_AVBuffer_GetBufferAttr ||
            !OH_AVBuffer_SetBufferAttr ||
            !OH_MD_KEY_AUD_SAMPLE_RATE || !*OH_MD_KEY_AUD_SAMPLE_RATE ||
            !OH_MD_KEY_AUD_CHANNEL_COUNT || !*OH_MD_KEY_AUD_CHANNEL_COUNT ||
            !OH_MD_KEY_AUDIO_SAMPLE_FORMAT || !*OH_MD_KEY_AUDIO_SAMPLE_FORMAT ||
            !OH_MD_KEY_AAC_IS_ADTS || !*OH_MD_KEY_AAC_IS_ADTS ||
            !OH_MD_KEY_BITRATE || !*OH_MD_KEY_BITRATE ||
            !OH_MD_KEY_PROFILE || !*OH_MD_KEY_PROFILE) {
            throw std::runtime_error("系统音频编码接口不可用");
        }
    }
};

inline MediaApi& AudioApi()
{
    static MediaApi api;
    return api;
}
} // namespace

#define OH_AVFormat_Create AudioApi().OH_AVFormat_Create
#define OH_AVFormat_Destroy AudioApi().OH_AVFormat_Destroy
#define OH_AVFormat_SetIntValue AudioApi().OH_AVFormat_SetIntValue
#define OH_AVFormat_SetLongValue AudioApi().OH_AVFormat_SetLongValue
#define OH_AVFormat_GetIntValue AudioApi().OH_AVFormat_GetIntValue
#define OH_AudioCodec_CreateByMime AudioApi().OH_AudioCodec_CreateByMime
#define OH_AudioCodec_RegisterCallback AudioApi().OH_AudioCodec_RegisterCallback
#define OH_AudioCodec_Configure AudioApi().OH_AudioCodec_Configure
#define OH_AudioCodec_Prepare AudioApi().OH_AudioCodec_Prepare
#define OH_AudioCodec_Start AudioApi().OH_AudioCodec_Start
#define OH_AudioCodec_Stop AudioApi().OH_AudioCodec_Stop
#define OH_AudioCodec_Destroy AudioApi().OH_AudioCodec_Destroy
#define OH_AudioCodec_PushInputBuffer AudioApi().OH_AudioCodec_PushInputBuffer
#define OH_AudioCodec_FreeOutputBuffer AudioApi().OH_AudioCodec_FreeOutputBuffer
#define OH_AVBuffer_GetAddr AudioApi().OH_AVBuffer_GetAddr
#define OH_AVBuffer_GetCapacity AudioApi().OH_AVBuffer_GetCapacity
#define OH_AVBuffer_GetBufferAttr AudioApi().OH_AVBuffer_GetBufferAttr
#define OH_AVBuffer_SetBufferAttr AudioApi().OH_AVBuffer_SetBufferAttr
#define OH_MD_KEY_AUD_SAMPLE_RATE (*AudioApi().OH_MD_KEY_AUD_SAMPLE_RATE)
#define OH_MD_KEY_AUD_CHANNEL_COUNT (*AudioApi().OH_MD_KEY_AUD_CHANNEL_COUNT)
#define OH_MD_KEY_AUDIO_SAMPLE_FORMAT (*AudioApi().OH_MD_KEY_AUDIO_SAMPLE_FORMAT)
#define OH_MD_KEY_AAC_IS_ADTS (*AudioApi().OH_MD_KEY_AAC_IS_ADTS)
#define OH_MD_KEY_BITRATE (*AudioApi().OH_MD_KEY_BITRATE)
#define OH_MD_KEY_PROFILE (*AudioApi().OH_MD_KEY_PROFILE)
