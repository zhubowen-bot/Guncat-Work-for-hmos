// Guncat Work run_js 工具: Node-API 桥
//
// ArkTS 侧接口(见 types/libguncatjs/index.d.ts):
//   runJs(code, options?) -> Promise<JsRunResult>
//   engineStatus() -> string(空串表示 JSVM 可用)
//
// 线程模型: JS 执行放在 Node-API 的异步任务(worker 线程)上, 绝不占用 UI 线程。
// 超时保护由 ArkTS 侧负责 —— JSVM-API 没有"中断执行"接口, 死循环无法从外部终止,
// 详见 JsCodeService 的说明。
#include <map>
#include <string>
#include <vector>

#include "hilog/log.h"
#include "jsvm_sandbox.h"
#include "napi/native_api.h"

namespace {

constexpr const char* kLogTag = "GuncatJsvm";
constexpr std::size_t kMaxCodeBytes = 512 * 1024;

struct AsyncRun {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    guncat::JsRunOptions options;
    guncat::JsRunOutcome outcome;
};

// ===== napi 值与 std::string 互转 =====

bool ValueToUtf8(napi_env env, napi_value value, std::string& out) {
    out.clear();
    if (value == nullptr) {
        return false;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
        return false;
    }
    std::size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    if (len == 0) {
        return true;
    }
    std::vector<char> buf(len + 1, '\0');
    std::size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, buf.data(), len + 1, &copied) != napi_ok) {
        return false;
    }
    out.assign(buf.data(), copied);
    return true;
}

bool PropToUtf8(napi_env env, napi_value obj, const char* name, std::string& out) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, name, &value) != napi_ok) {
        return false;
    }
    return ValueToUtf8(env, value, out);
}

bool PropToDouble(napi_env env, napi_value obj, const char* name, double& out) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, name, &value) != napi_ok) {
        return false;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_number) {
        return false;
    }
    return napi_get_value_double(env, value, &out) == napi_ok;
}

bool PropToBool(napi_env env, napi_value obj, const char* name, bool& out) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, name, &value) != napi_ok) {
        return false;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_boolean) {
        return false;
    }
    return napi_get_value_bool(env, value, &out) == napi_ok;
}

bool PropToObject(napi_env env, napi_value obj, const char* name, napi_value& out) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, name, &value) != napi_ok) {
        return false;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_object) {
        return false;
    }
    out = value;
    return true;
}

void SetPropString(napi_env env, napi_value obj, const char* name, const std::string& value) {
    napi_value text = nullptr;
    if (napi_create_string_utf8(env, value.c_str(), value.size(), &text) == napi_ok) {
        napi_set_named_property(env, obj, name, text);
    }
}

void SetPropBool(napi_env env, napi_value obj, const char* name, bool value) {
    napi_value flag = nullptr;
    if (napi_get_boolean(env, value, &flag) == napi_ok) {
        napi_set_named_property(env, obj, name, flag);
    }
}

void SetPropNumber(napi_env env, napi_value obj, const char* name, double value) {
    napi_value num = nullptr;
    if (napi_create_double(env, value, &num) == napi_ok) {
        napi_set_named_property(env, obj, name, num);
    }
}

// inputs: { "工作区相对路径": "文件文本" } -> std::map
void ReadInputs(napi_env env, napi_value inputsValue, std::map<std::string, std::string>& out) {
    napi_value names = nullptr;
    if (napi_get_property_names(env, inputsValue, &names) != napi_ok || names == nullptr) {
        return;
    }
    uint32_t count = 0;
    if (napi_get_array_length(env, names, &count) != napi_ok) {
        return;
    }
    for (uint32_t i = 0; i < count; i++) {
        napi_value key = nullptr;
        if (napi_get_element(env, names, i, &key) != napi_ok || key == nullptr) {
            continue;
        }
        std::string name;
        if (!ValueToUtf8(env, key, name) || name.empty()) {
            continue;
        }
        napi_value value = nullptr;
        if (napi_get_property(env, inputsValue, key, &value) != napi_ok) {
            continue;
        }
        std::string text;
        if (!ValueToUtf8(env, value, text)) {
            continue;
        }
        // 键名归一化(去 './'/重复斜杠), 与 js 侧 read() 的查询规则保持一致
        std::string normalized = guncat::NormalizeRelPath(name);
        if (normalized.empty()) {
            continue;
        }
        out[normalized] = text;
    }
}

