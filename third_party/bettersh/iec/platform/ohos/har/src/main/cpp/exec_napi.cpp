// exec_napi.cpp — the programmatic execution API, as ArkTS sees it.
//
// exec_session.cpp is the engine (pipes, deadline, job); this file is only the
// boundary: it reads an options object, calls the engine, and builds the result
// object. Nothing here decides policy, because a decision made twice is a
// decision that can disagree with itself.
//
// The shape is deliberately small and symmetrical:
//
//   const h = execStart({ cmd: 'git', args: ['status'], cwd: '/…' });
//   const r = execPoll(h.id, 64 * 1024, 64 * 1024);   // out/err since last call
//   const w = await execWait(h.id, 30_000);           // { code, signal, … }
//   execRelease(h.id);
//
// execWait is a promise without a worker of its own: it hands the id to the
// NAPI async work queue, which parks a libuv thread on the engine's condition
// variable. The JS thread is never blocked by a command, which is the whole
// reason this API exists next to the terminal.
#include "exec_napi.h"

#include <napi/native_api.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "exec/exec_session.h"

namespace {

using iec::ExecChunk;
using iec::ExecOptions;
using iec::ExecState;

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

napi_value MakeString(napi_env env, const std::string& value) {
    napi_value out = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &out);
    return out;
}

napi_value MakeInt(napi_env env, int64_t value) {
    napi_value out = nullptr;
    napi_create_int64(env, value, &out);
    return out;
}

napi_value MakeBool(napi_env env, bool value) {
    napi_value out = nullptr;
    napi_get_boolean(env, value, &out);
    return out;
}

bool HasProperty(napi_env env, napi_value object, const char* name) {
    bool has = false;
    napi_has_named_property(env, object, name, &has);
    return has;
}

bool ReadString(napi_env env, napi_value object, const char* name,
                std::string* out, bool required, const char* what) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) return !required;

    napi_valuetype type = napi_undefined;
    napi_typeof(env, value, &type);
    if (type == napi_undefined || type == napi_null) {
        if (required) napi_throw_type_error(env, nullptr, what);
        return !required;
    }
    if (type != napi_string) {
        napi_throw_type_error(env, nullptr, what);
        return false;
    }

    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok)
        return false;
    std::vector<char> buffer(length + 1, '\0');
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(),
                                   &length) != napi_ok)
        return false;
    out->assign(buffer.data(), length);
    return true;
}

bool ReadInt(napi_env env, napi_value object, const char* name, int* out,
             const char* what) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) return true;

    napi_valuetype type = napi_undefined;
    napi_typeof(env, value, &type);
    if (type == napi_undefined || type == napi_null) return true;
    if (type != napi_number) {
        napi_throw_type_error(env, nullptr, what);
        return false;
    }

    double number = 0;
    if (napi_get_value_double(env, value, &number) != napi_ok) return false;
    *out = static_cast<int>(number);
    return true;
}

bool ReadBool(napi_env env, napi_value object, const char* name, bool* out,
              const char* what) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) return true;

    napi_valuetype type = napi_undefined;
    napi_typeof(env, value, &type);
    if (type == napi_undefined || type == napi_null) return true;
    if (type != napi_boolean) {
        napi_throw_type_error(env, nullptr, what);
        return false;
    }

    bool flag = false;
    if (napi_get_value_bool(env, value, &flag) != napi_ok) return false;
    *out = flag;
    return true;
}

bool ReadNumber(napi_env env, napi_value object, const char* name, double* out,
                const char* what) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) return true;

    napi_valuetype type = napi_undefined;
    napi_typeof(env, value, &type);
    if (type == napi_undefined || type == napi_null) return true;
    if (type != napi_number) {
        napi_throw_type_error(env, nullptr, what);
        return false;
    }

    if (napi_get_value_double(env, value, out) != napi_ok) return false;
    return true;
}

