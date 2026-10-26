// Guncat Work: Linux VM(QEMU TCI)原生桥
//
// 设计要点(与 HiSH 一致的做法, 见 https://github.com/harmoninux/HiSH, MIT):
//   * QEMU 以动态库形式打包(libs/arm64-v8a/libqemu-system-aarch64-tci.so),
//     本模块 dlopen 后调用 qemu_system_entry(argc, argv) —— 不 fork 子进程。
//   * 构建时开启 --enable-tcg-interpreter(TCG 字节码解释器), 不生成机器码,
//     因此不需要可执行内存/JIT 受限权限, 手机与上架包都能跑。
//   * VM 的 I/O 不靠串口协议: 命令与结果全部走 virtio-9p 共享目录(见 LinuxShellService),
//     串口只用于内核/引导日志排障, 本模块把最近若干 KB 存在环形缓冲里供 ArkTS 读取。
//
// ArkTS 侧接口见 types/libguncatvm/index.d.ts。
#include <dlfcn.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "hilog/log.h"
#include "napi/native_api.h"

namespace {

constexpr const char* kLogTag = "GuncatVm";
constexpr int kLogDomain = 0x3300;

// 串口环形缓冲: 只保留最近 kSerialRingBytes 字节, 供 status/serialTail 排障
constexpr std::size_t kSerialRingBytes = 64 * 1024;

std::mutex g_mutex;

using QemuEntry = int (*)(int, const char**);

QemuEntry g_entry = nullptr;
std::string g_libName;         // 实际加载到的库文件名(空=不可用)
std::string g_loadError;       // 不可用原因

std::atomic<bool> g_vmRunning{false};
std::atomic<bool> g_vmStarting{false};
int g_entryResult = 0;

std::thread g_vmThread;
std::thread g_serialThread;

int g_serialFd = -1;
std::string g_ring;
std::string g_serialPath;

napi_threadsafe_function g_dataTsFn = nullptr;
napi_threadsafe_function g_exitTsFn = nullptr;

// ===== 工具函数 =====

std::string ValueToUtf8(napi_env env, napi_value value) {
    std::string out;
    if (value == nullptr) {
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

std::string PropToString(napi_env env, napi_value obj, const char* name) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, name, &value) != napi_ok) {
        return std::string();
    }
    return ValueToUtf8(env, value);
}

// 串口数据可读化: 去 ANSI 转义、控制字符换成 '.', 便于直接把尾部日志塞进错误信息
std::string SanitizeForLog(const std::string& raw) {
    std::string out;
    out.reserve(raw.size());
    bool inEsc = false;
    for (std::size_t i = 0; i < raw.size(); ++i) {
        unsigned char c = static_cast<unsigned char>(raw[i]);
        if (inEsc) {
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) {
                inEsc = false;
            }
            continue;
        }
        if (c == 0x1b) {
            inEsc = true;
            continue;
        }
        if (c == '\n' || c == '\r' || c == '\t') {
            out.push_back(static_cast<char>(c));
        } else if (c >= 0x20 && c < 0x7f) {
            out.push_back(static_cast<char>(c));
        } else if (c >= 0x80) {
            // 非 ASCII 原样保留(UTF-8 序列交给 ArkTS 解码), 这里只过滤控制字节
            out.push_back(static_cast<char>(c));
        } else {
            out.push_back('.');
        }
    }
    return out;
}

// ===== 串口线程: 连接 QEMU 的 unix socket, 读日志 =====

// 把串口字节投递给 JS 回调(没有注册回调时只进环形缓冲, 供 serialTail 排障)
struct JsChunk {
    char* buf = nullptr;
    std::size_t size = 0;
};

void CallJsWithChunk(napi_env env, napi_value jsCallback, void* context, void* data) {
    if (env == nullptr || jsCallback == nullptr) {
        return;
    }
    std::vector<char> local;
    if (data != nullptr) {
        JsChunk* chunk = static_cast<JsChunk*>(data);
        if (chunk->buf != nullptr && chunk->size > 0) {
            local.assign(chunk->buf, chunk->buf + chunk->size);
        }
        delete[] chunk->buf;
        delete chunk;
    }
    if (local.empty()) {
        return;
    }
    napi_value arrayBuffer = nullptr;
    void* raw = nullptr;
    if (napi_create_arraybuffer(env, local.size(), &raw, &arrayBuffer) != napi_ok || raw == nullptr) {
        return;
    }
    std::memcpy(raw, local.data(), local.size());

    napi_value global = nullptr;
    napi_value result = nullptr;
    napi_get_global(env, &global);
    napi_value args[1] = {arrayBuffer};
    napi_call_function(env, global, jsCallback, 1, args, &result);
}

