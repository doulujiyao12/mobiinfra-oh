


#include <napi/native_api.h>
#include <hilog/log.h>
#include <string>
#include <sstream>
#include <mutex>
#include <cstdlib>
#include <unistd.h>
#include <fcntl.h>
#include <thread>
#include <deque>
#include <atomic>
#include <cstdarg>
#include <algorithm>
#include <cctype>
#include <dirent.h>
#include <fstream>
#include <limits>
#include <sys/stat.h>
#include <vector>
#include <errno.h>

#include "llm/llm.hpp"
#include "rawfile/raw_dir.h"
#include "rawfile/raw_file.h"
#include "rawfile/raw_file_manager.h"

#include <MNN/expr/Expr.hpp>
#include <MNN/expr/ExprCreator.hpp>
#include <MNN/expr/NeuralNetWorkOp.hpp>
#include <MNN/expr/Executor.hpp>
#include <MNN/expr/ExecutorScope.hpp>
#include <MNN/expr/Module.hpp>
#include <MNN/Interpreter.hpp>
#include <MNN/MNNForwardType.h>
#include <cmath>
#include <chrono>

#ifdef LOG_TAG
#undef LOG_TAG
#endif
#define LOG_TAG "MnnLlm"
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

using namespace MNN::Transformer;

static std::unique_ptr<Llm> g_llm = nullptr;
static std::mutex g_mutex;
static ChatMessages g_messages;
static std::string g_runtimeSandboxDir;

// ==================== Runtime log capture ====================
namespace {
struct LogCapture {
    std::mutex mu;
    std::deque<std::string> ring;
    size_t maxLines = 4000;
    FILE* file = nullptr;
    std::string filePath;
    std::atomic<bool> started{false};
    int origStdout = -1;
    int origStderr = -1;

    void append(const std::string& line) {
        std::lock_guard<std::mutex> g(mu);
        ring.push_back(line);
        if (ring.size() > maxLines) ring.pop_front();
        if (file) {
            fputs(line.c_str(), file);
            fputc('\n', file);
            fflush(file);
        }
    }
};
static LogCapture gLog;

static void logReader(int readFd) {
    char buf[4096];
    std::string pending;
    while (true) {
        ssize_t n = read(readFd, buf, sizeof(buf));
        if (n <= 0) break;
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, "MnnLlmCap", "%.*s", (int)n, buf);
        pending.append(buf, n);
        size_t pos;
        while ((pos = pending.find('\n')) != std::string::npos) {
            std::string line = pending.substr(0, pos);
            pending.erase(0, pos + 1);
            if (!line.empty()) gLog.append(line);
        }
    }
}

static void initLogCapture(const std::string& path) {
    bool expected = false;
    if (!gLog.started.compare_exchange_strong(expected, true)) return;
    gLog.filePath = path;

    // Load previous session's log into ring buffer (survives crash/restart)
    FILE* rf = fopen(path.c_str(), "r");
    if (rf) {
        char linebuf[2048];
        while (fgets(linebuf, sizeof(linebuf), rf)) {
            std::string line(linebuf);
            if (!line.empty() && line.back() == '\n') line.pop_back();
            if (!line.empty()) gLog.append(line);
        }
        fclose(rf);
    }

    gLog.file = fopen(path.c_str(), "a");

    // Also redirect stdout/stderr for any printf-based logging
    int pipefd[2];
    if (pipe(pipefd) == 0) {
        gLog.origStdout = dup(STDOUT_FILENO);
        gLog.origStderr = dup(STDERR_FILENO);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[1]);
        setvbuf(stdout, nullptr, _IOLBF, 0);
        setvbuf(stderr, nullptr, _IOLBF, 0);
        std::thread(logReader, pipefd[0]).detach();
    }
    gLog.append("==== session started ====");
}

static napi_value InitLogFile(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char path[1024] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], path, sizeof(path), &len);
    initLogCapture(std::string(path, len));
    napi_value ret;
    napi_create_string_utf8(env, "ok", 2, &ret);
    return ret;
}

static napi_value GetLogs(napi_env env, napi_callback_info) {
    std::string all;
    {
        std::lock_guard<std::mutex> g(gLog.mu);
        all.reserve(gLog.ring.size() * 80);
        for (auto& l : gLog.ring) {
            all += l;
            all += '\n';
        }
    }
    napi_value ret;
    napi_create_string_utf8(env, all.c_str(), all.size(), &ret);
    return ret;
}

static napi_value ClearLogs(napi_env env, napi_callback_info) {
    {
        std::lock_guard<std::mutex> g(gLog.mu);
        gLog.ring.clear();
        if (gLog.file) {
            fclose(gLog.file);
            gLog.file = fopen(gLog.filePath.c_str(), "w");
        }
    }
    napi_value ret;
    napi_create_string_utf8(env, "ok", 2, &ret);
    return ret;
}
} // anonymous namespace

// Strip HiLog privacy annotations (%{public}d -> %d) so vsnprintf can parse cleanly
static std::string stripHiLogFmt(const char* fmt) {
    std::string out;
    for (const char* p = fmt; *p; ++p) {
        if (*p == '%' && *(p + 1) == '{') {
            out += '%';
            p += 2;
            while (*p && *p != '}') ++p; // skip to closing '}'
        } else {
            out += *p;
        }
    }
    return out;
}

static void appLog(const char* fmt, ...) {
    std::string cleanFmt = stripHiLogFmt(fmt);
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), cleanFmt.c_str(), ap);
    va_end(ap);
    gLog.append(buf);
}

// Redefine LOGI/LOGE to write to both HiLog and the in-app ring buffer
#undef LOGI
#undef LOGE
#define LOGI(fmt, ...) do { \
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__); \
    appLog(fmt, ##__VA_ARGS__); \
} while(0)
#define LOGE(fmt, ...) do { \
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__); \
    appLog("[ERR] " fmt, ##__VA_ARGS__); \
} while(0)

// Agent mode state (prefix KV cache reuse)
static bool g_agent_mode = false;
static size_t g_prefix_pos = 0;
static int g_agent_step = 0;

// ======================= 基础工具函数 =======================

struct AsyncData {
    napi_async_work work;
    napi_deferred deferred;
    std::string inputStr;
    std::string outputStr;
    bool success;
    napi_threadsafe_function tsfn = nullptr;  // for token streaming
};

static std::string joinPath(const std::string& lhs, const std::string& rhs) {
    if (lhs.empty()) return rhs;
    if (rhs.empty()) return lhs;
    if (lhs.back() == '/') return lhs + rhs;
    return lhs + "/" + rhs;
}

static std::string parentDir(const std::string& path) {
    size_t pos = path.find_last_of('/');
    if (pos == std::string::npos) return "";
    if (pos == 0) return "/";
    return path.substr(0, pos);
}

static bool ensureDirectoryRecursive(const std::string& path) {
    if (path.empty() || path == "/") return true;
    struct stat st;
    if (::stat(path.c_str(), &st) == 0) {
        return S_ISDIR(st.st_mode);
    }
    std::string parent = parentDir(path);
    if (!parent.empty() && !ensureDirectoryRecursive(parent)) {
        return false;
    }
    if (::mkdir(path.c_str(), 0755) == 0 || errno == EEXIST) {
        return true;
    }
    return false;
}

static bool pathExistsLocal(const std::string& path) {
    struct stat st;
    return ::stat(path.c_str(), &st) == 0;
}

static void prependEnvPath(const char* key, const std::string& path) {
    const char* current = ::getenv(key);
    if (current == nullptr || std::string(current).empty()) {
        ::setenv(key, path.c_str(), 1);
        return;
    }
    std::string currentStr(current);
    if (currentStr == path || currentStr.find(path + ":") == 0 ||
        currentStr.find(":" + path) != std::string::npos) {
        return;
    }
    std::string merged = path + ":" + currentStr;
    ::setenv(key, merged.c_str(), 1);
}

static bool writeFileBytes(const std::string& path, const uint8_t* data, size_t len, std::string& err) {
    std::string dir = parentDir(path);
    if (!ensureDirectoryRecursive(dir)) {
        err = "create directory failed: " + dir;
        return false;
    }
    FILE* fp = ::fopen(path.c_str(), "wb");
    if (fp == nullptr) {
        err = "open file failed: " + path;
        return false;
    }
    size_t written = len == 0 ? 0 : ::fwrite(data, 1, len, fp);
    ::fclose(fp);
    if (written != len) {
        err = "write file failed: " + path;
        return false;
    }
    return true;
}

static bool copyRawFileToSandbox(NativeResourceManager* mgr,
                                 const std::string& rawPath,
                                 const std::string& dstPath,
                                 std::string& err) {
    RawFile* rawFile = OH_ResourceManager_OpenRawFile(mgr, rawPath.c_str());
    if (rawFile == nullptr) {
        err = "open raw file failed: " + rawPath;
        return false;
    }
    long len = OH_ResourceManager_GetRawFileSize(rawFile);
    if (len < 0) {
        OH_ResourceManager_CloseRawFile(rawFile);
        err = "invalid raw file size: " + rawPath;
        return false;
    }
    std::vector<uint8_t> buffer(static_cast<size_t>(len));
    int readLen = len == 0 ? 0 : OH_ResourceManager_ReadRawFile(rawFile, buffer.data(), buffer.size());
    OH_ResourceManager_CloseRawFile(rawFile);
    if (readLen < 0 || static_cast<size_t>(readLen) != buffer.size()) {
        err = "read raw file failed: " + rawPath;
        return false;
    }
    return writeFileBytes(dstPath, buffer.data(), buffer.size(), err);
}

static bool copyRawDirRecursive(NativeResourceManager* mgr,
                                const std::string& rawDirPath,
                                const std::string& dstDirPath,
                                std::string& err) {
    if (!ensureDirectoryRecursive(dstDirPath)) {
        err = "create destination directory failed: " + dstDirPath;
        return false;
    }
    RawDir* rawDir = OH_ResourceManager_OpenRawDir(mgr, rawDirPath.c_str());
    if (rawDir == nullptr) {
        err = "open raw directory failed: " + rawDirPath;
        return false;
    }
    int count = OH_ResourceManager_GetRawFileCount(rawDir);
    for (int i = 0; i < count; ++i) {
        const char* name = OH_ResourceManager_GetRawFileName(rawDir, i);
        if (name == nullptr || name[0] == '\0') {
            continue;
        }
        std::string childName(name);
        if (childName == "." || childName == "..") {
            continue;
        }
        std::string childRawPath = joinPath(rawDirPath, childName);
        std::string childDstPath = joinPath(dstDirPath, childName);
        if (OH_ResourceManager_IsRawDir(mgr, childRawPath.c_str())) {
            if (!copyRawDirRecursive(mgr, childRawPath, childDstPath, err)) {
                OH_ResourceManager_CloseRawDir(rawDir);
                return false;
            }
            continue;
        }
        if (!copyRawFileToSandbox(mgr, childRawPath, childDstPath, err)) {
            OH_ResourceManager_CloseRawDir(rawDir);
            return false;
        }
    }
    OH_ResourceManager_CloseRawDir(rawDir);
    return true;
}

static bool configureCustomOppRuntime(const std::string& sandboxRoot, std::string& err) {
    const std::string customRoot = joinPath(sandboxRoot, "vendors/customize");
    const std::string libDir = joinPath(customRoot, "lib");
    const std::string markerSo = joinPath(libDir, "libcustom_op.so");
    const std::string markerJson =
        joinPath(customRoot, "op_impl/ai_core/tbe/config/kirin9030/aic-kirin9030-ops-info.json");
    const std::string tmpDir = joinPath(sandboxRoot, "tmp");
    if (!pathExistsLocal(markerSo)) {
        err = "custom op library missing: " + markerSo;
        return false;
    }
    if (!pathExistsLocal(markerJson)) {
        err = "custom op config missing: " + markerJson;
        return false;
    }
    if (!ensureDirectoryRecursive(tmpDir)) {
        err = "create runtime tmp failed: " + tmpDir;
        return false;
    }
    ::setenv("ASCEND_CUSTOM_OPP_PATH", customRoot.c_str(), 1);
    prependEnvPath("LD_LIBRARY_PATH", libDir);
    g_runtimeSandboxDir = sandboxRoot;
    LOGI("Prepared custom OPP in sandbox: %{public}s", customRoot.c_str());
    return true;
}

static bool customOppSandboxReady(const std::string& sandboxRoot) {
    const std::string customRoot = joinPath(sandboxRoot, "vendors/customize");
    const std::string libSo = joinPath(customRoot, "lib/libcustom_op.so");
    const std::string kernelSo = joinPath(customRoot, "lib/libascendc_custom_kernels.so");
    const std::string infoJson =
        joinPath(customRoot, "op_impl/ai_core/tbe/config/kirin9030/aic-kirin9030-ops-info.json");
    return pathExistsLocal(libSo) && pathExistsLocal(kernelSo) && pathExistsLocal(infoJson);
}

static napi_value PrepareCustomOpp(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string err;
    if (argc < 2) {
        err = "prepareCustomOpp needs resourceManager and sandbox path";
    }

    char sandboxPath[1024] = {0};
    size_t len = 0;
    if (err.empty()) {
        napi_get_value_string_utf8(env, args[1], sandboxPath, sizeof(sandboxPath), &len);
    }
    std::string sandboxRoot(sandboxPath, len);
    if (err.empty() && sandboxRoot.empty()) {
        err = "sandbox path is empty";
    }

    NativeResourceManager* mgr = nullptr;
    if (err.empty()) {
        mgr = OH_ResourceManager_InitNativeResourceManager(env, args[0]);
        if (mgr == nullptr) {
            err = "init native resource manager failed";
        }
    }

    if (err.empty()) {
        RawDir* probe = OH_ResourceManager_OpenRawDir(mgr, "custom_opp");
        if (probe == nullptr) {
            LOGI("No custom_opp rawfile resources, skip custom OPP setup");
            OH_ResourceManager_ReleaseNativeResourceManager(mgr);
            napi_value ret;
            napi_create_string_utf8(env, "ok", NAPI_AUTO_LENGTH, &ret);
            return ret;
        }
        OH_ResourceManager_CloseRawDir(probe);
    }

    if (err.empty() && customOppSandboxReady(sandboxRoot)) {
        LOGI("Reuse existing custom OPP from sandbox: %{public}s", sandboxRoot.c_str());
    } else if (err.empty()) {
        if (!copyRawDirRecursive(mgr, "custom_opp", sandboxRoot, err)) {
            LOGE("Copy custom OPP rawfile failed: %{public}s", err.c_str());
        }
    }
    if (mgr != nullptr) {
        OH_ResourceManager_ReleaseNativeResourceManager(mgr);
    }

    if (err.empty() && !configureCustomOppRuntime(sandboxRoot, err)) {
        LOGE("Configure custom OPP runtime failed: %{public}s", err.c_str());
    }

    napi_value ret;
    if (err.empty()) {
        napi_create_string_utf8(env, "ok", NAPI_AUTO_LENGTH, &ret);
    } else {
        std::string msg = "error: " + err;
        napi_create_string_utf8(env, msg.c_str(), NAPI_AUTO_LENGTH, &ret);
    }
    return ret;
}

// ======================= Token streaming via TSFN =======================

// Called on JS main thread for each token
static void TokenTsfnCallback(napi_env env, napi_value js_callback, void* /*context*/, void* data) {
    if (data) {
        std::string* token = static_cast<std::string*>(data);
        napi_value argv;
        napi_create_string_utf8(env, token->c_str(), token->size(), &argv);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 1, &argv, nullptr);
        delete token;
    }
}

// Custom streambuf: accumulates full output AND streams each token chunk via TSFN
class TsfnStreambuf : public std::streambuf {
public:
    TsfnStreambuf(napi_threadsafe_function tsfn) : tsfn_(tsfn) {}
    std::string str() const { return accumulated_; }

protected:
    std::streamsize xsputn(const char* s, std::streamsize n) override {
        accumulated_.append(s, n);
        if (tsfn_ && n > 0) {
            std::string* data = new std::string(s, n);
            napi_call_threadsafe_function(tsfn_, data, napi_tsfn_blocking);
        }
        return n;
    }

    int_type overflow(int_type ch) override {
        if (ch != EOF) {
            char c = static_cast<char>(ch);
            accumulated_ += c;
            if (tsfn_) {
                std::string* data = new std::string(1, c);
                napi_call_threadsafe_function(tsfn_, data, napi_tsfn_blocking);
            }
        }
        return ch;
    }

private:
    napi_threadsafe_function tsfn_;
    std::string accumulated_;
};

// ========== 1. 拷贝模型到沙箱 (不耗时太多，可保留同步) ==========
static napi_value CopyModel(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char src[1024] = {0}, dst[1024] = {0};
    size_t len;
    napi_get_value_string_utf8(env, args[0], src, sizeof(src), &len);
    napi_get_value_string_utf8(env, args[1], dst, sizeof(dst), &len);

    std::string cmd = "cp -r ";
    cmd += src;
    cmd += " ";
    cmd += dst;
    int ret = system(cmd.c_str());

    napi_value result;
    napi_create_string_utf8(env, ret == 0 ? "ok" : "copy failed", NAPI_AUTO_LENGTH, &result);
    return result;
}

// ========== 2. 异步加载模型 ==========
static void LoadModelExecute(napi_env env, void* data) {
    AsyncData* asyncData = static_cast<AsyncData*>(data);
    LOGI("Loading model from: %{public}s", asyncData->inputStr.c_str());

    std::lock_guard<std::mutex> lock(g_mutex);
    g_llm.reset(Llm::createLLM(asyncData->inputStr));
    if (!g_llm) {
        asyncData->success = false;
        asyncData->outputStr = "error: create LLM failed";
        return;
    }

    std::string modelDir = asyncData->inputStr.substr(0, asyncData->inputStr.rfind('/'));
    std::string tmpPath = g_runtimeSandboxDir.empty() ? modelDir + "/tmp" : joinPath(g_runtimeSandboxDir, "tmp");
    if (!ensureDirectoryRecursive(tmpPath)) {
        g_llm.reset();
        asyncData->success = false;
        asyncData->outputStr = "error: create runtime tmp failed";
        LOGE("Create runtime tmp failed: %{public}s", tmpPath.c_str());
        return;
    }
    std::string tmpConfig = "{\"tmp_path\":\"" + tmpPath + "\"}";
    g_llm->set_config(tmpConfig);

    bool res = g_llm->load();
    if (res) {
        asyncData->success = true;
        asyncData->outputStr = "ok";
        LOGI("Model loaded OK");
    } else {
        g_llm.reset();
        asyncData->success = false;
        asyncData->outputStr = "error: load failed";
        LOGE("Model load FAILED");
    }
}