bool ReadStringArray(napi_env env, napi_value object, const char* name,
                     std::vector<std::string>* out, const char* what) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) return true;

    napi_valuetype type = napi_undefined;
    napi_typeof(env, value, &type);
    if (type == napi_undefined || type == napi_null) return true;
    if (type != napi_object) {
        napi_throw_type_error(env, nullptr, what);
        return false;
    }

    bool is_array = false;
    napi_is_array(env, value, &is_array);
    if (!is_array) {
        napi_throw_type_error(env, nullptr, what);
        return false;
    }

    uint32_t length = 0;
    napi_get_array_length(env, value, &length);
    for (uint32_t i = 0; i < length; i++) {
        napi_value item = nullptr;
        if (napi_get_element(env, value, i, &item) != napi_ok) return false;

        napi_valuetype item_type = napi_undefined;
        napi_typeof(env, item, &item_type);
        if (item_type != napi_string) {
            napi_throw_type_error(env, nullptr, what);
            return false;
        }

        size_t item_length = 0;
        napi_get_value_string_utf8(env, item, nullptr, 0, &item_length);
        std::vector<char> buffer(item_length + 1, '\0');
        napi_get_value_string_utf8(env, item, buffer.data(), buffer.size(),
                                   &item_length);
        out->emplace_back(buffer.data(), item_length);
    }
    return true;
}

// env is an object of string values: { PATH: "/bin", LANG: "C" }. Keys become
// "KEY=VALUE"; a non-string value is a type error rather than a silent toString,
// because an environment entry that says "1" when the caller meant a number is
// the kind of difference that shows up hours later.
bool ReadStringMap(napi_env env, napi_value object, const char* name,
                   std::vector<std::string>* out, const char* what) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) return true;

    napi_valuetype type = napi_undefined;
    napi_typeof(env, value, &type);
    if (type == napi_undefined || type == napi_null) return true;
    if (type != napi_object) {
        napi_throw_type_error(env, nullptr, what);
        return false;
    }

    napi_value keys = nullptr;
    if (napi_get_property_names(env, value, &keys) != napi_ok) return false;
    uint32_t count = 0;
    napi_get_array_length(env, keys, &count);

    for (uint32_t i = 0; i < count; i++) {
        napi_value key = nullptr;
        if (napi_get_element(env, keys, i, &key) != napi_ok) return false;

        size_t key_length = 0;
        napi_get_value_string_utf8(env, key, nullptr, 0, &key_length);
        std::vector<char> key_buffer(key_length + 1, '\0');
        napi_get_value_string_utf8(env, key, key_buffer.data(), key_buffer.size(),
                                   &key_length);

        napi_value item = nullptr;
        if (napi_get_property(env, value, key, &item) != napi_ok) return false;

        napi_valuetype item_type = napi_undefined;
        napi_typeof(env, item, &item_type);
        if (item_type != napi_string) {
            napi_throw_type_error(env, nullptr, what);
            return false;
        }

        size_t item_length = 0;
        napi_get_value_string_utf8(env, item, nullptr, 0, &item_length);
        std::vector<char> item_buffer(item_length + 1, '\0');
        napi_get_value_string_utf8(env, item, item_buffer.data(), item_buffer.size(),
                                   &item_length);

        out->emplace_back(std::string(key_buffer.data(), key_length) + "=" +
                          std::string(item_buffer.data(), item_length));
    }
    return true;
}

