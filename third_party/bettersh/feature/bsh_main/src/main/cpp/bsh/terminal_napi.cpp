// bsh/terminal_napi.cpp — 把 ArkTS 的 bshTerm* 调用接到新的终端实现上。
//
// 新实现是 bsh/terminal.cpp 编出的 libterminal.so：它用 forkpty 起一个 pty，
// 再 exec /bin/sh。这个 so 在链接期套了 IEC 的 tty/exec warp shim，所以
// forkpty/exec 都不在本进程真正发生，而是交给 App 内的 IEC 服务
// （EntryAbility 里 startIecServer() 拉起）。
//
// 兼容层保留旧的导出名与参数形状：
//   bshTermStart(sid, cb) -> 0 / -1
//   bshTermInput(sid, text) -> 写入字节数
//   bshTermResize(sid, cols, rows)
//   bshTermStop(sid)
// sid 只在 ArkTS 侧有意义；这里用它索引会话。旧的 bsh::BshTerm*NAPI 仍然
// 编在 libentry.so 里，但不再注册，因此不会被执行。
#include <dlfcn.h>
#include <napi/native_api.h>

#include <atomic>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "common/bsh_paths.h"
#include "terminal.h"
#include "terminal_napi.h"

namespace {

// ---------------------------------------------------------------------------
// libterminal.so 的入口
// ---------------------------------------------------------------------------

struct NativeApi {
    void* library = nullptr;

    terminal_session_t* (*terminal_start)(int, int, terminal_output_cb,
                                          terminal_exit_cb, void*) = nullptr;
    ssize_t (*terminal_input)(terminal_session_t*, const char*, size_t) = nullptr;
    int (*terminal_resize)(terminal_session_t*, int, int) = nullptr;
    int (*terminal_pid)(terminal_session_t*) = nullptr;
    void (*terminal_stop)(terminal_session_t*) = nullptr;
};

NativeApi g_api;
std::mutex g_api_mutex;

bool load_symbol(void** target, void* library, const char* name) {
    *target = dlsym(library, name);
    return *target != nullptr;
}

// 首次调用时加载 libterminal.so。优先按名字让动态链接器在 App 的 lib 目录里找，
// 找不到再用 bundle 内的绝对路径（与 procmgr 的 kBundledLibDir 一致）。
bool ensure_library(std::string* error) {
    std::lock_guard<std::mutex> lock(g_api_mutex);
    if (g_api.library) return true;

    const char* candidates[] = {
        "libterminal.so",
        BSH_BUNDLE_LIBS "libterminal.so",
    };

    for (const char* path : candidates) {
        dlerror();
        void* library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!library) {
            if (error) *error = dlerror();
            continue;
        }

        bool ok = load_symbol(reinterpret_cast<void**>(&g_api.terminal_start),
                              library, "terminal_start") &&
                  load_symbol(reinterpret_cast<void**>(&g_api.terminal_input),
                              library, "terminal_input") &&
                  load_symbol(reinterpret_cast<void**>(&g_api.terminal_resize),
                              library, "terminal_resize") &&
                  load_symbol(reinterpret_cast<void**>(&g_api.terminal_pid),
                              library, "terminal_pid") &&
                  load_symbol(reinterpret_cast<void**>(&g_api.terminal_stop),
                              library, "terminal_stop");
        if (!ok) {
            if (error) *error = "libterminal.so is missing an entry point";
            dlclose(library);
            continue;
        }

        g_api.library = library;
        return true;
    }

    if (error && error->empty()) *error = "cannot load libterminal.so";
    return false;
}

// ---------------------------------------------------------------------------
// 线程安全函数：native 读线程 → ArkTS
// ---------------------------------------------------------------------------

struct OutputEvent {
    std::vector<char> data;
};

struct ExitEvent {
    int code = 0;
};

struct Session {
    napi_env env = nullptr;
    terminal_session_t* native = nullptr;
    napi_threadsafe_function output_tsfn = nullptr;
    std::atomic<bool> closed{false};
};

void output_callback(terminal_session_t*, const char* data, size_t size,
                     void* user_data) {
    auto* session = static_cast<Session*>(user_data);
    if (!session || session->closed.load() || !session->output_tsfn) return;

    auto* event = new OutputEvent;
    event->data.assign(data, data + size);

    if (napi_call_threadsafe_function(session->output_tsfn, event,
                                      napi_tsfn_nonblocking) != napi_ok) {
        delete event;
    }
}

// 旧 ArkTS 回调收到的是 string（xterm.js 的 termWrite 只吃字符串）。
void call_output_js(napi_env env, napi_value js_callback, void* context, void* data) {
    auto* event = static_cast<OutputEvent*>(data);
    if (!env || !js_callback) {
        delete event;
        return;
    }

    napi_value value = nullptr;
    if (event->data.empty()) {
        napi_create_string_utf8(env, "", 0, &value);
    } else {
        napi_create_string_utf8(env, event->data.data(), event->data.size(), &value);
    }

    napi_value global = nullptr;
    napi_get_global(env, &global);
    napi_value argv[] = { value };
    napi_call_function(env, global, js_callback, 1, argv, nullptr);

    delete event;
    (void)context;
}

// ---------------------------------------------------------------------------
// 兼容层
// ---------------------------------------------------------------------------