static void AsyncComplete(napi_env env, napi_status status, void* data) {
    AsyncData* asyncData = static_cast<AsyncData*>(data);

    // Release TSFN if present (token streaming finished)
    if (asyncData->tsfn) {
        napi_release_threadsafe_function(asyncData->tsfn, napi_tsfn_release);
        asyncData->tsfn = nullptr;
    }

    napi_value result;
    napi_create_string_utf8(env, asyncData->outputStr.c_str(), asyncData->outputStr.size(), &result);

    if (asyncData->success) {
        napi_resolve_deferred(env, asyncData->deferred, result);
    } else {
        napi_reject_deferred(env, asyncData->deferred, result);
    }

    napi_delete_async_work(env, asyncData->work);
    delete asyncData;
}

static napi_value LoadModelAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char configPath[1024] = {0};
    size_t len;
    napi_get_value_string_utf8(env, args[0], configPath, sizeof(configPath), &len);

    AsyncData* asyncData = new AsyncData();
    asyncData->inputStr = configPath;

    napi_value promise;
    napi_create_promise(env, &asyncData->deferred, &promise);

    napi_value resourceName;
    napi_create_string_utf8(env, "LoadModelAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, LoadModelExecute, AsyncComplete, asyncData, &asyncData->work);
    napi_queue_async_work(env, asyncData->work);

    return promise;
}

// ========== 3. 异步单轮推理 ==========
static void GenerateExecute(napi_env env, void* data) {
    AsyncData* asyncData = static_cast<AsyncData*>(data);
    std::lock_guard<std::mutex> lock(g_mutex);
    
    if (!g_llm) {
        asyncData->success = false;
        asyncData->outputStr = "error: model not loaded";
        return;
    }

    std::ostringstream oss;
    g_llm->response(asyncData->inputStr, &oss);
    asyncData->outputStr = oss.str();

    auto context = g_llm->getContext();
    if(context) {
        float prefill_s = context->prefill_us / 1e6;
        float decode_s = context->decode_us / 1e6;
        char perf[512];
        snprintf(perf, sizeof(perf),
            "\n\n--- perf ---\nprompt tokens: %d\ndecode tokens: %d\nprefill: %.2f tok/s\ndecode:%.2f tok/s",
            context->prompt_len, context->gen_seq_len,
            prefill_s > 0 ? context->prompt_len / prefill_s : 0,
            decode_s > 0 ? context->gen_seq_len / decode_s : 0);
        asyncData->outputStr += perf;
    }
    asyncData->success = true;
}

static napi_value GenerateAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char prompt[4096] = {0};
    size_t len;
    napi_get_value_string_utf8(env, args[0], prompt, sizeof(prompt), &len);

    AsyncData* asyncData = new AsyncData();
    asyncData->inputStr = prompt;

    napi_value promise;
    napi_create_promise(env, &asyncData->deferred, &promise);

    napi_value resourceName;
    napi_create_string_utf8(env, "GenerateAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, GenerateExecute, AsyncComplete, asyncData, &asyncData->work);
    napi_queue_async_work(env, asyncData->work);

    return promise;
}

// ========== 4. 异步多轮对话 ==========
static void ChatExecute(napi_env env, void* data) {
    AsyncData* asyncData = static_cast<AsyncData*>(data);
    std::lock_guard<std::mutex> lock(g_mutex);
    
    if (!g_llm) {
        asyncData->success = false;
        asyncData->outputStr = "error: model not loaded";
        return;
    }

    if (asyncData->inputStr == "/reset") {
        g_llm->reset();
        g_messages.clear();
        g_messages.emplace_back("system", "You are a helpful assistant.");
        asyncData->success = true;
        asyncData->outputStr = "reset done";
        return;
    }

    if (g_messages.empty()) {
        g_messages.emplace_back("system", "You are a helpful assistant.");
    }
    g_messages.emplace_back("user", asyncData->inputStr);
    auto context = g_llm->getContext();
    std::ostringstream oss;
    g_llm->response(g_messages, &oss);
    
    if (context) {
        std::string assistant_str = oss.str();
        // printf("Assistant: %s\n", context->generate_str.c_str());
        if (assistant_str.empty()) {
            assistant_str = context->generate_str;
        } else {
            // context->generate_str = assistant_str;
            printf("Assistant: %s\n", context->generate_str.c_str());
        }
        g_messages.emplace_back("assistant", assistant_str);
        asyncData->outputStr = assistant_str;
    }
    asyncData->success = true;
}

static napi_value ChatAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char userMsg[4096] = {0};
    size_t len;
    napi_get_value_string_utf8(env, args[0], userMsg, sizeof(userMsg), &len);

    AsyncData* asyncData = new AsyncData();
    asyncData->inputStr = userMsg;

    napi_value promise;
    napi_create_promise(env, &asyncData->deferred, &promise);

    napi_value resourceName;
    napi_create_string_utf8(env, "ChatAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, ChatExecute, AsyncComplete, asyncData, &asyncData->work);
    napi_queue_async_work(env, asyncData->work);

    return promise;
}

// ========== 5. Agent Prefill (prefix KV cache reuse) ==========
static void AgentPrefillExecute(napi_env env, void* data) {
    AsyncData* asyncData = static_cast<AsyncData*>(data);
    std::lock_guard<std::mutex> lock(g_mutex);

    if (!g_llm) {
        asyncData->success = false;
        asyncData->outputStr = "error: model not loaded";
        return;
    }

    // If already in agent mode, reset first
    if (g_agent_mode) {
        g_llm->reset();
        g_agent_mode = false;
    }

    // Configure for prefix reuse
    g_llm->set_config("{\"reuse_kv\":true}");
    g_llm->set_config("{\"use_template\":false}");

    // Prefill prefix only (max_new_tokens = 0)
    g_llm->response(asyncData->inputStr, nullptr, nullptr, 0);
    g_prefix_pos = g_llm->getCurrentHistory();
    g_agent_mode = true;
    g_agent_step = 0;

    LOGI("AgentPrefill: prefix cached at %{public}zu tokens", g_prefix_pos);
    asyncData->success = true;
    asyncData->outputStr = "ok:" + std::to_string(g_prefix_pos);
}

static napi_value AgentPrefillAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // Dynamic string extraction for large prefix
    size_t strLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &strLen);
    std::string prefix(strLen, '\0');
    napi_get_value_string_utf8(env, args[0], &prefix[0], strLen + 1, &strLen);

    AsyncData* asyncData = new AsyncData();
    asyncData->inputStr = std::move(prefix);

    napi_value promise;
    napi_create_promise(env, &asyncData->deferred, &promise);

    napi_value resourceName;
    napi_create_string_utf8(env, "AgentPrefillAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, AgentPrefillExecute, AsyncComplete, asyncData, &asyncData->work);
    napi_queue_async_work(env, asyncData->work);

    return promise;
}

// ========== 6. Agent Step (erase + prefill variable + generate) ==========
static void AgentStepExecute(napi_env env, void* data) {
    AsyncData* asyncData = static_cast<AsyncData*>(data);
    std::lock_guard<std::mutex> lock(g_mutex);

    if (!g_llm) {
        asyncData->success = false;
        asyncData->outputStr = "error: model not loaded";
        return;
    }
    if (!g_agent_mode) {
        asyncData->success = false;
        asyncData->outputStr = "error: agent mode not active, call agentPrefill first";
        return;
    }

    // Erase previous step's variable + generated tokens, keep prefix KV
    if (g_agent_step > 0) {
        g_llm->eraseHistory(g_prefix_pos, 0);
        LOGI("AgentStep: erased KV after prefix pos %{public}zu", g_prefix_pos);
    }

    // Prefill variable part and generate (with optional token streaming)
    std::string response;
    if (asyncData->tsfn) {
        TsfnStreambuf buf(asyncData->tsfn);
        std::ostream tokenStream(&buf);
        g_llm->response(asyncData->inputStr, &tokenStream, nullptr, -1);
        response = buf.str();
    } else {
        std::ostringstream oss;
        g_llm->response(asyncData->inputStr, &oss, nullptr, -1);
        response = oss.str();
    }
    g_agent_step++;
    auto context = g_llm->getContext();
    if (context) {
        float prefill_s = context->prefill_us / 1e6;
        float decode_s = context->decode_us / 1e6;
        LOGI("AgentStep %{public}d: prompt=%{public}d decode=%{public}d prefill=%.2f tok/s decode=%.2f tok/s kv=%{public}zu",
             g_agent_step, context->prompt_len, context->gen_seq_len,
             prefill_s > 0 ? context->prompt_len / prefill_s : 0,
             decode_s > 0 ? context->gen_seq_len / decode_s : 0,
             g_llm->getCurrentHistory());
    }

    asyncData->success = true;
    asyncData->outputStr = response;
}

static napi_value AgentStepAsync(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // Dynamic string extraction
    size_t strLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &strLen);
    std::string variable(strLen, '\0');
    napi_get_value_string_utf8(env, args[0], &variable[0], strLen + 1, &strLen);

    AsyncData* asyncData = new AsyncData();
    asyncData->inputStr = std::move(variable);

    // Optional 2nd arg: onToken callback for streaming to floating window
    if (argc >= 2) {
        napi_valuetype argType;
        napi_typeof(env, args[1], &argType);
        if (argType == napi_function) {
            napi_value tsfnName;
            napi_create_string_utf8(env, "AgentStepTokenCb", NAPI_AUTO_LENGTH, &tsfnName);
            napi_create_threadsafe_function(env, args[1], nullptr, tsfnName,
                0, 1, nullptr, nullptr, nullptr, TokenTsfnCallback, &asyncData->tsfn);
        }
    }

    napi_value promise;
    napi_create_promise(env, &asyncData->deferred, &promise);

    napi_value resourceName;
    napi_create_string_utf8(env, "AgentStepAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, AgentStepExecute, AsyncComplete, asyncData, &asyncData->work);
    napi_queue_async_work(env, asyncData->work);

    return promise;
}

// ========== 7. Agent Reset (exit agent mode, restore defaults) ==========
static void AgentResetExecute(napi_env env, void* data) {
    AsyncData* asyncData = static_cast<AsyncData*>(data);
    std::lock_guard<std::mutex> lock(g_mutex);

    if (g_llm) {
        g_llm->reset();
        g_llm->set_config("{\"reuse_kv\":false}");
        g_llm->set_config("{\"use_template\":true}");
    }
    g_agent_mode = false;
    g_prefix_pos = 0;
    g_agent_step = 0;
    g_messages.clear();
    g_messages.emplace_back("system", "You are a helpful assistant.");

    LOGI("AgentReset: agent mode disabled, LLM restored to default");
    asyncData->success = true;
    asyncData->outputStr = "ok";
}

static napi_value AgentResetAsync(napi_env env, napi_callback_info info) {
    AsyncData* asyncData = new AsyncData();

    napi_value promise;
    napi_create_promise(env, &asyncData->deferred, &promise);

    napi_value resourceName;
    napi_create_string_utf8(env, "AgentResetAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, AgentResetExecute, AsyncComplete, asyncData, &asyncData->work);
    napi_queue_async_work(env, asyncData->work);

    return promise;
}

// ========== 8. 重置对话 ==========
static napi_value Reset(napi_env env, napi_callback_info info) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_llm) {
        g_llm->reset();
    }
    g_messages.clear();
    g_messages.emplace_back("system", "You are a helpful assistant.");

    napi_value result;
    napi_create_string_utf8(env, "ok", NAPI_AUTO_LENGTH, &result);
    return result;
}

// ========== 9. CPU BackendConfig overrides for op precision test ==========
// These globals are consumed by runConvTest / runConvTestInt8 when building
// the CPU Executor. HiAI side is unaffected (its backend has no use for
// BackendConfig). Values map directly onto MNN::BackendConfig::PrecisionMode
// and MemoryMode enums.
static MNN::BackendConfig::PrecisionMode g_cpuPrecision = MNN::BackendConfig::Precision_Normal;
static MNN::BackendConfig::MemoryMode    g_cpuMemory    = MNN::BackendConfig::Memory_Normal;

static MNN::BackendConfig makeCpuBackendConfig() {
    MNN::BackendConfig cfg;
    cfg.precision = g_cpuPrecision;
    cfg.memory    = g_cpuMemory;
    return cfg;
}

static const char* precisionName(MNN::BackendConfig::PrecisionMode p) {
    switch (p) {
        case MNN::BackendConfig::Precision_Normal:    return "Normal(fp32)";
        case MNN::BackendConfig::Precision_High:      return "High(fp32)";
        case MNN::BackendConfig::Precision_Low:       return "Low(fp16/ARM82)";
        case MNN::BackendConfig::Precision_Low_BF16:  return "Low_BF16";
        default:                                      return "?";
    }
}
static const char* memoryName(MNN::BackendConfig::MemoryMode m) {
    switch (m) {
        case MNN::BackendConfig::Memory_Normal: return "Normal";
        case MNN::BackendConfig::Memory_High:   return "High";
        case MNN::BackendConfig::Memory_Low:    return "Low";
        default:                                return "?";
    }
}

static napi_value SetCpuPrecision(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char mode[32] = {0}; size_t len = 0;
    if (argc >= 1) napi_get_value_string_utf8(env, args[0], mode, sizeof(mode), &len);
    if      (std::strcmp(mode, "high") == 0)     g_cpuPrecision = MNN::BackendConfig::Precision_High;
    else if (std::strcmp(mode, "low") == 0)      g_cpuPrecision = MNN::BackendConfig::Precision_Low;
    else if (std::strcmp(mode, "low_bf16") == 0) g_cpuPrecision = MNN::BackendConfig::Precision_Low_BF16;
    else                                         g_cpuPrecision = MNN::BackendConfig::Precision_Normal;
    LOGI("cpu precision=%{public}s", precisionName(g_cpuPrecision));
    napi_value ret; napi_create_string_utf8(env, "ok", 2, &ret); return ret;
}

static napi_value SetCpuMemory(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char mode[32] = {0}; size_t len = 0;
    if (argc >= 1) napi_get_value_string_utf8(env, args[0], mode, sizeof(mode), &len);
    if      (std::strcmp(mode, "high") == 0) g_cpuMemory = MNN::BackendConfig::Memory_High;
    else if (std::strcmp(mode, "low") == 0)  g_cpuMemory = MNN::BackendConfig::Memory_Low;
    else                                     g_cpuMemory = MNN::BackendConfig::Memory_Normal;
    LOGI("cpu memory=%{public}s", memoryName(g_cpuMemory));
    napi_value ret; napi_create_string_utf8(env, "ok", 2, &ret); return ret;
}

// ========== 10. HiAI Conv mode override (auto / matmul / conv) ==========
// Mirrors HIAI_CONV_MODE env consumed by HiAIConvExecution.cpp.
// Must be called BEFORE opTest (env is read during compileHiAIModel).
static napi_value SetConvMode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char mode[32] = {0};
    size_t len = 0;
    if (argc >= 1) {
        napi_get_value_string_utf8(env, args[0], mode, sizeof(mode), &len);
    }

    if (len == 0 || std::strcmp(mode, "auto") == 0) {
        unsetenv("HIAI_CONV_MODE");
        LOGI("HIAI_CONV_MODE unset (auto)");
    } else {
        setenv("HIAI_CONV_MODE", mode, 1);
        LOGI("HIAI_CONV_MODE=%{public}s", mode);
    }
    napi_value ret;
    napi_create_string_utf8(env, "ok", 2, &ret);
    return ret;
}

// ========== 10b. HiAI int8 quant path override ==========
// Mirrors HIAI_CONV_QUANT env consumed by HiAIConvExecution.cpp.
// Values:
//   auto / on (default): weight-only int8 — x_quant_type=0, filter int8 per-OC.
//                        fp16 CUBE MAC; int8 just compresses weight storage.
//   full:                genuine int8×int8 inside QuantizedConvolution —
//                        x_quant_type=1, x_quant_scale from HIAI_INT8_X_SCALE.
//   matmul_int8:         QuantizeV2 → MatMul(uint8×int8→int32) → DequantizeV2.
//                        Real int8 CUBE MAC + MatMul engine + per-channel
//                        weight quant via DequantizeV2.deq_scale. Only active
//                        when the op shape is 1×1 linear; other shapes
//                        degrade to the weight-only path automatically.
//   off:                 legacy — dequantize to fp32 at compile time.
// Must be called BEFORE opTest (env is read during compileHiAIModel).
static napi_value SetConvQuant(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char mode[32] = {0};
    size_t len = 0;
    if (argc >= 1) {
        napi_get_value_string_utf8(env, args[0], mode, sizeof(mode), &len);
    }

    if (len == 0 || std::strcmp(mode, "auto") == 0 || std::strcmp(mode, "on") == 0) {
        unsetenv("HIAI_CONV_QUANT");
        LOGI("HIAI_CONV_QUANT unset (auto: weight-only int8)");
    } else {
        setenv("HIAI_CONV_QUANT", mode, 1);
        LOGI("HIAI_CONV_QUANT=%{public}s", mode);
    }
    napi_value ret;
    napi_create_string_utf8(env, "ok", 2, &ret);
    return ret;
}

// ========== 10c. HiAI int8 x_scale override (used only in 'full' mode) =========
// Sets HIAI_INT8_X_SCALE consumed by HiAIConvExecution.cpp when building a
// QuantizedConvolution with x_quant_type=1. Pass 0 (or any <=0) to clear.
static napi_value SetInt8XScale(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double v = 0.0;
    if (argc >= 1) {
        napi_get_value_double(env, args[0], &v);
    }
    if (v > 0.0 && std::isfinite(v)) {
        char buf[64];
        snprintf(buf, sizeof(buf), "%.8g", v);
        setenv("HIAI_INT8_X_SCALE", buf, 1);
        LOGI("HIAI_INT8_X_SCALE=%{public}s", buf);
    } else {
        unsetenv("HIAI_INT8_X_SCALE");
        LOGI("HIAI_INT8_X_SCALE unset (default 1/127)");
    }
    napi_value ret;
    napi_create_string_utf8(env, "ok", 2, &ret);
    return ret;
}

// ========== 10. 单算子精度测试 (Convolution on CPU vs HiAI Delegate) ==========
using namespace MNN::Express;

