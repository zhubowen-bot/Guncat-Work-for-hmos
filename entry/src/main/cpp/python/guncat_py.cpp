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
#include <condition_variable>
#include <pthread.h>
#include <signal.h>
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
using FnPyThreadState_Get = void* (*)();
using FnPyThreadState_GetID = unsigned long (*)(void*);
// 3.10 起签名为 (unsigned long id, PyObject *exc); 用 void* 兜住更早的写法
using FnPyThreadState_SetAsyncExc = int (*)(unsigned long, void*);

struct PyApi {
    void* handle = nullptr;
    FnPy_IsInitialized isInitialized = nullptr;
    FnPy_Initialize initialize = nullptr;
    FnPy_FinalizeEx finalize = nullptr;
    FnPyRun_SimpleString runSimpleString = nullptr;
    FnPyGILState_Ensure gilEnsure = nullptr;
    FnPyGILState_Release gilRelease = nullptr;
    FnPyErr_SetInterrupt setInterrupt = nullptr;
    FnPyThreadState_Get threadStateGet = nullptr;
    FnPyThreadState_GetID threadStateGetID = nullptr;
    FnPyThreadState_SetAsyncExc setAsyncExc = nullptr;
    // PyExc_KeyboardInterrupt 是导出的**数据符号**(PyObject*), dlsym 拿到的是它的地址
    void** keyboardInterrupt = nullptr;
    // libpython 实际被加载的目录(就是应用的 lib 目录)。C 扩展模块也放在这里 ——
    // 设备上只有 lib 目录里的 .so 能 dlopen, 数据目录里的 ELF 会被拒。
    std::string libDir;
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
    g_api.threadStateGet = reinterpret_cast<FnPyThreadState_Get>(::dlsym(h, "PyThreadState_Get"));
    g_api.threadStateGetID = reinterpret_cast<FnPyThreadState_GetID>(::dlsym(h, "PyThreadState_GetID"));
    g_api.setAsyncExc = reinterpret_cast<FnPyThreadState_SetAsyncExc>(
        ::dlsym(h, "PyThreadState_SetAsyncExc"));
    g_api.keyboardInterrupt = reinterpret_cast<void**>(::dlsym(h, "PyExc_KeyboardInterrupt"));
    if (g_api.isInitialized == nullptr || g_api.initialize == nullptr ||
        g_api.runSimpleString == nullptr || g_api.gilEnsure == nullptr || g_api.gilRelease == nullptr) {
        g_api.error = "libpython 缺少必要符号(版本不匹配?)";
        return g_api;
    }
    // 用 dladdr 找出 libpython 落在哪个目录: C 扩展也在同一目录, 运行期要把它并进 PYTHONPATH
    Dl_info info;
    if (::dladdr(reinterpret_cast<void*>(g_api.initialize), &info) != 0 &&
        info.dli_fname != nullptr) {
        std::string path(info.dli_fname);
        std::size_t slash = path.find_last_of('/');
        if (slash != std::string::npos && slash > 0) {
            g_api.libDir = path.substr(0, slash);
        }
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

// 把路径安全地嵌进 Python 单引号字符串(路径由应用生成, 这里只做最小转义)
std::string PyLiteral(const std::string& raw) {
    std::string out;
    out.reserve(raw.size() + 8);
    for (std::size_t i = 0; i < raw.size(); ++i) {
        char c = raw[i];
        if (c == '\\' || c == '\'') {
            out.push_back('\\');
        }
        out.push_back(c);
    }
    return out;
}

void ReplaceAll(std::string& text, const std::string& token, const std::string& value) {
    std::size_t pos = 0;
    while ((pos = text.find(token, pos)) != std::string::npos) {
        text.replace(pos, token.size(), value);
        pos += value.size();
    }
}

// 用真实路径渲染启动器/诊断脚本
std::string RenderScript(const char* tpl, const std::string& codePath, const std::string& outPath,
                         const std::string& errPath, const std::string& metaPath,
                         const std::string& diagPath, const std::string& argvPath,
                         const std::string& stdinPath) {
    std::string script(tpl);
    ReplaceAll(script, "__GUNCAT_CODE__", PyLiteral(codePath));
    ReplaceAll(script, "__GUNCAT_OUT__", PyLiteral(outPath));
    ReplaceAll(script, "__GUNCAT_ERR__", PyLiteral(errPath));
    ReplaceAll(script, "__GUNCAT_META__", PyLiteral(metaPath));
    ReplaceAll(script, "__GUNCAT_DIAG__", PyLiteral(diagPath));
    ReplaceAll(script, "__GUNCAT_ARGV__", PyLiteral(argvPath));
    ReplaceAll(script, "__GUNCAT_STDIN__", PyLiteral(stdinPath));
    return script;
}

bool ReadBoolFile(const std::string& path, bool defVal) {    std::string t = Trim(ReadFile(path));
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
//
// 两条硬要求(踩过坑):
//   1. 顶层只 import sys/os/io —— 它们全是内置/冻结模块, 不依赖 lib-dynload 里的 C 扩展。
//      早先版本顶层 `import json, traceback`, 一旦某个 C 扩展加载失败(例如 _json),
//      启动器会在写结果文件之前就抛异常, 宿主只能看到"没有产出结果文件"这种瞎猜的报错。
//   2. 无论如何都要写 meta(含 stage + traceback), 失败时再写一份 diag(sys.path/import 探测),
//      让"解释器起没起来、stdlib 在哪、哪个扩展加载不了"在工具返回值里一眼可见。
const char* kLauncher = R"PYSRC(
import sys, os, io

# 注意: 这些路径是 native 侧在每次调用时**直接拼进源码**的, 不走环境变量。
# 踩过的坑: CPython 在 Py_Initialize 里就把 os.environ 快照下来了, native 之后再用
# libc setenv() 设的变量 Python 侧完全看不到 —— 于是 code/meta 路径全是空串,
# 启动器"成功"执行了一段空脚本(rc=0)、什么文件都没写, 宿主只能看到"没有产出结果文件"。
_code_path = '__GUNCAT_CODE__'
_out_path = '__GUNCAT_OUT__'
_err_path = '__GUNCAT_ERR__'
_meta_path = '__GUNCAT_META__'
_diag_path = '__GUNCAT_DIAG__'
_argv_path = '__GUNCAT_ARGV__'
_stdin_path = '__GUNCAT_STDIN__'


def _write(path, text):
    if not path:
        return
    try:
        _f = open(path, 'w', encoding='utf-8', errors='replace')
        try:
            _f.write(text)
        finally:
            _f.close()
    except BaseException:
        pass


def _fmt_exc():
    try:
        import traceback
        return traceback.format_exc()
    except BaseException:
        try:
            _t, _v, _ = sys.exc_info()
            return '%s: %r' % (_t, _v)
        except BaseException:
            return 'unknown error'


_stage = 'boot'
_ok = 0
_code = 0
_error = ''
_out = None
_errbuf = None

try:
    _stage = 'argv'
    _argv = ['-c']
    if _argv_path:
        try:
            _af = open(_argv_path, 'r', encoding='utf-8', errors='replace')
            try:
                _raw = _af.read()
            finally:
                _af.close()
            _argv = _raw.split('\n')
            if _argv and _argv[-1] == '':
                _argv.pop()
            if not _argv:
                _argv = ['-c']
        except BaseException:
            _argv = ['-c']
    sys.argv = list(_argv)

    # PEP 670: 默认把 int→str 的转换限制在 4300 位, 实机上 2**100000 能算但 str(n) 会
    # ValueError。数据分析场景里大整数转字符串很常见(哈希/阶乘/大数校验), 放宽到 10 万位。
    try:
        if hasattr(sys, 'set_int_max_str_digits'):
            sys.set_int_max_str_digits(100000)
    except BaseException:
        pass

    _stage = 'stdin'
    if _stdin_path:
        sys.stdin = open(_stdin_path, 'r', encoding='utf-8', errors='replace')

    _stage = 'read_code'
    _src = ''
    if _code_path:
        _cf = open(_code_path, 'r', encoding='utf-8')
        try:
            _src = _cf.read()
        finally:
            _cf.close()

    _stage = 'capture'
    _out = io.StringIO()
    _errbuf = io.StringIO()
    _saved_out, _saved_err = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = _out, _errbuf

    _stage = 'exec'
    _globals = {'__name__': '__main__', '__file__': _code_path}
    _ok = 1
    try:
        exec(compile(_src, '<run_python>', 'exec'), _globals, _globals)
    except SystemExit as _se:
        _code = _se.code if isinstance(_se.code, int) else (0 if _se.code is None else 1)
        if _code == 0:
            _ok = 1
        else:
            _ok = 0
            _error = 'SystemExit(%r)' % (_se.code,)
    except BaseException:
        _ok = 0
        _error = _fmt_exc()
    finally:
        sys.stdout, sys.stderr = _saved_out, _saved_err
        _stage = 'write_result'
        _write(_out_path, _out.getvalue())
        _write(_err_path, _errbuf.getvalue())
    _stage = 'done'
except BaseException:
    _ok = 0
    _error = _fmt_exc()
finally:
    if _ok == 0 and _diag_path:
        try:
            _lines = [
                'version=' + sys.version.replace('\n', ' '),
                'prefix=' + sys.prefix,
                'base_prefix=' + sys.base_prefix,
                'executable=' + sys.executable,
                'cwd=' + os.getcwd(),
                'argv=' + repr(sys.argv),
                'stage=' + _stage,
            ]
            for _p in sys.path:
                _lines.append('path=' + str(_p))
            for _m in ('posix', 'io', 'os', 'encodings', 'codecs', '_codecs',
                       'json', '_json', 'csv', '_csv', 'zlib', 'math', 'binascii'):
                try:
                    __import__(_m)
                    _lines.append('import %s=ok' % _m)
                except BaseException as _ie:
                    _lines.append('import %s=FAIL %r' % (_m, _ie))
            _write(_diag_path, '\n'.join(_lines) + '\n')
        except BaseException:
            pass
    _write(_meta_path, '%d\n%d\n%s\nstage=%s\n' % (1 if _ok else 0, _code, _error, _stage))
)PYSRC";

// 兜底诊断: 万一启动器连结果文件都没写出来(例如某个 import 就把解释器搞死了),
// 再用"只用 builtins + sys/os"的最小脚本探一次, 至少把 sys.path / sys.prefix 落盘。
const char* kMiniDiag = R"PYMINI(
import sys, os
_p = '__GUNCAT_DIAG__'
if _p:
    _lines = []
    try:
        _lines.append('mini version=' + sys.version.replace('\n', ' '))
        _lines.append('mini prefix=' + sys.prefix)
        _lines.append('mini executable=' + sys.executable)
        _lines.append('mini cwd=' + os.getcwd())
        for _x in sys.path:
            _lines.append('mini path=' + str(_x))
        _built = ('posix', 'io', 'os', 'encodings', '_codecs', '_json', 'zlib', 'math')
        for _m in _built:
            try:
                __import__(_m)
                _lines.append('mini import %s=ok' % _m)
            except BaseException as _e:
                _lines.append('mini import %s=FAIL %r' % (_m, _e))
    except BaseException as _e:
        _lines.append('mini failed %r' % (_e,))
    try:
        _f = open(_p, 'w')
        try:
            _f.write('\n'.join(_lines) + '\n')
        finally:
            _f.close()
    except BaseException:
        pass
)PYMINI";

struct PyRunOptions {
    std::string code;
    std::string workDir;
    std::string scratchDir;
    std::string pythonHome;
    std::string pythonPath;
    std::string argvJson = "[]";
    // argv: 一行一个参数(启动器按行切分, 不走 JSON)
    std::string argvText = "-c";
    // 可选: 标准输入文件(内容会被挂成 sys.stdin); 空串表示让 sys.stdin 保持默认
    std::string stdinPath;
    // 可选: CA 证书包路径(ssl 用); 空串则沿用系统默认
    std::string certFile;
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
    // PYTHONPATH = 调用方给的标准库 zip + 应用 lib 目录(C 扩展在这里)
    std::string pyPath = opt.pythonPath;
    if (!api.libDir.empty() && pyPath.find(api.libDir) == std::string::npos) {
        pyPath = pyPath.empty() ? api.libDir : (pyPath + ":" + api.libDir);
    }
    if (!pyPath.empty()) {
        ::setenv("PYTHONPATH", pyPath.c_str(), 1);
    }
    ::setenv("PYTHONUTF8", "1", 1);
    // 无 TTY 时 stdout 的 encoding 会是 None, 显式钉住 UTF-8 更可控
    ::setenv("PYTHONIOENCODING", "utf-8", 1);
    ::setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
    ::setenv("PYTHONNOUSERSITE", "1", 1);
    // https 要证书: 应用沙箱里没有系统 CA, 用随包带的 cacert.pem
    if (!opt.certFile.empty()) {
        ::setenv("SSL_CERT_FILE", opt.certFile.c_str(), 1);
    }
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
    const std::string diagPath = opt.scratchDir + "/diag.txt";
    const std::string argvPath = opt.scratchDir + "/argv.txt";
    ::unlink(outPath.c_str());
    ::unlink(errPath.c_str());
    ::unlink(metaPath.c_str());
    ::unlink(diagPath.c_str());
    if (!WriteFile(codePath, opt.code)) {
        out.error = "无法写入临时脚本目录: " + opt.scratchDir;
        return out;
    }
    // argv 走纯文本(一行一个), 启动器不需要 import json 就能拿到参数
    if (!WriteFile(argvPath, opt.argvText)) {
        out.error = "无法写入 argv 文件: " + argvPath;
        return out;
    }
    // 注意: 这些 GUNCAT_PY_* 环境变量只是留给排障用的副本 —— CPython 在 Py_Initialize 时
    // 已快照 os.environ, 之后再 setenv 是看不见的, 所以路径一律走上面的源码内联。
    ::setenv("GUNCAT_PY_CODE", codePath.c_str(), 1);
    ::setenv("GUNCAT_PY_OUT", outPath.c_str(), 1);
    ::setenv("GUNCAT_PY_ERR", errPath.c_str(), 1);
    ::setenv("GUNCAT_PY_META", metaPath.c_str(), 1);
    ::setenv("GUNCAT_PY_DIAG", diagPath.c_str(), 1);
    ::setenv("GUNCAT_PY_ARGV", argvPath.c_str(), 1);
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

