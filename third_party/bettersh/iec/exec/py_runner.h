// py_runner.h — 独立 python 解释器进程的启动入口。
#pragma once

#ifdef __cplusplus
extern "C" {
#else
#include <stdbool.h>
#endif

// 幂等。返回 false 表示 socket 建不起来（调用方只记日志，不影响其它工具）。
bool StartPyRunner();

#ifdef __cplusplus
}  // extern "C"
#endif
