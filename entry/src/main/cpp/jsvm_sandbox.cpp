// Guncat Work run_js 工具: JSVM-API 沙箱执行器实现
//
// 官方文档: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/jsvm-guidelines
// 关键约束(照做, 否则会崩):
//  1. OH_JSVM_Init 全进程只能成功一次, 重复调用返回 JSVM_GENERIC_FAILURE(表示"已初始化", 属正常)。
//  2. Scope 必须逆序关闭: HandleScope -> EnvScope -> VMScope -> DestroyEnv -> DestroyVM。
//  3. JSVM_Value 必须在 OpenHandleScope 之后创建, 且不能在其 HandleScope 关闭后使用。
//  4. JSVM_CallbackStruct 的生命周期必须长于 JSVM_Env(本项目用文件级静态对象)。
//  5. 任何 JSVM-API 调用失败都要清理挂起异常(GetAndClearLastException), 否则污染后续调用。
//  6. JSVM 是并发不安全的: 一个 Env 只在一个线程上用。本实现每次执行都在独立线程上创建独立 VM/Env。
#include "jsvm_sandbox.h"

#include <chrono>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "ark_runtime/jsvm.h"
#include "hilog/log.h"

namespace guncat {
namespace {

constexpr const char* kLogTag = "GuncatJsvm";
// 单行 console 输出的上限(防止一行 log 把结果撑爆)
constexpr std::size_t kMaxConsoleLineBytes = 8 * 1024;

// 单次执行的上下文(线程内可见; 沙箱回调只会在执行线程上被调用)
struct RunContext {
    const JsRunOptions* opts = nullptr;
    JsRunOutcome* outcome = nullptr;
    bool stdoutTruncated = false;
};

thread_local RunContext* g_context = nullptr;

long long ElapsedMs(const std::chrono::steady_clock::time_point& started) {
    return static_cast<long long>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count());
}

std::string StatusText(JSVM_Status status) {
    return "status=" + std::to_string(static_cast<int>(status));
}

std::string SizeText(std::size_t bytes) {
    if (bytes < 1024) {
        return std::to_string(bytes) + " B";
    }
    if (bytes < 1024 * 1024) {
        return std::to_string(bytes / 1024) + " KB";
    }
    return std::to_string(bytes / (1024 * 1024)) + " MB";
}

// 清理挂起异常, 避免污染后续 JSVM-API 调用(规范第 5 条)
void ClearPending(JSVM_Env env) {
    bool pending = false;
    if (OH_JSVM_IsExceptionPending(env, &pending) == JSVM_OK && pending) {
        JSVM_Value ignored = nullptr;
        OH_JSVM_GetAndClearLastException(env, &ignored);
    }
}

// JSVM 最后一条内部错误信息(API 调用失败时用于诊断)
std::string LastErrorInfo(JSVM_Env env) {
    if (env == nullptr) {
        return std::string();
    }
    const JSVM_ExtendedErrorInfo* info = nullptr;
    if (OH_JSVM_GetLastErrorInfo(env, &info) == JSVM_OK && info != nullptr &&
        info->errorMessage != nullptr) {
        return std::string(info->errorMessage);
    }
    return std::string();
}

// JSVM_Value -> UTF-8 文本(等价 JS 的 String(v))
bool ValueToUtf8(JSVM_Env env, JSVM_Value value, std::string& out) {
    out.clear();
    if (value == nullptr) {
        return false;
    }
    JSVM_Value str = nullptr;
    if (OH_JSVM_CoerceToString(env, value, &str) != JSVM_OK || str == nullptr) {
        ClearPending(env);
        return false;
    }
    std::size_t len = 0;
    if (OH_JSVM_GetValueStringUtf8(env, str, nullptr, 0, &len) != JSVM_OK) {
        ClearPending(env);
        return false;
    }
    if (len == 0) {
        return true;
    }
    std::vector<char> buf(len + 1, '\0');
    std::size_t copied = 0;
    if (OH_JSVM_GetValueStringUtf8(env, str, buf.data(), len + 1, &copied) != JSVM_OK) {
        ClearPending(env);
        return false;
    }
    out.assign(buf.data(), copied);
    return true;
}

// 值 -> 可读文本: 对象/数组优先 JSON(便于看结构), 其余按 String(v)(与 JS 语义一致)
std::string FormatValue(JSVM_Env env, JSVM_Value value) {
    JSVM_ValueType type = JSVM_UNDEFINED;
    if (OH_JSVM_Typeof(env, value, &type) == JSVM_OK && type == JSVM_OBJECT) {
        JSVM_Value json = nullptr;
        if (OH_JSVM_JsonStringify(env, value, &json) == JSVM_OK && json != nullptr) {
            std::string text;
            if (ValueToUtf8(env, json, text) && !text.empty()) {
                return text;
            }
        }
        // 循环引用等导致 stringify 失败: 清理异常后退回 String(v)
        ClearPending(env);
    }
    std::string text;
    ValueToUtf8(env, value, text);
    return text;
}

// 取挂起异常的可读描述(优先 stack, 带文件名与行号)
std::string DescribeException(JSVM_Env env) {
    bool pending = false;
    if (OH_JSVM_IsExceptionPending(env, &pending) != JSVM_OK || !pending) {
        std::string info = LastErrorInfo(env);
        return info.empty() ? std::string("未知错误") : info;
    }
    JSVM_Value exception = nullptr;
    if (OH_JSVM_GetAndClearLastException(env, &exception) != JSVM_OK || exception == nullptr) {
        return std::string("未知异常");
    }
    std::string text;
    JSVM_Value stack = nullptr;
    if (OH_JSVM_GetNamedProperty(env, exception, "stack", &stack) == JSVM_OK && stack != nullptr) {
        ValueToUtf8(env, stack, text);
    }
    if (text.empty()) {
        ValueToUtf8(env, exception, text);
    }
    if (text.empty()) {
        text = "未知异常";
    }
    return text;
}

void AppendStdout(const std::string& text) {
    RunContext* ctx = g_context;
    if (ctx == nullptr || ctx->opts == nullptr || ctx->outcome == nullptr) {
        return;
    }
    std::string& out = ctx->outcome->stdoutText;
    if (out.size() >= ctx->opts->stdoutLimitBytes) {
        ctx->stdoutTruncated = true;
        return;
    }
    std::size_t room = ctx->opts->stdoutLimitBytes - out.size();
    if (text.size() > room) {
        out.append(text, 0, room);
        ctx->stdoutTruncated = true;
    } else {
        out.append(text);
    }
}

// 抛出 JS 异常并返回 nullptr(回调内的错误一律交给脚本 try/catch 处理)
JSVM_Value ThrowAndReturn(JSVM_Env env, const std::string& message) {
    OH_JSVM_ThrowError(env, nullptr, message.c_str());
    return nullptr;
}

// ===== 注入到沙箱的 native 函数 =====

// console.log / console.info / ... / print / log: 收集到 stdout
JSVM_Value JSVM_CDECL HostConsole(JSVM_Env env, JSVM_CallbackInfo info) {
    std::size_t argc = 0;
    OH_JSVM_GetCbInfo(env, info, &argc, nullptr, nullptr, nullptr);
    std::string line;
    if (argc > 0) {
        std::vector<JSVM_Value> args(argc, nullptr);
        std::size_t count = argc;
        if (OH_JSVM_GetCbInfo(env, info, &count, args.data(), nullptr, nullptr) == JSVM_OK) {
            for (std::size_t i = 0; i < count; i++) {
                if (i > 0) {
                    line += " ";
                }
                line += FormatValue(env, args[i]);
                if (line.size() > kMaxConsoleLineBytes) {
                    line.resize(kMaxConsoleLineBytes);
                    line += "…(单行超长已截断)";
                    break;
                }
            }
        }
    }
    line += "\n";
    AppendStdout(line);
    JSVM_Value undefined = nullptr;
    OH_JSVM_GetUndefined(env, &undefined);
    return undefined;
}

// read(path): 读取由 ArkTS 侧预载的输入文件文本, 未命中返回 undefined
JSVM_Value JSVM_CDECL HostRead(JSVM_Env env, JSVM_CallbackInfo info) {
    std::size_t argc = 1;
    JSVM_Value args[1] = {nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, args, nullptr, nullptr);
    RunContext* ctx = g_context;
    if (ctx == nullptr || ctx->opts == nullptr) {
        return ThrowAndReturn(env, "read(): 执行上下文已失效");
    }
    if (ctx->opts->inputs.empty()) {
        // 空 inputs 几乎总是"调用方忘了传 files": 明确报错, 而不是静默返回 undefined
        return ThrowAndReturn(env, "read(): 本次执行没有预载任何输入文件 —— 请在 run_js 的 "
            "files 参数里列出要读取的工作区文件(相对路径, 多个用逗号分隔)");
    }
    std::string name;
    if (argc >= 1 && ValueToUtf8(env, args[0], name)) {
        // 查询也走归一化: read("./a/b.txt") / read("a//b.txt") 都能命中同一份输入
        std::string key = NormalizeRelPath(name);
        std::map<std::string, std::string>::const_iterator it = ctx->opts->inputs.find(key);
        if (it != ctx->opts->inputs.end()) {
            JSVM_Value text = nullptr;
            if (OH_JSVM_CreateStringUtf8(env, it->second.c_str(), it->second.size(), &text) == JSVM_OK) {
                return text;
            }
            ClearPending(env);
            return ThrowAndReturn(env, "read(): 创建字符串失败");
        }
    }
    JSVM_Value undefined = nullptr;
    OH_JSVM_GetUndefined(env, &undefined);
    return undefined;
}

// write(path, content): 声明一个输出文件, 执行成功后由 ArkTS 侧落盘(仅 ok=true 时写)
JSVM_Value JSVM_CDECL HostWrite(JSVM_Env env, JSVM_CallbackInfo info) {
    std::size_t argc = 2;
    JSVM_Value args[2] = {nullptr, nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, args, nullptr, nullptr);
    RunContext* ctx = g_context;
    if (ctx == nullptr || ctx->opts == nullptr || ctx->outcome == nullptr) {
        return ThrowAndReturn(env, "write(): 执行上下文已失效");
    }
    std::string name;
    if (argc < 1 || !ValueToUtf8(env, args[0], name) || name.empty()) {
        return ThrowAndReturn(env, "write(name, content): name 必须是非空字符串(工作区相对路径)");
    }
    std::string content;
    if (argc >= 2 && !ValueToUtf8(env, args[1], content)) {
        return ThrowAndReturn(env, "write(name, content): content 无法转成字符串");
    }
    const JsRunOptions* opts = ctx->opts;
    if (content.size() > opts->outputFileLimitBytes) {
        return ThrowAndReturn(env, "输出文件 " + name + " 超过单文件上限 " +
            SizeText(opts->outputFileLimitBytes) + "(当前 " + SizeText(content.size()) +
            "), 请分片写出或缩小数据量");
    }
    std::map<std::string, std::string>& outputs = ctx->outcome->outputs;
    std::size_t total = 0;
    for (std::map<std::string, std::string>::const_iterator it = outputs.begin();
         it != outputs.end(); ++it) {
        total += it->second.size();
    }
    std::map<std::string, std::string>::iterator existed = outputs.find(name);
    if (existed == outputs.end()) {
        if (outputs.size() >= opts->maxOutputFiles) {
            return ThrowAndReturn(env, "输出文件数量超过上限 " +
                std::to_string(opts->maxOutputFiles) + " 个");
        }
        total += content.size();
    } else {
        total = total - existed->second.size() + content.size();
    }
    if (total > opts->outputTotalLimitBytes) {
        return ThrowAndReturn(env, "输出总量超过上限 " + SizeText(opts->outputTotalLimitBytes));
    }
    outputs[name] = content;
    JSVM_Value undefined = nullptr;
    OH_JSVM_GetUndefined(env, &undefined);
    return undefined;
}

// 回调对象必须是静态/长生命周期(规范第 4 条)
JSVM_CallbackStruct g_consoleCallback = {HostConsole, nullptr};
JSVM_CallbackStruct g_readCallback = {HostRead, nullptr};
JSVM_CallbackStruct g_writeCallback = {HostWrite, nullptr};

// 把 native 函数挂到目标对象上
bool BindFunction(JSVM_Env env, JSVM_Value target, const char* name, JSVM_CallbackStruct* cb) {
    JSVM_Value fn = nullptr;
    if (OH_JSVM_CreateFunction(env, name, JSVM_AUTO_LENGTH, cb, &fn) != JSVM_OK || fn == nullptr) {
        ClearPending(env);
        return false;
    }
    if (OH_JSVM_SetNamedProperty(env, target, name, fn) != JSVM_OK) {
        ClearPending(env);
        return false;
    }
    return true;
}

bool BindString(JSVM_Env env, JSVM_Value target, const char* name, const std::string& value) {
    JSVM_Value text = nullptr;
    if (OH_JSVM_CreateStringUtf8(env, value.c_str(), value.size(), &text) != JSVM_OK) {
        ClearPending(env);
        return false;
    }
    if (OH_JSVM_SetNamedProperty(env, target, name, text) != JSVM_OK) {
        ClearPending(env);
        return false;
    }
    return true;
}

// 准备沙箱全局环境: console / print / log / read / write / inputs
bool PrepareSandbox(JSVM_Env env, const JsRunOptions& options, std::string& error) {
    JSVM_Value global = nullptr;
    JSVM_Status globalStatus = OH_JSVM_GetGlobal(env, &global);
    if (globalStatus != JSVM_OK || global == nullptr) {
        error = "获取全局对象失败(" + StatusText(globalStatus) + ")";
        ClearPending(env);
        return false;
    }

    // console.{log,info,warn,error,debug} 全部指向同一个收集器(沙箱不做日志分级)
    JSVM_Value consoleObj = nullptr;
    if (OH_JSVM_CreateObject(env, &consoleObj) != JSVM_OK || consoleObj == nullptr) {
        ClearPending(env);
        error = "创建 console 对象失败";
        return false;
    }
    const char* consoleMethods[] = {"log", "info", "warn", "error", "debug"};
    for (std::size_t i = 0; i < 5; i++) {
        if (!BindFunction(env, consoleObj, consoleMethods[i], &g_consoleCallback)) {
            error = "挂载 console." + std::string(consoleMethods[i]) + " 失败";
            return false;
        }
    }
    if (OH_JSVM_SetNamedProperty(env, global, "console", consoleObj) != JSVM_OK) {
        ClearPending(env);
        error = "挂载 console 失败";
        return false;
    }

    // print / log 是 console.log 的简写(给"脚本式"写法用)
    JSVM_Value consoleLog = nullptr;
    if (OH_JSVM_GetNamedProperty(env, consoleObj, "log", &consoleLog) != JSVM_OK ||
        consoleLog == nullptr) {
        ClearPending(env);
        error = "读取 console.log 失败";
        return false;
    }
    if (OH_JSVM_SetNamedProperty(env, global, "print", consoleLog) != JSVM_OK ||
        OH_JSVM_SetNamedProperty(env, global, "log", consoleLog) != JSVM_OK) {
        ClearPending(env);
        error = "挂载 print/log 失败";
        return false;
    }

    if (!BindFunction(env, global, "read", &g_readCallback)) {
        error = "挂载 read 失败";
        return false;
    }
    if (!BindFunction(env, global, "write", &g_writeCallback)) {
        error = "挂载 write 失败";
        return false;
    }

    // inputs: 只读输入文件内容(键为工作区相对路径)
    JSVM_Value inputsObj = nullptr;
    if (OH_JSVM_CreateObject(env, &inputsObj) != JSVM_OK || inputsObj == nullptr) {
        ClearPending(env);
        error = "创建 inputs 对象失败";
        return false;
    }
    for (std::map<std::string, std::string>::const_iterator it = options.inputs.begin();
         it != options.inputs.end(); ++it) {
        if (!BindString(env, inputsObj, it->first.c_str(), it->second)) {
            error = "写入 inputs[" + it->first + "] 失败";
            return false;
        }
    }
    if (OH_JSVM_SetNamedProperty(env, global, "inputs", inputsObj) != JSVM_OK) {
        ClearPending(env);
        error = "挂载 inputs 失败";
        return false;
    }
    return true;
}

// Scope/VM 资源的逆序释放(规范第 2 条)
class EnvResources {
public:
    ~EnvResources() {
        if (handleScopeOpened) {
            OH_JSVM_CloseHandleScope(env, handleScope);
        }
        if (envScopeOpened) {
            OH_JSVM_CloseEnvScope(env, envScope);
        }
        if (vmScopeOpened) {
            OH_JSVM_CloseVMScope(vm, vmScope);
        }
        if (envCreated) {
            OH_JSVM_DestroyEnv(env);
        }
        if (vmCreated) {
            OH_JSVM_DestroyVM(vm);
        }
    }