    const int32_t timeoutMs = opt.timeoutMs > 0 ? opt.timeoutMs : 60000;
    std::atomic<bool> finished{false};
    std::atomic<bool> interruptFired{false};

    int state = api.gilEnsure();
    // 超时打断机制的选择(都在宿主逐项实测过):
    //   * PyErr_SetInterrupt: CPython 只在它认定的 main thread 上处理中断, 从别的线程调用
    //     会被丢("Signal 2 ignored due to race condition"), 实机表现为 timeout_ms 完全失效;
    //   * PyThreadState_SetAsyncExc: 恒返回 0(id 找不到), 不可用;
    //   * **pthread_kill(运行线程, SIGINT)**: 立刻在下一个字节码边界抛 KeyboardInterrupt ✔
    // 所以这里记下运行线程的 pthread 句柄, 看门狗到点直接给它发 SIGINT。
    const pthread_t runnerThread = ::pthread_self();

    std::thread watchdog([&finished, &interruptFired, timeoutMs, &api, runnerThread]() {
        const int stepMs = 20;
        int waited = 0;
        while (!finished.load() && waited < timeoutMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(stepMs));
            waited += stepMs;
        }
        if (finished.load()) {
            return;
        }
        OH_LOG_WARN(LOG_APP, "python timeout after %{public}d ms, sending SIGINT to runner", timeoutMs);
        int rcSig = ::pthread_kill(runnerThread, SIGINT);
        if (rcSig != 0 && api.setInterrupt != nullptr) {
            api.setInterrupt();  // 兜底
        }
        interruptFired.store(true);
    });