void CallJsOnExit(napi_env env, napi_value jsCallback, void* context, void* data) {
    if (env == nullptr || jsCallback == nullptr) {
        return;
    }
    napi_value global = nullptr;
    napi_get_global(env, &global);
    napi_call_function(env, global, jsCallback, 0, nullptr, nullptr);
}

void DeliverSerial(const char* data, std::size_t size) {
    napi_threadsafe_function tsfn = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_ring.append(data, size);
        if (g_ring.size() > kSerialRingBytes) {
            g_ring.erase(0, g_ring.size() - kSerialRingBytes);
        }
        tsfn = g_dataTsFn;
    }
    if (tsfn == nullptr) {
        return;
    }
    JsChunk* chunk = new JsChunk();
    chunk->size = size;
    chunk->buf = new char[size];
    std::memcpy(chunk->buf, data, size);
    if (napi_call_threadsafe_function(tsfn, chunk, napi_tsfn_nonblocking) != napi_ok) {
        delete[] chunk->buf;
        delete chunk;
    }
}

void SerialThreadFunc(std::string socketPath) {
    // 等 QEMU 把 unix socket 建出来
    int waited = 0;
    while (waited < 600) {  // 30s
        struct stat st {};
        if (::stat(socketPath.c_str(), &st) == 0) {
            break;
        }
        if (!g_vmRunning.load()) {
            return;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        ++waited;
    }

    int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        OH_LOG_ERROR(LOG_APP, "serial socket() failed: %{public}d", errno);
        return;
    }
    sockaddr_un addr {};
    addr.sun_family = AF_UNIX;
    if (socketPath.size() >= sizeof(addr.sun_path)) {
        OH_LOG_ERROR(LOG_APP, "serial socket path too long");
        ::close(fd);
        return;
    }
    std::memcpy(addr.sun_path, socketPath.c_str(), socketPath.size());
    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        OH_LOG_ERROR(LOG_APP, "serial connect failed: %{public}d", errno);
        ::close(fd);
        return;
    }
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_serialFd = fd;
    }
    OH_LOG_INFO(LOG_APP, "serial connected: %{public}s", socketPath.c_str());

    char buf[4096];
    while (true) {
        pollfd pfd {};
        pfd.fd = fd;
        pfd.events = POLLIN;
        int r = ::poll(&pfd, 1, 200);
        if (r < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (r == 0) {
            if (!g_vmRunning.load()) {
                break;
            }
            continue;
        }
        ssize_t n = ::read(fd, buf, sizeof(buf));
        if (n > 0) {
            DeliverSerial(buf, static_cast<std::size_t>(n));
        } else if (n == 0) {
            break;  // 对端关闭
        } else if (errno != EINTR && errno != EAGAIN) {
            break;
        }
    }
    ::close(fd);
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_serialFd = -1;
    }
    OH_LOG_INFO(LOG_APP, "serial disconnected");
}

// ===== QEMU 主线程 =====

void VmThreadFunc(std::vector<std::string> args, QemuEntry entry) {
    std::vector<const char*> argv;
    argv.reserve(args.size() + 1);
    for (auto& a : args) {
        argv.push_back(a.c_str());
    }
    argv.push_back(nullptr);
    OH_LOG_INFO(LOG_APP, "qemu entry start, argc=%{public}zu", args.size());
    int rc = entry(static_cast<int>(args.size()), argv.data());
    OH_LOG_INFO(LOG_APP, "qemu entry exit: %{public}d", rc);
    g_entryResult = rc;
    g_vmRunning.store(false);

    napi_threadsafe_function tsfn = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        tsfn = g_exitTsFn;
    }
    if (tsfn != nullptr) {
        napi_call_threadsafe_function(tsfn, nullptr, napi_tsfn_nonblocking);
    }
}

// ===== 库加载 =====

// 优先 TCI(解释执行, 无 JIT 权限要求), 再退 JIT 版(仅开发机/模拟器有需要时)
QemuEntry LoadQemuLibrary() {
    if (g_entry != nullptr) {
        return g_entry;
    }
    if (!g_loadError.empty()) {
        return nullptr;
    }
    const char* candidates[] = {"libqemu-system-aarch64-tci.so", "libqemu-system-aarch64.so"};
    for (const char* name : candidates) {
        void* handle = ::dlopen(name, RTLD_LAZY);
        if (handle == nullptr) {
            continue;
        }
        auto entry = reinterpret_cast<QemuEntry>(::dlsym(handle, "qemu_system_entry"));
        if (entry == nullptr) {
            OH_LOG_ERROR(LOG_APP, "%{public}s has no qemu_system_entry", name);
            ::dlclose(handle);
            continue;
        }
        g_entry = entry;
        g_libName = name;
        OH_LOG_INFO(LOG_APP, "qemu library loaded: %{public}s", name);
        return g_entry;
    }
    g_loadError = std::string("无法加载 QEMU 运行库(需要 arm64-v8a 的 libqemu-system-aarch64-tci.so): ") +
        (::dlerror() != nullptr ? ::dlerror() : "dlopen failed");
    OH_LOG_ERROR(LOG_APP, "%{public}s", g_loadError.c_str());
    return nullptr;
}