    JSVM_VM vm = nullptr;
    JSVM_Env env = nullptr;
    JSVM_VMScope vmScope = nullptr;
    JSVM_EnvScope envScope = nullptr;
    JSVM_HandleScope handleScope = nullptr;
    bool vmCreated = false;
    bool envCreated = false;
    bool vmScopeOpened = false;
    bool envScopeOpened = false;
    bool handleScopeOpened = false;
};

std::once_flag g_initOnce;
std::string g_initError;

}  // namespace

std::string NormalizeRelPath(const std::string& raw) {
    std::string body = raw;
    while (!body.empty() && body[0] == '/') {
        body.erase(0, 1);
    }
    while (body.size() >= 2 && body[0] == '.' && body[1] == '/') {
        body.erase(0, 2);
    }
    std::string cleaned;
    bool lastWasSlash = false;
    for (std::size_t i = 0; i < body.size(); i++) {
        char ch = body[i];
        if (ch == '/') {
            if (cleaned.empty() || lastWasSlash) {
                continue;
            }
            lastWasSlash = true;
        } else {
            lastWasSlash = false;
        }
        cleaned += ch;
    }
    while (!cleaned.empty() && cleaned[cleaned.size() - 1] == '/') {
        cleaned.erase(cleaned.size() - 1);
    }
    return cleaned;
}