// batch: input batch size (N); warmup/repeat: timing iterations
static std::string runConvTest(int ic, int oc, int ih, int iw, int kh, int kw,
                               int strideH, int strideW, int group,
                               int batch = 1, int warmup = 3, int repeat = 10) {
    std::ostringstream log;
    log << "=== Conv Test: N=" << batch << " ic=" << ic << " oc=" << oc
        << " ih=" << ih << " iw=" << iw
        << " kh=" << kh << " kw=" << kw
        << " stride=" << strideH << " group=" << group << " ===\n";

    int weightSize = oc * (ic / group) * kh * kw;
    std::vector<float> weight(weightSize);
    std::vector<float> bias(oc);
    for (int i = 0; i < weightSize; i++) weight[i] = (float)((i % 7) - 3) * 0.1f;
    for (int i = 0; i < oc; i++) bias[i] = (float)((i % 5) - 2) * 0.05f;

    int inputSize = batch * ic * ih * iw;
    std::vector<float> inputData(inputSize);
    for (int i = 0; i < inputSize; i++) inputData[i] = (float)((i % 11) - 5) * 0.1f;

    using Clock = std::chrono::high_resolution_clock;
    using Ms    = std::chrono::duration<double, std::milli>;
    auto elapsed = [](Clock::time_point a, Clock::time_point b) {
        return Ms(b - a).count();
    };

    // ── CPU ──────────────────────────────────────────────────────────────
    log << "CPU cfg: memory=" << memoryName(g_cpuMemory)
        << " precision=" << precisionName(g_cpuPrecision) << "\n";
    std::vector<float> cpuOutput;
    double cpuFirstMs = -1, cpuAvgMs = -1;
    std::vector<double> cpuWarmupMs;
    {
        auto exe = Executor::newExecutor(MNN_FORWARD_CPU, makeCpuBackendConfig(), 1);
        ExecutorScope scope(exe);
        auto x = _Input({batch, ic, ih, iw}, NCHW);
        ::memcpy(x->writeMap<float>(), inputData.data(), inputSize * sizeof(float));
        auto convWeight = weight;
        auto convBias   = bias;
        auto y = _Conv(std::move(convWeight), std::move(convBias), x,
                       {ic, oc}, {kw, kh}, VALID, {strideW, strideH}, {1, 1}, group);
        y = _Convert(y, NCHW);

        // first call: includes kernel selection + weight packing
        auto t0 = Clock::now();
        auto ptr = y->readMap<float>();
        cpuFirstMs = elapsed(t0, Clock::now());
        if (!ptr) { log << "ERROR: CPU conv output is null\n"; return log.str(); }
        cpuOutput.assign(ptr, ptr + y->getInfo()->size);
        log << "CPU output: " << cpuOutput.size() << " elems  shape="
            << y->getInfo()->dim[0] << "x" << y->getInfo()->dim[1]
            << "x" << y->getInfo()->dim[2] << "x" << y->getInfo()->dim[3] << "\n";

        // warmup – record each iteration
        for (int i = 0; i < warmup; i++) {
            ::memcpy(x->writeMap<float>(), inputData.data(), inputSize * sizeof(float));
            auto tw0 = Clock::now();
            y->readMap<float>();
            cpuWarmupMs.push_back(elapsed(tw0, Clock::now()));
        }
        // steady-state
        auto ts0 = Clock::now();
        for (int i = 0; i < repeat; i++) {
            ::memcpy(x->writeMap<float>(), inputData.data(), inputSize * sizeof(float));
            y->readMap<float>();
        }
        cpuAvgMs = elapsed(ts0, Clock::now()) / repeat;
    }

    // ── HiAI ─────────────────────────────────────────────────────────────
    std::vector<float> hiaiOutput;
    double hiaiFirstMs = -1, hiaiAvgMs = -1;
    std::vector<double> hiaiWarmupMs;
    {
        auto exe = Executor::newExecutor(MNN_FORWARD_USER_1, MNN::BackendConfig(), 1);
        ExecutorScope scope(exe);
        auto x = _Input({batch, ic, ih, iw}, NCHW);
        ::memcpy(x->writeMap<float>(), inputData.data(), inputSize * sizeof(float));
        auto convWeight = weight;
        auto convBias   = bias;
        auto y = _Conv(std::move(convWeight), std::move(convBias), x,
                       {ic, oc}, {kw, kh}, VALID, {strideW, strideH}, {1, 1}, group);
        y = _Convert(y, NCHW);

        // first call: includes BuildIRModel + Load + 1st NPU inference
        auto t0 = Clock::now();
        auto ptr = y->readMap<float>();
        hiaiFirstMs = elapsed(t0, Clock::now());
        if (!ptr) { log << "ERROR: HiAI conv output is null (backend not available?)\n"; return log.str(); }
        hiaiOutput.assign(ptr, ptr + y->getInfo()->size);
        log << "HiAI output: " << hiaiOutput.size() << " elems\n";

        // warmup – record each iteration
        for (int i = 0; i < warmup; i++) {
            ::memcpy(x->writeMap<float>(), inputData.data(), inputSize * sizeof(float));
            auto tw0 = Clock::now();
            y->readMap<float>();
            hiaiWarmupMs.push_back(elapsed(tw0, Clock::now()));
        }
        // steady-state
        auto ts0 = Clock::now();
        for (int i = 0; i < repeat; i++) {
            ::memcpy(x->writeMap<float>(), inputData.data(), inputSize * sizeof(float));
            y->readMap<float>();
        }
        hiaiAvgMs = elapsed(ts0, Clock::now()) / repeat;
    }

    // ── Precision ────────────────────────────────────────────────────────
    if (cpuOutput.size() != hiaiOutput.size()) {
        log << "FAIL: size mismatch CPU=" << cpuOutput.size()
            << " HiAI=" << hiaiOutput.size() << "\n";
        return log.str();
    }
    float maxRef = 0.0f;
    for (auto v : cpuOutput) maxRef = std::max(maxRef, std::abs(v));
    if (maxRef < 1e-6f) maxRef = 1e-6f;
    float maxDiff = 0.0f;
    int maxDiffIdx = 0, failCount = 0;
    for (int i = 0; i < (int)cpuOutput.size(); i++) {
        float diff = std::abs(cpuOutput[i] - hiaiOutput[i]);
        if (diff > maxDiff) { maxDiff = diff; maxDiffIdx = i; }
        if (diff / maxRef > 0.01f) failCount++;
    }
    float relError = maxDiff / maxRef;
    log << "max|ref|=" << maxRef << "  maxDiff=" << maxDiff
        << "  relErr=" << (relError * 100.0f) << "%"
        << "  @idx=" << maxDiffIdx << "\n";
    log << "fail_count=" << failCount << "/" << cpuOutput.size() << "\n";

    // ── Timing report ────────────────────────────────────────────────────
    char buf[256];
    // CPU
    snprintf(buf, sizeof(buf), "CPU  first=%.2fms", cpuFirstMs);
    log << buf;
    for (int i = 0; i < (int)cpuWarmupMs.size(); i++) {
        snprintf(buf, sizeof(buf), "  w%d=%.2fms", i, cpuWarmupMs[i]);
        log << buf;
    }
    snprintf(buf, sizeof(buf), "  steady(x%d)=%.2fms\n", repeat, cpuAvgMs);
    log << buf;

    // HiAI
    snprintf(buf, sizeof(buf), "HiAI first=%.2fms(compile+infer)", hiaiFirstMs);
    log << buf;
    for (int i = 0; i < (int)hiaiWarmupMs.size(); i++) {
        snprintf(buf, sizeof(buf), "  w%d=%.2fms", i, hiaiWarmupMs[i]);
        log << buf;
    }
    snprintf(buf, sizeof(buf), "  steady(x%d)=%.2fms\n", repeat, hiaiAvgMs);
    log << buf;

    // speedup
    snprintf(buf, sizeof(buf),
             "speedup(steady) CPU/HiAI=%.2fx  (>1=NPU faster)\n",
             hiaiAvgMs > 0 ? cpuAvgMs / hiaiAvgMs : 0.0);
    log << buf;

    if (relError < 0.01f) {
        log << "PASS\n";
    } else if (relError < 0.05f) {
        log << "WARN: relErr=" << (relError * 100.0f) << "% (>1% threshold)\n";
    } else {
        log << "FAIL: relErr=" << (relError * 100.0f) << "% (>5%)\n";
    }

    return log.str();
}

// Per-channel int8 symmetric quant helper — thin wrapper around the public
// MNN::Express::_HybridInt8Conv (DynamicQuant-style float-IO + int8 weight).
// Equivalent to what mnn_converter.py::rebuild_linear emits for
// --quant_bit=8 --quant_block=0 (channel-wise).
static MNN::Express::VARP _PerChannelInt8Conv(
    const std::vector<float>& weight,
    const std::vector<float>& bias,
    MNN::Express::VARP x,
    int ic, int oc, int kh, int kw,
    int strideH, int strideW, int group) {
    using namespace MNN::Express;
    std::vector<float> w = weight;
    std::vector<float> b = bias;
    return _HybridInt8Conv(std::move(w), std::move(b), x,
                           /*channel=*/{ic, oc},
                           /*kernelSize=*/{kw, kh},
                           /*pad=*/VALID,
                           /*stride=*/{strideW, strideH},
                           /*dilate=*/{1, 1},
                           /*group=*/group,
                           /*pads=*/{0, 0},
                           /*relu=*/false, /*relu6=*/false,
                           /*nbits=*/8, /*quantBlock=*/0);
}

// ── Int8 per-channel variant of runConvTest ───────────────────────────────
// CPU side: MNN picks the DynamicQuant hybrid int8 kernel (float I/O, int8 weight).
// HiAI side: by default (HIAI_CONV_QUANT=auto) HiAIConvExecution now builds a
//            hiai::op::QuantizedConvolution graph with DT_INT8 filter +
//            per-OC filter_quant_scales, so the Da Vinci CUBE runs its
//            int8 MAC path. Set HIAI_CONV_QUANT=off to fall back to the
//            legacy dequant-to-fp32 Convolution/MatMul graph for comparison.
static std::string runConvTestInt8(int ic, int oc, int ih, int iw, int kh, int kw,
                                    int strideH, int strideW, int group,
                                    int batch = 1, int warmup = 3, int repeat = 10) {
    using namespace MNN::Express;
    std::ostringstream log;
    log << "=== INT8 per-channel: N=" << batch << " ic=" << ic << " oc=" << oc
        << " ih=" << ih << " iw=" << iw
        << " kh=" << kh << " kw=" << kw
        << " stride=" << strideH << " group=" << group << " ===\n";

    int weightSize = oc * (ic / group) * kh * kw;
    std::vector<float> weight(weightSize);
    std::vector<float> bias(oc);
    for (int i = 0; i < weightSize; i++) weight[i] = (float)((i % 7) - 3) * 0.1f;
    for (int i = 0; i < oc; i++) bias[i] = (float)((i % 5) - 2) * 0.05f;

    int inputSize = batch * ic * ih * iw;
    std::vector<float> inputData(inputSize);
    for (int i = 0; i < inputSize; i++) inputData[i] = (float)((i % 11) - 5) * 0.1f;

    using Clock = std::chrono::high_resolution_clock;
    using Ms    = std::chrono::duration<double, std::milli>;
    auto elapsed = [](Clock::time_point a, Clock::time_point b) {
        return Ms(b - a).count();
    };

    // ── CPU (int8 per-channel weight, fp32/fp16 I/O depending on config) ──
    // Note: int8 weight is only kept when memory==Memory_Low (gated by
    // MNN_LOW_MEMORY). If user picks Memory_Normal/High, weights will be
    // dequantized to fp32 at load time and CPU will fall back to the same
    // kernel as the fp32 test — useful for A/B inspection.
    log << "CPU cfg: memory=" << memoryName(g_cpuMemory)
        << " precision=" << precisionName(g_cpuPrecision);
    if (g_cpuMemory != MNN::BackendConfig::Memory_Low) {
        log << "  [WARN: non-Low memory → int8 weights get dequantized]";
    }
    log << "\n";
    std::vector<float> cpuOutput;
    double cpuFirstMs = -1, cpuAvgMs = -1;
    std::vector<double> cpuWarmupMs;
    {
        auto exe = Executor::newExecutor(MNN_FORWARD_CPU, makeCpuBackendConfig(), 1);
        ExecutorScope scope(exe);
        auto x = _Input({batch, ic, ih, iw}, NCHW);
        ::memcpy(x->writeMap<float>(), inputData.data(), inputSize * sizeof(float));
        auto y = _PerChannelInt8Conv(weight, bias, x, ic, oc, kh, kw,
                                     strideH, strideW, group);
        y = _Convert(y, NCHW);

        auto t0 = Clock::now();
        auto ptr = y->readMap<float>();
        cpuFirstMs = elapsed(t0, Clock::now());
        if (!ptr) { log << "ERROR: CPU int8 output null\n"; return log.str(); }
        cpuOutput.assign(ptr, ptr + y->getInfo()->size);

        for (int i = 0; i < warmup; i++) {
            ::memcpy(x->writeMap<float>(), inputData.data(), inputSize * sizeof(float));
            auto tw0 = Clock::now();
            y->readMap<float>();
            cpuWarmupMs.push_back(elapsed(tw0, Clock::now()));
        }
        auto ts0 = Clock::now();
        for (int i = 0; i < repeat; i++) {
            ::memcpy(x->writeMap<float>(), inputData.data(), inputSize * sizeof(float));
            y->readMap<float>();
        }
        cpuAvgMs = elapsed(ts0, Clock::now()) / repeat;
    }

    // ── HiAI (same quant op; HiAIConvExecution dequant to fp32 internally) ──
    std::vector<float> hiaiOutput;
    double hiaiFirstMs = -1, hiaiAvgMs = -1;
    std::vector<double> hiaiWarmupMs;
    {
        // In 'full' / 'matmul_int8' int8 modes the NPU needs a fixed x_scale
        // at compile time. Auto-calibrate from the test input's amax so the
        // A/B is semantically meaningful (user doesn't have to guess).
        const char* qm = std::getenv("HIAI_CONV_QUANT");
        bool needXScale = qm != nullptr &&
                          (std::strcmp(qm, "full")        == 0 ||
                           std::strcmp(qm, "matmul_int8") == 0 ||
                           std::strcmp(qm, "fc_int8")     == 0);
        if (needXScale) {
            float amax = 1e-8f;
            for (int i = 0; i < inputSize; i++) {
                float v = std::fabs(inputData[i]);
                if (v > amax) amax = v;
            }
            float xScale = amax / 127.0f;
            char buf[64];
            snprintf(buf, sizeof(buf), "%.8g", xScale);
            setenv("HIAI_INT8_X_SCALE", buf, 1);
            log << qm << " x_scale (amax/127) = " << buf << "\n";
        }

        auto exe = Executor::newExecutor(MNN_FORWARD_USER_1, MNN::BackendConfig(), 1);
        ExecutorScope scope(exe);
        auto x = _Input({batch, ic, ih, iw}, NCHW);
        ::memcpy(x->writeMap<float>(), inputData.data(), inputSize * sizeof(float));
        auto y = _PerChannelInt8Conv(weight, bias, x, ic, oc, kh, kw,
                                     strideH, strideW, group);
        y = _Convert(y, NCHW);

        auto t0 = Clock::now();
        auto ptr = y->readMap<float>();
        hiaiFirstMs = elapsed(t0, Clock::now());
        if (!ptr) { log << "ERROR: HiAI int8 output null\n"; return log.str(); }
        hiaiOutput.assign(ptr, ptr + y->getInfo()->size);

        for (int i = 0; i < warmup; i++) {
            ::memcpy(x->writeMap<float>(), inputData.data(), inputSize * sizeof(float));
            auto tw0 = Clock::now();
            y->readMap<float>();
            hiaiWarmupMs.push_back(elapsed(tw0, Clock::now()));
        }
        auto ts0 = Clock::now();
        for (int i = 0; i < repeat; i++) {
            ::memcpy(x->writeMap<float>(), inputData.data(), inputSize * sizeof(float));
            y->readMap<float>();
        }
        hiaiAvgMs = elapsed(ts0, Clock::now()) / repeat;
    }

    // ── Precision vs each other ─────────────────────────────────────────
    if (cpuOutput.size() != hiaiOutput.size()) {
        log << "FAIL: size mismatch CPU=" << cpuOutput.size()
            << " HiAI=" << hiaiOutput.size() << "\n";
        return log.str();
    }
    float maxRef = 0.0f;
    for (auto v : cpuOutput) maxRef = std::max(maxRef, std::abs(v));
    if (maxRef < 1e-6f) maxRef = 1e-6f;
    float maxDiff = 0.0f;
    int failCount = 0;
    for (int i = 0; i < (int)cpuOutput.size(); i++) {
        float diff = std::abs(cpuOutput[i] - hiaiOutput[i]);
        if (diff > maxDiff) maxDiff = diff;
        if (diff / maxRef > 0.02f) failCount++;  // looser threshold vs fp32 (quant noise)
    }
    float relError = maxDiff / maxRef;
    log << "max|ref|=" << maxRef << "  maxDiff=" << maxDiff
        << "  relErr=" << (relError * 100.0f) << "%"
        << "  fail=" << failCount << "/" << cpuOutput.size() << "\n";

    char buf[256];
    snprintf(buf, sizeof(buf), "CPU  (int8 DynamicQuant) first=%.2fms", cpuFirstMs);
    log << buf;
    for (int i = 0; i < (int)cpuWarmupMs.size(); i++) {
        snprintf(buf, sizeof(buf), "  w%d=%.2fms", i, cpuWarmupMs[i]);
        log << buf;
    }
    snprintf(buf, sizeof(buf), "  steady(x%d)=%.2fms\n", repeat, cpuAvgMs);
    log << buf;

    const char* hiaiLbl = "HiAI (int8 weight, fp16 MAC)";
    if (const char* qm = std::getenv("HIAI_CONV_QUANT")) {
        if      (std::strcmp(qm, "off")         == 0) hiaiLbl = "HiAI (dequant->fp16)";
        else if (std::strcmp(qm, "full")        == 0) hiaiLbl = "HiAI (int8 MAC, Conv)";
        else if (std::strcmp(qm, "matmul_int8") == 0) hiaiLbl = "HiAI (int8 MAC, MatMul chain)";
        else if (std::strcmp(qm, "fc_int8")     == 0) hiaiLbl = "HiAI (int8 MAC, QuantizedFullyConnection)";
    }
    snprintf(buf, sizeof(buf), "%s first=%.2fms(compile+infer)", hiaiLbl, hiaiFirstMs);
    log << buf;
    for (int i = 0; i < (int)hiaiWarmupMs.size(); i++) {
        snprintf(buf, sizeof(buf), "  w%d=%.2fms", i, hiaiWarmupMs[i]);
        log << buf;
    }
    snprintf(buf, sizeof(buf), "  steady(x%d)=%.2fms\n", repeat, hiaiAvgMs);
    log << buf;

    snprintf(buf, sizeof(buf),
             "speedup(steady) CPU/HiAI=%.2fx  (>1=NPU faster)\n",
             hiaiAvgMs > 0 ? cpuAvgMs / hiaiAvgMs : 0.0);
    log << buf;

    if (relError < 0.02f) log << "PASS\n";
    else if (relError < 0.05f) log << "WARN: relErr=" << (relError * 100.0f) << "% (>2%)\n";
    else log << "FAIL: relErr=" << (relError * 100.0f) << "% (>5%)\n";
    return log.str();
}