std::string Base64Encode(const std::string& input) {
    static const char kTable[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    std::string out;
    out.reserve((input.size() + 2) / 3 * 4);

    size_t i = 0;
    for (; i + 2 < input.size(); i += 3) {
        const uint32_t n = (static_cast<uint8_t>(input[i]) << 16) |
                           (static_cast<uint8_t>(input[i + 1]) << 8) |
                           static_cast<uint8_t>(input[i + 2]);
        out.push_back(kTable[(n >> 18) & 0x3f]);
        out.push_back(kTable[(n >> 12) & 0x3f]);
        out.push_back(kTable[(n >> 6) & 0x3f]);
        out.push_back(kTable[n & 0x3f]);
    }
    if (i < input.size()) {
        const uint32_t a = static_cast<uint8_t>(input[i]);
        const uint32_t b = i + 1 < input.size() ? static_cast<uint8_t>(input[i + 1]) : 0;
        const uint32_t n = (a << 16) | (b << 8);
        out.push_back(kTable[(n >> 18) & 0x3f]);
        out.push_back(kTable[(n >> 12) & 0x3f]);
        out.push_back(i + 1 < input.size() ? kTable[(n >> 6) & 0x3f] : '=');
        out.push_back('=');
    }
    return out;
}

napi_value MakeStateObject(napi_env env, const ExecState& state) {
    napi_value object = nullptr;
    napi_create_object(env, &object);

    napi_set_named_property(env, object, "id", MakeInt(env, state.id));
    napi_set_named_property(env, object, "pid", MakeInt(env, state.pid));
    napi_set_named_property(env, object, "job", MakeString(env, state.job));
    napi_set_named_property(env, object, "running", MakeBool(env, state.running));
    napi_set_named_property(env, object, "exited", MakeBool(env, state.exited));
    napi_set_named_property(env, object, "code", MakeInt(env, state.exit_code));
    napi_set_named_property(env, object, "signal", MakeInt(env, state.signal));
    napi_set_named_property(env, object, "timedOut", MakeBool(env, state.timed_out));
    napi_set_named_property(env, object, "outEof", MakeBool(env, state.out_eof));
    napi_set_named_property(env, object, "errEof", MakeBool(env, state.err_eof));
    napi_set_named_property(env, object, "outDropped",
                            MakeInt(env, static_cast<int64_t>(state.out_dropped)));
    napi_set_named_property(env, object, "errDropped",
                            MakeInt(env, static_cast<int64_t>(state.err_dropped)));
    return object;
}

void ThrowError(napi_env env, const std::string& message) {
    napi_throw_error(env, nullptr, message.c_str());
}

/* ------------------------------------------------------------------ */
/* execStart                                                           */
/* ------------------------------------------------------------------ */

// execStart(options: ExecStartOptions): ExecHandle
napi_value ExecStart(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "execStart(options) expects an object");
        return nullptr;
    }

    napi_valuetype type = napi_undefined;
    napi_typeof(env, argv[0], &type);
    if (type != napi_object) {
        napi_throw_type_error(env, nullptr, "execStart(options) expects an object");
        return nullptr;
    }

    ExecOptions options;
    if (!ReadString(env, argv[0], "cmd", &options.cmd, true,
                    "execStart: cmd must be a non-empty string") ||
        options.cmd.empty()) {
        if (options.cmd.empty()) napi_throw_type_error(env, nullptr, "execStart: cmd is empty");
        return nullptr;
    }

    if (!ReadStringArray(env, argv[0], "args", &options.args,
                         "execStart: args must be an array of strings") ||
        !ReadString(env, argv[0], "cwd", &options.cwd, false, "") ||
        !ReadStringMap(env, argv[0], "env", &options.env,
                       "execStart: env must map names to strings") ||
        !ReadBool(env, argv[0], "envReplace", &options.env_replace, "") ||
        !ReadString(env, argv[0], "stdin", &options.stdin_data, false, "") ||
        !ReadBool(env, argv[0], "keepStdinOpen", &options.keep_stdin_open, "") ||
        !ReadInt(env, argv[0], "timeoutMs", &options.timeout_ms, "") ||
        !ReadString(env, argv[0], "job", &options.job, false, "")) {
        return nullptr;
    }

    double cap = 0;
    if (!ReadNumber(env, argv[0], "maxOutputBytes", &cap, "")) return nullptr;
    if (cap > 0) options.max_output_bytes = static_cast<size_t>(cap);

    ExecState state;
    std::string error;
    const int id = iec::Start(options, &state, &error);
    if (id < 0) {
        ThrowError(env, error.empty() ? "execStart failed" : error);
        return nullptr;
    }

    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "id", MakeInt(env, id));
    napi_set_named_property(env, result, "pid", MakeInt(env, state.pid));
    napi_set_named_property(env, result, "job", MakeString(env, state.job));
    return result;
}

/* ------------------------------------------------------------------ */
/* execPoll                                                            */
/* ------------------------------------------------------------------ */