// ===== N-API 导出 =====

napi_value MakeBool(napi_env env, bool value) {
    napi_value out = nullptr;
    napi_get_boolean(env, value, &out);
    return out;
}

napi_value MakeString(napi_env env, const std::string& value) {
    napi_value out = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &out);
    return out;
}

// isAvailable(): 空串表示可用, 否则是不可用原因
napi_value JsIsAvailable(napi_env env, napi_callback_info) {
    LoadQemuLibrary();
    std::string reason;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        reason = g_entry == nullptr ? (g_loadError.empty() ? "QEMU 运行库不可用" : g_loadError) : std::string();
    }
    return MakeString(env, reason);
}

// startVM({ argsLines, serialSocket }): { ok, error, lib, running }
napi_value JsStartVm(napi_env env, napi_callback_info info) {
    std::size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string argsLines;
    std::string serialSocket;
    if (argc >= 1) {
        argsLines = PropToString(env, args[0], "argsLines");
        serialSocket = PropToString(env, args[0], "serialSocket");
    }

    napi_value result = nullptr;
    napi_create_object(env, &result);

    if (argsLines.empty()) {
        napi_set_named_property(env, result, "ok", MakeBool(env, false));
        napi_set_named_property(env, result, "error", MakeString(env, "缺少参数 argsLines"));
        napi_set_named_property(env, result, "lib", MakeString(env, ""));
        return result;
    }
    if (g_vmRunning.load() || g_vmStarting.load()) {
        std::string lib;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            lib = g_libName;
        }
        napi_set_named_property(env, result, "ok", MakeBool(env, false));
        napi_set_named_property(env, result, "error", MakeString(env, "VM 已在运行"));
        napi_set_named_property(env, result, "lib", MakeString(env, lib));
        return result;
    }

    QemuEntry entry = LoadQemuLibrary();
    if (entry == nullptr) {
        std::string reason;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            reason = g_loadError.empty() ? "QEMU 运行库不可用" : g_loadError;
        }
        napi_set_named_property(env, result, "ok", MakeBool(env, false));
        napi_set_named_property(env, result, "error", MakeString(env, reason));
        napi_set_named_property(env, result, "lib", MakeString(env, ""));
        return result;
    }

    // 按行切参数(与 HiSH 的 startVM 约定一致: 一行一个 argv)
    std::vector<std::string> argvList;
    std::size_t pos = 0;
    while (pos <= argsLines.size()) {
        std::size_t next = argsLines.find('\n', pos);
        std::string line = next == std::string::npos ? argsLines.substr(pos) : argsLines.substr(pos, next - pos);
        if (!line.empty()) {
            if (!line.empty() && line.back() == '\r') {
                line.pop_back();
            }
            argvList.push_back(line);
        }
        if (next == std::string::npos) {
            break;
        }
        pos = next + 1;
    }
    if (argvList.empty()) {
        napi_set_named_property(env, result, "ok", MakeBool(env, false));
        napi_set_named_property(env, result, "error", MakeString(env, "argsLines 为空"));
        napi_set_named_property(env, result, "lib", MakeString(env, ""));
        return result;
    }

    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_ring.clear();
        g_serialPath = serialSocket;
    }
    g_vmStarting.store(true);
    g_vmRunning.store(true);

    try {
        g_vmThread = std::thread(VmThreadFunc, argvList, entry);
        g_vmThread.detach();
    } catch (const std::exception& e) {
        g_vmRunning.store(false);
        g_vmStarting.store(false);
        napi_set_named_property(env, result, "ok", MakeBool(env, false));
        napi_set_named_property(env, result, "error", MakeString(env, std::string("启动线程失败: ") + e.what()));
        napi_set_named_property(env, result, "lib", MakeString(env, g_libName));
        return result;
    }

    if (!serialSocket.empty()) {
        try {
            g_serialThread = std::thread(SerialThreadFunc, serialSocket);
            g_serialThread.detach();
        } catch (const std::exception& e) {
            OH_LOG_ERROR(LOG_APP, "serial thread failed: %{public}s", e.what());
        }
    }

    g_vmStarting.store(false);
    napi_set_named_property(env, result, "ok", MakeBool(env, true));
    napi_set_named_property(env, result, "error", MakeString(env, ""));
    napi_set_named_property(env, result, "lib", MakeString(env, g_libName));
    return result;
}