    std::string script = RenderScript(kLauncher, codePath, outPath, errPath, metaPath,
                                      diagPath, argvPath, opt.stdinPath);
    int rc = api.runSimpleString(script.c_str());
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
        // 启动器没写出结果: 再用最小脚本探一次(只用 sys/os), 保证至少拿到 sys.path 级信息
        OH_LOG_WARN(LOG_APP, "launcher produced no meta (rc=%{public}d), running mini diag", rc);
        ::unlink(diagPath.c_str());
        std::string mini = RenderScript(kMiniDiag, codePath, outPath, errPath, metaPath,
                                        diagPath, argvPath, opt.stdinPath);
        int state2 = api.gilEnsure();
        int rc2 = api.runSimpleString(mini.c_str());
        api.gilRelease(state2);
        std::string diag = Trim(ReadFile(diagPath));
        out.error = "Python 启动器没有产出结果(rc=" + std::to_string(rc) +
            ", 兜底诊断 rc=" + std::to_string(rc2) + ")";
        if (!diag.empty()) {
            out.error += "\n—— 运行库诊断 ——\n" + diag;
        } else {
            out.error += "\n(连最小诊断脚本也没跑出结果: 解释器初始化后基本不可用, "
                         "优先怀疑 PYTHONHOME 指向的目录里没有标准库, 或 libpython 与扩展模块不匹配)";
        }
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
    // meta 末尾带一行 stage=<阶段>, 单独摘出来(失败时拼进报错, 便于判断卡在哪一步)
    std::string stage;
    std::size_t stagePos = out.error.rfind("\nstage=");
    if (stagePos != std::string::npos) {
        stage = Trim(out.error.substr(stagePos + 7));
        out.error = out.error.substr(0, stagePos);
    } else if (out.error.compare(0, 6, "stage=") == 0) {
        stage = Trim(out.error.substr(6));
        out.error.clear();
    }
    out.ok = (okFlag == "1");
    out.stdoutText = ReadFile(outPath);
    out.stderrText = ReadFile(errPath);
    out.timedOut = !out.ok && (interruptFired.load() ||
        (out.durationMs >= timeoutMs && out.error.find("KeyboardInterrupt") != std::string::npos));
    if (!out.ok) {
        if (out.error.empty()) {
            out.error = "执行失败(退出码 " + std::to_string(out.exitCode) + ")";
        }
        if (!stage.empty() && stage != "done") {
            out.error += "\n(启动器停在阶段: " + stage + ")";
        }
        // 启动器判失败时也把诊断带上: 用户/模型能直接看到 sys.path 与哪些扩展加载不了
        std::string diag = Trim(ReadFile(diagPath));
        if (!diag.empty() && out.error.find("import ") == std::string::npos) {
            out.error += "\n—— 运行库诊断 ——\n" + diag;
        }
    }
    return out;
}