// execPoll(id, maxOut?, maxErr?, encoding?): ExecPollResult
//
// The bytes returned here are consumed: a second call with the same arguments
// returns only what arrived in between. That is what makes it usable for a live
// view and for a final result without either side having to remember an offset.
napi_value ExecPoll(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    int32_t id = -1;
    if (argc < 1 || napi_get_value_int32(env, argv[0], &id) != napi_ok) {
        napi_throw_type_error(env, nullptr, "execPoll(id) expects a number");
        return nullptr;
    }

    double max_out = 256 * 1024;
    double max_err = 256 * 1024;
    if (argc > 1 && argv[1] != nullptr) napi_get_value_double(env, argv[1], &max_out);
    if (argc > 2 && argv[2] != nullptr) napi_get_value_double(env, argv[2], &max_err);

    std::string encoding = "utf8";
    if (argc > 3 && argv[3] != nullptr) {
        napi_value value = argv[3];
        napi_valuetype type = napi_undefined;
        napi_typeof(env, value, &type);
        if (type == napi_string) {
            size_t length = 0;
            napi_get_value_string_utf8(env, value, nullptr, 0, &length);
            std::vector<char> buffer(length + 1, '\0');
            napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(),
                                       &length);
            encoding.assign(buffer.data(), length);
        }
    }
    const bool binary = encoding == "base64";

    ExecChunk chunk;
    ExecState state;
    if (!iec::Poll(id, static_cast<size_t>(max_out), static_cast<size_t>(max_err),
                   &chunk, &state)) {
        ThrowError(env, "execPoll: unknown session id");
        return nullptr;
    }

    napi_value result = MakeStateObject(env, state);
    napi_set_named_property(env, result, "out",
                            MakeString(env, binary ? Base64Encode(chunk.out) : chunk.out));
    napi_set_named_property(env, result, "err",
                            MakeString(env, binary ? Base64Encode(chunk.err) : chunk.err));
    napi_set_named_property(env, result, "encoding",
                            MakeString(env, binary ? "base64" : "utf8"));
    return result;
}

/* ------------------------------------------------------------------ */
/* execWait (promise)                                                  */
/* ------------------------------------------------------------------ */

struct WaitWork {
    int      id = -1;
    int      timeout_ms = 0;
    bool     ok = false;
    ExecState state;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

void WaitComplete(napi_env env, napi_status status, void* data) {
    auto* work = static_cast<WaitWork*>(data);

    if (status != napi_ok || !work->ok) {
        napi_value message = MakeString(env, "execWait: unknown session id");
        napi_value error = nullptr;
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, work->deferred, error);
    } else {
        napi_value result = nullptr;
        napi_create_object(env, &result);
        napi_set_named_property(env, result, "code", MakeInt(env, work->state.exit_code));
        napi_set_named_property(env, result, "signal", MakeInt(env, work->state.signal));
        napi_set_named_property(env, result, "timedOut",
                                MakeBool(env, work->state.timed_out));
        napi_set_named_property(env, result, "running",
                                MakeBool(env, work->state.running));
        napi_resolve_deferred(env, work->deferred, result);
    }

    napi_delete_async_work(env, work->work);
    delete work;
}

void WaitExecute(napi_env env, void* data) {
    (void)env;
    auto* work = static_cast<WaitWork*>(data);
    work->ok = iec::Wait(work->id, work->timeout_ms, &work->state);
}

// execWait(id, timeoutMs?): Promise<{ code, signal, timedOut, running }>
//
// timeoutMs is how long *this call* is willing to wait; 0 or absent means until
// the program ends. It is not a deadline for the program -- that is
// ExecStartOptions.timeoutMs, enforced by the engine even if nobody is waiting.
napi_value ExecWait(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    int32_t id = -1;
    if (argc < 1 || napi_get_value_int32(env, argv[0], &id) != napi_ok) {
        napi_throw_type_error(env, nullptr, "execWait(id) expects a number");
        return nullptr;
    }

    int32_t timeout_ms = 0;
    if (argc > 1 && argv[1] != nullptr) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[1], &type);
        if (type == napi_number) napi_get_value_int32(env, argv[1], &timeout_ms);
    }

    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) return nullptr;

    auto* work = new WaitWork;
    work->id = id;
    work->timeout_ms = timeout_ms;
    work->deferred = deferred;

    napi_value name = MakeString(env, "iecExecWait");
    if (napi_create_async_work(env, nullptr, name, WaitExecute, WaitComplete, work,
                               &work->work) != napi_ok) {
        delete work;
        napi_value message = MakeString(env, "execWait: cannot schedule the wait");
        napi_value error = nullptr;
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, deferred, error);
        return promise;
    }
    napi_queue_async_work(env, work->work);
    return promise;
}

