// bshutil/bshutil.h — 内置命令 bshutil
//
// 用途:改 BetterSH 自己的设置(终端行为 / 窗口与界面 / 系统交互)、查看 hap 里
// 打包的 rawfile、看 procmgr 的进程表。实现在 bshutil.cpp,shell 那边只调
// bshutil_exec 一个函数。
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* 执行一条 bshutil 命令,输出写到 out_fd(通常是会话 pty)。
 *   argc/argv : argv[0] 必须是 "bshutil"
 *   cwd       : **调用方**的当前目录,只有需要把相对路径解析成绝对路径的子命令
 *               (`rawfile get` 的目标)才用得上;拿不到就传 NULL。
 *               必须由客户端带过来:服务端跑在主进程里,它的 cwd 是应用启动目录,
 *               跟用户在终端里 cd 到哪没有关系(同 procmgr 的 CWD,见 bsh_client.c)。
 *   sid       : **调用方所在的会话号**(0 = 主窗口的 bsh,>0 = 新开的 tab)。
 *               只有"要请 ArkTS 做事"的子命令用得上(picker / newtab),它们必须
 *               发生在发起命令的那个窗口里。同样由客户端从自己的 BSH_SESSION
 *               环境变量读出来带过来(服务端是主进程,不知道自己替谁干活)。
 * 返回码即命令退出码:0 成功 / 1 设备或 UI 不满足条件 / 2 用法错误。 */
int bshutil_exec(int argc, char* const argv[], int out_fd, const char* cwd, int sid);

/* 一行摘要,给 shell 的 help 列表用(不含换行)。 */
const char* bshutil_summary(void);

#ifdef __cplusplus
}
#endif
