// procmgr/bsh_client.h — control socket 客户端(宿主 shell 与命令 so 共用)
//
// 纯 C、只依赖 socket。两条使用路径:
//   - 宿主 shell:执行一条命令时,把 argv + 会话 pty slave fd 交给 procmgr;
//   - 命令 so(经 --wrap exec* 的 shim/exec_shim.c):内部要 exec 别的程序时,把当前
//     进程可继承的 fd 一并交给 procmgr(fd 不能靠继承,fork 出子进程的是主进程)。
//
// ⚠ 改这个文件(或 shim/exec_shim.c)之后,记得重编**所有把它们的 .o 编进去的产物** ——
//   命令 so 各自烤了一份副本,漏编哪个,那个命令就还用着旧行为:
//     scripts/build_mksh.sh     → libmksh.so
//     scripts/build_llvm.sh     → libclangbsh.so / liblld.so
//     scripts/build_dropbear.sh → libsshcore.so
//   (宿主 shell 那份在 libentry.so 里,跟 build_hap.sh 一起走。)
//   实测踩过:只改了这里、只跑了 build_hap,于是 `sh` 里 `cd` 之后 `ls` 仍然列旧目录
//   —— libmksh.so 里那份拷贝是旧的。
//
// socket 路径从环境变量 BSH_CTRL_SOCK 读取(procmgr 启动时注入,子进程天然继承)。
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// 同步 spawn:等子进程退出,返回其 exit code(0-255);-1 = 请求失败(没连上
// procmgr、协议错、命令不存在)。失败原因见 bsh_client_last_error()。
//   cmd/argv: argv[0] 必须是命令名(multicall 依赖);argv 以 NULL 结尾
//   fds[3]  : 子进程 0/1/2 各自要用的 fd;-1 表示该槽位不指定
int bsh_spawnv_sync(const char* cmd, char* const argv[], const int fds[3]);

// 同上,但 fd 与目标号任意配对(供命令 so 委托时继承管道/重定向等 fd)。
// src_fds[i] → target_fds[i],共 n 个;n 上限 16。失败返回 -1。
int bsh_spawnv_sync_fdmap(const char* cmd, char* const argv[],
                          const int* src_fds, const int* target_fds, int n);

// 带**环境**的版本:envp 非空时用它(execve 语义 —— `FOO=1 cmd` 的改动就在这个参数
// 里,不是调用方的 environ),空则用调用方的 environ。委托走的进程是 procmgr fork 的,
// 不带环境就等于继承 procmgr 那份,调用方改过的变量会丢。
int bsh_spawnv_sync_fdmap_env(const char* cmd, char* const argv[],
                              char* const envp[],
                              const int* src_fds, const int* target_fds, int n);

// 异步 spawn:进程建好就返回(不等它结束),pid 写进 *out_pid。返回 0 成功、-1 失败。
//
// 为什么需要这样一个"半截"的 spawn:exec_shim 委托成功之后、目标还活着的时候，
// 得先把自己那些带 FD_CLOEXEC 的 fd 关掉 —— 真 execve 是内核在这一刻替我们关的，
// 而"另起进程"这条路上要拖到进程退出才关，subprocess 的 error pipe 就一直开着
// （CPython 拿它判断"孩子起来了"）→ 父进程卡死。详见 shim/exec_shim.c 文件头。
// 配套的是下面的 bsh_wait_pid()。
int bsh_spawnv_async_fdmap_env(const char* cmd, char* const argv[],
                               char* const envp[],
                               const int* src_fds, const int* target_fds, int n,
                               int* out_pid);

// 等一个**已经建好**的进程结束,退出码写进 *out_code(0-255)。返回 0 成功、-1 失败。
// 进程表由 procmgr 维护:建进程时若用 WAIT 0,它会派一个后台线程回收,
// 这里只是查那张表,所以不会和谁抢 waitpid。
int bsh_wait_pid(int pid, int* out_code);

// 连通性自检:返回 1 = 服务端应答 PONG。
int bsh_procmgr_ping(void);

// 取 procmgr 的进程表原始响应(多行,含 "INFO pid=… alive=… code=… cmd=…"),
// 写进 buf 并保证以 '\0' 结尾。返回 1 成功,0 失败(见 last_error)。
int bsh_procmgr_list(char* buf, size_t cap);

// 请求终止某个 procmgr 创建的进程(先 SIGTERM,800ms 后 SIGKILL)。
// 返回 1 = 请求已受理。
int bsh_procmgr_terminate(int pid);

// 让 procmgr 把 sig 交给"当前前台"那个进程(它 fork 出来的、不在调用方进程组里的那个)。
// 给 guest 里的 pty_shim 用:假 pty 收到 Ctrl+C 时,调用方能杀的只有自己这侧的委托
// 中间体,真正干活的程序收不到 —— 见 procmgr.h 的 SignalForeground。
// 返回 1 = 已交给对方,0 = 当前没有前台进程或请求失败。
int bsh_procmgr_signal_fg(int sig);

/* ---- 会话软 tty 的远端读写(命令 so 的 tty_shim 用) ----
 * 会话 tty 的状态(termios/winsize/前台进程组)只有主进程一份真相;命令 so 不
 * 链接宿主,按需经 control socket 读写。len 必须等于 sizeof(struct termios)
 * (两侧同一份 SDK/musl,布局一致;长度不符服务端会拒)。
 * 全部返回 0 成功、-1 失败(见 bsh_client_last_error)。 */
int bsh_tty_remote_tcgetattr(void* tio, size_t len);
int bsh_tty_remote_tcsetattr(const void* tio, size_t len);
int bsh_tty_remote_get_winsize(unsigned short* rows, unsigned short* cols);
int bsh_tty_remote_set_winsize(unsigned short rows, unsigned short cols);
int bsh_tty_remote_get_pgrp(int* pgrp);
int bsh_tty_remote_set_pgrp(int pgrp);

// 最近一次失败的说明(进程内静态缓冲,非线程安全;成功时为空串)。
const char* bsh_client_last_error(void);

#ifdef __cplusplus
}
#endif
