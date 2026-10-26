// Guncat Work: 原生 Python 运行时桥(CPython 3.12，动态加载 libpython)
//
// 为什么是 dlopen 而不是链接：
//   * 与 QEMU 一样，libpython3.12.so 作为预编译产物随 HAP 打包，只在 arm64 设备上存在；
//     用 dlopen 可以让 x86_64 模拟器构建照常编译通过，运行期再给出明确原因。
//   * 也避免把 CPython 头文件/CMake 依赖拖进构建。
//   * 只用到 6 个稳定 ABI 的符号（Py_Initialize / PyRun_SimpleString / PyGILState_* ...），
//     它们从 3.x 起就没变过。
//
// 执行的语义：
//   * 每次调用在一个**复用的解释器实例**里执行（import 缓存得以复用 → 启动从 3s 级降到 ms 级）；
//   * 用户代码的 globals 每次都是全新的 dict，互不串味；
//   * 工作目录切到调用方给的 workDir（就是会话工作区），脚本可直接用相对路径读写，
//     与 shell / read_file / write_file 看到的是同一批文件；
//   * stdout/stderr 在 Python 层用 io.StringIO 捕获，写成文件再读回（避免在 C++ 里解析）；
//   * 超时：看门狗线程调 PyErr_SetInterrupt() 触发 KeyboardInterrupt（纯 Python 循环有效，
//     阻塞在 C 调用里的情况无法中断，按"放弃等待"处理，与 run_js 的策略一致）。
#include <dlfcn.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "hilog/log.h"
#include "napi/native_api.h"

namespace {

constexpr const char* kTag = "GuncatPy";
constexpr int kLogDomain = 0x3300;

// ===== libpython 符号表(只用稳定 ABI) =====
using FnPy_IsInitialized = int (*)();
using FnPy_Initialize = void (*)();
using FnPy_FinalizeEx = int (*)();
using FnPyRun_SimpleString = int (*)(const char*);
using FnPyGILState_Ensure = int (*)();
using FnPyGILState_Release = void (*)(int);
using FnPyErr_SetInterrupt = void (*)();

struct PyApi {
    void* handle = nullptr;
    FnPy_IsInitialized isInitialized = nullptr;
    FnPy_Initialize initialize = nullptr;
    FnPy_FinalizeEx finalize = nullptr;
    FnPyRun_SimpleString runSimpleString = nullptr;
    FnPyGILState_Ensure gilEnsure = nullptr;
    FnPyGILState_Release gilRelease = nullptr;
    FnPyErr_SetInterrupt setInterrupt = nullptr;
    std::string error;
    bool ok = false;
};

std::mutex g_mutex;
PyApi g_api;
std::atomic<bool> g_running{false};
// 超时被放弃、但仍在后台占着解释器的调用数(与 run_js 同策略: 不无限累积)
std::atomic<int> g_abandoned{0};
constexpr int kMaxAbandoned = 2;
constexpr const char* kLibName = "libpython3.12.so";

PyApi& LoadPyApi() {
    if (g_api.ok || !g_api.error.empty()) {
        return g_api;
    }
    void* h = ::dlopen(kLibName, RTLD_NOW | RTLD_GLOBAL);
    if (h == nullptr) {
        const char* err = ::dlerror();
        g_api.error = std::string("无法加载 ") + kLibName + ": " + (err != nullptr ? err : "dlopen failed");
        return g_api;
    }
    g_api.handle = h;
    g_api.isInitialized = reinterpret_cast<FnPy_IsInitialized>(::dlsym(h, "Py_IsInitialized"));
    g_api.initialize = reinterpret_cast<FnPy_Initialize>(::dlsym(h, "Py_Initialize"));
    g_api.finalize = reinterpret_cast<FnPy_FinalizeEx>(::dlsym(h, "Py_FinalizeEx"));
    g_api.runSimpleString = reinterpret_cast<FnPyRun_SimpleString>(::dlsym(h, "PyRun_SimpleString"));
    g_api.gilEnsure = reinterpret_cast<FnPyGILState_Ensure>(::dlsym(h, "PyGILState_Ensure"));
    g_api.gilRelease = reinterpret_cast<FnPyGILState_Release>(::dlsym(h, "PyGILState_Release"));
    g_api.setInterrupt = reinterpret_cast<FnPyErr_SetInterrupt>(::dlsym(h, "PyErr_SetInterrupt"));
    if (g_api.isInitialized == nullptr || g_api.initialize == nullptr ||
        g_api.runSimpleString == nullptr || g_api.gilEnsure == nullptr || g_api.gilRelease == nullptr) {
        g_api.error = "libpython 缺少必要符号(版本不匹配?)";
        return g_api;
    }
    g_api.ok = true;
    return g_api;
}

// ===== 小工具 =====

std::string ReadFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return std::string();
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

bool WriteFile(const std::string& path, const std::string& content) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) {
        return false;
    }
    out.write(content.data(), static_cast<std::streamsize>(content.size()));
    return out.good();
}