// ── Attention (fused OpType_Attention) precision test ────────────────────
// Builds a 4-input VARP graph (Q,K,V,[mask]) with _Attention, serializes it
// once via Variable::save, then loads it back as a Module twice — once with
// a CPU RuntimeManager and once with a HiAI NPU (MNN_FORWARD_USER_0)
// RuntimeManager. Going through Module (rather than raw VARP + ExecutorScope)
// is the only path where Variable::save populates the op's inputIndexes/
// outputIndexes — the Express lazy-eval path leaves those null, which
// NPUAttention::onResize dereferences at line 68 → SIGSEGV.
static std::string runAttentionTest(int batch, int seqLen, int numHead, int headDim,
                                    bool useMask,
                                    int warmup = 1, int repeat = 2) {
    std::ostringstream log;
    log << "=== Attention Test: B=" << batch << " S=" << seqLen
        << " H=" << numHead << " D=" << headDim
        << " mask=" << (useMask ? "yes" : "no") << " ===\n";

    const int qkvElem  = batch * seqLen * numHead * headDim;
    const int maskElem = batch * seqLen * seqLen;
    std::vector<float> qData(qkvElem), kData(qkvElem), vData(qkvElem);
    std::vector<float> maskData(useMask ? maskElem : 0, 0.0f);
    // Deterministic small-magnitude inputs so softmax stays numerically
    // stable across fp32/fp16 paths — we're measuring algorithmic divergence
    // between CPU and NPU, not fp over/underflow.
    for (int i = 0; i < qkvElem; i++) qData[i] = (float)((i % 13) - 6) * 0.02f;
    for (int i = 0; i < qkvElem; i++) kData[i] = (float)((i % 11) - 5) * 0.02f;
    for (int i = 0; i < qkvElem; i++) vData[i] = (float)((i % 9)  - 4) * 0.05f;
    // Mask stays all-zero (every position visible) — matches Qwen3VL visual
    // encoder where a single-image packed sequence has no boundaries to hide.
    (void)maskData;

    using Clock = std::chrono::high_resolution_clock;
    using Ms    = std::chrono::duration<double, std::milli>;
    auto elapsed = [](Clock::time_point a, Clock::time_point b) {
        return Ms(b - a).count();
    };

    // ── Build VARP graph once and serialize to a buffer ──────────────────
    // The buffer is constructed under the default (CPU) executor scope. No
    // kernels run here — Variable::save just walks the Expr tree and writes
    // a flatbuffer, filling inputIndexes/outputIndexes from tensor positions.
    std::vector<int8_t> graphBuffer;
    {
        auto q = _Input({batch, seqLen, numHead, headDim}, NCHW);
        auto k = _Input({batch, seqLen, numHead, headDim}, NCHW);
        auto v = _Input({batch, seqLen, numHead, headDim}, NCHW);
        q->setName("attn_q");
        k->setName("attn_k");
        v->setName("attn_v");
        VARP mask = nullptr;
        if (useMask) {
            mask = _Input({batch, seqLen, seqLen}, NCHW);
            mask->setName("attn_mask");
        }
        auto y = _Attention(q, k, v, mask, /*kv_cache=*/false);
        if (y.get() == nullptr) {
            log << "ERROR: _Attention returned null (MNN_SUPPORT_TRANSFORMER_FUSE off?)\n";
            return log.str();
        }
        y->setName("attn_out");
        graphBuffer = Variable::save({y});
        if (graphBuffer.empty()) {
            log << "ERROR: Variable::save produced empty buffer\n";
            return log.str();
        }
    }

    // Build a fresh input VARP batch (with real data copied in) for one
    // forward pass. New VARPs per call keeps the Module's input lifetime
    // simple — the Module doesn't reuse host buffers across invocations.
    auto makeInputs = [&]() -> std::vector<VARP> {
        std::vector<VARP> ins;
        auto qv = _Input({batch, seqLen, numHead, headDim}, NCHW);
        ::memcpy(qv->writeMap<float>(), qData.data(), qkvElem * sizeof(float));
        ins.push_back(qv);
        auto kv = _Input({batch, seqLen, numHead, headDim}, NCHW);
        ::memcpy(kv->writeMap<float>(), kData.data(), qkvElem * sizeof(float));
        ins.push_back(kv);
        auto vv = _Input({batch, seqLen, numHead, headDim}, NCHW);
        ::memcpy(vv->writeMap<float>(), vData.data(), qkvElem * sizeof(float));
        ins.push_back(vv);
        if (useMask) {
            auto mv = _Input({batch, seqLen, seqLen}, NCHW);
            ::memcpy(mv->writeMap<float>(), maskData.data(), maskElem * sizeof(float));
            ins.push_back(mv);
        }
        return ins;
    };

    // Per-backend run: build RuntimeManager + Module, do first+warmup+steady.
    // Same code path for CPU and NPU; only the ScheduleConfig.type differs.
    auto runOnBackend = [&](MNNForwardType fwdType,
                            const MNN::BackendConfig& bnCfgIn,
                            std::vector<float>& outVec,
                            double& firstMs,
                            std::vector<double>& warmupLog,
                            double& avgMs,
                            std::string& errOut) -> bool {
        MNN::ScheduleConfig sched;
        sched.type      = fwdType;
        sched.numThread = 1;
        MNN::BackendConfig bnCfg = bnCfgIn; // copy so the ptr we hand out lives
        sched.backendConfig = &bnCfg;

        std::shared_ptr<Executor::RuntimeManager> rtmgr(
            Executor::RuntimeManager::createRuntimeManager(sched));
        if (rtmgr.get() == nullptr) {
            errOut = "createRuntimeManager failed";
            return false;
        }

        // NPUBackend compiles the HiAI OM model at load time and expects a
        // fixed shape — shapeMutable must be false or resize-time shape
        // re-inference would blow away the compiled graph. Mirrors
        // omni.cpp::loadVisual's npuModuleCfg for MNN_FORWARD_USER_0/USER_1.
        Module::Config mcfg;
        if (fwdType == MNN_FORWARD_USER_0 || fwdType == MNN_FORWARD_USER_1) {
            mcfg.shapeMutable = false;
            mcfg.rearrange    = false;
        }

        std::shared_ptr<Module> m(Module::load(
            /*inputs=*/{}, /*outputs=*/{},
            reinterpret_cast<const uint8_t*>(graphBuffer.data()),
            graphBuffer.size(),
            rtmgr, &mcfg));
        if (m.get() == nullptr) {
            errOut = "Module::load returned nullptr";
            return false;
        }

        // ── First call: includes graph compile + weight packing + 1st infer
        auto t0 = Clock::now();
        auto ins = makeInputs();
        auto outs = m->onForward(ins);
        if (outs.empty() || outs[0].get() == nullptr) {
            errOut = "onForward returned empty/null output";
            return false;
        }
        auto ptr = outs[0]->readMap<float>();
        firstMs = elapsed(t0, Clock::now());
        if (ptr == nullptr) {
            errOut = "output readMap returned null";
            return false;
        }
        auto info = outs[0]->getInfo();
        outVec.assign(ptr, ptr + info->size);

        // ── Warmup (per-iteration timing)
        for (int i = 0; i < warmup; i++) {
            auto tw_ins = makeInputs();
            auto tw0 = Clock::now();
            auto o = m->onForward(tw_ins);
            o[0]->readMap<float>();
            warmupLog.push_back(elapsed(tw0, Clock::now()));
        }
        // ── Steady-state average
        auto ts0 = Clock::now();
        for (int i = 0; i < repeat; i++) {
            auto st_ins = makeInputs();
            auto o = m->onForward(st_ins);
            o[0]->readMap<float>();
        }
        avgMs = elapsed(ts0, Clock::now()) / repeat;

        // Dump output shape (first pass only — same across iterations).
        if (info != nullptr) {
            std::ostringstream shapeStr;
            for (int d = 0; d < (int)info->dim.size(); d++) {
                shapeStr << info->dim[d] << (d + 1 < (int)info->dim.size() ? "x" : "");
            }
            errOut = shapeStr.str(); // repurpose errOut to return the shape string
        }
        return true;
    };

    // ── CPU ──────────────────────────────────────────────────────────────
    log << "CPU cfg: memory=" << memoryName(g_cpuMemory)
        << " precision=" << precisionName(g_cpuPrecision) << "\n";
    std::vector<float> cpuOutput;
    double cpuFirstMs = -1, cpuAvgMs = -1;
    std::vector<double> cpuWarmupMs;
    std::string cpuInfo;
    if (!runOnBackend(MNN_FORWARD_CPU, makeCpuBackendConfig(),
                      cpuOutput, cpuFirstMs, cpuWarmupMs, cpuAvgMs, cpuInfo)) {
        log << "ERROR: CPU Module path failed (" << cpuInfo << ")\n";
        return log.str();
    }
    log << "CPU output: " << cpuOutput.size() << " elems  shape=" << cpuInfo << "\n";

    // ── HiAI NPU (MNN_FORWARD_USER_0 — the full NPUBackend where
    //    NPUAttention is registered; not the conv-only delegate on USER_1) ─
    std::vector<float> hiaiOutput;
    double hiaiFirstMs = -1, hiaiAvgMs = -1;
    std::vector<double> hiaiWarmupMs;
    std::string hiaiInfo;
    
    // Fix: Set memory mode to High to disable memory reuse for NPU tensor matching
    MNN::BackendConfig npuConfig;
    npuConfig.memory = MNN::BackendConfig::Memory_High;
    
    if (!runOnBackend(MNN_FORWARD_USER_0, npuConfig,
                      hiaiOutput, hiaiFirstMs, hiaiWarmupMs, hiaiAvgMs, hiaiInfo)) {
        log << "ERROR: HiAI NPU Module path failed (" << hiaiInfo << ")\n";
        return log.str();
    }
    log << "HiAI output: " << hiaiOutput.size() << " elems  shape=" << hiaiInfo << "\n";

    // ── Precision ────────────────────────────────────────────────────────
    if (cpuOutput.size() != hiaiOutput.size()) {
        log << "FAIL: size mismatch CPU=" << cpuOutput.size()
            << " HiAI=" << hiaiOutput.size() << "\n";
        return log.str();
    }
    float maxRef = 0.0f;
    for (auto v : cpuOutput) maxRef = std::max(maxRef, std::abs(v));
    if (maxRef < 1e-6f) maxRef = 1e-6f;
    float maxDiff = 0.0f;
    int maxDiffIdx = 0, failCount = 0;
    for (int i = 0; i < (int)cpuOutput.size(); i++) {
        float diff = std::abs(cpuOutput[i] - hiaiOutput[i]);
        if (diff > maxDiff) { maxDiff = diff; maxDiffIdx = i; }
        if (diff / maxRef > 0.01f) failCount++;
    }
    float relError = maxDiff / maxRef;
    log << "max|ref|=" << maxRef << "  maxDiff=" << maxDiff
        << "  relErr=" << (relError * 100.0f) << "%"
        << "  @idx=" << maxDiffIdx << "\n";
    log << "fail_count=" << failCount << "/" << cpuOutput.size() << "\n";

    // ── Timing report ────────────────────────────────────────────────────
    char buf[256];
    snprintf(buf, sizeof(buf), "CPU  first=%.2fms(load+compile+infer)", cpuFirstMs);
    log << buf;
    for (int i = 0; i < (int)cpuWarmupMs.size(); i++) {
        snprintf(buf, sizeof(buf), "  w%d=%.2fms", i, cpuWarmupMs[i]);
        log << buf;
    }
    snprintf(buf, sizeof(buf), "  steady(x%d)=%.2fms\n", repeat, cpuAvgMs);
    log << buf;

    snprintf(buf, sizeof(buf), "HiAI first=%.2fms(load+compile+infer)", hiaiFirstMs);
    log << buf;
    for (int i = 0; i < (int)hiaiWarmupMs.size(); i++) {
        snprintf(buf, sizeof(buf), "  w%d=%.2fms", i, hiaiWarmupMs[i]);
        log << buf;
    }
    snprintf(buf, sizeof(buf), "  steady(x%d)=%.2fms\n", repeat, hiaiAvgMs);
    log << buf;

    snprintf(buf, sizeof(buf),
             "speedup(steady) CPU/HiAI=%.2fx  (>1=NPU faster)\n",
             hiaiAvgMs > 0 ? cpuAvgMs / hiaiAvgMs : 0.0);
    log << buf;

    // Attention through softmax amplifies small fp accumulation errors, so
    // we widen the PASS gate to 2% (vs 1% for conv) but still flag >5% as
    // FAIL — anything past that is a real algorithmic divergence.
    if (relError < 0.02f) {
        log << "PASS\n";
    } else if (relError < 0.05f) {
        log << "WARN: relErr=" << (relError * 100.0f) << "% (>2% threshold)\n";
    } else {
        log << "FAIL: relErr=" << (relError * 100.0f) << "% (>5%)\n";
    }

    return log.str();
}

