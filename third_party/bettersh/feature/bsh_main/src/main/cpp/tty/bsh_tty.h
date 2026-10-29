// tty/bsh_tty.h — 会话软 tty 的状态(宿主侧,唯一真相)
//
// BetterSH 的会话 pty 是 socketpair(无内核行规程)。要让 vim 这类全屏程序以为
// 自己在真 tty 上,把 termios/winsize/前台进程组记在这里:
//   - 本文件是**宿主 libentry 侧**的实现:它持有 mmap(MAP_SHARED) 的会话状态,
//     这些状态的唯一真相就在这里;
//   - 命令 so 里的 shim/tty_shim.c **不链接本实现**:它在自己的进程里维护一张
//     "哪些 fd 是 tty"的本地表(isatty/fcntl 这类 fd 身份只能本地判断,fd 号是
//     进程私有的),而 termios/winsize/前台进程组经 procmgr 的 control socket
//     读写(CMD TTY,见 procmgr/ctrl_socket.cpp 与 procmgr/bsh_client.c);
//   - 于是命令 so 与宿主彻底解耦:编它们不需要 libentry.so 存在,也不必先跑
//     一次 build_hap(与 procmgr 的委托模型同构:主进程是服务端)。
//
// 线程/进程模型(有意不加锁):状态由宿主线程与 fork 出的命令各自读写,
// 有竞争风险的只有窗口尺寸,走原子量兜底。
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct termios;
struct winsize;

/* ---- 会话号 sid ----
 * 0 = 主窗口的 bsh 会话(唯一、进程内);>0 = 从 `bshutil newtab` 开出来的 tab
 * (每个 tab 是一条自己 fork 出来的 mksh,跑在**各自的**软 pty 上)。
 *
 * 为什么每个会话要有一份自己的 termios/winsize/前台进程组:软 pty 是 socketpair
 * (见 softpty.cpp),**没有内核行规程**,这些状态本来就全在用户态,一份就只够一个
 * 会话用 —— 两个会话共用一份的话,在 tab B 里跑 vim 会拿到 tab A 的网格尺寸。 */
#define BSH_SID_MAX 8

/* ---- session 接口:不经 fd,直连会话 tty 状态 ----
 * control socket 的 CMD TTY 用它应答命令 so 的请求(请求里带 SID,见 ctrl_socket.cpp);
 * 宿主 shell 也用它。 */
int bsh_tty_session_tcgetattr(int sid, struct termios* t);
int bsh_tty_session_tcsetattr(int sid, const struct termios* t);
int bsh_tty_session_get_winsize(int sid, uint16_t* rows, uint16_t* cols);
int bsh_tty_session_set_winsize(int sid, uint16_t rows, uint16_t cols);
int bsh_tty_session_get_pgrp(int sid);
int bsh_tty_session_set_pgrp(int sid, int pgrp);
/* spawn 前调用:把前台进程组拉回当前进程组(新命令接管终端的起点)。
 * 交互式 shell(mksh)随后会自己 tcsetpgrp 到它的子进程组。
 * 只对 sid 0(bsh 会话)有意义 —— 别的会话是**独立进程**里的 shell 在管自己的
 * 前台组(它经 tty_shim → pgrp_set 报上来),宿主"当前进程组"跟它没关系。 */
void bsh_tty_session_reset_pgrp(int sid);

/* 前端(xterm 实际网格)更新尺寸 */
void bsh_tty_set_shell_size(int sid, uint16_t rows, uint16_t cols);

/* 会话启动时建共享状态(MAP_SHARED):fork 出的命令继承同一映射,
 * 因此命令侧的改动对宿主可见(反之亦然)。每个 sid 各建一份,重复调用幂等。 */
void bsh_tty_init_shared(int sid, uint16_t rows, uint16_t cols);

/* 输入路径信号转发:会话 tty 处于 ISIG 且 c 为 VINTR/VQUIT/VSUSP 时,
 * 向前台进程组发对应信号(无有效前台组则发给 fallback_pid)。
 * 返回 1 = 已按信号处理(调用方不要再把该字节写入 pty);0 = 未处理透传。 */
int bsh_tty_forward_sig(int sid, unsigned char c, int fallback_pid);

/* 窗口尺寸变化转发:前端(xterm 网格)改了尺寸后,把 SIGWINCH 发给前台。
 * 全屏程序(vim)靠它重排;ssh 客户端靠它触发对远端 pty 的 window-change,
 * 少了这一步远端会一直停在会话建立时的行列。 */
void bsh_tty_forward_winch(int sid, int fallback_pid);

/* 输入侧行规程翻译:软 pty 没有内核 ldisc,这里按会话 termios 的 ICRNL 把回车
 * (CR)翻成换行(NL),与真 tty 一致(ICRNL 关掉时原样透传)。
 * 前端 xterm.js 的 Enter 发的是 CR,不翻的话只在等 '\n' 的程序会永远等不到
 * —— dropbear 确认主机密钥那句 while ((getchar()) != '\n') 就是。 */
unsigned char bsh_tty_input_translate(int sid, unsigned char c);

#ifdef __cplusplus
}
#endif
