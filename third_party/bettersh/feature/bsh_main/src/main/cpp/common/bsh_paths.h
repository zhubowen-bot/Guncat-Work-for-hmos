// common/bsh_paths.h — 应用私有目录布局的**唯一定义**(宿主与命令 so 共用)
//
// 布局:
//   files/        ← 资源根(bsh_sysroot()):性质像一套 sysroot。启动时 initResource 把
//                    clang-res/musl/vim-runtime/fonts/python/npm/testprogs/weston-terminal/
//                    usr/share/{x11/xkb,weston} 解到这里;运行时共享的小文件(三个 socket
//                    与 bsh-ws.bin)**也放这一层** —— 它们是应用的基础设施,不属于用户的家。
//   files/home/   ← bsh_home_dir() (=$HOME):会话家目录,只放"用户的东西":
//                    .ssh/ .harmony/ bettersh.conf autorun*.sh autorun.log hello.c
//
// ⚠ 资源根是**运行期**值(见下面 BSH_SYSROOT_DEFAULT 的说明)：它挂在模块名下，
//   模块名随 product 变(tablet / phone)，所以任何"建路径"的地方都必须用
//   bsh_sysroot() / bsh_home_dir() 这些访问器，不要在别处再写一遍字面量。
//
// 仍然有**另一份副本**、改动资源根时要一起看的地方(它们编不出运行期路径)：
//   - scripts/build_weston_terminal.sh  config.h 的 WESTON_DEFAULT_RT_DIR 与 fonts.tar 里
//                                       fonts.conf 的 <dir> 行 —— 前者由脚本从本文件取值，
//                                       后者已在运行期被 shell.cpp 重写(见那里的说明)
//   - scripts/build_weston_deps.sh      -Dxkb-config-root(编进 libxkbcommon 的默认值;
//                                       运行期 XKB_CONFIG_ROOT 覆盖,见 shell.cpp)
//   - scripts/build_vim.sh              configure --prefix(运行期 VIMRUNTIME 可覆盖)
//   - scripts/build_python.sh           configure --prefix(运行期 PYTHONHOME 可覆盖)
//   - scripts/node-ohos/bsh_node_entry.cc   npm-cli.js 路径(读环境变量 BSH_SYSROOT)
//   - scripts/jdk-ohos/bsh_java_entry.cc    java.home(读环境变量 BSH_SYSROOT)
//   - scripts/wait_autorun.sh               宿主机轮询设备日志用的路径
//   - rawfile/tools/autorun-all.sh          设备侧自检脚本里引用资源根的地方
//
// box64 已经**不在**这个名单里了：box64_spawn.c 原来编了个写死的 procmgr sock 默认值，
// 现在改成读 BSH_CTRL_SOCK（与 bsh_client.c 同一个变量），不再有会过期的副本。
#pragma once

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* pkg 的可持久化下载缓存目录。若可用则使用这个 */
#define BSH_PKG_CACHE_DIR \
    "/storage/Users/currentUser/Download/com.yiyan.bettersh/.pkg-cache"

/* apt 的默认镜像源。**必须是 https** —— 内置的 HTTP 客户端走 mbedTLS，只做 TLS 连接
 * （明文 http:// 会被 bsh_http 的解析判成 "URL 不合法"）。
 *
 * 定义在这儿而不是 apt_main.c 里：`$HOME/.bshrc` 由 shell.cpp 生成，那里要拿同一个值
 * 写 `export BSH_APT_MIRROR=…`，用户换源就改 .bshrc 里那一行（或 `apt source <url>`，
 * 那条路写在 $SYSROOT/pkgs/apt-source，优先级更高）。 */
#define BSH_APT_MIRROR_DEFAULT "https://ports.ubuntu.com/ubuntu-ports"

/* sysroot 兜底。若环境变量 BSH_SYSROOT 不可用，且 bsh_sysroot_path 没有有效值，
 * 退回 tablet 至少在多数情况下可用。*/
#define BSH_SYSROOT_DEFAULT "/data/storage/el2/base/haps/tablet/files"