napi_value BuildResult(napi_env env, const guncat::JsRunOutcome& outcome) {
    napi_value obj = nullptr;
    if (napi_create_object(env, &obj) != napi_ok) {
        return nullptr;
    }
    SetPropBool(env, obj, "ok", outcome.ok);
    SetPropBool(env, obj, "hasResult", outcome.hasResult);
    SetPropString(env, obj, "stdout", outcome.stdoutText);
    SetPropString(env, obj, "result", outcome.resultText);
    SetPropString(env, obj, "error", outcome.error);
    SetPropString(env, obj, "notice", outcome.notice);
    SetPropNumber(env, obj, "durationMs", static_cast<double>(outcome.durationMs));
    SetPropNumber(env, obj, "inputCount", static_cast<double>(outcome.inputCount));
    napi_value inputKeys = nullptr;
    if (napi_create_array_with_length(env, outcome.inputKeys.size(), &inputKeys) == napi_ok) {
        for (std::size_t i = 0; i < outcome.inputKeys.size(); i++) {
            napi_value key = nullptr;
            if (napi_create_string_utf8(env, outcome.inputKeys[i].c_str(),
                                       outcome.inputKeys[i].size(), &key) == napi_ok) {
                napi_set_element(env, inputKeys, static_cast<uint32_t>(i), key);
            }
        }
        napi_set_named_property(env, obj, "inputKeys", inputKeys);
    }
    napi_value outputs = nullptr;
    if (napi_create_object(env, &outputs) == napi_ok) {
        for (std::map<std::string, std::string>::const_iterator it = outcome.outputs.begin();
             it != outcome.outputs.end(); ++it) {
            SetPropString(env, outputs, it->first.c_str(), it->second);
        }
        napi_set_named_property(env, obj, "outputs", outputs);
    }
    return obj;
}

// 出错时也 resolve(而不是 reject), 让 ArkTS 侧统一按 JsRunResult 处理
void ResolveError(napi_env env, napi_deferred deferred, const std::string& message) {
    guncat::JsRunOutcome outcome;
    outcome.error = message;
    napi_value result = BuildResult(env, outcome);
    if (result != nullptr) {
        napi_resolve_deferred(env, deferred, result);
    }
}

// ===== 异步任务 =====

void ExecuteRun(napi_env env, void* data) {
    // worker 线程: 严禁调用任何 napi_* 接口
    AsyncRun* run = static_cast<AsyncRun*>(data);
    run->outcome = guncat::Run(run->options);
}

void CompleteRun(napi_env env, napi_status status, void* data) {
    AsyncRun* run = static_cast<AsyncRun*>(data);
    if (status != napi_ok) {
        run->outcome = guncat::JsRunOutcome();
        run->outcome.error = "JS 执行任务被取消或失败(status=" +
            std::to_string(static_cast<int>(status)) + ")";
    }
    napi_value result = BuildResult(env, run->outcome);
    if (result != nullptr) {
        napi_resolve_deferred(env, run->deferred, result);
    }
    if (run->work != nullptr) {
        napi_delete_async_work(env, run->work);
    }
    delete run;
}

double ClampDouble(double value, double low, double high) {
    if (value < low) {
        return low;
    }
    if (value > high) {
        return high;
    }
    return value;
}

