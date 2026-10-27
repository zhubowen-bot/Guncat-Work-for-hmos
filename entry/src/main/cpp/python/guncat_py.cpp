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
//   * stdout/stderr 用**真实文件对象 + dup2 重定向 fd 1/2** 捕获：print、sys.stdout.buffer、
//     fileno()、os.write(1) 四条路径都落在同一份文件里（StringIO 那条老路会让后三条失效）；
//   * 解释器常驻，所以每次调用前后做一遍**进程级状态快照/回滚**（sys.path / os.environ /
//     warnings / logging / random / numpy 打印选项），用户上一次调用的副作用不会漏到下一次；
//   * 超时：启动器用 ast 给循环注入截止检查（到点抛 TimeoutError，纯 Python 层，不伤进程），
//     宿主侧再兜一层"软超时"（放弃等待 + 熔断），阻塞在 C 调用里的按"放弃等待"处理。
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

struct PyApi {
    void* handle = nullptr;
    FnPy_IsInitialized isInitialized = nullptr;
    FnPy_Initialize initialize = nullptr;
    FnPy_FinalizeEx finalize = nullptr;
    FnPyRun_SimpleString runSimpleString = nullptr;
    FnPyGILState_Ensure gilEnsure = nullptr;
    FnPyGILState_Release gilRelease = nullptr;
    // libpython 实际被加载的目录(就是应用的 lib 目录)。C 扩展模块也放在这里 ——
    // 设备上只有 lib 目录里的 .so 能 dlopen, 数据目录里的 ELF 会被拒。
    std::string libDir;
    std::string error;
    bool ok = false;
};

