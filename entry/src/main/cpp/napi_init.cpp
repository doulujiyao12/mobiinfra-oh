//#include <napi/native_api.h>
//  #include <hilog/log.h>
//  #include <string>
//  #include <sstream>
//  #include <mutex>
//  #include <cstdlib>
//
//  #include "llm/llm.hpp"
//
//  #define LOG_TAG "MnnLlm"
//  #define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
//  #define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
//
//  using namespace MNN::Transformer;
//
//  static std::unique_ptr<Llm> g_llm = nullptr;
//  static std::mutex g_mutex;
//  static ChatMessages g_messages;
//
//  // ========== 1. 拷贝模型到沙箱 ==========
//  // copyModel(src: string, dst: string): string
//  static napi_value CopyModel(napi_env env, napi_callback_info info) {
//      size_t argc = 2;
//      napi_value args[2];
//      napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
//
//      char src[1024], dst[1024];
//      size_t len;
//      napi_get_value_string_utf8(env, args[0], src, sizeof(src), &len);
//      napi_get_value_string_utf8(env, args[1], dst, sizeof(dst), &len);
//
//      LOGI("CopyModel: %{public}s -> %{public}s", src, dst);
//
//      std::string cmd = "cp -r ";
//      cmd += src;
//      cmd += " ";
//      cmd += dst;
//      int ret = system(cmd.c_str());
//
//      LOGI("CopyModel result: %{public}d", ret);
//
//      napi_value result;
//      napi_create_string_utf8(env, ret == 0 ? "ok" : "copy failed", NAPI_AUTO_LENGTH, &result);
//      return result;
//  }
//
//  // ========== 2. 加载模型 ==========
//  // loadModel(configPath: string): string
//  static napi_value LoadModel(napi_env env, napi_callback_info info) {
//      size_t argc = 1;
//      napi_value args[1];
//      napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
//
//      char configPath[1024];
//      size_t len;
//      napi_get_value_string_utf8(env, args[0], configPath, sizeof(configPath), &len);
//
//      LOGI("Loading model from: %{public}s", configPath);
//
//      std::lock_guard<std::mutex> lock(g_mutex);
//      g_llm.reset(Llm::createLLM(configPath));
//      if (!g_llm) {
//          LOGE("createLLM failed");
//          napi_value result;
//          napi_create_string_utf8(env, "error: create LLM failed", NAPI_AUTO_LENGTH, &result);
//          return result;
//      }
//
//      // tmp_path 设置为模型所在目录的 tmp 子目录
//      std::string configStr(configPath);
//      std::string modelDir = configStr.substr(0, configStr.rfind('/'));
//      std::string tmpPath = modelDir + "/tmp";
//      std::string tmpConfig = "{\"tmp_path\":\"" + tmpPath + "\"}";
//      g_llm->set_config(tmpConfig);
//
//      bool res = g_llm->load();
//
//      napi_value result;
//      if (res) {
//          LOGI("Model loaded successfully");
//          napi_create_string_utf8(env, "ok", NAPI_AUTO_LENGTH, &result);
//      } else {
//          LOGE("Model load failed");
//          g_llm.reset();
//          napi_create_string_utf8(env, "error: load failed", NAPI_AUTO_LENGTH, &result);
//      }
//      return result;
//  }
//
//  // ========== 3. 单轮推理 ==========
//  // generate(prompt: string): string
//  static napi_value Generate(napi_env env, napi_callback_info info) {
//      size_t argc = 1;
//      napi_value args[1];
//      napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
//
//      char prompt[4096];
//      size_t len;
//      napi_get_value_string_utf8(env, args[0], prompt, sizeof(prompt), &len);
//
//      LOGI("Prompt: %{public}s", prompt);
//
//      std::lock_guard<std::mutex> lock(g_mutex);
//      if (!g_llm) {
//          napi_value result;
//          napi_create_string_utf8(env, "error: model not loaded", NAPI_AUTO_LENGTH, &result);
//          return result;
//      }
//
//      std::ostringstream oss;
//      g_llm->response(std::string(prompt), &oss);
//      std::string output = oss.str();
//
//      auto context = g_llm->getContext();
//      float prefill_s = context->prefill_us / 1e6;
//      float decode_s = context->decode_us / 1e6;
//      char perf[512];
//      snprintf(perf, sizeof(perf),
//          "\n\n--- perf ---\nprompt tokens: %d\ndecode tokens: %d\nprefill: %.2f tok/s\ndecode:%.2f tok/s",
//          context->prompt_len, context->gen_seq_len,
//          prefill_s > 0 ? context->prompt_len / prefill_s : 0,
//          decode_s > 0 ? context->gen_seq_len / decode_s : 0);
//      output += perf;
//
//      LOGI("Response length: %{public}zu", output.size());
//
//      napi_value result;
//      napi_create_string_utf8(env, output.c_str(), output.size(), &result);
//      return result;
//  }
//
//  // ========== 4. 多轮对话 ==========
//  // chat(userMessage: string): string
//  static napi_value Chat(napi_env env, napi_callback_info info) {
//      size_t argc = 1;
//      napi_value args[1];
//      napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
//
//      char userMsg[4096];
//      size_t len;
//      napi_get_value_string_utf8(env, args[0], userMsg, sizeof(userMsg), &len);
//
//      std::lock_guard<std::mutex> lock(g_mutex);
//      if (!g_llm) {
//          napi_value result;
//          napi_create_string_utf8(env, "error: model not loaded", NAPI_AUTO_LENGTH, &result);
//          return result;
//      }
//
//      std::string user_str(userMsg);
//
//      if (user_str == "/reset") {
//          g_llm->reset();
//          g_messages.clear();
//          g_messages.emplace_back("system", "You are a helpful assistant.");
//          napi_value result;
//          napi_create_string_utf8(env, "reset done", NAPI_AUTO_LENGTH, &result);
//          return result;
//      }
//
//      if (g_messages.empty()) {
//          g_messages.emplace_back("system", "You are a helpful assistant.");
//      }
//      g_messages.emplace_back("user", user_str);
//
//      g_llm->response(g_messages);
//      auto context = g_llm->getContext();
//      std::string assistant_str = context->generate_str;
//      g_messages.emplace_back("assistant", assistant_str);
//
//      napi_value result;
//      napi_create_string_utf8(env, assistant_str.c_str(), assistant_str.size(), &result);
//      return result;
//  }
//
//  // ========== 5. 重置对话 ==========
//  // reset(): string
//  static napi_value Reset(napi_env env, napi_callback_info info) {
//      std::lock_guard<std::mutex> lock(g_mutex);
//      if (g_llm) {
//          g_llm->reset();
//      }
//      g_messages.clear();
//      g_messages.emplace_back("system", "You are a helpful assistant.");
//
//      napi_value result;
//      napi_create_string_utf8(env, "ok", NAPI_AUTO_LENGTH, &result);
//      return result;
//  }
//
//  // ========== N-API 模块注册 ==========
//  EXTERN_C_START
//  static napi_value Init(napi_env env, napi_value exports) {
//      napi_property_descriptor desc[] = {
//          {"copyModel", nullptr, CopyModel, nullptr, nullptr, nullptr, napi_default, nullptr},
//          {"loadModel", nullptr, LoadModel, nullptr, nullptr, nullptr, napi_default, nullptr},
//          {"generate",  nullptr, Generate,  nullptr, nullptr, nullptr, napi_default, nullptr},
//          {"chat",      nullptr, Chat,      nullptr, nullptr, nullptr, napi_default, nullptr},
//          {"reset",     nullptr, Reset,     nullptr, nullptr, nullptr, napi_default, nullptr},
//      };
//      napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
//      return exports;
//  }
//  EXTERN_C_END
//
//  static napi_module mnnModule = {
//      .nm_version = 1,
//      .nm_flags = 0,
//      .nm_filename = nullptr,
//      .nm_register_func = Init,
//      .nm_modname = "entry",
//      .nm_priv = nullptr,
//      .reserved = {0},
//  };
//
//  extern "C" __attribute__((constructor)) void RegisterModule(void) {
//      napi_module_register(&mnnModule);
//  }


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

#include "llm/llm.hpp"

#include <MNN/expr/Expr.hpp>
#include <MNN/expr/ExprCreator.hpp>
#include <MNN/expr/NeuralNetWorkOp.hpp>
#include <MNN/expr/Executor.hpp>
#include <MNN/expr/ExecutorScope.hpp>
#include <MNN/MNNForwardType.h>
#include <cmath>
#include <chrono>

#define LOG_TAG "MnnLlm"
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

using namespace MNN::Transformer;

static std::unique_ptr<Llm> g_llm = nullptr;
static std::mutex g_mutex;
static ChatMessages g_messages;

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
    std::string tmpPath = modelDir + "/tmp";
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

    g_llm->response(g_messages);
    auto context = g_llm->getContext();
    if (context) {
        std::string assistant_str = context->generate_str;
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
                           std::strcmp(qm, "matmul_int8") == 0);
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