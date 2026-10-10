#include <napi/native_api.h>

static napi_value MakeString(napi_env env, const char* value) {
    napi_value ret;
    napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &ret);
    return ret;
}

static napi_value MakeResolvedPromise(napi_env env, const char* value) {
    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);
    napi_resolve_deferred(env, deferred, MakeString(env, value));
    return promise;
}

static napi_value Disabled(napi_env env, napi_callback_info) {
    return MakeString(env, "disabled: local MNN is not available on x86_64 cloud-ui build");
}

static napi_value DisabledAsync(napi_env env, napi_callback_info) {
    return MakeResolvedPromise(env, "disabled: local MNN is not available on x86_64 cloud-ui build");
}

static napi_value Ok(napi_env env, napi_callback_info) {
    return MakeString(env, "ok");
}

static napi_value Empty(napi_env env, napi_callback_info) {
    return MakeString(env, "");
}

static napi_value False(napi_env env, napi_callback_info) {
    napi_value value;
    napi_get_boolean(env, false, &value);
    return value;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"prepareCustomOpp", nullptr, Disabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"copyModel", nullptr, Disabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadModel", nullptr, DisabledAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"generate", nullptr, DisabledAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"chat", nullptr, DisabledAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelChat", nullptr, Disabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isChatRunning", nullptr, False, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"restoreChatHistory", nullptr, Ok, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reset", nullptr, Ok, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"unloadModel", nullptr, Ok, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"agentPrefill", nullptr, DisabledAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"agentStep", nullptr, DisabledAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"agentReset", nullptr, DisabledAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"opTest", nullptr, DisabledAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"omcTest", nullptr, DisabledAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setConvMode", nullptr, Ok, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setConvQuant", nullptr, Ok, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setInt8XScale", nullptr, Ok, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setCpuPrecision", nullptr, Ok, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setCpuMemory", nullptr, Ok, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initLogFile", nullptr, Ok, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getLogs", nullptr, Empty, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearLogs", nullptr, Ok, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterModule(void) {
    napi_module_register(&module);
}