std::mutex g_mutex;
PyApi g_api;
std::atomic<bool> g_running{false};
// 仍在后台跑、**还没回收**的软超时调用数。
// 只统计软超时: 硬超时(AST 截止)在启动器里抛 TimeoutError 后线程已经把调用做完并归还了
// 解释器, 属于"已回收", 不能算进来 —— 早先按 timedOut 计数, 结果两次正常的超时就把
// 整个会话的 Python 永久锁死(实测复现)。这个计数是**活的**: 僵尸任务一结束就减回去。
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
std::string RenderScript(const char* tpl, const std::string& deadlineText,
                         const std::string& codePath, const std::string& outPath,
                         const std::string& errPath, const std::string& metaPath,
                         const std::string& diagPath, const std::string& argvPath,
                         const std::string& stdinPath, const std::string& warnPath,
                         const std::string& cacheDir) {
    std::string script(tpl);
    ReplaceAll(script, "__GUNCAT_CODE__", PyLiteral(codePath));
    ReplaceAll(script, "__GUNCAT_OUT__", PyLiteral(outPath));
    ReplaceAll(script, "__GUNCAT_ERR__", PyLiteral(errPath));
    ReplaceAll(script, "__GUNCAT_META__", PyLiteral(metaPath));
    ReplaceAll(script, "__GUNCAT_DIAG__", PyLiteral(diagPath));
    ReplaceAll(script, "__GUNCAT_ARGV__", PyLiteral(argvPath));
    ReplaceAll(script, "__GUNCAT_STDIN__", PyLiteral(stdinPath));
    ReplaceAll(script, "__GUNCAT_WARN__", PyLiteral(warnPath));
    ReplaceAll(script, "__GUNCAT_CACHE__", PyLiteral(cacheDir));
    ReplaceAll(script, "__GUNCAT_DEADLINE__", deadlineText);
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

// 启动器: 用户代码在子命名空间里执行, 输出被重定向到文件后由宿主读回。
// 全部状态走环境变量里的文件路径, 避免把用户代码拼进 Python 源码字符串。
//
// 两条硬要求(踩过坑):
//   1. 顶层只 import sys/os/io —— 它们全是内置/冻结模块, 不依赖 lib-dynload 里的 C 扩展。
//      早先版本顶层 `import json, traceback`, 一旦某个 C 扩展加载失败(例如 _json),
//      启动器会在写结果文件之前就抛异常, 宿主只能看到"没有产出结果文件"这种瞎猜的报错。
//   2. 无论如何都要写 meta(含 stage + traceback), 失败时再写一份 diag(sys.path/import 探测),
//      让"解释器起没起来、stdlib 在哪、哪个扩展加载不了"在工具返回值里一眼可见。
const char* kLauncher = R"PYSRC(

import sys, os, io, time

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
_warn_path = '__GUNCAT_WARN__'
_cache_dir = '__GUNCAT_CACHE__'


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


# 常见"没随包/在设备上不可用"的模块 → 给出可执行的替代建议。
# 附在 traceback 后面, 让模型(和用户)当场知道下一步怎么做,
# 而不是看到一句 ModuleNotFoundError 就反复重试同一个 import。
_GUNCAT_HINTS = {
    'scipy': 'scipy 已随包, 直接用: linalg / optimize / sparse / integrate / signal / '
              'interpolate / stats / special 都可用。出现这个错说明运行库没释放完整(重启应用即可), '
              '不要改用 numpy 手写实现。',
    'sklearn': 'scikit-learn 未随包。分类/回归用 scipy 现成的: '
               'scipy.optimize.minimize/curve_fit、scipy.cluster.vq、scipy.stats; '
               '线性模型直接 numpy.linalg.lstsq。不要从零手写算法。',
    'tkinter': '设备上没有窗口系统, tkinter 不可用。要出图请用 matplotlib(Agg) 存 PNG。',
    'PyQt5': '设备上没有 GUI 后端。用 matplotlib(Agg)/Pillow 生成图片文件。',
    'cv2': 'OpenCV 未随包。图像处理用 Pillow(Image.open/resize/filter) 或 numpy。',
    'torch': 'PyTorch 未随包(体积与工具链都不允许)。数值计算用 numpy。',
    'tensorflow': 'TensorFlow 未随包。数值计算用 numpy。',
    'numba': 'numba 未随包(需要 LLVM JIT)。热点循环用 numpy 向量化。',
    'pyarrow': 'pyarrow/parquet 未随包。持久化用 to_csv / to_pickle / to_json, '
               '或 openpyxl 写 xlsx。',
    'fastparquet': 'parquet 后端未随包。持久化用 to_csv / to_pickle / to_json。',
    'psycopg2': 'PostgreSQL 驱动未随包; 需要数据库时用 sqlite3(标准库, 已可用)。',
    'pymysql': 'pymysql 未随包; 需要数据库时用 sqlite3(标准库, 已可用)。',
    'multiprocessing': 'multiprocessing 只有 fork 上下文可用: Process/Pipe 可以, '
                       '但 spawn/forkserver 要重新 exec 解释器(嵌入式解释器没有可执行体), '
                       'Queue/Pool/Lock 要 /dev/shm(沙箱里没有)。'
                       '并行用 guncat_mp.map(func, items, workers=4) 或 threading。',
    '_multiprocessing': '同上: 只用 fork 相关的 API, 别碰 Queue/Pool/Lock。',
}


def _hint(text):
    """给 traceback 追加"下一步怎么办"的提示。"""
    try:
        if not text:
            return text
        extra = []
        for _mod, _tip in _GUNCAT_HINTS.items():
            if ("No module named '%s'" % _mod) in text:
                extra.append('提示(%s): %s' % (_mod, _tip))
        if 'No module named' in text and not extra:
            extra.append('提示: 该模块没有随应用打包(运行期不能 pip install)。'
                         'run_python 可用的库见工具描述; 需要新库请反馈。')
        if 'Cannot load backend' in text or 'no display' in text:
            extra.append('提示: 无 GUI 后端, 请先 matplotlib.use("Agg") 再 savefig 成文件。')
        # 设备上没有 /tmp: pandas.to_pickle("/tmp/x.pkl") 之类会报"目录不存在",
        # 用户容易误判成自己路径写错, 这里直接给可用替代。
        if '/tmp' in text and ('No such file or directory' in text or
                               'non-existent' in text or "does not exist" in text):
            extra.append('提示: 设备上没有 /tmp。临时文件用 tempfile.gettempdir() / '
                         'NamedTemporaryFile(实际落在应用缓存目录), 或直接写当前工作区的相对路径。')
        if '解释器安装目录' in text or 'Read-only file system' in text:
            extra.append('提示: 标准库/三方库目录是只读的(写它会跨调用、跨会话生效)。'
                         '要写文件用工作区相对路径或 tempfile.gettempdir()。')
        if '没有可重新 exec 的 python 可执行体' in text:
            extra.append('提示: 并行请用 guncat_mp.map(func, items, workers=4); '
                         'I/O 并发用 threading / ThreadPoolExecutor。')
        if not extra:
            return text
        return text.rstrip() + '\n\n' + '\n'.join(extra)
    except BaseException:
        return text


# ===== 内存(设备上进程被杀是 SIGKILL, Python 里根本捕获不到) =====
# 阈值按真机口径定的: 系统 12 GB, 全库加载后本进程 RSS 约 1.2 GB。
_GUNCAT_MEM_AVAIL_WARN_KB = 2 * 1024 * 1024      # 系统可用 < 2 GB 就提醒
# 全库加载后 RSS 本来就有 1.1~1.2 GB, 所以 RSS 的门槛要明显高于它, 否则每次调用都在念。
_GUNCAT_MEM_RSS_WARN_KB = 1536 * 1024            # 本进程 RSS > 1.5 GB 才提醒
_GUNCAT_MEM_GROWTH_WARN_KB = 512 * 1024          # 本次调用把 VmHWM 顶高 > 512 MB 也提醒
_GUNCAT_MEM_GC_KB = 400 * 1024                   # 这么大才值得跑一次 gc.collect()


def _read_mem():
    """读 /proc 拿内存数字(kB); 非 Linux 或读不到时返回 None。

    不用 psutil: 那要 import 一个模块(约 20ms), 这点开销每次调用都付不划算。
    """
    _info = {}
    try:
        _f = open('/proc/self/status', 'r')
        try:
            for _line in _f:
                if _line.startswith('VmRSS:'):
                    _info['rss'] = int(_line.split()[1])
                elif _line.startswith('VmHWM:'):
                    _info['peak'] = int(_line.split()[1])
        finally:
            _f.close()
    except BaseException:
        pass
    try:
        _f = open('/proc/meminfo', 'r')
        try:
            for _line in _f:
                if _line.startswith('MemAvailable:'):
                    _info['avail'] = int(_line.split()[1])
                    break
        finally:
            _f.close()
    except BaseException:
        pass
    return _info or None


def _fmt_mb(kb):
    return '%.0f MB' % (kb / 1024.0)


def _mem_note(before, after):
    """内存紧张时给一句可执行的提醒; 正常情况返回空串(不要每次都啰嗦)。

    三种触发条件: 系统可用 < 2 GB; 本进程 RSS > 1.5 GB; 本次调用把 VmHWM 顶高 > 512 MB。
    最后一个才是"这一次脚本吃得多"的信号 —— 全靠 RSS 门槛会把全库加载后的正常状态也报出来。
    """
    try:
        _m = after or before or {}
        _b = before or {}
        _avail = _m.get('avail')
        _rss = _m.get('rss')
        _peak = _m.get('peak')
        # VmHWM 是进程累计峰值: 只有"这一次把水线顶高了"才算本次调用的信号,
        # 否则一次大分配会让此后每一次调用都在念同一句话。
        _hot = ((_avail and _avail < _GUNCAT_MEM_AVAIL_WARN_KB) or
                (_rss and _rss > _GUNCAT_MEM_RSS_WARN_KB) or
                (_peak and _b.get('peak') and
                 (_peak - _b.get('peak')) > _GUNCAT_MEM_GROWTH_WARN_KB))
        if not _hot:
            return ''
        _notes = []
        if _avail:
            _notes.append('设备可用 %.1f GB' % (_avail / 1048576.0))
        if _rss:
            _notes.append('本进程 RSS ' + _fmt_mb(_rss))
        if _peak:
            _notes.append('峰值 ' + _fmt_mb(_peak))
        return ('内存: ' + '；'.join(_notes) +
                '。大数组 / 大 DataFrame 可能被系统直接杀掉(SIGKILL, Python 里捕获不到), '
                '建议分块处理, 用完 del + gc.collect()。')
    except BaseException:
        return ''


def _release_globals(g, mem):
    """把上一次调用的用户命名空间放掉。

    踩过的坑: exec 用的 dict 挂在 __main__._globals 上, 下一次调用才被替换 ——
    上一次脚本里 400MB 的数组会一直占着 RSS(实测对象确实还活着)。内存吃紧时
    这就是"单独跑没事、连着跑就崩"的放大器。
    """
    if g is None:
        return
    try:
        g.clear()
    except BaseException:
        return
    try:
        if mem and (mem.get('rss') or 0) > _GUNCAT_MEM_GC_KB:
            import gc
            gc.collect()
    except BaseException:
        pass


# ===== 一次性防护(解释器常驻, 这些钩子只装一次就永久生效) =====
# 为什么写在启动器里而不是 sitecustomize: sitecustomize 在 extras 目录里, 换它要重打
# 运行库 zip; 启动器跟着 libguncatpy.so 走, 装上就生效。
_GUNCAT_WRITE_FLAGS = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND
_GUNCAT_MUT_EVENTS = frozenset((
    'os.remove', 'os.rmdir', 'os.mkdir', 'os.rename', 'os.replace', 'os.link',
    'os.symlink', 'os.chmod', 'os.chown', 'os.truncate', 'os.utime', 'shutil.rmtree',
))


def _under(path, root):
    """path 是否落在 root 里(纯字符串, 不做 realpath —— 审计钩子里不能触发 IO)。"""
    if not path or not root:
        return False
    try:
        p = path if os.path.isabs(path) else os.path.join(os.getcwd(), path)
        p = os.path.normpath(p)
    except BaseException:
        return False
    root = root.rstrip('/').rstrip('\\')
    if p == root:
        return True
    return p.startswith(root + '/') or p.startswith(root + '\\')


def _patch_multiprocessing():
    """让 spawn/forkserver 当场报错, 而不是静默 exitcode=255。

    嵌入式解释器没有可执行体(sys.executable 为空), multiprocessing 的 spawn 却要重新
    exec 一个 python —— 子进程起不来, 而 start()/join() 全程不抛异常, 用户会误以为
    子进程跑过了。这是最危险的一类失败(静默错误), 所以换成明确的 RuntimeError。
    """
    try:
        import multiprocessing.spawn as _spawn
        if getattr(_spawn, '_guncat_patched', False):
            return
        _spawn._guncat_patched = True

        def _no_executable(*_a, **_k):
            raise RuntimeError(
                'run_python 不支持 multiprocessing 的 spawn / forkserver 启动方式: '
                '设备上的解释器是编进应用里的 libpython(.so), 没有可重新 exec 的 python '
                '可执行体, 子进程会以 exitcode=255 静默失败(既不报错也不执行)。'
                '请改用: 默认 fork 上下文(Process / Pipe)、guncat_mp.map(func, items)、'
                '或者 threading / ThreadPoolExecutor。')

        _spawn.get_executable = _no_executable
    except BaseException:
        pass


class _MpPatchLoader:
    def __init__(self, inner):
        self._inner = inner

    def create_module(self, spec):
        return self._inner.create_module(spec)

    def exec_module(self, module):
        self._inner.exec_module(module)
        _patch_multiprocessing()

    def __getattr__(self, name):
        return getattr(self._inner, name)


class _MpPatchFinder:
    """multiprocessing 首次 import 之后立刻打补丁(不改导入结果, 只包一层)。"""

    _done = False

    def find_spec(self, fullname, path=None, target=None):
        if self._done or fullname != 'multiprocessing':
            return None
        self._done = True
        try:
            import importlib.machinery as _machinery
            spec = _machinery.PathFinder.find_spec(fullname, path)
            if spec is None or spec.loader is None:
                return None
            spec.loader = _MpPatchLoader(spec.loader)
            return spec
        except BaseException:
            return None


def _install_guards():
    if getattr(sys, '_guncat_guarded', False):
        return
    sys._guncat_guarded = True
    # 启动快照: 只在这里记一次"环境本来长什么样"。诊断里必须用快照,
    # 否则用户上一轮改脏的 sys.path 会被当成环境信息打出来(实测出现过 path=/FAKE/LEAK/PATH)。
    try:
        sys._guncat_boot = {
            'version': sys.version.replace('\n', ' '),
            'prefix': sys.prefix,
            'executable': sys.executable,
            'path': list(sys.path),
        }
    except BaseException:
        pass
    # matplotlib 的字体缓存默认落在不可写目录, 于是每次 import 都在临时目录重建
    # (真机实测首次 import 到 5 秒)。指到应用 cache 目录, 缓存只建一次。
    try:
        if _cache_dir:
            _mpl_dir = os.path.join(_cache_dir, 'matplotlib')
            if not os.path.isdir(_mpl_dir):
                os.makedirs(_mpl_dir, exist_ok=True)
            if os.path.isdir(_mpl_dir):
                os.environ.setdefault('MPLCONFIGDIR', _mpl_dir)
    except BaseException:
        pass
    try:
        if 'multiprocessing' in sys.modules:
            _patch_multiprocessing()
        else:
            sys.meta_path.insert(0, _MpPatchFinder())
    except BaseException:
        pass
    # 解释器安装树只读: 里面的文件会被**此后每一次调用**导入, 写进去等于跨会话代码注入。
    _root = ''
    try:
        _root = os.path.normpath(sys.prefix or '')
    except BaseException:
        _root = ''
    if not _root:
        return

    def _deny(path):
        raise PermissionError(
            'run_python 不允许修改解释器安装目录(%s): %s。'
            '标准库/三方库是只读的(改了会跨调用、跨会话生效); '
            '要写文件请用工作区相对路径或 tempfile.gettempdir()。' % (_root, path))

    def _audit(event, args):
        try:
            if event == 'open':
                _p = args[0] if args else None
                if not isinstance(_p, str):
                    return
                _mode = args[1] if len(args) > 1 else None
                _flags = args[2] if len(args) > 2 else 0
                _writing = False
                if isinstance(_mode, str) and ('w' in _mode or 'a' in _mode or
                                               'x' in _mode or '+' in _mode):
                    _writing = True
                if isinstance(_flags, int) and (_flags & _GUNCAT_WRITE_FLAGS):
                    _writing = True
                if _writing and _under(_p, _root):
                    _deny(_p)
            elif event in _GUNCAT_MUT_EVENTS:
                for _a in args[:2]:
                    if isinstance(_a, str) and _under(_a, _root):
                        _deny(_a)
        except PermissionError:
            raise
        except BaseException:
            return

    try:
        sys.addaudithook(_audit)
    except BaseException:
        pass


# ===== 跨调用状态隔离 =====
# 解释器常驻的代价: os.environ / sys.path / warnings.filters / logging 级别 /
# random 种子 / numpy 打印选项 全是**进程级**状态, 一次调用改了, 下次还在。
# 危害不是单次, 而是故障不可复现(警告被吞、模块解析命中错的东西、随机实验不可重复)。
_GUNCAT_STATE_MODULES = ('warnings', 'logging', 'random')
_GUNCAT_NP_PRINT_KEYS = ('edgeitems', 'linewidth', 'threshold', 'precision', 'suppress',
                         'nanstr', 'infstr', 'formatter', 'sign', 'floatmode')


def _save_state():
    st = {'mods': {}}
    try:
        st['path'] = list(sys.path)
    except BaseException:
        pass
    try:
        st['env'] = dict(os.environ)
    except BaseException:
        pass
    try:
        for _m in _GUNCAT_STATE_MODULES:
            st['mods'][_m] = _m in sys.modules
    except BaseException:
        pass
    if 'warnings' in sys.modules:
        try:
            st['warn_filters'] = list(sys.modules['warnings'].filters)
        except BaseException:
            pass
    if 'logging' in sys.modules:
        try:
            _l = sys.modules['logging']
            st['log_level'] = _l.root.level
            st['log_handlers'] = list(_l.root.handlers)
            st['log_disable'] = _l.root.manager.disable
        except BaseException:
            pass
    if 'numpy' in sys.modules:
        try:
            _np = sys.modules['numpy']
            st['np_print'] = _np.get_printoptions()
            st['np_err'] = _np.geterr()
        except BaseException:
            pass
    return st


def _restore_state(st):
    try:
        if 'path' in st:
            sys.path[:] = st['path']
    except BaseException:
        pass
    try:
        if 'env' in st:
            _env = os.environ
            for _k in list(_env.keys()):
                if _k not in st['env']:
                    try:
                        del _env[_k]
                    except BaseException:
                        pass
            for _k, _v in st['env'].items():
                if _env.get(_k) != _v:
                    try:
                        _env[_k] = _v
                    except BaseException:
                        pass
    except BaseException:
        pass
    # 本次调用才第一次 import 的模块回不到"原始状态", 直接复位成默认值。
    _mods = st.get('mods') or {}
    if 'warnings' in sys.modules:
        try:
            _w = sys.modules['warnings']
            if _mods.get('warnings') and 'warn_filters' in st:
                _w.filters[:] = st['warn_filters']
            elif not _mods.get('warnings'):
                _w.resetwarnings()
        except BaseException:
            pass
    if 'logging' in sys.modules:
        try:
            _l = sys.modules['logging']
            if _mods.get('logging'):
                if 'log_level' in st:
                    _l.root.setLevel(st['log_level'])
                if 'log_handlers' in st:
                    _l.root.handlers[:] = st['log_handlers']
                if 'log_disable' in st:
                    _l.root.manager.disable = st['log_disable']
            else:
                _l.root.setLevel(_l.WARNING)
                _l.root.handlers[:] = []
                _l.root.manager.disable = 0
        except BaseException:
            pass
    if 'random' in sys.modules:
        # 随机数状态一律重新播种(≈ 每次运行都是新进程), 而不是恢复快照:
        # 恢复快照会让每个调用都从同一个状态开始, "连跑两次结果一样"更让人困惑。
        try:
            sys.modules['random'].seed()
        except BaseException:
            pass
    if 'numpy' in sys.modules:
        try:
            _np = sys.modules['numpy']
            _kw = {}
            if 'np_print' in st:
                for _k in _GUNCAT_NP_PRINT_KEYS:
                    if _k in st['np_print']:
                        _kw[_k] = st['np_print'][_k]
            if _kw:
                _np.set_printoptions(**_kw)
            elif 'np_print' not in st:
                _np.set_printoptions(precision=8, threshold=1000, edgeitems=3,
                                     linewidth=75, suppress=False)
            if 'np_err' in st:
                _np.seterr(**_np_err_kwargs(st['np_err']))
            else:
                _np.seterr(all='warn')
        except BaseException:
            pass


def _np_err_kwargs(err):
    out = {}
    for _k in ('divide', 'over', 'under', 'invalid'):
        if _k in err:
            out[_k] = err[_k]
    return out


# ===== 输出捕获 =====
# 为什么不是 io.StringIO: 那玩意没有 .buffer, fileno() 抛 UnsupportedOperation,
# 而 os.write(1, ...) 更是直接绕过缓冲写到宿主进程的 stdout(既不在结果里也不报错)。
# 改成"真实文件对象 + dup2 重定向 fd 1/2": print / sys.stdout.buffer / fileno / os.write
# 四条路径落到同一个文件, 顺序也自然。
_io_state = {'active': False}


def _capture_start():
    st = _io_state
    st['saved_out'] = sys.stdout
    st['saved_err'] = sys.stderr
    try:
        st['fd1'] = os.dup(1)
        st['fd2'] = os.dup(2)
        _f1 = os.open(_out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        _f2 = os.open(_err_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.dup2(_f1, 1)
            os.dup2(_f2, 2)
        finally:
            os.close(_f1)
            os.close(_f2)
        st['out_stream'] = io.TextIOWrapper(io.FileIO(1, 'w', closefd=False),
                                            encoding='utf-8', errors='replace',
                                            write_through=True)
        st['err_stream'] = io.TextIOWrapper(io.FileIO(2, 'w', closefd=False),
                                            encoding='utf-8', errors='replace',
                                            write_through=True)
        sys.stdout = st['out_stream']
        sys.stderr = st['err_stream']
        st['active'] = 'fd'
    except BaseException:
        # 兜底: 回到 StringIO(功能退化, 但至少还能跑)
        try:
            sys.stdout = st['saved_out']
            sys.stderr = st['saved_err']
        except BaseException:
            pass
        for _k in ('fd1', 'fd2'):
            _fd = st.get(_k)
            if _fd is not None:
                try:
                    os.dup2(_fd, 1 if _k == 'fd1' else 2)
                except BaseException:
                    pass
                try:
                    os.close(_fd)
                except BaseException:
                    pass
                st[_k] = None
        st['out_stream'] = io.StringIO()
        st['err_stream'] = io.StringIO()
        sys.stdout = st['out_stream']
        sys.stderr = st['err_stream']
        st['active'] = 'stringio'


def _capture_stop():
    st = _io_state
    if not st.get('active'):
        return
    _kind = st['active']
    st['active'] = False
    _out_s = st.get('out_stream')
    _err_s = st.get('err_stream')
    for _s in (_out_s, _err_s):
        try:
            _s.flush()
        except BaseException:
            pass
    # 只 flush 不 close: 用户可能留了后台线程往 sys.stdout 里写, close 会让它抛
    # "I/O operation on closed file"。包装器是 FileIO(closefd=False), 丢掉引用后
    # 由 GC 回收, 不会关掉 fd 1/2。
    st['out_stream'] = None
    st['err_stream'] = None
    try:
        sys.stdout = st['saved_out']
        sys.stderr = st['saved_err']
    except BaseException:
        pass
    if _kind == 'stringio':
        _write(_out_path, _out_s.getvalue())
        _write(_err_path, _err_s.getvalue())
        return
    for _k, _target in (('fd1', 1), ('fd2', 2)):
        _fd = st.get(_k)
        if _fd is None:
            continue
        try:
            os.dup2(_fd, _target)
        except BaseException:
            pass
        try:
            os.close(_fd)
        except BaseException:
            pass
        st[_k] = None


_stage = 'boot'
_ok = 0
_code = 0
_error = ''
_state = None
_globals = None
_mem_before = None
_mem_after = None
_warn = ''

try:
    _stage = 'install_guards'
    _install_guards()

    _stage = 'memory'
    _mem_before = _read_mem()

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
    _capture_start()
    _state = _save_state()

    _stage = 'compile'
    _deadline_s = __GUNCAT_DEADLINE__
    _tick_dl = (time.monotonic() + _deadline_s) if _deadline_s and _deadline_s > 0 else None

    def _guard_iter(_it):
        # 非 range 的 for 循环: 用生成器包装, 每 256 项看一次表。
        # (range 循环走另一个更便宜的方案: 直接用循环变量取模, 不用函数调用。)
        _n = 0
        _dl = _tick_dl
        for _v in _it:
            _n += 1
            if (_n & 255) == 0 and _dl is not None and time.monotonic() > _dl:
                raise TimeoutError('run_python 超时(ast-deadline)')
            yield _v

    def _arm(_code_src):
        # 给**所有 while 循环**的循环体首行插入截止检查(含 while True 与 while <条件式>)。
        # for 循环用"每 256 轮看一次表": 逐轮检查会让紧凑数值循环慢 2~3 倍, 代价不划算。
        # 为什么是这里: 实机证明信号中断不可用(要么被丢弃, 要么直接杀进程),
        # 而纯 Python 层的检查绝不会伤到进程。
        try:
            import ast as _ast
            _tree = _ast.parse(_code_src, '<run_python>', 'exec')
        except SyntaxError:
            return _code_src

        class _Deadline(_ast.NodeTransformer):
            def _guard(self):
                _now = _ast.Call(func=_ast.Name(id='__guncat_now', ctx=_ast.Load()),
                                 args=[], keywords=[])
                _test = _ast.BoolOp(op=_ast.And(), values=[
                    _ast.Name(id='__guncat_deadline', ctx=_ast.Load()),
                    _ast.Compare(left=_now, ops=[_ast.Gt()],
                                 comparators=[_ast.Name(id='__guncat_deadline', ctx=_ast.Load())]),
                ])
                _raise = _ast.Raise(
                    exc=_ast.Call(func=_ast.Name(id='__guncat_timeout', ctx=_ast.Load()),
                                  args=[_ast.Constant('run_python 超时(ast-deadline)')],
                                  keywords=[]),
                    cause=None)
                return _ast.If(test=_test, body=[_raise], orelse=[])

            def visit_While(self, node):
                self.generic_visit(node)
                node.body.insert(0, self._guard())
                return node

            def visit_For(self, node):
                self.generic_visit(node)
                _dl_name = _ast.Name(id='__guncat_deadline', ctx=_ast.Load())
                _check = _ast.If(test=_ast.BoolOp(op=_ast.And(), values=[
                    _dl_name,
                    _ast.Compare(left=_ast.Call(func=_ast.Name(id='__guncat_now', ctx=_ast.Load()),
                                                args=[], keywords=[]),
                                 ops=[_ast.Gt()], comparators=[_dl_name])]),
                    body=[_ast.Raise(exc=_ast.Call(
                        func=_ast.Name(id='__guncat_timeout', ctx=_ast.Load()),
                        args=[_ast.Constant('run_python 超时(ast-deadline)')], keywords=[]), cause=None)],
                    orelse=[])
                _it = node.iter
                _is_range = (isinstance(_it, _ast.Call) and
                             isinstance(_it.func, _ast.Name) and _it.func.id == 'range' and
                             isinstance(node.target, _ast.Name))
                if _is_range:
                    # range 循环: `if not (i & 255): <看表>` —— 每轮只多两次算术, 约 30ns。
                    # 掩码是常量, 所以 8/256/8192 的每轮开销完全一样: 取小值只为让"慢循环体"
                    # (比如每轮 5ms)也来得及中断 —— 8192 轮要等 40 秒才看表, 等于没有超时。
                    _mask = _ast.UnaryOp(op=_ast.Not(),
                                          operand=_ast.BinOp(left=_ast.Name(id=node.target.id, ctx=_ast.Load()),
                                                             op=_ast.BitAnd(),
                                                             right=_ast.Constant(255)))
                    node.body.insert(0, _ast.If(test=_mask, body=[_check], orelse=[]))
                else:
                    # 其它可迭代对象: 包一层生成器(每 256 项看表一次)
                    node.iter = _ast.Call(func=_ast.Name(id='__guncat_iter', ctx=_ast.Load()),
                                          args=[_it], keywords=[])
                return node

        return _ast.fix_missing_locations(_Deadline().visit(_tree))

    _stage = 'exec'
    _globals = {
        '__name__': '__main__', '__file__': _code_path,
        '__guncat_deadline': _tick_dl,
        '__guncat_now': time.monotonic,
        '__guncat_timeout': TimeoutError,
        '__guncat_iter': _guard_iter,
    }
    _ok = 1
    try:
        exec(compile(_arm(_src), '<run_python>', 'exec'), _globals, _globals)
    except SystemExit as _se:
        _code = _se.code if isinstance(_se.code, int) else (0 if _se.code is None else 1)
        if _code == 0:
            _ok = 1
        else:
            _ok = 0
            _error = 'SystemExit(%r)' % (_se.code,)
    except BaseException:
        _ok = 0
        _error = _hint(_fmt_exc())
    finally:
        _stage = 'restore'
        _mem_after = _read_mem()
        if _state is not None:
            _restore_state(_state)
        _stage = 'release'
        _release_globals(_globals, _mem_after)
        _stage = 'write_result'
        _capture_stop()
    _stage = 'done'
except BaseException:
    _ok = 0
    _error = _hint(_fmt_exc())
finally:
    try:
        _capture_stop()
    except BaseException:
        pass
    try:
        _warn = _mem_note(_mem_before, _mem_after)
        if _warn:
            _write(_warn_path, _warn)
    except BaseException:
        _warn = ''
    if _ok == 0 and _diag_path:
        try:
            _boot = getattr(sys, '_guncat_boot', None) or {}
            _lines = [
                'version=' + sys.version.replace('\n', ' '),
                'prefix=' + sys.prefix,
                'base_prefix=' + sys.base_prefix,
                'executable=' + sys.executable,
                'cwd=' + os.getcwd(),
                'argv=' + repr(sys.argv),
                'stage=' + _stage,
            ]
            if _mem_before or _mem_after:
                _m = _mem_after or _mem_before or {}
                _lines.append('mem rss=%s peak=%s avail=%s (kB)' % (
                    _m.get('rss', '?'), _m.get('peak', '?'), _m.get('avail', '?')))
            if _boot:
                _lines.append('boot version=' + str(_boot.get('version')))
                _lines.append('boot prefix=' + str(_boot.get('prefix')))
                _lines.append('boot executable=' + str(_boot.get('executable')))
                _boot_path = _boot.get('path') or []
                for _p in _boot_path:
                    _lines.append('path=' + str(_p))
                # 运行期被用户代码改出来的条目单独标出来: 别把用户噪音当环境信息
                for _p in sys.path:
                    if _p not in _boot_path:
                        _lines.append('path(runtime-added)=' + str(_p))
            else:
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
    // 可选: 应用 cache 目录(matplotlib 的 MPLCONFIGDIR 指到这里, 字体缓存只建一次)
    std::string cacheDir;
    int32_t timeoutMs = 60000;
};

struct PyRunOutcome {
    bool ok = false;
    bool timedOut = false;      // 命中超时(硬/软都算)
    bool softTimeout = false;   // 宿主放弃等待, 任务还在后台跑
    int32_t exitCode = 0;
    std::string stdoutText;
    std::string stderrText;
    std::string error;
    // 非致命提醒(目前只有内存): 单独一个字段, 不要混进 error / stderr
    std::string warning;
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
    const std::string warnPath = opt.scratchDir + "/warn.txt";
    ::unlink(warnPath.c_str());
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

    int state = api.gilEnsure();
    // 这里**故意不再有任何信号/中断注入**。
    // 实机回归(7 次实验)证明: 鸿蒙应用进程的 SIGINT 处置不受我们控制 ——
    //   5/7 次 pthread_kill 发过去被直接丢弃(timeout_ms 完全失效),
    //   2/7 次 SIGINT 是默认动作, 信号一到进程当场被杀(闪退)。
    // 所以超时改由两层配合: 启动器里的 AST 截止检查(能在 while True 里抛 TimeoutError),
    // 以及宿主侧的软超时(放弃等待 + 熔断后续调用)。见 DispatchToRunner。
    // 传给启动器的超时(秒): AST 截止检查到点抛 TimeoutError
    const double timeoutSeconds =
        static_cast<double>(opt.timeoutMs > 0 ? opt.timeoutMs : 60000) / 1000.0;
    char deadlineBuf[32];
    snprintf(deadlineBuf, sizeof(deadlineBuf), "%.3f", timeoutSeconds);
    std::string script = RenderScript(kLauncher, deadlineBuf, codePath, outPath, errPath, metaPath,
                                      diagPath, argvPath, opt.stdinPath, warnPath, opt.cacheDir);
    int rc = api.runSimpleString(script.c_str());
    api.gilRelease(state);

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
        std::string mini = RenderScript(kMiniDiag, deadlineBuf, codePath, outPath, errPath, metaPath,
                                        diagPath, argvPath, opt.stdinPath, std::string(), std::string());
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
    out.warning = Trim(ReadFile(warnPath));
    if (!out.warning.empty()) {
        OH_LOG_WARN(LOG_APP, "run_python memory warning: %{public}s", out.warning.c_str());
    }
    // 硬超时由启动器的 AST 截止检查抛出, 消息里带固定标记
    out.timedOut = !out.ok && out.error.find("run_python 超时") != std::string::npos;
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
// 为什么要有它: 解释器只在"初始化它的那个线程"上才行为稳定(线程态、信号、GIL 记录都绑在
// 那个线程上), 而 NAPI 回调可能落在不同线程。做法: 第一次调用时起一个专属线程,
// 由它初始化解释器并长期复用, 之后所有执行都投递给它。
//
// 超时策略(实机回归后定的):
//   * 硬超时: 启动器在 `while True` 这类常量真循环里插入截止检查, 到点抛 TimeoutError;
//   * 软超时: 宿主等 timeout_ms + 1.5s 仍没结束, 就放弃等待并返回"超时(未能中断)",
//     同时把运行时标记为忙, 拒绝后续调用(熔断), 避免排队把 CPU 越烧越满。
//   * 绝不发信号: 实机证明 SIGINT 在本进程里要么被丢弃, 要么直接杀进程(闪退)。
struct PyJob {
    PyRunOptions opt;
    PyRunOutcome out;
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
    bool abandoned = false;
};

std::mutex g_runnerMutex;          // 保护下面的 runner 生命周期
std::thread* g_runner = nullptr;
std::mutex g_queueMutex;           // 保护 g_pending
std::condition_variable g_queueCv;
std::shared_ptr<PyJob> g_pending;
std::atomic<bool> g_runnerStarted{false};
std::atomic<int> g_busy{0};          // 排队 + 执行中的调用数(>0 表示运行时忙)

void RunnerLoop() {
    for (;;) {
        std::shared_ptr<PyJob> job;
        {
            std::unique_lock<std::mutex> lock(g_queueMutex);
            g_queueCv.wait(lock, []() { return g_pending != nullptr; });
            job = g_pending;
            g_pending = nullptr;
        }
        if (!job) {
            return;
        }
        PyRunOutcome out;
        try {
            out = RunPythonInner(job->opt);
        } catch (const std::exception& e) {
            out.ok = false;
            out.error = std::string("native 异常: ") + e.what();
        }
        bool orphan = false;
        {
            std::lock_guard<std::mutex> lock(job->mutex);
            job->out = out;
            job->done = true;
            orphan = job->abandoned;
        }
        job->cv.notify_all();
        g_busy.fetch_sub(1);
        if (orphan) {
            // 僵尸任务终于跑完了: 把"未回收"计数减回去, 本会话的 Python 立刻恢复可用。
            // 这一步是"超时回收"的闭环 —— 没有它, 计数只增不减, 两次超时就永久锁死会话。
            g_abandoned.fetch_sub(1);
            OH_LOG_WARN(LOG_APP, "abandoned python call finished (rc=%{public}d), python re-enabled",
                        out.exitCode);
        }
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
    auto job = std::make_shared<PyJob>();
    job->opt = opt;
    g_busy.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(g_queueMutex);
        g_pending = job;
    }
    g_queueCv.notify_one();

    const int32_t timeoutMs = opt.timeoutMs > 0 ? opt.timeoutMs : 60000;
    // 多给 1.5 秒: 让启动器里的硬截止(TimeoutError)有机会把 meta/traceback 写完
    const auto limit = std::chrono::steady_clock::now() +
                       std::chrono::milliseconds(timeoutMs + 1500);
    std::unique_lock<std::mutex> lock(job->mutex);
    if (!job->cv.wait_until(lock, limit, [&job]() { return job->done; })) {
        job->abandoned = true;
        lock.unlock();
        g_abandoned.fetch_add(1);
        out.ok = false;
        out.timedOut = true;
        out.softTimeout = true;
        out.exitCode = -1;
        out.error = "执行超过 " + std::to_string(timeoutMs) +
                    " ms 且未能中断(任务仍在后台运行)。"
                    "在它结束之前, run_python 会直接拒绝(不会排队); 等它跑完即自动恢复"
                    "(最多允许 2 个这样的任务同时挂着, 不做无限累积)。";
        OH_LOG_WARN(LOG_APP, "python soft timeout after %{public}d ms (job abandoned)", timeoutMs);
        return out;
    }
    return job->out;
}

// 0=可用 1=忙(还有调用在跑/在回收, 结束即恢复)。
// 早先还有一个"连续 10 次软超时 → 本会话永久停用"的封禁状态(2): 它把"用户写了死循环"
// 升级成"整个会话再也不能用 Python, 只能重启应用", 而且计数口径和文档对不上。现在
// 改用活的 g_abandoned 计数(见上), 僵尸任务结束即自动恢复, 不需要重启。
int PyRuntimeState() {
    return g_busy.load() > 0 ? 1 : 0;
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

// pyState(): 0=可用 1=忙(上一个调用还在跑/在回收, 结束即恢复)
napi_value JsPyState(napi_env env, napi_callback_info) {
    napi_value out = nullptr;
    napi_create_int32(env, PyRuntimeState(), &out);
    return out;
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
        opt.cacheDir = PropToString(env, args[0], "cacheDir");
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
            MakeString(env, "已有 2 个超时后仍在后台运行的 Python 调用(未回收), 为避免持续占 CPU 暂不执行。"
                            "它们一结束就自动恢复, 不需要重启应用。"));
        return result;
    }
    if (g_busy.load() > 0) {
        // 上一个调用还在跑(通常是超时被放弃、仍在后台执行的任务)。
        // 绝不排队: 队列只有一个槽位, 排进来会覆盖/饿死, 而且把 CPU 越烧越满。
        napi_set_named_property(env, result, "ok", MakeBool(env, false));
        napi_set_named_property(env, result, "error",
            MakeString(env, "上一个 Python 调用还没结束(超时后仍在后台运行, 未能中断)。"
                            "它结束后会自动恢复, 这里不会排队。"));
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

    // 注意: 这里**不能**按 outcome.timedOut 记账 —— 硬超时(AST 截止)是干净回收的,
    // 只有 softTimeout(宿主放弃等待、线程还卡在调用里)才算"未回收"。
    // 那个计数已经在 DispatchToRunner 里加、在 RunnerLoop 里任务真正结束时减。
    std::string errHead = outcome.error.size() > 160 ? outcome.error.substr(0, 160) : outcome.error;
    OH_LOG_INFO(LOG_APP, "run_python ok=%{public}d timeout=%{public}d rc=%{public}d %{public}lldms err=%{public}s",
        outcome.ok ? 1 : 0, outcome.timedOut ? 1 : 0, outcome.exitCode,
        static_cast<long long>(outcome.durationMs), errHead.c_str());
    napi_set_named_property(env, result, "ok", MakeBool(env, outcome.ok));
    napi_set_named_property(env, result, "timedOut", MakeBool(env, outcome.timedOut));
    napi_set_named_property(env, result, "softTimeout", MakeBool(env, outcome.softTimeout));
    napi_set_named_property(env, result, "exitCode", MakeInt(env, outcome.exitCode));
    napi_set_named_property(env, result, "stdout", MakeString(env, outcome.stdoutText));
    napi_set_named_property(env, result, "stderr", MakeString(env, outcome.stderrText));
    napi_set_named_property(env, result, "error", MakeString(env, outcome.error));
    napi_set_named_property(env, result, "warning", MakeString(env, outcome.warning));
    napi_set_named_property(env, result, "durationMs", MakeInt(env, outcome.durationMs));
    return result;
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"isAvailable", nullptr, JsIsAvailable, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runPython", nullptr, JsRunPython, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"pyState", nullptr, JsPyState, nullptr, nullptr, nullptr, napi_default, nullptr},
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