std::string Trim(const std::string& s) {
    std::size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) {
        return std::string();
    }
    std::size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

bool ReadBoolFile(const std::string& path, bool defVal) {
    std::string t = Trim(ReadFile(path));
    if (t == "1" || t == "true") {
        return true;
    }
    if (t == "0" || t == "false") {
        return false;
    }
    return defVal;
}

std::string PropToString(napi_env env, napi_value obj, const char* name) {
    std::string out;
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, name, &value) != napi_ok) {
        return out;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
        return out;
    }
    std::size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok || len == 0) {
        return out;
    }
    std::vector<char> buf(len + 1, '\0');
    std::size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, buf.data(), len + 1, &copied) != napi_ok) {
        return out;
    }
    out.assign(buf.data(), copied);
    return out;
}

int32_t PropToInt(napi_env env, napi_value obj, const char* name, int32_t defVal) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, name, &value) != napi_ok) {
        return defVal;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_number) {
        return defVal;
    }
    int32_t out = defVal;
    napi_get_value_int32(env, value, &out);
    return out;
}

// 启动器: 用户代码在子命名空间里执行, 输出被 io.StringIO 捕获后落盘。
// 全部状态走环境变量里的文件路径, 避免把用户代码拼进 Python 源码字符串。
const char* kLauncher = R"PYSRC(
import json, os, sys, io, traceback

_code_path = os.environ['GUNCAT_PY_CODE']
_out_path = os.environ['GUNCAT_PY_OUT']
_err_path = os.environ['GUNCAT_PY_ERR']
_meta_path = os.environ['GUNCAT_PY_META']
_argv = json.loads(os.environ.get('GUNCAT_PY_ARGV', '[]'))

sys.argv = list(_argv)
sys.dont_write_bytecode = True

_stdin_path = os.environ.get('GUNCAT_PY_STDIN', '')
if _stdin_path:
    sys.stdin = open(_stdin_path, 'r', encoding='utf-8', errors='replace')

with open(_code_path, 'r', encoding='utf-8') as _f:
    _src = _f.read()

_out, _err = io.StringIO(), io.StringIO()
_saved_out, _saved_err = sys.stdout, sys.stderr
sys.stdout, sys.stderr = _out, _err

_globals = {'__name__': '__main__', '__file__': _code_path, '__builtins__': __builtins__}
_ok = True
_error = ''
_exit_code = 0
try:
    exec(compile(_src, '<run_python>', 'exec'), _globals, _globals)
except SystemExit as _e:
    _exit_code = _e.code if isinstance(_e.code, int) else (0 if _e.code is None else 1)
    _ok = _exit_code == 0
    if not _ok:
        _error = 'SystemExit(%r)' % (_e.code,)
except BaseException:
    _ok = False
    _error = traceback.format_exc()
finally:
    sys.stdout, sys.stderr = _saved_out, _saved_err

with open(_out_path, 'w', encoding='utf-8') as _f:
    _f.write(_out.getvalue())
with open(_err_path, 'w', encoding='utf-8') as _f:
    _f.write(_err.getvalue())
with open(_meta_path, 'w', encoding='utf-8') as _f:
    _f.write('%d\n%d\n' % (1 if _ok else 0, _exit_code))
    _f.write(_error)
)PYSRC";

struct PyRunOptions {
    std::string code;
    std::string workDir;
    std::string scratchDir;
    std::string pythonHome;
    std::string pythonPath;
    std::string argvJson = "[]";
    // 可选: 标准输入文件(内容会被挂成 sys.stdin); 空串表示让 sys.stdin 保持默认
    std::string stdinPath;
    int32_t timeoutMs = 60000;
};

struct PyRunOutcome {
    bool ok = false;
    bool timedOut = false;
    int32_t exitCode = 0;
    std::string stdoutText;
    std::string stderrText;
    std::string error;
    int64_t durationMs = 0;
};