// runJs(code: string, options?: RunJsOptions): Promise<JsRunResult>
napi_value RunJs(napi_env env, napi_callback_info info) {
    std::size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    std::string code;
    if (argc < 1 || !ValueToUtf8(env, argv[0], code) || code.empty()) {
        ResolveError(env, deferred, "缺少参数 code(要执行的 JS 源码)");
        return promise;
    }
    if (code.size() > kMaxCodeBytes) {
        ResolveError(env, deferred, "代码过长(" + std::to_string(code.size()) +
            " 字节), 上限 " + std::to_string(kMaxCodeBytes) + " 字节");
        return promise;
    }

    // JSVM 初始化放在 JS 线程上先做掉(官方样例同样在调用侧初始化); 失败则直接返回原因,
    // 不至于让 work 线程创建 VM 时才失败。
    std::string engineError = guncat::EnsureInit();
    if (!engineError.empty()) {
        ResolveError(env, deferred, "JS 引擎不可用: " + engineError);
        return promise;
    }

    AsyncRun* run = new AsyncRun();
    run->deferred = deferred;
    run->options.code = code;
    run->options.resourceName = "run_js.js";

    napi_value options = nullptr;
    napi_valuetype optionsType = napi_undefined;
    // 注意: argv[1] 本身就是 options 对象(不是 { options: ... } 包装)
    if (argc >= 2 && argv[1] != nullptr &&
        napi_typeof(env, argv[1], &optionsType) == napi_ok && optionsType == napi_object) {
        options = argv[1];
        napi_value inputs = nullptr;
        if (PropToObject(env, options, "inputs", inputs)) {
            ReadInputs(env, inputs, run->options.inputs);
        }
        std::string resourceName;
        if (PropToUtf8(env, options, "resourceName", resourceName) && !resourceName.empty()) {
            run->options.resourceName = resourceName;
        }
        double number = 0;
        if (PropToDouble(env, options, "heapMb", number)) {
            run->options.heapLimitBytes = static_cast<std::size_t>(
                ClampDouble(number, 16, 1024)) * 1024ull * 1024ull;
        }
        if (PropToDouble(env, options, "stdoutLimitKb", number)) {
            run->options.stdoutLimitBytes = static_cast<std::size_t>(
                ClampDouble(number, 1, 1024)) * 1024ull;
        }
        if (PropToDouble(env, options, "outputFileLimitKb", number)) {
            run->options.outputFileLimitBytes = static_cast<std::size_t>(
                ClampDouble(number, 1, 4096)) * 1024ull;
        }
        if (PropToDouble(env, options, "outputTotalLimitKb", number)) {
            run->options.outputTotalLimitBytes = static_cast<std::size_t>(
                ClampDouble(number, 1, 8192)) * 1024ull;
        }
        if (PropToDouble(env, options, "maxOutputFiles", number)) {
            run->options.maxOutputFiles = static_cast<std::size_t>(
                ClampDouble(number, 1, 64));
        }
    }

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "guncatjs.runJs", NAPI_AUTO_LENGTH, &resourceName);
    napi_status status = napi_create_async_work(env, nullptr, resourceName, ExecuteRun,
                                               CompleteRun, run, &run->work);
    if (status != napi_ok) {
        delete run;
        ResolveError(env, deferred, "创建异步任务失败(status=" +
            std::to_string(static_cast<int>(status)) + ")");
        return promise;
    }
    status = napi_queue_async_work(env, run->work);
    if (status != napi_ok) {
        napi_delete_async_work(env, run->work);
        delete run;
        ResolveError(env, deferred, "提交异步任务失败(status=" +
            std::to_string(static_cast<int>(status)) + ")");
        return promise;
    }
    return promise;
}

// engineStatus(): string —— 空串表示 JSVM 可用, 否则为不可用原因
napi_value EngineStatus(napi_env env, napi_callback_info info) {
    std::string error = guncat::EnsureInit();
    napi_value result = nullptr;
    if (napi_create_string_utf8(env, error.c_str(), error.size(), &result) != napi_ok) {
        napi_get_undefined(env, &result);
    }
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"runJs", nullptr, RunJs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"engineStatus", nullptr, EngineStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    OH_LOG_INFO(LOG_APP, "[%{public}s] native module loaded", kLogTag);
    return exports;
}

}  // namespace

static napi_module guncatJsModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "guncatjs",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterGuncatJsModule(void) {
    napi_module_register(&guncatJsModule);
}