std::mutex g_sessions_mutex;
std::unordered_map<int, Session*> g_sessions;

Session* take_session(int sid) {
    std::lock_guard<std::mutex> lock(g_sessions_mutex);
    auto it = g_sessions.find(sid);
    if (it == g_sessions.end()) return nullptr;
    Session* session = it->second;
    g_sessions.erase(it);
    return session;
}

void destroy_session(Session* session) {
    if (!session) return;

    session->closed.store(true);
    if (session->native) {
        g_api.terminal_stop(session->native);
        session->native = nullptr;
    }
    if (session->output_tsfn) {
        napi_release_threadsafe_function(session->output_tsfn, napi_tsfn_abort);
        session->output_tsfn = nullptr;
    }
    delete session;
}

napi_value make_error(napi_env env, const char* message) {
    napi_throw_error(env, nullptr, message);
    return nullptr;
}

bool read_string(napi_env env, napi_value value, std::string& out) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok)
        return false;

    std::vector<char> buffer(length + 1, '\0');
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(),
                                   &length) != napi_ok)
        return false;

    out.assign(buffer.data(), length);
    return true;
}

bool read_int(napi_env env, napi_value value, int32_t& out) {
    return napi_get_value_int32(env, value, &out) == napi_ok;
}

}  // namespace

namespace bsh {

#if !defined(INTERCEPT_VERSION) || INTERCEPT_VERSION == 2

// bshTermStart(sid, cb)
napi_value BshTermStartNAPI(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 2) return make_error(env, "bshTermStart(sid, callback)");

    int32_t sid = 0;
    if (!read_int(env, argv[0], sid))
        return make_error(env, "bshTermStart: sid must be a number");

    napi_valuetype type = napi_undefined;
    napi_typeof(env, argv[1], &type);
    if (type != napi_function)
        return make_error(env, "bshTermStart: callback must be a function");

    std::string error;
    if (!ensure_library(&error))
        return make_error(env, error.c_str());

    // 同一个 sid 再次启动时，先收掉旧会话。
    destroy_session(take_session(sid));

    auto* session = new Session;
    session->env = env;

    napi_value resource_name = nullptr;
    napi_create_string_utf8(env, "IecTerminalOutput", NAPI_AUTO_LENGTH,
                            &resource_name);
    if (napi_create_threadsafe_function(env, argv[1], nullptr, resource_name,
                                        0, 1, nullptr, nullptr, session,
                                        call_output_js,
                                        &session->output_tsfn) != napi_ok) {
        delete session;
        return make_error(env, "bshTermStart: cannot create output bridge");
    }

    // 旧接口不带尺寸；WebTerminal 起来后会立刻用 bshTermResize 报真实大小。
    session->native = g_api.terminal_start(80, 24, output_callback, nullptr, session);
    if (!session->native) {
        napi_release_threadsafe_function(session->output_tsfn, napi_tsfn_abort);
        delete session;
        return make_error(env, "bshTermStart: terminal_start failed");
    }

    {
        std::lock_guard<std::mutex> lock(g_sessions_mutex);
        g_sessions[sid] = session;
    }

    napi_value ret = nullptr;
    napi_create_int32(env, 0, &ret);
    return ret;
}

// bshTermInput(sid, text)
napi_value BshTermInputNAPI(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 2) return make_error(env, "bshTermInput(sid, text)");

    int32_t sid = 0;
    if (!read_int(env, argv[0], sid))
        return make_error(env, "bshTermInput: sid must be a number");

    napi_valuetype type = napi_undefined;
    napi_typeof(env, argv[1], &type);
    if (type != napi_string)
        return make_error(env, "bshTermInput: text must be a string");

    std::string text;
    if (!read_string(env, argv[1], text))
        return make_error(env, "bshTermInput: cannot read text");

    Session* session = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_sessions_mutex);
        auto it = g_sessions.find(sid);
        if (it != g_sessions.end()) session = it->second;
    }
    if (!session || !session->native)
        return make_error(env, "bshTermInput: session is not running");

    const ssize_t written =
        g_api.terminal_input(session->native, text.data(), text.size());

    napi_value ret = nullptr;
    napi_create_int64(env, written, &ret);
    return ret;
}

// bshTermResize(sid, cols, rows)
napi_value BshTermResizeNAPI(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 3) return make_error(env, "bshTermResize(sid, cols, rows)");

    int32_t sid = 0;
    int32_t cols = 0;
    int32_t rows = 0;
    if (!read_int(env, argv[0], sid) || !read_int(env, argv[1], cols) ||
        !read_int(env, argv[2], rows))
        return make_error(env, "bshTermResize: numeric arguments required");

    Session* session = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_sessions_mutex);
        auto it = g_sessions.find(sid);
        if (it != g_sessions.end()) session = it->second;
    }
    if (session && session->native)
        g_api.terminal_resize(session->native, cols, rows);

    return nullptr;
}

// bshTermStop(sid)
napi_value BshTermStopNAPI(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    int32_t sid = 0;
    if (argc > 0 && !read_int(env, argv[0], sid))
        return make_error(env, "bshTermStop: sid must be a number");

    destroy_session(take_session(sid));
    return nullptr;
}

#endif

}  // namespace bsh