bool EnsureInterpreter(const PyRunOptions& opt, std::string& err) {
    PyApi& api = LoadPyApi();
    if (!api.ok) {
        err = api.error;
        return false;
    }
    if (api.isInitialized() != 0) {
        return true;
    }
    // CPython 从环境变量读 HOME/PATH(必须在初始化之前设置)
    if (!opt.pythonHome.empty()) {
        ::setenv("PYTHONHOME", opt.pythonHome.c_str(), 1);
    }
    if (!opt.pythonPath.empty()) {
        ::setenv("PYTHONPATH", opt.pythonPath.c_str(), 1);
    }
    ::setenv("PYTHONUTF8", "1", 1);
    ::setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
    ::setenv("PYTHONNOUSERSITE", "1", 1);
    api.initialize();
    if (api.isInitialized() == 0) {
        err = "Py_Initialize 失败(检查 PYTHONHOME/PYTHONPATH 是否正确)";
        return false;
    }
    OH_LOG_INFO(LOG_APP, "python interpreter initialized");
    return true;
}

PyRunOutcome RunPythonInner(const PyRunOptions& opt) {
    PyRunOutcome out;
    auto start = std::chrono::steady_clock::now();
    std::string err;
    if (!EnsureInterpreter(opt, err)) {
        out.error = err;
        out.timedOut = false;
        out.ok = false;
        return out;
    }
    PyApi& api = LoadPyApi();

    const std::string codePath = opt.scratchDir + "/code.py";
    const std::string outPath = opt.scratchDir + "/stdout.txt";
    const std::string errPath = opt.scratchDir + "/stderr.txt";
    const std::string metaPath = opt.scratchDir + "/meta.txt";
    ::unlink(outPath.c_str());
    ::unlink(errPath.c_str());
    ::unlink(metaPath.c_str());
    if (!WriteFile(codePath, opt.code)) {
        out.error = "无法写入临时脚本目录: " + opt.scratchDir;
        return out;
    }
    ::setenv("GUNCAT_PY_CODE", codePath.c_str(), 1);
    ::setenv("GUNCAT_PY_OUT", outPath.c_str(), 1);
    ::setenv("GUNCAT_PY_ERR", errPath.c_str(), 1);
    ::setenv("GUNCAT_PY_META", metaPath.c_str(), 1);
    ::setenv("GUNCAT_PY_ARGV", opt.argvJson.c_str(), 1);
    if (opt.stdinPath.empty()) {
        ::unsetenv("GUNCAT_PY_STDIN");
    } else {
        ::setenv("GUNCAT_PY_STDIN", opt.stdinPath.c_str(), 1);
    }

    std::string previousCwd;
    {
        char buf[4096];
        if (::getcwd(buf, sizeof(buf)) != nullptr) {
            previousCwd.assign(buf);
        }
    }
    if (!opt.workDir.empty() && ::chdir(opt.workDir.c_str()) != 0) {
        out.error = "无法切换到工作区: " + opt.workDir;
        return out;
    }

    std::atomic<bool> finished{false};
    const int32_t timeoutMs = opt.timeoutMs > 0 ? opt.timeoutMs : 60000;
    std::thread watchdog([&finished, timeoutMs, &api]() {
        const int stepMs = 50;
        int waited = 0;
        while (!finished.load() && waited < timeoutMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(stepMs));
            waited += stepMs;
        }
        if (!finished.load()) {
            OH_LOG_WARN(LOG_APP, "python timeout after %{public}d ms, raising KeyboardInterrupt", timeoutMs);
            if (api.setInterrupt != nullptr) {
                api.setInterrupt();  // 让纯 Python 循环在下一个字节码边界抛 KeyboardInterrupt
            }
        }
    });

    int state = api.gilEnsure();
    int rc = api.runSimpleString(kLauncher);
    api.gilRelease(state);

    finished.store(true);
    watchdog.join();

    {
        char buf[4096];
        if (!previousCwd.empty() && ::getcwd(buf, sizeof(buf)) != nullptr) {
            ::chdir(previousCwd.c_str());
        }
    }

    auto end = std::chrono::steady_clock::now();
    out.durationMs = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();

    const bool hasMeta = ::access(metaPath.c_str(), F_OK) == 0;
    if (!hasMeta) {
        out.error = (rc != 0) ? "Python 执行失败(没有产出结果文件, 可能是解释器初始化不完整)"
                              : "Python 执行没有产出结果文件";
        return out;
    }
    std::string meta = ReadFile(metaPath);
    std::size_t first = meta.find('\n');
    std::size_t second = (first == std::string::npos) ? std::string::npos : meta.find('\n', first + 1);
    if (first == std::string::npos) {
        out.error = "结果文件格式异常";
        return out;
    }
    const std::string okFlag = meta.substr(0, first);
    if (second == std::string::npos) {
        out.exitCode = 0;
        out.error = meta.substr(first + 1);
    } else {
        std::string codeStr = meta.substr(first + 1, second - first - 1);
        out.exitCode = std::atoi(codeStr.c_str());
        out.error = meta.substr(second + 1);
    }
    out.ok = (okFlag == "1");
    out.stdoutText = ReadFile(outPath);
    out.stderrText = ReadFile(errPath);
    out.timedOut = out.durationMs >= timeoutMs && !out.ok && out.error.find("KeyboardInterrupt") != std::string::npos;
    if (!out.ok && out.error.empty()) {
        out.error = "执行失败(退出码 " + std::to_string(out.exitCode) + ")";
    }
    return out;
}

