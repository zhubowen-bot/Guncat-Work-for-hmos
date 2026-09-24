// Guncat Work run_js 工具: JSVM-API 沙箱执行器(纯 JSVM-API, 不含 Node-API 逻辑)
//
// 设计要点:
//  - 每次执行创建独立的 VM + 上下文, 执行完立即销毁 —— 脚本之间无状态残留。
//  - 沙箱只注入纯计算与显式桥接能力(console/inputs/read/write), 无网络、无文件系统、
//    无模块加载(JSVM 本身不支持 ES Module)。
//  - JSVM-API 没有"中断执行"接口, 死循环无法从外部终止, 因此超时保护由 ArkTS 侧负责
//    (见 JsCodeService), native 侧只保证执行在非 UI 线程上。
#ifndef GUNCAT_JSVM_SANDBOX_H
#define GUNCAT_JSVM_SANDBOX_H

#include <cstddef>
#include <map>
#include <string>
#include <vector>

namespace guncat {

// 工作区相对路径归一化: 去掉开头的 '/' 与 './'、折叠重复斜杠、去掉结尾斜杠。
// 输入文件键名与 read() 查询都用它, 于是 read("./a/b.txt")、read("a//b.txt") 都能命中。
std::string NormalizeRelPath(const std::string& raw);

// 单次执行参数(全部由 ArkTS 侧传入)
struct JsRunOptions {
    std::string code;                                     // 用户 JS 源码
    std::string resourceName = "run_js.js";               // 报错/调用栈里显示的文件名
    std::map<std::string, std::string> inputs;            // 只读输入文件: 工作区相对路径 -> 文本
    std::size_t heapLimitBytes = 256ull * 1024ull * 1024ull;   // 单次执行堆上限(0=引擎默认)
    std::size_t stdoutLimitBytes = 64ull * 1024ull;            // 控制台输出上限
    std::size_t outputFileLimitBytes = 1024ull * 1024ull;      // 单个输出文件上限
    std::size_t outputTotalLimitBytes = 4ull * 1024ull * 1024ull;  // 输出总量上限
    std::size_t maxOutputFiles = 16;                           // 输出文件个数上限
};

// 单次执行结果
struct JsRunOutcome {
    bool ok = false;                                   // 脚本是否成功执行完
    std::string error;                                 // ok=false 时的错误说明(含阶段)
    std::string stdoutText;                            // console 输出
    std::string resultText;                            // 完成值文本(最后一条表达式的值)
    bool hasResult = false;                            // 完成值是否为 undefined
    std::map<std::string, std::string> outputs;        // write() 声明的输出文件(仅 ok=true 时有效)
    std::size_t inputCount = 0;                        // 实际收到的预载输入文件数(供上层核对)
    std::vector<std::string> inputKeys;                // 实际安装到 inputs 上的键名(归一化后)
    std::string notice;                                // 截断等提示(追加到结果尾部)
    long long durationMs = 0;                          // 执行耗时
};

// 进程级 JSVM 初始化(幂等、线程安全)。成功返回空串, 失败返回原因。
std::string EnsureInit();

// 在当前线程执行一段 JS(阻塞直到执行结束或脚本自行结束)。
JsRunOutcome Run(const JsRunOptions& options);

}  // namespace guncat

#endif  // GUNCAT_JSVM_SANDBOX_H