namespace {

struct ChunkBenchResult {
    VARPS outputs;
    double firstMs = -1.0;
    double avgMs = -1.0;
    std::vector<double> warmupMs;
    std::string info;
};

static bool fileExists(const std::string& path) {
    struct stat st;
    return ::stat(path.c_str(), &st) == 0;
}

static bool isDirectory(const std::string& path) {
    struct stat st;
    return ::stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

static std::string readTextFile(const std::string& path) {
    std::ifstream ifs(path);
    if (!ifs.good()) {
        return "";
    }
    std::ostringstream oss;
    oss << ifs.rdbuf();
    return oss.str();
}

static size_t skipJsonWs(const std::string& s, size_t i) {
    while (i < s.size()) {
        unsigned char c = (unsigned char)s[i];
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
        ++i;
    }
    return i;
}

static bool findJsonKeyValueStart(const std::string& jsonText,
                                 const std::string& key,
                                 size_t& valuePosOut) {
    std::string needle = "\"" + key + "\"";
    size_t kpos = jsonText.find(needle);
    if (kpos == std::string::npos) return false;
    size_t colon = jsonText.find(':', kpos + needle.size());
    if (colon == std::string::npos) return false;
    valuePosOut = skipJsonWs(jsonText, colon + 1);
    return valuePosOut < jsonText.size();
}

static int extractJsonInt(const std::string& jsonText, const std::string& key, int defaultValue) {
    size_t pos = 0;
    if (!findJsonKeyValueStart(jsonText, key, pos)) return defaultValue;
    bool neg = false;
    if (jsonText[pos] == '-') {
        neg = true;
        ++pos;
    }
    if (pos >= jsonText.size() || !std::isdigit((unsigned char)jsonText[pos])) return defaultValue;
    long long v = 0;
    while (pos < jsonText.size() && std::isdigit((unsigned char)jsonText[pos])) {
        v = v * 10 + (jsonText[pos] - '0');
        ++pos;
    }
    if (neg) v = -v;
    if (v > std::numeric_limits<int>::max()) return std::numeric_limits<int>::max();
    if (v < std::numeric_limits<int>::min()) return std::numeric_limits<int>::min();
    return (int)v;
}

static std::string extractJsonString(const std::string& jsonText, const std::string& key,
                                     const std::string& defaultValue) {
    size_t pos = 0;
    if (!findJsonKeyValueStart(jsonText, key, pos)) return defaultValue;
    if (jsonText[pos] != '"') return defaultValue;
    ++pos;
    std::string out;
    while (pos < jsonText.size()) {
        char c = jsonText[pos++];
        if (c == '"') break;
        if (c == '\\' && pos < jsonText.size()) {
            char esc = jsonText[pos++];
            if (esc == '"' || esc == '\\' || esc == '/') out.push_back(esc);
            else if (esc == 'b') out.push_back('\b');
            else if (esc == 'f') out.push_back('\f');
            else if (esc == 'n') out.push_back('\n');
            else if (esc == 'r') out.push_back('\r');
            else if (esc == 't') out.push_back('\t');
            else out.push_back(esc);
            continue;
        }
        out.push_back(c);
    }
    if (out.empty()) return defaultValue;
    return out;
}

static int extractChunkIndexFromName(const std::string& name) {
    const std::string prefix = "visual_blocks_npu_";
    const std::string suffix = ".mnn";
    if (name.size() <= prefix.size() + suffix.size()) return std::numeric_limits<int>::max();
    if (name.compare(0, prefix.size(), prefix) != 0) return std::numeric_limits<int>::max();
    if (name.compare(name.size() - suffix.size(), suffix.size(), suffix) != 0) return std::numeric_limits<int>::max();
    size_t p = prefix.size();
    if (!std::isdigit((unsigned char)name[p])) return std::numeric_limits<int>::max();
    int v = 0;
    while (p < name.size() - suffix.size() && std::isdigit((unsigned char)name[p])) {
        v = v * 10 + (name[p] - '0');
        ++p;
    }
    if (p != name.size() - suffix.size()) return std::numeric_limits<int>::max();
    return v;
}

static std::string basenameOf(const std::string& path) {
    auto pos = path.find_last_of('/');
    if (pos == std::string::npos) {
        return path;
    }
    return path.substr(pos + 1);
}

static std::vector<std::string> listVisualChunkModels(const std::string& modelDir) {
    std::vector<std::string> out;
    DIR* dir = ::opendir(modelDir.c_str());
    if (dir == nullptr) {
        return out;
    }
    struct dirent* ent = nullptr;
    while ((ent = ::readdir(dir)) != nullptr) {
        std::string name = ent->d_name;
        if (extractChunkIndexFromName(name) != std::numeric_limits<int>::max()) {
            out.push_back(modelDir + "/" + name);
        }
    }
    ::closedir(dir);
    std::sort(out.begin(), out.end(), [](const std::string& a, const std::string& b) {
        int ia = extractChunkIndexFromName(basenameOf(a));
        int ib = extractChunkIndexFromName(basenameOf(b));
        if (ia != ib) {
            return ia < ib;
        }
        return a < b;
    });
    return out;
}

static MNNForwardType visualBackendFromString(const std::string& backend) {
    std::string v = backend;
    std::transform(v.begin(), v.end(), v.begin(),
                   [](unsigned char c) { return (char)std::tolower(c); });
    if (v == "npu") {
        return MNN_FORWARD_NN;
    }
    if (v == "hiai_delegate") {
        return MNN_FORWARD_USER_1;
    }
    if (v == "hiai") {
        return MNN_FORWARD_USER_0;
    }
    return MNN_FORWARD_USER_0;
}

static std::string forwardTypeName(MNNForwardType type) {
    switch (type) {
        case MNN_FORWARD_CPU: return "CPU";
        case MNN_FORWARD_NN: return "NN";
        case MNN_FORWARD_USER_0: return "HiAI";
        case MNN_FORWARD_USER_1: return "HiAIDelegate";
        default: return "Unknown";
    }
}

static std::string varShapeStringLocal(const VARP& v) {
    if (v.get() == nullptr || v->getInfo() == nullptr) {
        return "<null>";
    }
    std::ostringstream oss;
    auto info = v->getInfo();
    for (int i = 0; i < (int)info->dim.size(); ++i) {
        oss << info->dim[i];
        if (i + 1 < (int)info->dim.size()) {
            oss << "x";
        }
    }
    return oss.str();
}

static VARP cloneToHostInput(const VARP& src, const char* name = nullptr) {
    if (src.get() == nullptr || src->getInfo() == nullptr) {
        return nullptr;
    }
    auto info = src->getInfo();
    auto srcHost = src->readMap<uint8_t>();
    if (srcHost == nullptr) {
        return nullptr;
    }
    auto dst = _Input(info->dim, NCHW, info->type);
    auto dstHost = dst->writeMap<uint8_t>();
    if (dstHost == nullptr) {
        return nullptr;
    }
    ::memcpy(dstHost, srcHost, (size_t)info->size * (size_t)info->type.bytes());
    if (name != nullptr) {
        dst->setName(name);
    }
    return dst;
}

static bool readVarToFloatVector(const VARP& src, std::vector<float>& out, std::string& err) {
    if (src.get() == nullptr || src->getInfo() == nullptr) {
        err = "null output";
        return false;
    }
    VARP readVar = src;
    auto info = src->getInfo();
    if (!(info->type.code == halide_type_float && info->type.bits == 32)) {
        readVar = _Cast(src, halide_type_of<float>());
        if (readVar.get() == nullptr || readVar->getInfo() == nullptr) {
            err = "cast to float failed";
            return false;
        }
        info = readVar->getInfo();
    }
    auto ptr = readVar->readMap<float>();
    if (ptr == nullptr) {
        err = "readMap<float> returned null";
        return false;
    }
    out.assign(ptr, ptr + info->size);
    return true;
}

// ---- save outputs for offline Python analysis ----

static bool saveVectorToBin(const std::string& path, const std::vector<float>& data, std::string& err) {
    const uint8_t* bytes = reinterpret_cast<const uint8_t*>(data.data());
    size_t byteLen = data.size() * sizeof(float);
    if (!writeFileBytes(path, bytes, byteLen, err)) return false;
    return true;
}

static void saveChunkOutputs(const std::string& outDir, int chunkIdx,
                             const std::string& chunkName,
                             const std::vector<VARP>& cpuOutputs,
                             const std::vector<VARP>& npuOutputs) {
    for (size_t oi = 0; oi < cpuOutputs.size() && oi < npuOutputs.size(); ++oi) {
        std::vector<float> cpuVec, npuVec;
        std::string readErr;
        if (!readVarToFloatVector(cpuOutputs[oi], cpuVec, readErr)) continue;
        if (!readVarToFloatVector(npuOutputs[oi], npuVec, readErr)) continue;

        const std::string label = (oi == 0) ? "hidden_states"
            : ("deepstack_hidden_" + std::to_string(oi - 1));

        std::string shapeStr = "unknown";
        if (cpuOutputs[oi]->getInfo() && !cpuOutputs[oi]->getInfo()->dim.empty()) {
            std::ostringstream ss;
            auto& dim = cpuOutputs[oi]->getInfo()->dim;
            for (size_t d = 0; d < dim.size(); ++d) {
                if (d) ss << "x";
                ss << dim[d];
            }
            shapeStr = ss.str();
        }

        std::string cpuPath = outDir + "/chunk" + std::to_string(chunkIdx + 1)
                            + "_out" + std::to_string(oi) + "_" + shapeStr + "_cpu.bin";
        std::string npuPath = outDir + "/chunk" + std::to_string(chunkIdx + 1)
                            + "_out" + std::to_string(oi) + "_" + shapeStr + "_npu.bin";

        std::string saveErr;
        saveVectorToBin(cpuPath, cpuVec, saveErr);
        saveVectorToBin(npuPath, npuVec, saveErr);
    }

    std::string metaPath = outDir + "/chunk" + std::to_string(chunkIdx + 1) + "_meta.txt";
    std::ostringstream meta;
    meta << "chunk=" << chunkName << "\n";
    for (size_t oi = 0; oi < cpuOutputs.size() && oi < npuOutputs.size(); ++oi) {
        const std::string label = (oi == 0) ? "hidden_states"
            : ("deepstack_hidden_" + std::to_string(oi - 1));
        std::string shapeStr = "unknown";
        if (cpuOutputs[oi]->getInfo() && !cpuOutputs[oi]->getInfo()->dim.empty()) {
            std::ostringstream ss;
            auto& dim = cpuOutputs[oi]->getInfo()->dim;
            for (size_t d = 0; d < dim.size(); ++d) {
                if (d) ss << "x";
                ss << dim[d];
            }
            shapeStr = ss.str();
        }
        meta << "out" << oi << "=" << label << " shape=" << shapeStr << "\n";
    }
    std::string metaStr = meta.str();
    std::vector<uint8_t> metaBytes(metaStr.begin(), metaStr.end());
    std::string metaErr;
    writeFileBytes(metaPath, metaBytes.data(), metaBytes.size(), metaErr);
}

// ---- end save helpers ----

static std::vector<VARP> cloneInputs(const std::vector<VARP>& srcs) {
    std::vector<VARP> out;
    out.reserve(srcs.size());
    for (size_t i = 0; i < srcs.size(); ++i) {
        out.push_back(cloneToHostInput(srcs[i]));
    }
    return out;
}

static bool pickEvenGrid(int seqLen, int& gridH, int& gridW) {
    int bestH = 0, bestW = 0;
    int bestDiff = std::numeric_limits<int>::max();
    for (int h = 2; h * h <= seqLen; h += 2) {
        if (seqLen % h != 0) {
            continue;
        }
        int w = seqLen / h;
        if ((w % 2) != 0) {
            continue;
        }
        int diff = std::abs(h - w);
        if (diff < bestDiff) {
            bestDiff = diff;
            bestH = h;
            bestW = w;
        }
    }
    if (bestH == 0 || bestW == 0) {
        return false;
    }
    gridH = bestH;
    gridW = bestW;
    return true;
}

static std::vector<VARP> buildQwen3VlPreInputs(int seqLen, int patchDim, int numGridPerSide,
                                               std::string& err) {
    constexpr int mergeSize = 2;
    int gridH = 0, gridW = 0;
    if (!pickEvenGrid(seqLen, gridH, gridW)) {
        err = "failed to find even grid_h/grid_w for seq_len=" + std::to_string(seqLen);
        return {};
    }

    std::vector<float> patchesData(seqLen * patchDim);
    for (int i = 0; i < (int)patchesData.size(); ++i) {
        patchesData[i] = (float)((i % 29) - 14) * 0.01f;
    }
    auto patches = _Input({seqLen, patchDim}, NCHW);
    ::memcpy(patches->writeMap<float>(), patchesData.data(), patchesData.size() * sizeof(float));

    VARP positionIds = _Input({2, seqLen}, NCHW, halide_type_of<int>());
    auto hpos = positionIds->writeMap<int>();
    auto wpos = hpos + seqLen;
    const int wblockSize = mergeSize * mergeSize;
    const int hblockSize = wblockSize * (gridW / mergeSize);
    for (int i = 0; i < gridH; ++i) {
        int hIdx = i / mergeSize;
        int hOff = i % mergeSize;
        for (int j = 0; j < gridW; ++j) {
            int wIdx = j / mergeSize;
            int wOff = j % mergeSize;
            int index = hIdx * hblockSize + wIdx * wblockSize + hOff * 2 + wOff;
            hpos[index] = i;
            wpos[index] = j;
        }
    }

    std::vector<float> hIdxs(gridH);
    std::vector<float> wIdxs(gridW);
    for (int i = 0; i < gridH; ++i) {
        hIdxs[i] = (gridH > 1)
            ? static_cast<float>(i) * (numGridPerSide - 1) / (gridH - 1)
            : 0.0f;
    }
    for (int i = 0; i < gridW; ++i) {
        wIdxs[i] = (gridW > 1)
            ? static_cast<float>(i) * (numGridPerSide - 1) / (gridW - 1)
            : 0.0f;
    }

    VARP idxTensor = _Input({4, seqLen}, NCHW, halide_type_of<int>());
    VARP weightTensor = _Input({4, seqLen}, NCHW, halide_type_of<float>());
    auto idxPtr = idxTensor->writeMap<int>();
    auto weightPtr = weightTensor->writeMap<float>();
    for (int i = 0; i < gridH; ++i) {
        int hFloor = static_cast<int>(hIdxs[i]);
        int hCeil = std::min(hFloor + 1, numGridPerSide - 1);
        float dh = hIdxs[i] - hFloor;
        for (int j = 0; j < gridW; ++j) {
            int wFloor = static_cast<int>(wIdxs[j]);
            int wCeil = std::min(wFloor + 1, numGridPerSide - 1);
            float dw = wIdxs[j] - wFloor;
            int idx = i * gridW + j;
            idxPtr[0 * seqLen + idx] = hFloor * numGridPerSide + wFloor;
            idxPtr[1 * seqLen + idx] = hFloor * numGridPerSide + wCeil;
            idxPtr[2 * seqLen + idx] = hCeil * numGridPerSide + wFloor;
            // Keep the same index layout used in omni.cpp so the chunk test
            // matches the current Harmony app deployment path exactly.
            idxPtr[3 * seqLen + idx] = hCeil * numGridPerSide + wCeil;
            weightPtr[0 * seqLen + idx] = (1.0f - dh) * (1.0f - dw);
            weightPtr[1 * seqLen + idx] = (1.0f - dh) * dw;
            weightPtr[2 * seqLen + idx] = dh * (1.0f - dw);
            weightPtr[3 * seqLen + idx] = dh * dw;
        }
    }

    idxTensor = _Reshape(idxTensor, {4, 1, gridH / mergeSize, mergeSize, gridW / mergeSize, mergeSize});
    idxTensor = _Permute(idxTensor, {0, 1, 2, 4, 3, 5});
    idxTensor = _Reshape(idxTensor, {4, -1});
    weightTensor = _Reshape(weightTensor, {4, 1, gridH / mergeSize, mergeSize, gridW / mergeSize, mergeSize});
    weightTensor = _Permute(weightTensor, {0, 1, 2, 4, 3, 5});
    weightTensor = _Reshape(weightTensor, {4, -1});
    return {patches, positionIds, idxTensor, weightTensor};
}

static std::string compareOutputVectors(const std::vector<float>& cpuOutput,
                                        const std::vector<float>& npuOutput,
                                        const std::string& label,
                                        bool& allPass) {
    std::ostringstream log;
    if (cpuOutput.size() != npuOutput.size()) {
        allPass = false;
        log << "  [" << label << "] FAIL: size mismatch CPU=" << cpuOutput.size()
            << " NPU=" << npuOutput.size() << "\n";
        return log.str();
    }
    float maxRef = 0.0f;
    float maxDiff = 0.0f;
    double sumSq = 0.0;
    int maxDiffIdx = 0;
    int failCount = 0;
    for (size_t i = 0; i < cpuOutput.size(); ++i) {
        maxRef = std::max(maxRef, std::fabs(cpuOutput[i]));
        float diff = std::fabs(cpuOutput[i] - npuOutput[i]);
        sumSq += (double)diff * (double)diff;
        if (diff > maxDiff) {
            maxDiff = diff;
            maxDiffIdx = (int)i;
        }
    }
    if (maxRef < 1e-6f) {
        maxRef = 1e-6f;
    }
    for (size_t i = 0; i < cpuOutput.size(); ++i) {
        float diff = std::fabs(cpuOutput[i] - npuOutput[i]);
        if (diff / maxRef > 0.02f) {
            failCount++;
        }
    }
    const float relError = maxDiff / maxRef;
    const double rms = std::sqrt(sumSq / std::max<size_t>(1, cpuOutput.size()));
    log << "  [" << label << "] max|ref|=" << maxRef
        << " maxDiff=" << maxDiff
        << " relErr=" << (relError * 100.0f) << "%"
        << " rmsDiff=" << rms
        << " @idx=" << maxDiffIdx
        << " fail=" << failCount << "/" << cpuOutput.size();
    if (relError < 0.02f) {
        log << " PASS\n";
    } else if (relError < 0.05f) {
        allPass = false;
        log << " WARN\n";
    } else {
        allPass = false;
        log << " FAIL\n";
    }
    return log.str();
}

static std::string runQwen3VlRopeTest(int seqLen = 608,
                                      int numHead = 16,
                                      int headDim = 64,
                                      int warmup = 1,
                                      int repeat = 2) {
    std::ostringstream log;
    const int batch = 1;
    if (seqLen <= 0 || numHead <= 0 || headDim <= 0) {
        log << "ERROR: invalid shape args seqLen=" << seqLen
            << " numHead=" << numHead << " headDim=" << headDim << "\n";
        return log.str();
    }

    const int qElem = batch * seqLen * numHead * headDim;
    const int rotaryElem = 2 * 1 * seqLen * 1 * headDim;
    std::vector<float> qData(qElem);
    std::vector<float> rotaryData(rotaryElem);
    for (int i = 0; i < qElem; ++i) {
        qData[i] = (float)((i % 41) - 20) * 0.01f;
    }
    for (int i = 0; i < rotaryElem; ++i) {
        rotaryData[i] = (float)((i % 37) - 18) * 0.02f;
    }

    std::vector<int8_t> graphBuffer;
    {
        auto q = _Input({batch, seqLen, numHead, headDim}, NCHW);
        auto rotary = _Input({2, 1, seqLen, 1, headDim}, NCHW);
        q->setName("rope_q");
        rotary->setName("rotary_pos_emb");

        auto idx0 = _Scalar<int>(0);
        auto idx1 = _Scalar<int>(1);
        auto axis0 = _Scalar<int>(0);
        auto gatherCos = _GatherV2(rotary, idx0, axis0);
        auto gatherSin = _GatherV2(rotary, idx1, axis0);
        gatherCos->setName("rope_gather_cos");
        gatherSin->setName("rope_gather_sin");

        auto mulCos = _Multiply(q, gatherCos);
        auto mulSin = _Multiply(q, gatherSin);
        auto ropeOut = _Add(mulCos, mulSin);
        mulCos->setName("rope_mul_cos");
        mulSin->setName("rope_mul_sin");
        ropeOut->setName("rope_out");
        graphBuffer = Variable::save({gatherCos, gatherSin, mulCos, mulSin, ropeOut});
        if (graphBuffer.empty()) {
            log << "ERROR: Variable::save for rope graph returned empty\n";
            return log.str();
        }
    }

    auto makeInputs = [&]() -> std::vector<VARP> {
        auto q = _Input({batch, seqLen, numHead, headDim}, NCHW);
        ::memcpy(q->writeMap<float>(), qData.data(), qData.size() * sizeof(float));
        auto rotary = _Input({2, 1, seqLen, 1, headDim}, NCHW);
        ::memcpy(rotary->writeMap<float>(), rotaryData.data(), rotaryData.size() * sizeof(float));
        return {q, rotary};
    };

    auto runOnBackend = [&](MNNForwardType fwdType,
                            const MNN::BackendConfig& backendCfg,
                            const Module::Config& moduleCfg,
                            std::vector<std::vector<float>>& outTensors,
                            std::vector<std::string>& outShapes,
                            double& firstMs,
                            std::vector<double>& warmupMs,
                            double& avgMs,
                            std::string& errOut) -> bool {
        using Clock = std::chrono::high_resolution_clock;
        using Ms = std::chrono::duration<double, std::milli>;
        auto elapsed = [](Clock::time_point a, Clock::time_point b) {
            return Ms(b - a).count();
        };

        MNN::ScheduleConfig sched;
        sched.type = fwdType;
        sched.numThread = 1;
        MNN::BackendConfig cfg = backendCfg;
        sched.backendConfig = &cfg;
        std::shared_ptr<Executor::RuntimeManager> rtMgr(
            Executor::RuntimeManager::createRuntimeManager(sched));
        if (rtMgr.get() == nullptr) {
            errOut = "createRuntimeManager failed";
            return false;
        }
        std::shared_ptr<Module> module(Module::load(
            {}, {}, reinterpret_cast<const uint8_t*>(graphBuffer.data()), graphBuffer.size(), rtMgr, &moduleCfg));
        if (module.get() == nullptr) {
            errOut = "Module::load returned nullptr";
            return false;
        }

        auto t0 = Clock::now();
        auto ins = makeInputs();
        auto outs = module->onForward(ins);
        firstMs = elapsed(t0, Clock::now());
        if (outs.empty()) {
            errOut = "onForward returned empty outputs";
            return false;
        }
        outTensors.clear();
        outShapes.clear();
        outTensors.resize(outs.size());
        outShapes.resize(outs.size());
        for (size_t i = 0; i < outs.size(); ++i) {
            std::string readErr;
            if (!readVarToFloatVector(outs[i], outTensors[i], readErr)) {
                errOut = "read output[" + std::to_string(i) + "] failed: " + readErr;
                return false;
            }
            outShapes[i] = varShapeStringLocal(outs[i]);
        }

        warmupMs.clear();
        for (int i = 0; i < warmup; ++i) {
            auto wi = makeInputs();
            auto tw0 = Clock::now();
            auto o = module->onForward(wi);
            if (o.empty() || o[0].get() == nullptr || o[0]->readMap<void>() == nullptr) {
                errOut = "warmup output invalid";
                return false;
            }
            warmupMs.push_back(elapsed(tw0, Clock::now()));
        }

        auto ts0 = Clock::now();
        for (int i = 0; i < repeat; ++i) {
            auto si = makeInputs();
            auto o = module->onForward(si);
            if (o.empty() || o[0].get() == nullptr || o[0]->readMap<void>() == nullptr) {
                errOut = "steady output invalid";
                return false;
            }
        }
        avgMs = elapsed(ts0, Clock::now()) / std::max(1, repeat);
        return true;
    };

    log << "=== Qwen3VL RoPE Gather Test ===\n";
    log << "shape: q=" << batch << "x" << seqLen << "x" << numHead << "x" << headDim
        << " rotary=2x1x" << seqLen << "x1x" << headDim << "\n";
    log << "goal: verify Gather(axis=0, idx=0/1) + broadcast Mul/Add on HiAI vs CPU\n";

    MNN::BackendConfig cpuCfg = makeCpuBackendConfig();
    Module::Config cpuModuleCfg;
    cpuModuleCfg.shapeMutable = true;
    cpuModuleCfg.rearrange = true;

    std::vector<std::vector<float>> cpuOuts;
    std::vector<std::string> cpuShapes;
    std::vector<double> cpuWarmupMs;
    double cpuFirstMs = -1.0, cpuAvgMs = -1.0;
    std::string err;
    if (!runOnBackend(MNN_FORWARD_CPU, cpuCfg, cpuModuleCfg,
                      cpuOuts, cpuShapes, cpuFirstMs, cpuWarmupMs, cpuAvgMs, err)) {
        log << "ERROR: CPU rope run failed: " << err << "\n";
        return log.str();
    }

    MNN::BackendConfig npuCfg;
    npuCfg.memory = MNN::BackendConfig::Memory_High;
    Module::Config npuModuleCfg;
    npuModuleCfg.shapeMutable = false;
    npuModuleCfg.rearrange = false;
    std::vector<std::vector<float>> npuOuts;
    std::vector<std::string> npuShapes;
    std::vector<double> npuWarmupMs;
    double npuFirstMs = -1.0, npuAvgMs = -1.0;
    if (!runOnBackend(MNN_FORWARD_USER_0, npuCfg, npuModuleCfg,
                      npuOuts, npuShapes, npuFirstMs, npuWarmupMs, npuAvgMs, err)) {
        log << "ERROR: HiAI rope run failed: " << err << "\n";
        return log.str();
    }

    log << "CPU outputs=" << cpuOuts.size() << " shapes:";
    for (const auto& s : cpuShapes) log << " " << s;
    log << "\n";
    log << "HiAI outputs=" << npuOuts.size() << " shapes:";
    for (const auto& s : npuShapes) log << " " << s;
    log << "\n";

    log << "CPU first=" << cpuFirstMs << "ms";
    for (size_t i = 0; i < cpuWarmupMs.size(); ++i) log << " w" << i << "=" << cpuWarmupMs[i] << "ms";
    log << " steady(x" << repeat << ")=" << cpuAvgMs << "ms\n";
    log << "HiAI first=" << npuFirstMs << "ms";
    for (size_t i = 0; i < npuWarmupMs.size(); ++i) log << " w" << i << "=" << npuWarmupMs[i] << "ms";
    log << " steady(x" << repeat << ")=" << npuAvgMs << "ms\n";

    const std::vector<std::string> names = {
        "gather_cos", "gather_sin", "mul_cos", "mul_sin", "rope_add"
    };
    bool allPass = true;
    if (cpuOuts.size() != npuOuts.size()) {
        allPass = false;
        log << "FAIL: output count mismatch CPU=" << cpuOuts.size()
            << " HiAI=" << npuOuts.size() << "\n";
    }
    const size_t cnt = std::min(cpuOuts.size(), npuOuts.size());
    for (size_t i = 0; i < cnt; ++i) {
        const std::string label = (i < names.size()) ? names[i] : ("out_" + std::to_string(i));
        log << compareOutputVectors(cpuOuts[i], npuOuts[i], label, allPass);
    }
    log << (allPass ? "PASS\n" : "WARN/FAIL\n");
    return log.str();
}

// Synthetic LayerNorm A/B test. Builds a single-op VARP graph
//   x[1, S, H] -> _LayerNorm(axis=[-1], epsilon=1e-6, gamma, beta)
// via the public Express helper _LayerNorm (added to libMNN), serialises
// it once with Variable::save, then Module::load's the buffer twice — once
// on CPU and once on HiAI NPU — so both backends hit their native
// OpType_LayerNorm kernel (NPULayerNorm.cpp vs CPULayerNorm.cpp).
// Weights are synthetic (we only care about CPU-vs-NPU numerical agreement
// and throughput, not real Qwen3VL semantics). Default shape [1, 608, 1024]
// matches the hidden tensor of /blocks.0/input_layernorm in the exported
// Qwen3VL visual encoder (see test_qwen3vl_op.txt).
static std::string runQwen3VlLayerNormABTest(int seqLen = 608,
                                             int hiddenDim = 1024,
                                             int warmup = 1,
                                             int repeat = 2,
                                             bool gammaZero = false) {
    using Clock = std::chrono::high_resolution_clock;
    using Ms = std::chrono::duration<double, std::milli>;
    auto elapsed = [](Clock::time_point a, Clock::time_point b) {
        return Ms(b - a).count();
    };
    std::ostringstream log;
    if (seqLen <= 0 || hiddenDim <= 0) {
        log << "ERROR: invalid shape seqLen=" << seqLen << " hiddenDim=" << hiddenDim << "\n";
        return log.str();
    }

    const int batch = 1;
    const size_t totalElem = (size_t)batch * seqLen * hiddenDim;
    const float eps = 1e-6f;

    std::vector<float> xData(totalElem);
    std::vector<float> gamma(hiddenDim);
    std::vector<float> beta(hiddenDim);
    for (size_t i = 0; i < totalElem; ++i) {
        const int signedMod = static_cast<int>(i % 29);
        xData[i] = static_cast<float>(signedMod - 14) * 0.05f;
    }
    for (int i = 0; i < hiddenDim; ++i) {
        gamma[i] = 1.0f + (float)((i % 17) - 8) * 0.01f;
        beta[i]  = (float)((i % 13) - 6) * 0.01f;
    }
    // Diagnostic mode: zero gamma to detect whether HiAI's hiai::op::LayerNorm
    // silently ignores gamma. With gamma=0 and beta=real, math says output = beta
    // identically. If NPU output also equals beta in this mode AND in real-gamma
    // mode, gamma is being eaten. If outputs differ between the two modes, gamma
    // is at least partially applied.
    if (gammaZero) {
        std::fill(gamma.begin(), gamma.end(), 0.0f);
    }

    // Build VARP graph once under default CPU executor scope, serialize.
    // Variable::save populates inputIndexes/outputIndexes that NPU kernels
    // dereference — same reason _Attention test goes through Module.
    std::vector<int8_t> graphBuffer;
    {
        auto x = _Input({batch, seqLen, hiddenDim}, NCHW);
        x->setName("ln_in");
        auto y = _LayerNorm(x, {-1}, eps, gamma, beta, /*group=*/1, /*useRMS=*/false);
        if (y.get() == nullptr) {
            log << "ERROR: _LayerNorm returned null (libMNN.so too old?)\n";
            return log.str();
        }
        y->setName("ln_out");
        graphBuffer = Variable::save({y});
        if (graphBuffer.empty()) {
            log << "ERROR: Variable::save returned empty buffer\n";
            return log.str();
        }
    }

    auto makeInputs = [&]() -> std::vector<VARP> {
        auto x = _Input({batch, seqLen, hiddenDim}, NCHW);
        ::memcpy(x->writeMap<float>(), xData.data(), totalElem * sizeof(float));
        return {x};
    };

    auto runOnBackend = [&](MNNForwardType fwdType,
                            const MNN::BackendConfig& backendCfg,
                            const Module::Config& moduleCfg,
                            std::vector<float>& outVec,
                            std::string& outShape,
                            double& firstMs,
                            std::vector<double>& warmupLog,
                            double& avgMs,
                            std::string& errOut) -> bool {
        MNN::ScheduleConfig sched;
        sched.type = fwdType;
        sched.numThread = 1;
        MNN::BackendConfig cfg = backendCfg;
        sched.backendConfig = &cfg;
        std::shared_ptr<Executor::RuntimeManager> rtMgr(
            Executor::RuntimeManager::createRuntimeManager(sched));
        if (rtMgr.get() == nullptr) {
            errOut = "createRuntimeManager failed";
            return false;
        }
        std::shared_ptr<Module> module(Module::load(
            {}, {}, reinterpret_cast<const uint8_t*>(graphBuffer.data()),
            graphBuffer.size(), rtMgr, &moduleCfg));
        if (module.get() == nullptr) {
            errOut = "Module::load returned nullptr";
            return false;
        }

        auto t0 = Clock::now();
        auto ins = makeInputs();
        auto outs = module->onForward(ins);
        firstMs = elapsed(t0, Clock::now());
        if (outs.empty() || outs[0].get() == nullptr) {
            errOut = "onForward returned empty output";
            return false;
        }
        std::string readErr;
        if (!readVarToFloatVector(outs[0], outVec, readErr)) {
            errOut = "read output failed: " + readErr;
            return false;
        }
        outShape = varShapeStringLocal(outs[0]);

        warmupLog.clear();
        for (int i = 0; i < warmup; ++i) {
            auto wi = makeInputs();
            auto tw0 = Clock::now();
            auto o = module->onForward(wi);
            if (o.empty() || o[0].get() == nullptr || o[0]->readMap<void>() == nullptr) {
                errOut = "warmup output invalid";
                return false;
            }
            warmupLog.push_back(elapsed(tw0, Clock::now()));
        }
        auto ts0 = Clock::now();
        for (int i = 0; i < repeat; ++i) {
            auto si = makeInputs();
            auto o = module->onForward(si);
            if (o.empty() || o[0].get() == nullptr || o[0]->readMap<void>() == nullptr) {
                errOut = "steady output invalid";
                return false;
            }
        }
        avgMs = elapsed(ts0, Clock::now()) / std::max(1, repeat);
        return true;
    };

    log << "=== Qwen3VL LayerNorm A/B Test (synthetic, axis=-1) ===\n";
    log << "shape: x=" << batch << "x" << seqLen << "x" << hiddenDim
        << "  gamma=beta=" << hiddenDim
        << "  epsilon=" << eps
        << "  gammaMode=" << (gammaZero ? "ZERO" : "REAL") << "\n";
    log << "goal: compare CPULayerNorm vs NPULayerNorm (HiAI) precision & perf\n";

    MNN::BackendConfig cpuCfg = makeCpuBackendConfig();
    Module::Config cpuModuleCfg;
    cpuModuleCfg.shapeMutable = true;
    cpuModuleCfg.rearrange = true;
    std::vector<float> cpuOut;
    std::string cpuShape;
    std::vector<double> cpuWarmupMs;
    double cpuFirstMs = -1.0, cpuAvgMs = -1.0;
    std::string err;
    if (!runOnBackend(MNN_FORWARD_CPU, cpuCfg, cpuModuleCfg,
                      cpuOut, cpuShape, cpuFirstMs, cpuWarmupMs, cpuAvgMs, err)) {
        log << "ERROR: CPU layernorm run failed: " << err << "\n";
        return log.str();
    }

    MNN::BackendConfig npuCfg;
    npuCfg.memory = MNN::BackendConfig::Memory_High;
    Module::Config npuModuleCfg;
    // HiAI compiles the OM graph at load time against fixed shapes; making the
    // shape mutable would trigger rebuild on every forward. Mirrors
    // omni.cpp::loadVisual for MNN_FORWARD_USER_0.
    npuModuleCfg.shapeMutable = false;
    npuModuleCfg.rearrange = false;
    std::vector<float> npuOut;
    std::string npuShape;
    std::vector<double> npuWarmupMs;
    double npuFirstMs = -1.0, npuAvgMs = -1.0;
    if (!runOnBackend(MNN_FORWARD_USER_0, npuCfg, npuModuleCfg,
                      npuOut, npuShape, npuFirstMs, npuWarmupMs, npuAvgMs, err)) {
        log << "ERROR: HiAI layernorm run failed: " << err << "\n";
        return log.str();
    }

    log << "CPU  shape=" << cpuShape << " first=" << cpuFirstMs << "ms";
    for (size_t i = 0; i < cpuWarmupMs.size(); ++i) log << " w" << i << "=" << cpuWarmupMs[i] << "ms";
    log << " steady(x" << repeat << ")=" << cpuAvgMs << "ms\n";
    log << "HiAI shape=" << npuShape << " first=" << npuFirstMs << "ms(load+compile+infer)";
    for (size_t i = 0; i < npuWarmupMs.size(); ++i) log << " w" << i << "=" << npuWarmupMs[i] << "ms";
    log << " steady(x" << repeat << ")=" << npuAvgMs << "ms\n";
    if (npuAvgMs > 0) {
        char buf[96];
        snprintf(buf, sizeof(buf), "speedup(steady) CPU/HiAI=%.2fx (>1 = NPU faster)\n",
                 cpuAvgMs / npuAvgMs);
        log << buf;
    }

    auto vecStats = [](const std::vector<float>& v) {
        if (v.empty()) return std::string("empty");
        float mn = v[0], mx = v[0];
        double sumsq = 0.0, sumabs = 0.0;
        for (float x : v) {
            mn = std::min(mn, x);
            mx = std::max(mx, x);
            sumsq += (double)x * x;
            sumabs += std::fabs(x);
        }
        char buf[160];
        snprintf(buf, sizeof(buf), "min=%g max=%g mean|.|=%g rms=%g n=%zu",
                 mn, mx, sumabs / v.size(),
                 std::sqrt(sumsq / v.size()), v.size());
        return std::string(buf);
    };
    auto headDump = [](const std::vector<float>& v, int n) {
        std::ostringstream os;
        int k = std::min<int>(n, (int)v.size());
        for (int i = 0; i < k; ++i) {
            if (i) os << " ";
            os << v[i];
        }
        return os.str();
    };
    log << "cpu  stats: " << vecStats(cpuOut) << "\n";
    log << "npu  stats: " << vecStats(npuOut) << "\n";
    log << "cpu[0..15]: " << headDump(cpuOut, 16) << "\n";
    log << "npu[0..15]: " << headDump(npuOut, 16) << "\n";
    // Peek at a mid-tensor row start so we can tell per-row LN vs whole-tensor LN.
    if (cpuOut.size() >= (size_t)hiddenDim * 2) {
        size_t r1 = (size_t)hiddenDim;          // row 1 head
        size_t r2 = cpuOut.size() - (size_t)hiddenDim; // last row head
        log << "cpu[row1 h=0..7]: " << headDump(
                std::vector<float>(cpuOut.begin() + r1, cpuOut.begin() + r1 + 8), 8) << "\n";
        log << "npu[row1 h=0..7]: " << headDump(
                std::vector<float>(npuOut.begin() + r1, npuOut.begin() + r1 + 8), 8) << "\n";
        log << "cpu[lastRow h=0..7]: " << headDump(
                std::vector<float>(cpuOut.begin() + r2, cpuOut.begin() + r2 + 8), 8) << "\n";
        log << "npu[lastRow h=0..7]: " << headDump(
                std::vector<float>(npuOut.begin() + r2, npuOut.begin() + r2 + 8), 8) << "\n";
    }

    bool pass = true;
    log << compareOutputVectors(cpuOut, npuOut, "layernorm_out", pass);
    log << (pass ? "PASS\n" : "WARN/FAIL\n");
    return log.str();
}

static bool runModuleBench(const std::string& modelPath,
                           MNNForwardType fwdType,
                           const MNN::BackendConfig& backendConfig,
                           const Module::Config& moduleConfig,
                           const std::vector<VARP>& baseInputs,
                           int warmup,
                           int repeat,
                           ChunkBenchResult& result) {
    using Clock = std::chrono::high_resolution_clock;
    using Ms = std::chrono::duration<double, std::milli>;
    auto elapsed = [](Clock::time_point a, Clock::time_point b) {
        return Ms(b - a).count();
    };

    MNN::ScheduleConfig sched;
    sched.type = fwdType;
    sched.numThread = 1;
    MNN::BackendConfig cfg = backendConfig;
    sched.backendConfig = &cfg;

    std::shared_ptr<Executor::RuntimeManager> rtMgr(
        Executor::RuntimeManager::createRuntimeManager(sched));
    if (rtMgr.get() == nullptr) {
        result.info = "createRuntimeManager failed";
        return false;
    }
    std::shared_ptr<Module> module(Module::load({}, {}, modelPath.c_str(), rtMgr, &moduleConfig));
    if (module.get() == nullptr) {
        result.info = "Module::load returned nullptr";
        return false;
    }

    auto t0 = Clock::now();
    auto firstInputs = cloneInputs(baseInputs);
    auto firstOut = module->onForward(firstInputs);
    if (firstOut.empty()) {
        result.info = "onForward returned empty outputs";
        return false;
    }
    for (size_t i = 0; i < firstOut.size(); ++i) {
        if (firstOut[i].get() == nullptr || firstOut[i]->readMap<void>() == nullptr) {
            result.info = "output[" + std::to_string(i) + "] readMap returned null";
            return false;
        }
        auto hostCopy = cloneToHostInput(firstOut[i]);
        if (hostCopy.get() == nullptr) {
            result.info = "host clone failed for output[" + std::to_string(i) + "]";
            return false;
        }
        result.outputs.push_back(hostCopy);
    }
    result.firstMs = elapsed(t0, Clock::now());
    if (result.outputs[0].get() != nullptr) {
        result.info = "shape=" + varShapeStringLocal(result.outputs[0]);
    }

    result.warmupMs.clear();
    for (int i = 0; i < warmup; ++i) {
        auto ins = cloneInputs(baseInputs);
        auto tw0 = Clock::now();
        auto out = module->onForward(ins);
        if (out.empty() || out[0].get() == nullptr || out[0]->readMap<void>() == nullptr) {
            result.info = "warmup output null";
            return false;
        }
        result.warmupMs.push_back(elapsed(tw0, Clock::now()));
    }

    auto ts0 = Clock::now();
    for (int i = 0; i < repeat; ++i) {
        auto ins = cloneInputs(baseInputs);
        auto out = module->onForward(ins);
        if (out.empty() || out[0].get() == nullptr || out[0]->readMap<void>() == nullptr) {
            result.info = "steady output null";
            return false;
        }
    }
    result.avgMs = elapsed(ts0, Clock::now()) / std::max(1, repeat);
    return true;
}

static std::string runTanhTest(int warmup = 1, int repeat = 2) {
    using Clock = std::chrono::high_resolution_clock;
    using Ms = std::chrono::duration<double, std::milli>;
    auto elapsed = [](Clock::time_point a, Clock::time_point b) {
        return Ms(b - a).count();
    };
    std::ostringstream log;

    // Input: wide range [-30, +30] to exercise fp16 tanh saturation
    const int N = 2048;
    std::vector<float> xData(N);
    for (int i = 0; i < N; ++i) {
        // sweep from -30 to +30, plus some edge values
        float t = -30.0f + 60.0f * (float)i / (float)(N - 1);
        xData[i] = t;
    }
    // Append specific test points
    std::vector<float> extraVals = {-100.0f, -50.0f, -20.0f, -10.0f, -5.0f, -1.0f,
                                     0.0f, 1.0f, 5.0f, 10.0f, 20.0f, 50.0f, 100.0f};
    xData.insert(xData.end(), extraVals.begin(), extraVals.end());
    const int totalN = (int)xData.size();

    // Build VARP graph: y = tanh(x)
    std::vector<int8_t> graphBuffer;
    {
        auto x = _Input({totalN}, NCHW);
        x->setName("tanh_in");
        auto y = _Tanh(x);
        if (y.get() == nullptr) {
            log << "ERROR: _Tanh returned null\n";
            return log.str();
        }
        y->setName("tanh_out");
        graphBuffer = Variable::save({y});
        if (graphBuffer.empty()) {
            log << "ERROR: Variable::save returned empty\n";
            return log.str();
        }
    }

    auto makeInputs = [&]() -> std::vector<VARP> {
        auto x = _Input({totalN}, NCHW);
        ::memcpy(x->writeMap<float>(), xData.data(), totalN * sizeof(float));
        return {x};
    };

    auto runOnBackend = [&](MNNForwardType fwdType,
                            const MNN::BackendConfig& backendCfg,
                            const Module::Config& moduleCfg,
                            std::vector<float>& outVec,
                            std::string& outShape,
                            double& firstMs,
                            std::vector<double>& warmupList,
                            double& avgMs,
                            std::string& errOut) -> bool {
        MNN::ScheduleConfig sched;
        sched.type = fwdType;
        sched.numThread = 1;
        MNN::BackendConfig cfg = backendCfg;
        sched.backendConfig = &cfg;
        std::shared_ptr<Executor::RuntimeManager> rtMgr(
            Executor::RuntimeManager::createRuntimeManager(sched));
        if (rtMgr.get() == nullptr) {
            errOut = "createRuntimeManager failed";
            return false;
        }
        std::shared_ptr<Module> module(Module::load(
            {}, {}, reinterpret_cast<const uint8_t*>(graphBuffer.data()),
            graphBuffer.size(), rtMgr, &moduleCfg));
        if (module.get() == nullptr) {
            errOut = "Module::load returned nullptr";
            return false;
        }

        auto t0 = Clock::now();
        auto ins = makeInputs();
        auto outs = module->onForward(ins);
        firstMs = elapsed(t0, Clock::now());
        if (outs.empty() || outs[0].get() == nullptr) {
            errOut = "onForward returned empty output";
            return false;
        }
        std::string readErr;
        if (!readVarToFloatVector(outs[0], outVec, readErr)) {
            errOut = "read output failed: " + readErr;
            return false;
        }
        outShape = varShapeStringLocal(outs[0]);

        warmupList.clear();
        for (int i = 0; i < warmup; ++i) {
            auto wi = makeInputs();
            auto tw0 = Clock::now();
            auto o = module->onForward(wi);
            double t = elapsed(tw0, Clock::now());
            warmupList.push_back(t);
            if (o.empty() || o[0].get() == nullptr || o[0]->readMap<void>() == nullptr) {
                errOut = "warmup output invalid";
                return false;
            }
        }
        auto ts0 = Clock::now();
        for (int i = 0; i < repeat; ++i) {
            auto si = makeInputs();
            auto o = module->onForward(si);
            if (o.empty() || o[0].get() == nullptr || o[0]->readMap<void>() == nullptr) {
                errOut = "steady output invalid";
                return false;
            }
        }
        avgMs = elapsed(ts0, Clock::now()) / std::max(1, repeat);
        return true;
    };

    log << "=== Tanh Precision Test (x in [-30,30] + edge points) ===\n";
    log << "N=" << totalN << "  warmup=" << warmup << "  repeat=" << repeat << "\n";

    MNN::BackendConfig cpuCfg = makeCpuBackendConfig();
    Module::Config cpuModuleCfg;
    cpuModuleCfg.shapeMutable = true;
    cpuModuleCfg.rearrange = true;
    std::vector<float> cpuOut;
    std::string cpuShape;
    double cpuFirst = -1, cpuAvg = -1;
    std::vector<double> cpuWarm;
    std::string err;
    if (!runOnBackend(MNN_FORWARD_CPU, cpuCfg, cpuModuleCfg, cpuOut, cpuShape, cpuFirst, cpuWarm, cpuAvg, err)) {
        log << "ERROR: CPU run failed: " << err << "\n";
        return log.str();
    }
    log << "CPU first=" << cpuFirst << "ms";
    for (size_t w = 0; w < cpuWarm.size(); ++w) log << " w" << w << "=" << cpuWarm[w] << "ms";
    log << " steady(avg)=" << cpuAvg << "ms  shape=" << cpuShape << "\n";

    MNN::BackendConfig npuCfg;
    npuCfg.memory = MNN::BackendConfig::Memory_High;
    Module::Config npuModuleCfg;
    npuModuleCfg.shapeMutable = false;
    npuModuleCfg.rearrange = false;
    std::vector<float> npuOut;
    std::string npuShape;
    double npuFirst = -1, npuAvg = -1;
    std::vector<double> npuWarm;
    if (!runOnBackend(MNN_FORWARD_USER_0, npuCfg, npuModuleCfg, npuOut, npuShape, npuFirst, npuWarm, npuAvg, err)) {
        log << "ERROR: HiAI run failed: " << err << "\n";
        return log.str();
    }
    log << "HiAI first=" << npuFirst << "ms steady(avg)=" << npuAvg << "ms  shape=" << npuShape << "\n";

    bool pass = true;
    log << compareOutputVectors(cpuOut, npuOut, "tanh", pass);

    // Detailed per-point breakdown for key values
    log << "\n--- Pointwise comparison (first 10 and edge values) ---\n";
    log << "idx     input          CPU(tanh)      NPU(tanh)      diff\n";
    auto printPoint = [&](int idx) {
        if (idx < 0 || idx >= totalN) return;
        float diff = std::fabs(cpuOut[idx] - npuOut[idx]);
        log << std::setw(5) << idx << "  "
            << std::setw(12) << std::setprecision(6) << xData[idx] << "  "
            << std::setw(12) << std::setprecision(6) << cpuOut[idx] << "  "
            << std::setw(12) << std::setprecision(6) << npuOut[idx] << "  "
            << std::setw(10) << std::setprecision(6) << diff << "\n";
    };
    for (int i = 0; i < 10; ++i) printPoint(i);
    for (int i = N; i < totalN; ++i) printPoint(i);  // edge values

    if (pass) log << "\nTanh result: PASS\n";
    else      log << "\nTanh result: FAIL\n";
    return log.str();
}

static std::string runGeluTest(int warmup = 1, int repeat = 2) {
    using Clock = std::chrono::high_resolution_clock;
    using Ms = std::chrono::duration<double, std::milli>;
    auto elapsed = [](Clock::time_point a, Clock::time_point b) {
        return Ms(b - a).count();
    };
    std::ostringstream log;

    // Same input as tanh test: wide range + edge values
    const int N = 2048;
    std::vector<float> xData(N);
    for (int i = 0; i < N; ++i) {
        xData[i] = -30.0f + 60.0f * (float)i / (float)(N - 1);
    }
    std::vector<float> extraVals = {-100.0f, -50.0f, -20.0f, -10.0f, -5.0f, -1.0f,
                                     0.0f, 1.0f, 5.0f, 10.0f, 20.0f, 50.0f, 100.0f};
    xData.insert(xData.end(), extraVals.begin(), extraVals.end());
    const int totalN = (int)xData.size();

    // Build VARP graph: y = GELU(x) using fused GELU op
    std::vector<int8_t> graphBuffer;
    {
        auto x = _Input({totalN}, NCHW);
        x->setName("gelu_in");
        auto y = _Gelu(x);
        if (y.get() == nullptr) {
            log << "ERROR: _Gelu returned null\n";
            return log.str();
        }
        y->setName("gelu_out");
        graphBuffer = Variable::save({y});
        if (graphBuffer.empty()) {
            log << "ERROR: Variable::save returned empty\n";
            return log.str();
        }
    }

    auto makeInputs = [&]() -> std::vector<VARP> {
        auto x = _Input({totalN}, NCHW);
        ::memcpy(x->writeMap<float>(), xData.data(), totalN * sizeof(float));
        return {x};
    };

    auto runOnBackend = [&](MNNForwardType fwdType,
                            const MNN::BackendConfig& backendCfg,
                            const Module::Config& moduleCfg,
                            std::vector<float>& outVec,
                            std::string& outShape,
                            double& firstMs,
                            std::vector<double>& warmupList,
                            double& avgMs,
                            std::string& errOut) -> bool {
        MNN::ScheduleConfig sched;
        sched.type = fwdType;
        sched.numThread = 1;
        MNN::BackendConfig cfg = backendCfg;
        sched.backendConfig = &cfg;
        std::shared_ptr<Executor::RuntimeManager> rtMgr(
            Executor::RuntimeManager::createRuntimeManager(sched));
        if (rtMgr.get() == nullptr) {
            errOut = "createRuntimeManager failed";
            return false;
        }
        std::shared_ptr<Module> module(Module::load(
            {}, {}, reinterpret_cast<const uint8_t*>(graphBuffer.data()),
            graphBuffer.size(), rtMgr, &moduleCfg));
        if (module.get() == nullptr) {
            errOut = "Module::load returned nullptr";
            return false;
        }

        auto t0 = Clock::now();
        auto ins = makeInputs();
        auto outs = module->onForward(ins);
        firstMs = elapsed(t0, Clock::now());
        if (outs.empty() || outs[0].get() == nullptr) {
            errOut = "onForward returned empty output";
            return false;
        }
        std::string readErr;
        if (!readVarToFloatVector(outs[0], outVec, readErr)) {
            errOut = "read output failed: " + readErr;
            return false;
        }
        outShape = varShapeStringLocal(outs[0]);

        warmupList.clear();
        for (int i = 0; i < warmup; ++i) {
            auto wi = makeInputs();
            auto tw0 = Clock::now();
            auto o = module->onForward(wi);
            double t = elapsed(tw0, Clock::now());
            warmupList.push_back(t);
            if (o.empty() || o[0].get() == nullptr || o[0]->readMap<void>() == nullptr) {
                errOut = "warmup output invalid";
                return false;
            }
        }
        auto ts0 = Clock::now();
        for (int i = 0; i < repeat; ++i) {
            auto si = makeInputs();
            auto o = module->onForward(si);
            if (o.empty() || o[0].get() == nullptr || o[0]->readMap<void>() == nullptr) {
                errOut = "steady output invalid";
                return false;
            }
        }
        avgMs = elapsed(ts0, Clock::now()) / std::max(1, repeat);
        return true;
    };

    log << "=== GELU Precision Test (fused, x in [-30,30] + edges) ===\n";
    log << "N=" << totalN << "  warmup=" << warmup << "  repeat=" << repeat << "\n";

    MNN::BackendConfig cpuCfg = makeCpuBackendConfig();
    Module::Config cpuModuleCfg;
    cpuModuleCfg.shapeMutable = true;
    cpuModuleCfg.rearrange = true;
    std::vector<float> cpuOut;
    std::string cpuShape;
    double cpuFirst = -1, cpuAvg = -1;
    std::vector<double> cpuWarm;
    std::string err;
    if (!runOnBackend(MNN_FORWARD_CPU, cpuCfg, cpuModuleCfg, cpuOut, cpuShape, cpuFirst, cpuWarm, cpuAvg, err)) {
        log << "ERROR: CPU run failed: " << err << "\n";
        return log.str();
    }
    log << "CPU first=" << cpuFirst << "ms";
    for (size_t w = 0; w < cpuWarm.size(); ++w) log << " w" << w << "=" << cpuWarm[w] << "ms";
    log << " steady(avg)=" << cpuAvg << "ms  shape=" << cpuShape << "\n";

    MNN::BackendConfig npuCfg;
    npuCfg.memory = MNN::BackendConfig::Memory_High;
    Module::Config npuModuleCfg;
    npuModuleCfg.shapeMutable = false;
    npuModuleCfg.rearrange = false;
    std::vector<float> npuOut;
    std::string npuShape;
    double npuFirst = -1, npuAvg = -1;
    std::vector<double> npuWarm;
    if (!runOnBackend(MNN_FORWARD_USER_0, npuCfg, npuModuleCfg, npuOut, npuShape, npuFirst, npuWarm, npuAvg, err)) {
        log << "ERROR: HiAI run failed: " << err << "\n";
        return log.str();
    }
    log << "HiAI first=" << npuFirst << "ms steady(avg)=" << npuAvg << "ms  shape=" << npuShape << "\n";

    bool pass = true;
    log << compareOutputVectors(cpuOut, npuOut, "gelu", pass);

    log << "\n--- Pointwise (first 10 + edges) ---\n";
    log << "idx     input          CPU(gelu)      NPU(gelu)      diff\n";
    auto printPoint = [&](int idx) {
        if (idx < 0 || idx >= totalN) return;
        float diff = std::fabs(cpuOut[idx] - npuOut[idx]);
        log << std::setw(5) << idx << "  "
            << std::setw(12) << std::setprecision(6) << xData[idx] << "  "
            << std::setw(12) << std::setprecision(6) << cpuOut[idx] << "  "
            << std::setw(12) << std::setprecision(6) << npuOut[idx] << "  "
            << std::setw(10) << std::setprecision(6) << diff << "\n";
    };
    for (int i = 0; i < 10; ++i) printPoint(i);
    for (int i = N; i < totalN; ++i) printPoint(i);

    if (pass) log << "\nGELU result: PASS\n";
    else      log << "\nGELU result: FAIL\n";
    return log.str();
}

static std::string runQwen3VlChunkModelTest(const std::string& modelRoot,
                                            int seqLen = 608,
                                            int warmup = 1,
                                            int repeat = 2) {
    std::ostringstream log;
    std::string modelDir = modelRoot;
    if (!modelDir.empty() && modelDir.size() > 12 &&
        modelDir.substr(modelDir.size() - 12) == "/config.json") {
        modelDir = modelDir.substr(0, modelDir.find_last_of('/'));
    }
    if (!isDirectory(modelDir)) {
        log << "ERROR: model directory not found: " << modelDir << "\n";
        return log.str();
    }

    const std::string configPath = modelDir + "/config.json";
    const std::string configText = readTextFile(configPath);
    const int numGridPerSide = extractJsonInt(configText, "num_grid_per_side", 48);
    const std::string visualBackend = extractJsonString(configText, "visual_blocks_backend_type", "hiai");
    const MNNForwardType npuType = visualBackendFromString(visualBackend);

    const std::string prePath = modelDir + "/visual_pre.mnn";
    if (!fileExists(prePath)) {
        log << "ERROR: visual_pre.mnn not found: " << prePath << "\n";
        return log.str();
    }
    auto chunkPaths = listVisualChunkModels(modelDir);
    if (chunkPaths.empty()) {
        log << "ERROR: no visual_blocks_npu_*.mnn found under: " << modelDir << "\n";
        return log.str();
    }

    log << "=== Qwen3VL Visual Chunk Precision Test ===\n";
    log << "model_dir=" << modelDir << "\n";
    log << "chunk_count=" << chunkPaths.size() << "\n";
    log << "seq_len=" << seqLen << "  num_grid_per_side=" << numGridPerSide
        << "  visual_backend=" << visualBackend
        << " (" << forwardTypeName(npuType) << ")\n";

    MNN::BackendConfig cpuCfg = makeCpuBackendConfig();
    Module::Config cpuModuleCfg;
    cpuModuleCfg.shapeMutable = true;
    cpuModuleCfg.rearrange = true;

    MNN::ScheduleConfig preSched;
    preSched.type = MNN_FORWARD_CPU;
    preSched.numThread = 1;
    preSched.backendConfig = &cpuCfg;
    std::shared_ptr<Executor::RuntimeManager> preRt(
        Executor::RuntimeManager::createRuntimeManager(preSched));
    if (preRt.get() == nullptr) {
        log << "ERROR: create CPU runtime for visual_pre failed\n";
        return log.str();
    }
    std::shared_ptr<Module> preModule(Module::load({}, {}, prePath.c_str(), preRt, &cpuModuleCfg));
    if (preModule.get() == nullptr || preModule->getInfo() == nullptr) {
        log << "ERROR: load visual_pre.mnn failed\n";
        return log.str();
    }
    const auto* preInfo = preModule->getInfo();
    bool hasQwen3Pos = false;
    for (const auto& name : preInfo->inputNames) {
        if (name == "idx_tensor") {
            hasQwen3Pos = true;
            break;
        }
    }
    if (!hasQwen3Pos) {
        log << "ERROR: visual_pre.mnn inputs do not contain idx_tensor; "
            << "this test currently targets Qwen3VL split-export models only.\n";
        return log.str();
    }
    int patchDim = 1536;
    if (!preInfo->inputs.empty() && preInfo->inputs[0].dim.size() >= 2 && preInfo->inputs[0].dim[1] > 0) {
        patchDim = preInfo->inputs[0].dim[1];
    }

    std::string buildErr;
    auto preInputs = buildQwen3VlPreInputs(seqLen, patchDim, numGridPerSide, buildErr);
    if (!buildErr.empty()) {
        log << "ERROR: failed to build visual_pre inputs: " << buildErr << "\n";
        return log.str();
    }
    auto preOut = preModule->onForward(preInputs);
    if (preOut.size() < 2 || preOut[0].get() == nullptr || preOut[1].get() == nullptr) {
        log << "ERROR: visual_pre output invalid, expected at least 2 tensors\n";
        return log.str();
    }
    auto hidden0 = cloneToHostInput(preOut[0], "visual_hidden_0");
    auto rotary = cloneToHostInput(preOut[1], "visual_rotary");
    if (hidden0.get() == nullptr || rotary.get() == nullptr) {
        log << "ERROR: failed to materialize visual_pre outputs to host\n";
        return log.str();
    }
    auto hiddenInfo = hidden0->getInfo();
    if (hiddenInfo == nullptr || hiddenInfo->dim.empty()) {
        log << "ERROR: hidden_states info missing after visual_pre\n";
        return log.str();
    }
    const int hiddenSeqLen = hiddenInfo->dim[0];
    auto attentionMask = _Input({1, hiddenSeqLen, hiddenSeqLen}, NCHW);
    ::memset(attentionMask->writeMap<float>(), 0, (size_t)hiddenSeqLen * hiddenSeqLen * sizeof(float));
    attentionMask = cloneToHostInput(attentionMask, "visual_mask");
    if (attentionMask.get() == nullptr) {
        log << "ERROR: failed to build attention_mask\n";
        return log.str();
    }

    log << "visual_pre hidden_states shape=" << varShapeStringLocal(hidden0)
        << " rotary shape=" << varShapeStringLocal(rotary)
        << " mask shape=" << varShapeStringLocal(attentionMask) << "\n\n";

    VARP currentHidden = hidden0;
    int totalPass = 0;
    const int totalChunks = (int)chunkPaths.size();
    for (int i = 0; i < totalChunks; ++i) {
        const auto& chunkPath = chunkPaths[i];
        log << "[" << (i + 1) << "/" << totalChunks << "] " << basenameOf(chunkPath) << "\n";
        log << "input hidden shape=" << varShapeStringLocal(currentHidden)
            << " rotary shape=" << varShapeStringLocal(rotary)
            << " mask shape=" << varShapeStringLocal(attentionMask) << "\n";

        const std::vector<VARP> chunkInputs = {currentHidden, rotary, attentionMask};

        ChunkBenchResult cpuRes;
        if (!runModuleBench(chunkPath, MNN_FORWARD_CPU, cpuCfg, cpuModuleCfg, chunkInputs, warmup, repeat, cpuRes)) {
            log << "ERROR: CPU run failed: " << cpuRes.info << "\n\n";
            continue;
        }

        MNN::BackendConfig npuCfg;
        npuCfg.memory = MNN::BackendConfig::Memory_High;
        Module::Config npuModuleCfg;
        npuModuleCfg.shapeMutable = false;
        npuModuleCfg.rearrange = false;
        ChunkBenchResult npuRes;
        if (!runModuleBench(chunkPath, npuType, npuCfg, npuModuleCfg, chunkInputs, warmup, repeat, npuRes)) {
            log << "ERROR: " << forwardTypeName(npuType) << " run failed: " << npuRes.info << "\n\n";
            continue;
        }

        log << "CPU first=" << cpuRes.firstMs << "ms";
        for (size_t w = 0; w < cpuRes.warmupMs.size(); ++w) {
            log << " w" << w << "=" << cpuRes.warmupMs[w] << "ms";
        }
        log << " steady(x" << repeat << ")=" << cpuRes.avgMs << "ms " << cpuRes.info << "\n";

        log << forwardTypeName(npuType) << " first=" << npuRes.firstMs << "ms";
        for (size_t w = 0; w < npuRes.warmupMs.size(); ++w) {
            log << " w" << w << "=" << npuRes.warmupMs[w] << "ms";
        }
        log << " steady(x" << repeat << ")=" << npuRes.avgMs << "ms " << npuRes.info << "\n";
        log << "speedup(steady) CPU/" << forwardTypeName(npuType) << "="
            << (npuRes.avgMs > 0.0 ? cpuRes.avgMs / npuRes.avgMs : 0.0)
            << "x\n";

        bool chunkPass = true;
        const size_t outputCount = std::min(cpuRes.outputs.size(), npuRes.outputs.size());
        if (cpuRes.outputs.size() != npuRes.outputs.size()) {
            chunkPass = false;
            log << "output_count mismatch CPU=" << cpuRes.outputs.size()
                << " NPU=" << npuRes.outputs.size() << "\n";
        }
        for (size_t oi = 0; oi < outputCount; ++oi) {
            std::vector<float> cpuVec, npuVec;
            std::string readErr;
            if (!readVarToFloatVector(cpuRes.outputs[oi], cpuVec, readErr)) {
                chunkPass = false;
                log << "  [output" << oi << "] CPU read failed: " << readErr << "\n";
                continue;
            }
            if (!readVarToFloatVector(npuRes.outputs[oi], npuVec, readErr)) {
                chunkPass = false;
                log << "  [output" << oi << "] NPU read failed: " << readErr << "\n";
                continue;
            }
            const std::string label = (oi == 0) ? "hidden_states" : ("deepstack_hidden_" + std::to_string(oi - 1));
            log << compareOutputVectors(cpuVec, npuVec, label, chunkPass);
        }

        // Save CPU/NPU outputs for offline Python analysis
        {
            std::string outDir = modelDir + "/debug_outputs";
            ensureDirectoryRecursive(outDir);
            saveChunkOutputs(outDir, i, basenameOf(chunkPath),
                             cpuRes.outputs, npuRes.outputs);
        }

        currentHidden = cloneToHostInput(cpuRes.outputs[0], "visual_hidden_next");
        if (currentHidden.get() == nullptr) {
            log << "ERROR: failed to carry CPU hidden_states into next chunk\n\n";
            break;
        }
        if (chunkPass) {
            totalPass++;
            log << "Chunk result: PASS\n\n";
        } else {
            log << "Chunk result: WARN/FAIL\n\n";
        }
    }
    log << "=== Visual Chunk Summary: " << totalPass << "/" << totalChunks << " passed ===\n";
    return log.str();
}

} // namespace

static void OpTestExecute(napi_env env, void* data) {
    AsyncData* asyncData = static_cast<AsyncData*>(data);
    std::ostringstream result;

    // Parse config: "ic,oc,ih,iw,kh,kw,strideH,strideW,group"
    // or "preset" for predefined test suite
    std::string cfg = asyncData->inputStr;

    if (cfg == "preset" || cfg.empty()) {
        // Typical ViT conv patterns, batch=1
        struct TestCase { int ic, oc, ih, iw, kh, kw, sh, sw, g; const char* name; };
        TestCase cases[] = {
            {3,   64,  14, 14, 7, 7, 2, 2, 1, "patch_embed_7x7"},
            {64,  128, 7,  7,  1, 1, 1, 1, 1, "proj_1x1_small"},
            {128, 256, 7,  7,  1, 1, 1, 1, 1, "proj_1x1_medium"},
            {3,   768, 14, 14, 14,14,14,14,1, "vit_patch14"},
            {32,  32,  8,  8,  3, 3, 1, 1, 1, "conv3x3_basic"},
            {64,  64,  8,  8,  3, 3, 1, 1, 64,"depthwise_3x3"},
        };
        int n = sizeof(cases) / sizeof(cases[0]);
        int pass = 0;
        for (int i = 0; i < n; i++) {
            auto& c = cases[i];
            result << "[" << (i+1) << "/" << n << "] " << c.name << "\n";
            std::string r = runConvTest(c.ic, c.oc, c.ih, c.iw, c.kh, c.kw, c.sh, c.sw, c.g);
            result << r;
            if (r.find("PASS") != std::string::npos) pass++;
            result << "\n";
        }
        result << "=== Summary: " << pass << "/" << n << " passed ===\n";
    } else if (cfg == "qwen3vl") {
        // Real Qwen3VL visual encoder ops (matmul-converted 1x1 conv, N=608 tokens)
        // warmup=2 repeat=5 to keep runtime reasonable on device
        struct TestCase { int n, ic, oc, kh, kw, g; const char* name; };
        TestCase cases[] = {
            {608, 1024, 1024, 1, 1, 1, "attn_qkv/out_proj (1024->1024)"},
            {608, 1024, 4096, 1, 1, 1, "mlp_fc1 (1024->4096)"},
            {608, 4096, 1024, 1, 1, 1, "mlp_fc2 (4096->1024)"},
        };
        int n = sizeof(cases) / sizeof(cases[0]);
        int pass = 0;
        for (int i = 0; i < n; i++) {
            auto& c = cases[i];
            result << "[" << (i+1) << "/" << n << "] " << c.name << "\n";
            // ih=iw=1 (matmul-as-conv), batch=N
            std::string r = runConvTest(c.ic, c.oc, 1, 1, c.kh, c.kw, 1, 1, c.g, c.n, 2, 5);
            result << r;
            if (r.find("PASS") != std::string::npos) pass++;
            result << "\n";
        }
        result << "=== Qwen3VL Summary: " << pass << "/" << n << " passed ===\n";
    } else if (cfg == "qwen3vl_int8") {
        // Same ops as qwen3vl but weights quantized to int8 per-channel symmetric.
        // Lets us see if CPU's int8 DynamicQuant beats fp16-on-NPU for these shapes.
        struct TestCase { int n, ic, oc, kh, kw, g; const char* name; };
        TestCase cases[] = {
            {608, 1024, 1024, 1, 1, 1, "attn_qkv/out_proj (1024->1024)"},
            {608, 1024, 4096, 1, 1, 1, "mlp_fc1 (1024->4096)"},
            {608, 4096, 1024, 1, 1, 1, "mlp_fc2 (4096->1024)"},
        };
        int n = sizeof(cases) / sizeof(cases[0]);
        int pass = 0;
        for (int i = 0; i < n; i++) {
            auto& c = cases[i];
            result << "[" << (i+1) << "/" << n << "] " << c.name << "\n";
            std::string r = runConvTestInt8(c.ic, c.oc, 1, 1, c.kh, c.kw, 1, 1, c.g, c.n, 2, 5);
            result << r;
            if (r.find("PASS") != std::string::npos) pass++;
            result << "\n";
        }
        result << "=== Qwen3VL Int8 Summary: " << pass << "/" << n << " passed ===\n";
    } else if (cfg == "qwen3vl_attn") {
        // Qwen3VL visual encoder self-attention — shape captured from
        // on-device NPUAttention.onResize log:
        //   Q[B=1,Sq=608,H=16,D=64] K[1,608,16,64] V[1,608,16,64] mask=3D[1,608,608]
        // One case with mask, one without, so we cover both NPUAttention code
        // paths (the mask-Reshape-Add branch and the no-mask branch).
        struct TestCase { int b, s, h, d; bool mask; const char* name; };
        TestCase cases[] = {
            {1, 608, 16, 64, true,  "attn_block0 with mask [1,608,608]"},
//            {1, 608, 16, 64, false, "attn_block0 no-mask"},
        };
        int n = sizeof(cases) / sizeof(cases[0]);
        int pass = 0;
        for (int i = 0; i < n; i++) {
            auto& c = cases[i];
            result << "[" << (i+1) << "/" << n << "] " << c.name << "\n";
            std::string r = runAttentionTest(c.b, c.s, c.h, c.d, c.mask, 1, 2);
            result << r;
            if (r.find("PASS") != std::string::npos) pass++;
            result << "\n";
        }
        result << "=== Qwen3VL Attn Summary: " << pass << "/" << n << " passed ===\n";
    } else if (cfg == "qwen3vl_rope") {
        result << runQwen3VlRopeTest(608, 16, 64, 1, 2);
    } else if (cfg == "qwen3vl_tanh") {
        result << runTanhTest(1, 2);
    } else if (cfg == "qwen3vl_gelu") {
        result << runGeluTest(1, 2);
    } else if (cfg == "qwen3vl_ln_ab" || cfg.rfind("qwen3vl_ln_ab|", 0) == 0) {
        // Accepted payload shapes (modelDir is ignored — the new test uses
        // synthetic weights, but we keep the positional parse so existing UI
        // trigger `qwen3vl_ln_ab|<modelDir>|<seqLen>` still works):
        //   qwen3vl_ln_ab
        //   qwen3vl_ln_ab|<seqLen>
        //   qwen3vl_ln_ab|<modelDir>|<seqLen>
        //   qwen3vl_ln_ab|<modelDir>|<seqLen>|<hiddenDim>
        int seqLen = 608;
        int hiddenDim = 1024;
        if (cfg.rfind("qwen3vl_ln_ab|", 0) == 0) {
            std::string payload = cfg.substr(std::string("qwen3vl_ln_ab|").size());
            std::vector<std::string> tokens;
            size_t pos = 0;
            while (pos <= payload.size()) {
                size_t nxt = payload.find('|', pos);
                if (nxt == std::string::npos) {
                    tokens.push_back(payload.substr(pos));
                    break;
                }
                tokens.push_back(payload.substr(pos, nxt - pos));
                pos = nxt + 1;
            }
            // Drop a leading path-like token (anything starting with '/')
            if (!tokens.empty() && !tokens.front().empty() && tokens.front()[0] == '/') {
                tokens.erase(tokens.begin());
            }
            if (!tokens.empty() && !tokens[0].empty()) {
                seqLen = std::max(1, std::atoi(tokens[0].c_str()));
            }
            if (tokens.size() >= 2 && !tokens[1].empty()) {
                hiddenDim = std::max(1, std::atoi(tokens[1].c_str()));
            }
        }
        result << runQwen3VlLayerNormABTest(seqLen, hiddenDim, 1, 2);
    } else if (cfg == "qwen3vl_ln_ab_g0" || cfg.rfind("qwen3vl_ln_ab_g0|", 0) == 0) {
        // Diagnostic variant: gamma=0, beta=real. Math says output ≡ beta.
        // If NPU output ALSO equals beta in real-gamma mode, the gamma input
        // is being ignored by hiai::op::LayerNorm.
        // Payload: qwen3vl_ln_ab_g0[|<seqLen>[|<hiddenDim>]]
        int seqLen = 608;
        int hiddenDim = 1024;
        if (cfg.rfind("qwen3vl_ln_ab_g0|", 0) == 0) {
            std::string payload = cfg.substr(std::string("qwen3vl_ln_ab_g0|").size());
            std::vector<std::string> tokens;
            size_t pos = 0;
            while (pos <= payload.size()) {
                size_t nxt = payload.find('|', pos);
                if (nxt == std::string::npos) {
                    tokens.push_back(payload.substr(pos));
                    break;
                }
                tokens.push_back(payload.substr(pos, nxt - pos));
                pos = nxt + 1;
            }
            if (!tokens.empty() && !tokens.front().empty() && tokens.front()[0] == '/') {
                tokens.erase(tokens.begin());
            }
            if (!tokens.empty() && !tokens[0].empty()) {
                seqLen = std::max(1, std::atoi(tokens[0].c_str()));
            }
            if (tokens.size() >= 2 && !tokens[1].empty()) {
                hiddenDim = std::max(1, std::atoi(tokens[1].c_str()));
            }
        }
        result << runQwen3VlLayerNormABTest(seqLen, hiddenDim, 1, 2, /*gammaZero=*/true);
    } else if (cfg.rfind("qwen3vl_chunks|", 0) == 0) {
        std::string payload = cfg.substr(std::string("qwen3vl_chunks|").size());
        std::string modelDir = payload;
        int seqLen = 608;
        auto splitPos = payload.find('|');
        if (splitPos != std::string::npos) {
            modelDir = payload.substr(0, splitPos);
            auto seqStr = payload.substr(splitPos + 1);
            if (!seqStr.empty()) {
                seqLen = std::max(1, std::atoi(seqStr.c_str()));
            }
        }
        result << runQwen3VlChunkModelTest(modelDir, seqLen, 1, 2);
    } else {
        // Custom: "N,ic,oc,ih,iw[,kh,kw,sh,sw,group]"
        int N=1, ic=0, oc=0, ih=0, iw=0, kh=1, kw=1, sh=1, sw=1, g=1;
        int parsed = sscanf(cfg.c_str(), "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
                            &N, &ic, &oc, &ih, &iw, &kh, &kw, &sh, &sw, &g);
        if (parsed < 5 || ic <= 0 || oc <= 0 || ih <= 0 || iw <= 0 || N <= 0) {
            result << "ERROR: invalid config: " << cfg << "\n";
            result << "Format: N,ic,oc,ih,iw[,kh,kw,sh,sw,group]\n";
        } else {
            result << runConvTest(ic, oc, ih, iw, kh, kw, sh, sw, g, N);
        }
    }

    asyncData->success = true;
    asyncData->outputStr = result.str();
}

static napi_value OpTestAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string config = "preset";
    if (argc >= 1) {
        size_t strLen = 0;
        napi_get_value_string_utf8(env, args[0], nullptr, 0, &strLen);
        if (strLen > 0) {
            config.resize(strLen);
            napi_get_value_string_utf8(env, args[0], &config[0], strLen + 1, &strLen);
        }
    }