/* ------------------------------------------------------------------ */
/* Controls                                                            */
/* ------------------------------------------------------------------ */

// execWrite(id, data): number of bytes accepted (0 = pipe full, -1 = no stdin)
napi_value ExecWrite(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    int32_t id = -1;
    if (argc < 2 || napi_get_value_int32(env, argv[0], &id) != napi_ok) {
        napi_throw_type_error(env, nullptr, "execWrite(id, data) expects a number and a string");
        return nullptr;
    }

    std::string data;
    size_t length = 0;
    if (napi_get_value_string_utf8(env, argv[1], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "execWrite: data must be a string");
        return nullptr;
    }
    std::vector<char> buffer(length + 1, '\0');
    napi_get_value_string_utf8(env, argv[1], buffer.data(), buffer.size(), &length);
    data.assign(buffer.data(), length);

    const long written = iec::Write(id, data.data(), data.size());
    return MakeInt(env, static_cast<int64_t>(written));
}

napi_value ExecCloseStdin(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    int32_t id = -1;
    if (argc < 1 || napi_get_value_int32(env, argv[0], &id) != napi_ok) {
        napi_throw_type_error(env, nullptr, "execCloseStdin(id) expects a number");
        return nullptr;
    }
    return MakeBool(env, iec::CloseStdin(id));
}

napi_value ExecTerminate(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    int32_t id = -1;
    if (argc < 1 || napi_get_value_int32(env, argv[0], &id) != napi_ok) {
        napi_throw_type_error(env, nullptr, "execTerminate(id, graceMs?) expects a number");
        return nullptr;
    }

    int32_t grace_ms = 800;
    if (argc > 1 && argv[1] != nullptr) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[1], &type);
        if (type == napi_number) napi_get_value_int32(env, argv[1], &grace_ms);
    }
    return MakeBool(env, iec::Terminate(id, grace_ms));
}

napi_value ExecSignal(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    int32_t id = -1;
    int32_t signo = 0;
    if (argc < 2 || napi_get_value_int32(env, argv[0], &id) != napi_ok ||
        napi_get_value_int32(env, argv[1], &signo) != napi_ok) {
        napi_throw_type_error(env, nullptr, "execSignal(id, signo) expects two numbers");
        return nullptr;
    }
    return MakeBool(env, iec::Signal(id, signo));
}

napi_value ExecRelease(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    int32_t id = -1;
    if (argc < 1 || napi_get_value_int32(env, argv[0], &id) != napi_ok) {
        napi_throw_type_error(env, nullptr, "execRelease(id) expects a number");
        return nullptr;
    }
    return MakeBool(env, iec::Release(id));
}

napi_value ExecList(napi_env env, napi_callback_info /*info*/) {
    return MakeString(env, iec::List());
}

napi_value ExecCount(napi_env env, napi_callback_info /*info*/) {
    return MakeInt(env, static_cast<int64_t>(iec::Count()));
}

}  // namespace

void RegisterExecNapi(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"execStart",      nullptr, ExecStart,      nullptr, nullptr, nullptr, napi_default, nullptr},
        {"execPoll",       nullptr, ExecPoll,       nullptr, nullptr, nullptr, napi_default, nullptr},
        {"execWait",       nullptr, ExecWait,       nullptr, nullptr, nullptr, napi_default, nullptr},
        {"execWrite",      nullptr, ExecWrite,      nullptr, nullptr, nullptr, napi_default, nullptr},
        {"execCloseStdin", nullptr, ExecCloseStdin, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"execTerminate",  nullptr, ExecTerminate,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"execSignal",     nullptr, ExecSignal,     nullptr, nullptr, nullptr, napi_default, nullptr},
        {"execRelease",    nullptr, ExecRelease,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"execList",       nullptr, ExecList,       nullptr, nullptr, nullptr, napi_default, nullptr},
        {"execCount",      nullptr, ExecCount,      nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
}