// status(): { running, starting, lib, loadError, exitCode }
napi_value JsStatus(napi_env env, napi_callback_info) {
    napi_value result = nullptr;
    napi_create_object(env, &result);
    std::string lib;
    std::string err;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        lib = g_libName;
        err = g_loadError;
    }
    napi_value exitCode = nullptr;
    napi_create_int32(env, g_entryResult, &exitCode);
    napi_set_named_property(env, result, "running", MakeBool(env, g_vmRunning.load()));
    napi_set_named_property(env, result, "starting", MakeBool(env, g_vmStarting.load()));
    napi_set_named_property(env, result, "lib", MakeString(env, lib));
    napi_set_named_property(env, result, "loadError", MakeString(env, err));
    napi_set_named_property(env, result, "exitCode", exitCode);
    return result;
}

// serialTail(maxChars): 最近若干字符的串口日志(已做可读化处理)
napi_value JsSerialTail(napi_env env, napi_callback_info info) {
    std::size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t maxChars = 4000;
    if (argc >= 1 && args[0] != nullptr) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, args[0], &type);
        if (type == napi_number) {
            napi_get_value_int32(env, args[0], &maxChars);
        }
    }
    if (maxChars <= 0) {
        maxChars = 4000;
    }
    if (maxChars > static_cast<int32_t>(kSerialRingBytes)) {
        maxChars = static_cast<int32_t>(kSerialRingBytes);
    }
    std::string raw;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        raw = g_ring;
    }
    std::string text = SanitizeForLog(raw);
    if (text.size() > static_cast<std::size_t>(maxChars)) {
        text = text.substr(text.size() - static_cast<std::size_t>(maxChars));
    }
    return MakeString(env, text);
}

// onData(cb): 串口增量数据(ArrayBuffer, 原始字节)
napi_value JsOnData(napi_env env, napi_callback_info info) {
    std::size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    napi_value name = nullptr;
    napi_create_string_utf8(env, "guncatVmSerial", NAPI_AUTO_LENGTH, &name);
    napi_threadsafe_function tsfn = nullptr;
    napi_status status = napi_create_threadsafe_function(env, args[0], nullptr, name, 0, 1,
        nullptr, nullptr, nullptr, CallJsWithChunk, &tsfn);
    if (status == napi_ok) {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_dataTsFn = tsfn;
    }
    return nullptr;
}

// onExit(cb): QEMU 线程退出通知
napi_value JsOnExit(napi_env env, napi_callback_info info) {
    std::size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    napi_value name = nullptr;
    napi_create_string_utf8(env, "guncatVmExit", NAPI_AUTO_LENGTH, &name);
    napi_threadsafe_function tsfn = nullptr;
    napi_status status = napi_create_threadsafe_function(env, args[0], nullptr, name, 0, 1,
        nullptr, nullptr, nullptr, CallJsOnExit, &tsfn);
    if (status == napi_ok) {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_exitTsFn = tsfn;
    }
    return nullptr;
}

// sendInput(ArrayBuffer): 往串口写字节(终端/中断用; shell 工具本身不依赖它)
napi_value JsSendInput(napi_env env, napi_callback_info info) {
    std::size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return MakeBool(env, false);
    }
    void* data = nullptr;
    std::size_t length = 0;
    if (napi_get_arraybuffer_info(env, args[0], &data, &length) != napi_ok || data == nullptr) {
        return MakeBool(env, false);
    }
    int fd = -1;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        fd = g_serialFd;
    }
    if (fd < 0) {
        return MakeBool(env, false);
    }
    std::size_t written = 0;
    while (written < length) {
        ssize_t n = ::write(fd, static_cast<char*>(data) + written, length - written);
        if (n <= 0) {
            return MakeBool(env, false);
        }
        written += static_cast<std::size_t>(n);
    }
    return MakeBool(env, true);
}

napi_value JsRequestShutdown(napi_env env, napi_callback_info) {
    // QEMU 与 App 同进程, 进程退出即结束; 这里只把状态翻成 false 让上层停止等待。
    g_vmRunning.store(false);
    return MakeBool(env, true);
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"isAvailable", nullptr, JsIsAvailable, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startVM", nullptr, JsStartVm, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"status", nullptr, JsStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"serialTail", nullptr, JsSerialTail, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onData", nullptr, JsOnData, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onExit", nullptr, JsOnExit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendInput", nullptr, JsSendInput, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"requestShutdown", nullptr, JsRequestShutdown, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module guncatVmModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "guncatvm",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterGuncatVmModule() {
    napi_module_register(&guncatVmModule);
}