// ===== N-API =====

napi_value MakeString(napi_env env, const std::string& s) {
    napi_value out = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &out);
    return out;
}

napi_value MakeBool(napi_env env, bool v) {
    napi_value out = nullptr;
    napi_get_boolean(env, v, &out);
    return out;
}

napi_value MakeInt(napi_env env, int64_t v) {
    napi_value out = nullptr;
    napi_create_int64(env, v, &out);
    return out;
}

// isAvailable(): 空串表示可用, 否则为不可用原因
napi_value JsIsAvailable(napi_env env, napi_callback_info) {
    std::lock_guard<std::mutex> lock(g_mutex);
    PyApi& api = LoadPyApi();
    return MakeString(env, api.ok ? std::string() : api.error);
}

// runPython({ code, workDir, scratchDir, pythonHome, pythonPath, argvJson, timeoutMs })
napi_value JsRunPython(napi_env env, napi_callback_info info) {
    std::size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value result = nullptr;
    napi_create_object(env, &result);

    PyRunOptions opt;
    if (argc >= 1) {
        opt.code = PropToString(env, args[0], "code");
        opt.workDir = PropToString(env, args[0], "workDir");
        opt.scratchDir = PropToString(env, args[0], "scratchDir");
        opt.pythonHome = PropToString(env, args[0], "pythonHome");
        opt.pythonPath = PropToString(env, args[0], "pythonPath");
        opt.argvJson = PropToString(env, args[0], "argvJson");
        opt.stdinPath = PropToString(env, args[0], "stdinPath");
        if (opt.argvJson.empty()) {
            opt.argvJson = "[]";
        }
        opt.timeoutMs = PropToInt(env, args[0], "timeoutMs", 60000);
    }
    if (opt.code.empty()) {
        napi_set_named_property(env, result, "ok", MakeBool(env, false));
        napi_set_named_property(env, result, "error", MakeString(env, "缺少参数 code"));
        return result;
    }
    if (opt.scratchDir.empty()) {
        napi_set_named_property(env, result, "ok", MakeBool(env, false));
        napi_set_named_property(env, result, "error", MakeString(env, "缺少参数 scratchDir"));
        return result;
    }
    if (g_running.load()) {
        napi_set_named_property(env, result, "ok", MakeBool(env, false));
        napi_set_named_property(env, result, "error", MakeString(env, "已有 Python 调用在执行(串行模型)"));
        return result;
    }
    if (g_abandoned.load() >= kMaxAbandoned) {
        napi_set_named_property(env, result, "ok", MakeBool(env, false));
        napi_set_named_property(env, result, "error",
            MakeString(env, "已有多次超时未回收的 Python 调用, 为避免持续占 CPU 本会话不再执行; 重启应用后重试"));
        return result;
    }

    g_running.store(true);
    PyRunOutcome outcome;
    try {
        outcome = RunPythonInner(opt);
    } catch (const std::exception& e) {
        outcome.ok = false;
        outcome.error = std::string("native 异常: ") + e.what();
    }
    g_running.store(false);

    if (outcome.timedOut) {
        g_abandoned.fetch_add(1);
    }
    napi_set_named_property(env, result, "ok", MakeBool(env, outcome.ok));
    napi_set_named_property(env, result, "timedOut", MakeBool(env, outcome.timedOut));
    napi_set_named_property(env, result, "exitCode", MakeInt(env, outcome.exitCode));
    napi_set_named_property(env, result, "stdout", MakeString(env, outcome.stdoutText));
    napi_set_named_property(env, result, "stderr", MakeString(env, outcome.stderrText));
    napi_set_named_property(env, result, "error", MakeString(env, outcome.error));
    napi_set_named_property(env, result, "durationMs", MakeInt(env, outcome.durationMs));
    return result;
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"isAvailable", nullptr, JsIsAvailable, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runPython", nullptr, JsRunPython, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module guncatPyModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "guncatpy",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterGuncatPyModule() {
    napi_module_register(&guncatPyModule);
}
