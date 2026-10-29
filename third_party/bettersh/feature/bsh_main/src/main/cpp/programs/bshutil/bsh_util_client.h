// programs/bshutil/bsh_util_client.h — bshutil 服务的客户端(与 bshutil_main.cc 同目录)
//
// 位置:和命令 so 的入口放在一起 —— 客户端只服务这一个 so,所以跟着它走(宿主不引用
// 这里的东西,所以 programs/ 与 bshutil/ 之间没有互相依赖)。它要的
// sock 路径与帧格式来自 bshutil/bsh_util_proto.h(和服务端共用一份,不各写一份字面量)。
//
// 纯 C、只依赖 socket:命令 so 不能链接宿主的任何符号(这是本项目的铁律,见
// procmgr/bsh_client.h 的同款说明)。
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 把一条 bshutil 命令交给主进程的服务端执行:
 *   - 输出**流式**写入 fd_out(通常是 STDOUT_FILENO),所以 `bshutil conf > f` 里
 *     重定向天然成立(客户端就是个普通写 stdout 的程序);
 *   - 返回值 = 命令退出码(0 成功 / 1 环境不满足 / 2 用法错);
 *   - 连不上服务端、协议错、fd 写失败 → 返回 -1,说明见 bsh_util_client_last_error()。 */
int bsh_util_call(int argc, char* const argv[], int fd_out);

/* 最近一次失败的说明(进程内静态缓冲,非线程安全)。 */
const char* bsh_util_client_last_error(void);

#ifdef __cplusplus
}
#endif