// ===== 单线程执行器 =====
// 为什么要有它: CPython 只认"调用 Py_Initialize 的那个线程"为 main thread, 中断信号
// (PyErr_SetInterrupt) 也只在该线程上被处理。NAPI 回调可能落在不同线程上, 一旦运行线程
// 不是初始化线程, timeout_ms 就会彻底失效(实机: 6 秒的忙循环照跑 6 秒, stderr 只留
// "OSError: Signal 2 ignored due to race condition")。
// 做法: 第一次调用时起一个专属线程, 由它初始化解释器并长期复用; 之后所有执行都投递给它。
struct PyJob {
    PyRunOptions opt;
    PyRunOutcome out;
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
};

std::mutex g_runnerMutex;          // 保护下面的 runner 生命周期
std::thread* g_runner = nullptr;
std::mutex g_queueMutex;           // 保护 g_pending
std::condition_variable g_queueCv;
PyJob* g_pending = nullptr;
std::atomic<bool> g_runnerStarted{false};

void RunnerLoop() {
    for (;;) {
        PyJob* job = nullptr;
        {
            std::unique_lock<std::mutex> lock(g_queueMutex);
            g_queueCv.wait(lock, []() { return g_pending != nullptr; });
            job = g_pending;
            g_pending = nullptr;
        }
        if (job == nullptr) {
            return;
        }
        PyRunOutcome out;
        try {
            out = RunPythonInner(job->opt);  // 在这个线程上执行, 信号可被处理
        } catch (const std::exception& e) {
            out.ok = false;
            out.error = std::string("native 异常: ") + e.what();
        }
        {
            std::lock_guard<std::mutex> lock(job->mutex);
            job->out = out;
            job->done = true;
        }
        job->cv.notify_all();
    }
}