    AsyncData* asyncData = new AsyncData();
    asyncData->inputStr = std::move(config);

    napi_value promise;
    napi_create_promise(env, &asyncData->deferred, &promise);

    napi_value resourceName;
    napi_create_string_utf8(env, "OpTestAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, OpTestExecute, AsyncComplete,
                           asyncData, &asyncData->work);
    napi_queue_async_work(env, asyncData->work);

    return promise;
}

// ========== N-API 模块注册 ==========
EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"prepareCustomOpp", nullptr, PrepareCustomOpp,   nullptr, nullptr, nullptr, napi_default, nullptr},
        {"copyModel",    nullptr, CopyModel,         nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadModel",    nullptr, LoadModelAsync,     nullptr, nullptr, nullptr, napi_default, nullptr},
        {"generate",     nullptr, GenerateAsync,      nullptr, nullptr, nullptr, napi_default, nullptr},
        {"chat",         nullptr, ChatAsync,          nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reset",        nullptr, Reset,              nullptr, nullptr, nullptr, napi_default, nullptr},
        {"agentPrefill", nullptr, AgentPrefillAsync,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"agentStep",    nullptr, AgentStepAsync,     nullptr, nullptr, nullptr, napi_default, nullptr},
        {"agentReset",   nullptr, AgentResetAsync,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"opTest",       nullptr, OpTestAsync,        nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setConvMode",  nullptr, SetConvMode,        nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setConvQuant", nullptr, SetConvQuant,       nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setInt8XScale",nullptr, SetInt8XScale,      nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setCpuPrecision", nullptr, SetCpuPrecision,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setCpuMemory",    nullptr, SetCpuMemory,     nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initLogFile",  nullptr, InitLogFile,        nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getLogs",      nullptr, GetLogs,            nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearLogs",    nullptr, ClearLogs,          nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module mnnModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterModule(void) {
    napi_module_register(&mnnModule);
}