/* 会话号的环境变量名。0 = 主窗口的 bsh 会话;>0 = `bshutil newtab` 开出来的 tab。
 *
 * 为什么走环境变量(而不是参数一路传下来):这个号要跨**进程边界**用 —— procmgr 起的
 * 命令 so、exec 委托另起的进程都得知道"我属于哪个会话",而它们不是调用方 fork 的孩子
 * (是 procmgr fork 的,只继承 procmgr 的 environ),内存里的东西带不过去。与 pty_shim
 * 用 BSH_FAKE_PTY_ID 把"我是几号 pty"传给另起的进程是同一个思路(见 shim/pty_shim.c)。
 *
 * 谁设:procmgr 在 fork 子进程时按 SpawnRequest.sid 注入(见 procmgr.cpp 的 ForkChild)。
 * 谁读:bsh_client.c 的 tty_request(插进 CMD TTY 请求)、bsh_util_client.c 的 SID 行。
 * **缺席一律按 0 处理** —— 宿主自己发的请求、老的调用方都属于这种,所以加这个维度
 * 不会改变任何既有行为。 */
#define BSH_SESSION_ENV "BSH_SESSION"

/* 资源根(含结尾 NUL)的最大长度。设备侧实际约 45 字节，留足余量。 */
#define BSH_PATH_MAX 512

/* ── 资源根：一个全局变量 + 一对 setter/getter ────────────────────────── */
static char bsh_sysroot_path[BSH_PATH_MAX];

static inline void bsh_set_sysroot(const char *dir) {
    if (!dir || !*dir) return;
    /* 先过一遍临时缓冲再落全局：调用方很可能就是把 bsh_sysroot() 的返回值传进来
     * （那是指向 bsh_sysroot_path 自己的指针），snprintf 源目重叠是未定义行为。 */
    char tmp[BSH_PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s", dir);
    snprintf(bsh_sysroot_path, sizeof bsh_sysroot_path, "%s", tmp);
    setenv("BSH_SYSROOT", bsh_sysroot_path, 1);
}

static inline const char *bsh_sysroot(void) {
    const char *e = getenv("BSH_SYSROOT");
    if (e && *e) {
        if (strcmp(e, bsh_sysroot_path) != 0) {
            snprintf(bsh_sysroot_path, sizeof bsh_sysroot_path, "%s", e);
        }
    } else if (!bsh_sysroot_path[0]) {
        snprintf(bsh_sysroot_path, sizeof bsh_sysroot_path, "%s", BSH_SYSROOT_DEFAULT);
    }
    return bsh_sysroot_path;
}

/* ── 资源根下的路径：一律用这些访问器，不要用宏拼 ────────────────────────── */
static inline const char *bsh_sysroot_join(const char *suffix, char *buf, size_t n) {
    snprintf(buf, n, "%s%s", bsh_sysroot(), suffix);
    return buf;
}
/* 会话家目录:$HOME / chdir 的目标 / PATH 里的 bin / dropbear 的 pw_dir */
static inline const char *bsh_home_dir(void) {
    static char b[BSH_PATH_MAX];
    return bsh_sysroot_join("/home", b, sizeof b);
}
/* 启动器文件目录(见 procmgr/command_map.c 的 cmd_make_launchers) */
static inline const char *bsh_bin_dir(void) {
    static char b[BSH_PATH_MAX];
    return bsh_sysroot_join("/bin", b, sizeof b);
}
/* 运行时共享文件(与 socket 同层,留在资源根) */
static inline const char *bsh_wayland_sock_path(void) {
    static char b[BSH_PATH_MAX];
    return bsh_sysroot_join("/wl-sock", b, sizeof b);
}
static inline const char *bsh_ctrl_sock_path(void) {
    static char b[BSH_PATH_MAX];
    return bsh_sysroot_join("/bsh-ctrl.sock", b, sizeof b);
}
static inline const char *bsh_util_sock_path(void) {
    static char b[BSH_PATH_MAX];
    return bsh_sysroot_join("/bshutil.sock", b, sizeof b);
}
static inline const char *bsh_ws_file_path(void) {
    static char b[BSH_PATH_MAX];
    return bsh_sysroot_join("/bsh-ws.bin", b, sizeof b);
}
static inline const char *bsh_fonts_conf_path(void) {
    static char b[BSH_PATH_MAX];
    return bsh_sysroot_join("/fonts.conf", b, sizeof b);
}

/* bundle 内命令 so 的位置  */
#define BSH_BUNDLE_LIBS   "/data/storage/el1/bundle/libs/arm64/"
