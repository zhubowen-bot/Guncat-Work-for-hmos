// napi_init.cpp — C++ entry of the OHOS HAR.
//
// Exports hello() plus thin wrappers around the capability probe in
// exec/caps.cpp, so ArkTS can read or pin the same word the reference server
// uses.
#include <napi/native_api.h>
#include <sys/stat.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <fcntl.h>
#include <unistd.h>

#include "rawfile/raw_file.h"
#include "rawfile/raw_file_manager.h"

/* OH_LOG_INFO uses these two when it is expanded; without them the default
 * domain is 0 and the tag is NULL, which is not a useful hilog record. */
#ifndef LOG_DOMAIN
#define LOG_DOMAIN 0x0000
#endif
#ifndef LOG_TAG
#define LOG_TAG "IEC_LOGGER"
#endif
#include <hilog/log.h>

#include "common/archive_extract.h"
#include "common/ca_bundle.h"
#include "common/constant.h"
#include "exec/caps.h"
#include "exec/exec_server.h"
#include "exec_napi.h"
#include "logger/logger.h"
#include "tty/tty_server.h"

namespace {

// The ArkTS shape shared by setCaps() and probeCaps(). packed is the five-digit
// hexadecimal value; the other fields are its digits.
napi_value MakeCaps(napi_env env, uint64_t packed) {
    const HostCapabilities caps = UnpackCaps(packed);

    napi_value obj = nullptr;
    napi_create_object(env, &obj);

    napi_value value = nullptr;
    napi_create_double(env, static_cast<double>(packed), &value);
    napi_set_named_property(env, obj, "packed", value);

    napi_create_int32(env, caps.chmod, &value);
    napi_set_named_property(env, obj, "chmod", value);
    napi_create_int32(env, caps.fork, &value);
    napi_set_named_property(env, obj, "fork", value);
    napi_create_int32(env, caps.exec, &value);
    napi_set_named_property(env, obj, "exec", value);
    napi_create_int32(env, caps.jit, &value);
    napi_set_named_property(env, obj, "jit", value);
    napi_create_int32(env, caps.path, &value);
    napi_set_named_property(env, obj, "path", value);

    return obj;
}

napi_value Hello(napi_env env, napi_callback_info /*info*/) {
    napi_value ret = nullptr;
    const char* msg = "Hello from iec/platform/ohos/har (native)!";
    napi_create_string_utf8(env, msg, NAPI_AUTO_LENGTH, &ret);
    return ret;
}

// setCaps(cap: number): Caps
// Pins the capability word; the returned object is what it unpacked to.
napi_value SetCaps(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "setCaps(cap) expects one number");
        return nullptr;
    }

    double value = 0;
    if (napi_get_value_double(env, argv[0], &value) != napi_ok) {
        napi_throw_type_error(env, nullptr, "setCaps(cap): cap must be a number");
        return nullptr;
    }

    const uint64_t packed = static_cast<uint64_t>(value);
    setCaps(packed);
    return MakeCaps(env, packed);
}

// probeCaps(): Caps
// Runs the probes and returns their packed answer.
napi_value ProbeCaps(napi_env env, napi_callback_info /*info*/) {
    return MakeCaps(env, ProbeCapabilities());
}

// Reads one optional string argument. Missing, undefined and null all mean "use
// the default". Returns false after throwing when the argument is not a string.
bool ReadOptionalString(napi_env env, napi_value value, std::string& out) {
    napi_valuetype type = napi_undefined;

    if (napi_typeof(env, value, &type) != napi_ok) return false;
    if (type == napi_undefined || type == napi_null) return true;
    if (type != napi_string) {
        napi_throw_type_error(
            env, nullptr, "startIecServer: socket paths must be strings");
        return false;
    }

    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok)
        return false;
    std::vector<char> buf(len + 1, '\0');
    if (napi_get_value_string_utf8(env, value, buf.data(), buf.size(), &len) != napi_ok)
        return false;
    out.assign(buf.data(), len);
    return true;
}