bool EnsureRunner(std::string& err) {
    std::lock_guard<std::mutex> lock(g_runnerMutex);
    if (g_runner != nullptr) {
        return true;
    }
    PyApi& api = LoadPyApi();
    if (!api.ok) {
        err = api.error;
        return false;
    }
    g_runner = new std::thread(RunnerLoop);
    g_runnerStarted.store(true);
    OH_LOG_INFO(LOG_APP, "python runner thread started");
    return true;
}

PyRunOutcome DispatchToRunner(const PyRunOptions& opt) {
    PyRunOutcome out;
    std::string err;
    if (!EnsureRunner(err)) {
        out.ok = false;
        out.error = err;
        return out;
    }
    PyJob job;
    job.opt = opt;
    {
        std::lock_guard<std::mutex> lock(g_queueMutex);
        g_pending = &job;
    }
    g_queueCv.notify_one();
    std::unique_lock<std::mutex> lock(job.mutex);
    job.cv.wait(lock, [&job]() { return job.done; });
    return job.out;
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
        opt.certFile = PropToString(env, args[0], "certFile");
        if (!opt.argvJson.empty()) {
            opt.argvText = opt.argvJson;  // 字段名沿用 argvJson, 内容是"一行一个参数"的纯文本
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
        // 关键: 必须交给"调用过 Py_Initialize 的那个线程"执行。CPython 只有在它认定的
        // main thread 上才会处理中断信号 —— 实机现象是 PyErr_SetInterrupt 被丢掉
        // ("Signal 2 ignored due to race condition"), timeout_ms 完全失效。
        outcome = DispatchToRunner(opt);
    } catch (const std::exception& e) {
        outcome.ok = false;
        outcome.error = std::string("native 异常: ") + e.what();
    }
    g_running.store(false);

    if (outcome.timedOut) {
        g_abandoned.fetch_add(1);
    }
    std::string errHead = outcome.error.size() > 160 ? outcome.error.substr(0, 160) : outcome.error;
    OH_LOG_INFO(LOG_APP, "run_python ok=%{public}d timeout=%{public}d rc=%{public}d %{public}lldms err=%{public}s",
        outcome.ok ? 1 : 0, outcome.timedOut ? 1 : 0, outcome.exitCode,
        static_cast<long long>(outcome.durationMs), errHead.c_str());
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