std::string EnsureInit() {
    std::call_once(g_initOnce, []() {
        JSVM_InitOptions initOptions;
        memset(&initOptions, 0, sizeof(initOptions));
        JSVM_Status status = OH_JSVM_Init(&initOptions);
        // JSVM_GENERIC_FAILURE = 本进程已完成初始化, 无需重复执行(正常情况)
        if (status != JSVM_OK && status != JSVM_GENERIC_FAILURE) {
            g_initError = "OH_JSVM_Init 失败(" + StatusText(status) + ")";
            OH_LOG_ERROR(LOG_APP, "[%{public}s] %{public}s", kLogTag, g_initError.c_str());
        }
    });
    return g_initError;
}

JsRunOutcome Run(const JsRunOptions& options) {
    JsRunOutcome outcome;
    outcome.inputCount = options.inputs.size();  // 供上层核对参数是否真的送达 native
    for (std::map<std::string, std::string>::const_iterator it = options.inputs.begin();
         it != options.inputs.end(); ++it) {
        outcome.inputKeys.push_back(it->first);
    }
    const std::chrono::steady_clock::time_point started = std::chrono::steady_clock::now();

    RunContext ctx;
    ctx.opts = &options;
    ctx.outcome = &outcome;
    RunContext* previous = g_context;
    g_context = &ctx;

    std::string initError = EnsureInit();
    if (!initError.empty()) {
        outcome.error = "JS 引擎不可用: " + initError;
        g_context = previous;
        outcome.durationMs = ElapsedMs(started);
        return outcome;
    }

    EnvResources res;
    // 1) 创建引擎实例(VM)。堆上限给引擎一个天花板, 避免沙箱把应用内存吃光。
    JSVM_CreateVMOptions vmOptions;
    memset(&vmOptions, 0, sizeof(vmOptions));
    if (options.heapLimitBytes > 0) {
        vmOptions.maxOldGenerationSize = options.heapLimitBytes;
        vmOptions.maxYoungGenerationSize = options.heapLimitBytes / 4;
    }
    JSVM_Status status = OH_JSVM_CreateVM(&vmOptions, &res.vm);
    if (status != JSVM_OK || res.vm == nullptr) {
        // 堆参数不被接受时退回引擎默认配置, 不因此让工具不可用
        status = OH_JSVM_CreateVM(nullptr, &res.vm);
    }
    if (status != JSVM_OK || res.vm == nullptr) {
        outcome.error = "创建 JS 引擎失败(" + StatusText(status) + ")";
        g_context = previous;
        outcome.durationMs = ElapsedMs(started);
        return outcome;
    }
    res.vmCreated = true;

    // 2) 创建上下文
    status = OH_JSVM_CreateEnv(res.vm, 0, nullptr, &res.env);
    if (status != JSVM_OK || res.env == nullptr) {
        outcome.error = "创建 JS 上下文失败(" + StatusText(status) + "): " + LastErrorInfo(res.env);
        g_context = previous;
        outcome.durationMs = ElapsedMs(started);
        return outcome;
    }
    res.envCreated = true;

    // 3) 打开各级 Scope(顺序: VMScope -> EnvScope -> HandleScope)
    if (OH_JSVM_OpenVMScope(res.vm, &res.vmScope) != JSVM_OK) {
        outcome.error = "OpenVMScope 失败";
        g_context = previous;
        outcome.durationMs = ElapsedMs(started);
        return outcome;
    }
    res.vmScopeOpened = true;
    if (OH_JSVM_OpenEnvScope(res.env, &res.envScope) != JSVM_OK) {
        outcome.error = "OpenEnvScope 失败";
        g_context = previous;
        outcome.durationMs = ElapsedMs(started);
        return outcome;
    }
    res.envScopeOpened = true;
    if (OH_JSVM_OpenHandleScope(res.env, &res.handleScope) != JSVM_OK) {
        outcome.error = "OpenHandleScope 失败";
        g_context = previous;
        outcome.durationMs = ElapsedMs(started);
        return outcome;
    }
    res.handleScopeOpened = true;

    do {
        std::string prepareError;
        if (!PrepareSandbox(res.env, options, prepareError)) {
            outcome.error = "准备沙箱环境失败: " + prepareError;
            break;
        }
        JSVM_Value source = nullptr;
        if (OH_JSVM_CreateStringUtf8(res.env, options.code.c_str(), options.code.size(),
                                     &source) != JSVM_OK || source == nullptr) {
            ClearPending(res.env);
            outcome.error = "读取代码失败(代码可能过长)";
            break;
        }
        JSVM_ScriptOrigin origin;
        memset(&origin, 0, sizeof(origin));
        origin.sourceMapUrl = nullptr;
        origin.resourceName = options.resourceName.c_str();
        origin.resourceLineOffset = 0;
        origin.resourceColumnOffset = 0;

        JSVM_Script script = nullptr;
        bool cacheRejected = false;
        status = OH_JSVM_CompileScriptWithOrigin(res.env, source, nullptr, 0, true,
                                                &cacheRejected, &origin, &script);
        if (status != JSVM_OK || script == nullptr) {
            outcome.error = "语法错误(编译失败):\n" + DescribeException(res.env);
            break;
        }
        JSVM_Value result = nullptr;
        status = OH_JSVM_RunScript(res.env, script, &result);
        if (status != JSVM_OK) {
            outcome.error = "执行出错:\n" + DescribeException(res.env);
            break;
        }
        outcome.ok = true;
        JSVM_ValueType type = JSVM_UNDEFINED;
        if (result != nullptr && OH_JSVM_Typeof(res.env, result, &type) == JSVM_OK &&
            type != JSVM_UNDEFINED) {
            outcome.hasResult = true;
            if (type == JSVM_STRING) {
                ValueToUtf8(res.env, result, outcome.resultText);
            } else {
                outcome.resultText = FormatValue(res.env, result);
            }
        }
    } while (false);

    // 4) 关闭打开过的 Scope + 销毁上下文与引擎(由 EnvResources 析构逆序完成)
    g_context = previous;
    if (ctx.stdoutTruncated) {
        outcome.notice = "console 输出超过上限, 已截断";
    }
    outcome.durationMs = ElapsedMs(started);
    return outcome;
}

}  // namespace guncat