// The two services are started and stopped as a pair, so one lock covers both
// pointers. The host may create and destroy the ability more than once, which is
// why start is idempotent and stop is safe to call when nothing is running.
std::mutex g_server_lock;
std::unique_ptr<TtyServer> g_tty_server;
std::unique_ptr<ExecServer> g_exec_server;

// Resource manager registered by ArkTS. It is the same application-level
// manager BetterSH uses for libentry.so; HAR rawfiles are merged into it.
NativeResourceManager* g_res_mgr = nullptr;

// Caller holds g_server_lock. Each pointer is null unless every step that
// produced it succeeded, so this is also the rollback for a partly started pair.
void StopServersLocked() {
    if (g_tty_server) {
        g_tty_server->stopAndJoin();
        g_tty_server.reset();
    }
    if (g_exec_server) {
        g_exec_server->stopAndJoin();
        g_exec_server.reset();
    }
}

// The sandbox paths in constant.h point at directories the application owns but
// that are not necessarily created yet. bind() would fail with ENOENT; create
// the parent, and let bind() report anything else.
void EnsureParentDir(const std::string& path) {
    const size_t slash = path.rfind('/');
    if (slash == std::string::npos || slash == 0) return;
    mkdir(path.substr(0, slash).c_str(), 0755);
}

// ── bootstrap helpers ──────────────────────────────────────────────────────

// Reads a required string argument. Returns false after throwing.
bool ReadStringArg(napi_env env, napi_value value, const char* what,
                   std::string& out) {
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
        napi_throw_type_error(env, nullptr, what);
        return false;
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok)
        return false;
    std::vector<char> buf(len + 1, '\0');
    if (napi_get_value_string_utf8(env, value, buf.data(), buf.size(), &len) !=
        napi_ok)
        return false;
    out.assign(buf.data(), len);
    return true;
}

napi_value IntResult(napi_env env, int value) {
    napi_value ret = nullptr;
    napi_create_int32(env, value, &ret);
    return ret;
}

napi_value BoolResult(napi_env env, bool value) {
    napi_value ret = nullptr;
    napi_get_boolean(env, value, &ret);
    return ret;
}

// mkdir -p. Existing levels are not an error.
bool EnsureDirs(const std::string& path) {
    if (path.empty()) return true;

    std::string current;
    size_t start = 0;
    if (path[0] == '/') {
        current = "/";
        start = 1;
    }

    while (start <= path.size()) {
        const size_t slash = path.find('/', start);
        const std::string part =
            path.substr(start, slash == std::string::npos ? std::string::npos
                                                           : slash - start);
        if (!part.empty()) {
            if (!current.empty() && current.back() != '/') current += '/';
            current += part;
            if (mkdir(current.c_str(), 0755) != 0 && errno != EEXIST) {
                Logger::GetInstance()->LogE("[iec] mkdir %s: %s",
                                            current.c_str(), strerror(errno));
                return false;
            }
        }
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return true;
}

bool WriteAll(int fd, const void* data, size_t size) {
    const char* p = static_cast<const char*>(data);
    size_t left = size;
    while (left > 0) {
        const ssize_t n = write(fd, p, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        p += n;
        left -= static_cast<size_t>(n);
    }
    return true;
}

std::string ParentOf(const std::string& path) {
    const size_t slash = path.rfind('/');
    if (slash == std::string::npos) return std::string();
    if (slash == 0) return "/";
    return path.substr(0, slash);
}

bool WriteFile(const std::string& path, const void* data, size_t size,
               mode_t mode) {
    if (!EnsureDirs(ParentOf(path))) return false;

    const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (fd < 0) return false;
    bool ok = WriteAll(fd, data, size);
    if (close(fd) != 0) ok = false;
    return ok;
}

bool ReadRawFile(NativeResourceManager* mgr, const std::string& name,
                 std::vector<unsigned char>* out) {
    if (!mgr || !out) return false;

    RawFile* rf = OH_ResourceManager_OpenRawFile(mgr, name.c_str());
    if (!rf) return false;

    const long size = OH_ResourceManager_GetRawFileSize(rf);
    if (size <= 0 || size > (256L * 1024 * 1024)) {
        OH_ResourceManager_CloseRawFile(rf);
        return false;
    }

    out->resize(static_cast<size_t>(size));
    size_t off = 0;
    while (off < out->size()) {
        const int n = OH_ResourceManager_ReadRawFile(
            rf, out->data() + off, out->size() - off);
        if (n <= 0) break;
        off += static_cast<size_t>(n);
    }
    OH_ResourceManager_CloseRawFile(rf);
    return off == out->size();
}


napi_value StartServer(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string tty_path, exec_path;
    if (argc > 0 && !ReadOptionalString(env, argv[0], tty_path)) return nullptr;
    if (argc > 1 && !ReadOptionalString(env, argv[1], exec_path)) return nullptr;

    bool started = false;
    {
        std::lock_guard<std::mutex> lock(g_server_lock);

        if (g_tty_server && g_exec_server) {
            started = true;
        } else {
            // A half pair cannot survive a successful start; clear it before
            // replacing it, or the running half would leak.
            if (g_tty_server || g_exec_server) StopServersLocked();

            const std::string tty = tty_path.empty() ? TTY_SOCK_PATH : tty_path;
            const std::string exe = exec_path.empty() ? EXEC_SOCK_PATH : exec_path;
            EnsureParentDir(tty);
            EnsureParentDir(exe);

            try {
                auto tty_srv = std::make_unique<TtyServer>(tty);
                auto exec_srv = std::make_unique<ExecServer>(exe);

                // Both sockets are up before either thread starts: a client must
                // never see one service up and the other still missing. The
                // locals below are destroyed on the way out of the catch, and
                // their destructors join any thread that did start.
                tty_srv->start();
                exec_srv->start();
                tty_srv->startThread();
                exec_srv->startThread();

                g_tty_server = std::move(tty_srv);
                g_exec_server = std::move(exec_srv);
                started = true;
                Logger::GetInstance()->LogI(
                    "[iec] server started: tty=%s exec=%s", tty.c_str(), exe.c_str());
            } catch (const std::exception& e) {
                Logger::GetInstance()->LogE("[iec] start failed: %s", e.what());
                StopServersLocked();
            }
        }
    }

    napi_value ret = nullptr;
    napi_get_boolean(env, started, &ret);
    return ret;
}

// stopIecServer(): boolean
// Stops both services and joins their threads. Returns true when a running
// server was stopped and false when none was running.
napi_value StopServer(napi_env env, napi_callback_info /*info*/) {
    bool was_running = false;
    {
        std::lock_guard<std::mutex> lock(g_server_lock);
        was_running = static_cast<bool>(g_tty_server) || static_cast<bool>(g_exec_server);
        StopServersLocked();
        if (was_running) Logger::GetInstance()->LogI("[iec] server stopped");
    }

    napi_value ret = nullptr;
    napi_get_boolean(env, was_running, &ret);
    return ret;
}

// installCaBundle(dir?: string): boolean
// Writes the CA bundle embedded in the library to <dir>/cacert.pem. Missing
// arguments default to the directory git reads under the fake root.
napi_value InstallCaBundle(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string dir;
    if (argc > 0 && !ReadOptionalString(env, argv[0], dir)) return nullptr;
    if (dir.empty()) dir = std::string(FAKE_SYSROOT) + "/usr/share/git-core";

    const bool ok = IecInstallCaBundle(dir.c_str());
    if (!ok) {
        Logger::GetInstance()->LogW("[iec] CA bundle: cannot write to %s",
                                    dir.c_str());
    }

    napi_value ret = nullptr;
    napi_get_boolean(env, ok, &ret);
    return ret;
}

napi_value InitIecResourceManager(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_type_error(env, nullptr,
                              "initIecResourceManager(resourceManager) expects one argument");
        return nullptr;
    }

    if (g_res_mgr) {
        OH_ResourceManager_ReleaseNativeResourceManager(g_res_mgr);
        g_res_mgr = nullptr;
    }
    g_res_mgr = OH_ResourceManager_InitNativeResourceManager(env, argv[0]);
    if (!g_res_mgr) {
        Logger::GetInstance()->LogE("[iec] cannot initialize the resource manager");
    }
    return BoolResult(env, g_res_mgr != nullptr);
}

constexpr const char* kRawfileVersionMarker = FAKE_SYSROOT "/.rawfile-version";

napi_value CheckRawfileVersionMarker(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string expected;
    if (argc < 1 ||
        !ReadStringArg(env, argv[0],
                       "checkRawfileVersionMarker(version) expects a string",
                       expected))
        return nullptr;

    const int fd = open(kRawfileVersionMarker, O_RDONLY);
    if (fd < 0) return BoolResult(env, false);

    char buf[128];
    const ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return BoolResult(env, false);

    std::string got(buf, static_cast<size_t>(n));
    while (!got.empty() &&
           (got.back() == '\n' || got.back() == '\r' ||
            got.back() == ' ' || got.back() == '\t'))
        got.pop_back();

    return BoolResult(env, got == expected);
}

napi_value WriteRawfileVersionMarker(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string version;
    if (argc < 1 ||
        !ReadStringArg(env, argv[0],
                       "writeRawfileVersionMarker(version) expects a string",
                       version))
        return nullptr;

    const bool ok = WriteFile(kRawfileVersionMarker, version.data(),
                              version.size(), 0644);
    return IntResult(env, ok ? 0 : 1);
}

napi_value EnsureDir(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string path;
    if (argc < 1 ||
        !ReadStringArg(env, argv[0], "ensureDir(path) expects a string", path))
        return nullptr;

    return IntResult(env, EnsureDirs(path) ? 0 : 1);
}

napi_value WriteSoLauncher(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value argv[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string target, so, entry;
    int32_t arity = 0;
    if (argc < 4 ||
        !ReadStringArg(env, argv[0],
                       "writeSoLauncher(target, so, entry, arity, primary)", target) ||
        !ReadStringArg(env, argv[1],
                       "writeSoLauncher(target, so, entry, arity, primary)", so) ||
        !ReadStringArg(env, argv[2],
                       "writeSoLauncher(target, so, entry, arity, primary)", entry))
        return nullptr;
    if (napi_get_value_int32(env, argv[3], &arity) != napi_ok) {
        napi_throw_type_error(env, nullptr,
                              "writeSoLauncher: arity must be 2 or 3");
        return nullptr;
    }

    // The fifth argument names the process relationship: 0 = let the server decide,
    // 1 = fork, 2 = native child process, 3 = in this process. Optional, and 0 is
    // what an absent line means.
    int32_t primary = 0;
    if (argc >= 5) {
        napi_value converted = nullptr;
        if (napi_coerce_to_number(env, argv[4], &converted) == napi_ok) {
            napi_get_value_int32(env, converted, &primary);
        }
        if (primary < 0 || primary > 3) {
            napi_throw_type_error(env, nullptr,
                                  "writeSoLauncher: primary must be 0, 1, 2 or 3");
            return nullptr;
        }
    }

    if (target.empty() || so.empty() || so[0] != '/' || entry.empty() ||
        entry.size() > 255 || (arity != 2 && arity != 3) ||
        so.find('\n') != std::string::npos ||
        entry.find('\n') != std::string::npos) {
        Logger::GetInstance()->LogE("[iec] invalid launcher: %s", target.c_str());
        return IntResult(env, 1);
    }

    std::string body = "#IECSOv2\n" + so + "\n" + entry + "\n" +
                       std::to_string(arity) + "\n";
    if (primary != 0) body += std::to_string(primary) + "\n";
    if (!WriteFile(target, body.data(), body.size(), 0755) ||
        chmod(target.c_str(), 0755) != 0) {
        Logger::GetInstance()->LogE("[iec] cannot write launcher: %s",
                                    target.c_str());
        return IntResult(env, 1);
    }
    return IntResult(env, 0);
}

napi_value UnpackResource(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string name, dest;
    if (argc < 2 ||
        !ReadStringArg(env, argv[0],
                       "unpackResource(name, dest) expects two strings", name) ||
        !ReadStringArg(env, argv[1],
                       "unpackResource(name, dest) expects two strings", dest))
        return nullptr;

    if (!g_res_mgr) {
        Logger::GetInstance()->LogE("[iec] unpack %s: resource manager is not set",
                                    name.c_str());
        return IntResult(env, 1);
    }

    std::vector<unsigned char> data;
    if (!ReadRawFile(g_res_mgr, name, &data)) {
        Logger::GetInstance()->LogE("[iec] unpack %s: rawfile read failed",
                                    name.c_str());
        return IntResult(env, 1);
    }
    if (!EnsureDirs(dest)) return IntResult(env, 1);

    // 解包核心在 common/archive_extract.cpp：这里只负责把 rawfile 读成内存
    // 并做字符串参数转换，宿主测试可以对同一份实现跑 npm.tar.gz。
    if (IecExtractTar(data.data(), data.size(), dest.c_str()) != 0) {
        Logger::GetInstance()->LogE("[iec] unpack %s -> %s failed",
                                    name.c_str(), dest.c_str());
        return IntResult(env, 1);
    }

    Logger::GetInstance()->LogI("[iec] unpacked %s -> %s (%zu bytes)",
                                name.c_str(), dest.c_str(), data.size());
    return IntResult(env, 0);
}

napi_value WriteTxtFile(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string target, data;
    if (!ReadStringArg(env, argv[0],
                       "writeTxtFile(target, data)", target) ||
        !ReadStringArg(env, argv[1],
                       "writeTxtFile(target, data)", data))
        return nullptr;

    if (!WriteFile(target, data.data(), data.size(), 0755) ||
        chmod(target.c_str(), 0755) != 0) {
        Logger::GetInstance()->LogE("[iec] cannot write file: %s",
                                    target.c_str());
        return IntResult(env, 1);
    }
    return IntResult(env, 0);
}

napi_value Init(napi_env env, napi_value exports) {
    // The logger has no OHOS dependency of its own. Register hilog as a custom
    // sink here, where the NAPI/hilog libraries are already linked.
    Logger::GetInstance()->SetCustomWriter([](int level, const std::string& line) {
        if (level >= 2) {
            OH_LOG_ERROR(LOG_APP, "%{public}s", line.c_str());
        } else if (level == 1) {
            OH_LOG_WARN(LOG_APP, "%{public}s", line.c_str());
        } else {
            OH_LOG_INFO(LOG_APP, "%{public}s", line.c_str());
        }
    });

    // The bundle is written once here so it is in place before the first shell
    // can start git. installCaBundle() stays exported for callers that want to
    // refresh it after upgrading the embedded copy.
    if (!IecInstallCaBundle(FAKE_SYSROOT "/usr/share/git-core")) {
        Logger::GetInstance()->LogW("[iec] CA bundle: cannot write at init");
    }

    napi_property_descriptor desc[] = {
        {"hello",                       nullptr, Hello,                     nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setCaps",                     nullptr, SetCaps,                   nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeCaps",                   nullptr, ProbeCaps,                 nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startIecServer",              nullptr, StartServer,               nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopIecServer",               nullptr, StopServer,                nullptr, nullptr, nullptr, napi_default, nullptr},
        {"installCaBundle",             nullptr, InstallCaBundle,           nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initIecResourceManager",      nullptr, InitIecResourceManager,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"checkRawfileVersionMarker",   nullptr, CheckRawfileVersionMarker, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"writeRawfileVersionMarker",   nullptr, WriteRawfileVersionMarker, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"ensureDir",                   nullptr, EnsureDir,                 nullptr, nullptr, nullptr, napi_default, nullptr},
        {"writeSoLauncher",             nullptr, WriteSoLauncher,           nullptr, nullptr, nullptr, napi_default, nullptr},
        {"unpackResource",              nullptr, UnpackResource,            nullptr, nullptr, nullptr, napi_default, nullptr},
        {"writeTxtFile",                nullptr, WriteTxtFile,              nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    // The programmatic execution API. Kept in its own translation unit because it
    // is a different concern from the bootstrap helpers above and has its own
    // engine (exec/exec_session.cpp) behind it.
    RegisterExecNapi(env, exports);
    return exports;
}

}  // namespace

static napi_module helloModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "iec_server",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterHelloModule(void) {
    napi_module_register(&helloModule);
}
