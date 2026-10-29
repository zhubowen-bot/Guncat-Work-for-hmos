// procmgr/bsh_client.c — control socket 客户端实现
//
// 线协议见 ctrl_socket.cpp 顶部注释:帧 = [4B 大端长度] + 文本行 payload,
// fd 用 SCM_RIGHTS 附在首段上。这里只做"组装请求 → 发 → 收 → 解 EXIT_CODE"。
#include "bsh_client.h"
#include "../common/bsh_paths.h"   /* BSH_SESSION_ENV(控制通道要按会话号读写 tty 状态) */

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define BSH_CLIENT_MAX_FDS 16
#define BSH_CLIENT_MAX_FRAME (1024 * 1024)

/* 最近一次失败说明(非线程安全:每个进程内的调用路径都是单线程) */
static char g_last_error[256];

const char* bsh_client_last_error(void) { return g_last_error; }

static void set_err(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_last_error, sizeof g_last_error, fmt, ap);
    va_end(ap);
}

/* ---------- 可增长缓冲 ---------- */

typedef struct {
    char*  p;
    size_t len;
    size_t cap;
} Buf;

static int buf_reserve(Buf* b, size_t extra) {
    if (b->len + extra <= b->cap) return 1;
    size_t nc = b->cap ? b->cap : 256;
    while (nc < b->len + extra) nc *= 2;
    char* np = (char*)realloc(b->p, nc);
    if (!np) return 0;
    b->p = np;
    b->cap = nc;
    return 1;
}

static int buf_add(Buf* b, const char* s, size_t n) {
    if (!buf_reserve(b, n)) return 0;
    memcpy(b->p + b->len, s, n);
    b->len += n;
    return 1;
}

static int buf_adds(Buf* b, const char* s) { return buf_add(b, s, strlen(s)); }
static int buf_addc(Buf* b, char c) { return buf_add(b, &c, 1); }

/* ---------- 连接与收发 ---------- */

static int connect_ctrl(void) {
    const char* sock = getenv("BSH_CTRL_SOCK");
    if (!sock || !*sock) {
        set_err("BSH_CTRL_SOCK 未设置(procmgr 还没起来?)");
        return -1;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { set_err("socket: %s", strerror(errno)); return -1; }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr*)&addr, sizeof addr) < 0) {
        set_err("connect(%s): %s", sock, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static int send_frame(int fd, const char* payload, size_t len,
                      const int* fds, int n_fds) {
    uint8_t* first = (uint8_t*)malloc(4 + len);
    if (!first) { set_err("out of memory"); return 0; }
    first[0] = (uint8_t)(len >> 24);
    first[1] = (uint8_t)(len >> 16);
    first[2] = (uint8_t)(len >> 8);
    first[3] = (uint8_t)len;
    memcpy(first + 4, payload, len);

    struct iovec iov = { first, 4 + len };
    char cmsg_buf[CMSG_SPACE(sizeof(int) * BSH_CLIENT_MAX_FDS)];
    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    if (fds && n_fds > 0) {
        msg.msg_control = cmsg_buf;
        msg.msg_controllen = CMSG_SPACE(sizeof(int) * (size_t)n_fds);
        struct cmsghdr* cm = CMSG_FIRSTHDR(&msg);
        cm->cmsg_level = SOL_SOCKET;
        cm->cmsg_type = SCM_RIGHTS;
        cm->cmsg_len = CMSG_LEN(sizeof(int) * (size_t)n_fds);
        memcpy(CMSG_DATA(cm), fds, sizeof(int) * (size_t)n_fds);
        msg.msg_controllen = cm->cmsg_len;
    }

    ssize_t r;
    do { r = sendmsg(fd, &msg, MSG_NOSIGNAL); } while (r < 0 && errno == EINTR);
    free(first);
    if (r != (ssize_t)(4 + len)) { set_err("sendmsg: %s", strerror(errno)); return 0; }
    return 1;
}

static int read_frame(int fd, char* out, size_t out_cap, size_t* out_len) {
    uint8_t hdr[4];
    size_t got = 0;
    while (got < 4) {
        ssize_t r = recv(fd, hdr + got, 4 - got, 0);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; set_err("recv header: 对端关闭"); return 0; }
        got += (size_t)r;
    }
    uint32_t total = ((uint32_t)hdr[0] << 24) | ((uint32_t)hdr[1] << 16) |
                     ((uint32_t)hdr[2] << 8) | (uint32_t)hdr[3];
    if (total > BSH_CLIENT_MAX_FRAME) { set_err("响应帧过大(%u)", (unsigned)total); return 0; }
    if ((size_t)total >= out_cap) { set_err("响应帧超出本地缓冲(%u)", (unsigned)total); return 0; }
    size_t off = 0;
    while (off < total) {
        ssize_t r = recv(fd, out + off, total - off, 0);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; set_err("recv body: 对端关闭"); return 0; }
        off += (size_t)r;
    }
    out[off] = '\0';
    if (out_len) *out_len = off;
    return 1;
}

/* 从响应里取 "KEY <value>" 的一行值(取首个非空字符到行尾)。找不到返回 NULL。 */
static const char* line_value(const char* resp, const char* key) {
    size_t kl = strlen(key);
    for (const char* p = resp; *p; ) {
        if (strncmp(p, key, kl) == 0 && p[kl] == ' ') {
            return p + kl + 1;
        }
        const char* nl = strchr(p, '\n');
        if (!nl) break;
        p = nl + 1;
    }
    return NULL;
}

static int spawn_common(const char* cmd, char* const argv[], char* const envp[],
                        const int* src_fds, const int* target_fds, int n,
                        int sync, int* out_pid) {
    g_last_error[0] = '\0';
    if (!cmd || !*cmd) { set_err("命令为空"); return -1; }
    if (n < 0 || n > BSH_CLIENT_MAX_FDS) { set_err("fd 数量超限(%d)", n); return -1; }

    int fd = connect_ctrl();
    if (fd < 0) return -1;

    Buf body;
    memset(&body, 0, sizeof body);
    buf_adds(&body, "CMD CREATE\nPROTO_VER 1\nREQ_ID 1\nEXE ");
    buf_adds(&body, cmd);
    buf_addc(&body, '\n');
    /* WAIT 0 = 建好就回,调用方随后自己 bsh_wait_pid(见头文件那段说明:
     * exec_shim 要趁目标还活着的时候先关掉自己的 FD_CLOEXEC fd)。 */
    buf_adds(&body, sync ? "WAIT 1\n" : "WAIT 0\n");
    /* 带上调用方的当前目录。
     *
     * 子进程是 **procmgr** fork 出来的(不是调用方自己 fork),所以不写这一行,它
     * 就继承 procmgr 自己的 cwd。症状:`sh` 里 `cd /tmp` 之后 `pwd` 对、`ls` 却还在
     * 列原来的目录 —— pwd 是 shell 内建(看 shell 进程自己的 cwd),而 ls 是经这里
     * 委托出去的另一个进程。同理,命令 so 内部再委托(如 clang → cc1)时,cwd 就是
     * 那个命令 so 的 cwd,正是我们要的。
     * 服务端已有处理:ctrl_socket.cpp 解析 CWD → procmgr.cpp 子进程里 chdir。
     * getcwd 失败就整行不写,退回"继承"的老行为。 */
    char cwd[4096];
    if (getcwd(cwd, sizeof cwd)) {
        buf_adds(&body, "CWD ");
        buf_adds(&body, cwd);
        buf_addc(&body, '\n');
    }
    if (argv) {
        for (int i = 0; argv[i]; i++) {
            buf_adds(&body, "ARG ");
            buf_adds(&body, argv[i]);
            buf_addc(&body, '\n');
        }
    }
    /* 把**环境**也带过去：用调用方给的 envp（execve 的第三个参数），没给就用调用方
     * 自己的 environ。
     *
     * 子进程是 procmgr fork 出来的，不带环境就等于"继承 procmgr 自己的那份" ——
     * 于是 `FOO=1 cmd`、`export FOO=1; cmd` 这类改过的变量在委托后就丢了。
     * 踩到的实例：guest 侧 shim 认 BSH_TTY_STDIO 这个开关，自检里
     * `BSH_TTY_STDIO=1 <guest>` 因为这条丢失而没生效，查了半天。
     * 语义向 execve 靠：服务端按 ENV 行叠加（见 ctrl_socket.cpp 的 ApplyEnv）。
     * 上限：条数 1024、单条 4096 字节 —— 环境变量不该长到影响协议帧。 */
    {
        char* const* env = envp;
        extern char** environ;
        if (!env) env = environ;
        if (env) {
            for (int i = 0; env[i] && i < 1024; i++) {
                if (strlen(env[i]) > 4096) continue;
                if (strchr(env[i], '\n')) continue;   /* 协议是行式的,别拼坏 */
                buf_adds(&body, "ENV ");
                buf_adds(&body, env[i]);
                buf_addc(&body, '\n');
            }
        }
    }
    int nsend = 0;
    int send_fds[BSH_CLIENT_MAX_FDS];
    char line[48];
    for (int i = 0; i < n; i++) {
        if (src_fds[i] < 0) continue;
        send_fds[nsend++] = src_fds[i];
        snprintf(line, sizeof line, "FDREF %d\n", target_fds[i]);
        buf_adds(&body, line);
    }
    buf_adds(&body, "END");

    int rc = -1;
    if (body.p && send_frame(fd, body.p, body.len, send_fds, nsend)) {
        char resp[64 * 1024];
        if (read_frame(fd, resp, sizeof resp, NULL)) {
            if (strstr(resp, "STATUS ok")) {
                if (out_pid) {
                    const char* p = line_value(resp, "PID");
                    *out_pid = p ? atoi(p) : -1;
                }
                const char* v = line_value(resp, "EXIT_CODE");
                rc = v ? atoi(v) : 0;
            } else {
                const char* m = line_value(resp, "MSG");
                char msg[200];
                if (m) {
                    size_t i = 0;
                    while (m[i] && m[i] != '\n' && i + 1 < sizeof msg) { msg[i] = m[i]; i++; }
                    msg[i] = '\0';
                    set_err("%s", msg);
                } else {
                    set_err("procmgr 返回错误(无 MSG)");
                }
            }
        }
    }
    free(body.p);
    close(fd);
    return rc;
}

/* ---------- 对外 ---------- */

int bsh_spawnv_sync(const char* cmd, char* const argv[], const int fds[3]) {
    int src[3], tgt[3], n = 0;
    for (int i = 0; i < 3; i++) {
        if (fds && fds[i] >= 0) { src[n] = fds[i]; tgt[n] = i; n++; }
    }
    return spawn_common(cmd, argv, NULL, src, tgt, n, 1, NULL);
}

int bsh_spawnv_sync_fdmap(const char* cmd, char* const argv[],
                          const int* src_fds, const int* target_fds, int n) {
    return bsh_spawnv_sync_fdmap_env(cmd, argv, NULL, src_fds, target_fds, n);
}

/* 带环境版：envp 非空时用**它**（execve 语义），空则用调用方的 environ。
 * 见 spawn_common 里那段注释（为什么必须带）。 */
int bsh_spawnv_sync_fdmap_env(const char* cmd, char* const argv[],
                              char* const envp[],
                              const int* src_fds, const int* target_fds, int n) {
    static const int kNoFd[1] = { -1 };
    static const int kNoTgt[1] = { -1 };
    if (n <= 0) return spawn_common(cmd, argv, envp, kNoFd, kNoTgt, 0, 1, NULL);
    return spawn_common(cmd, argv, envp, src_fds, target_fds, n, 1, NULL);
}

/* 异步版：建好就回，pid 交给调用方（配套 bsh_wait_pid）。 */
int bsh_spawnv_async_fdmap_env(const char* cmd, char* const argv[],
                               char* const envp[],
                               const int* src_fds, const int* target_fds, int n,
                               int* out_pid) {
    static const int kNoFd[1] = { -1 };
    static const int kNoTgt[1] = { -1 };
    if (out_pid) *out_pid = -1;
    if (n <= 0) return spawn_common(cmd, argv, envp, kNoFd, kNoTgt, 0, 0, out_pid);
    return spawn_common(cmd, argv, envp, src_fds, target_fds, n, 0, out_pid);
}

/* 等一个已经建好的进程结束。服务端在 WAIT 0 那条路上已经派了后台线程回收它，
 * 所以这里只是查进程表 —— 不会和谁抢 waitpid。 */
int bsh_wait_pid(int pid, int* out_code) {
    g_last_error[0] = '\0';
    if (pid <= 0) { set_err("pid 无效(%d)", pid); return -1; }
    int fd = connect_ctrl();
    if (fd < 0) return -1;

    char body[64];
    int n = snprintf(body, sizeof body, "CMD WAIT\nPID %d\nEND", pid);
    int rc = -1;
    if (n > 0 && send_frame(fd, body, (size_t)n, NULL, 0)) {
        char resp[4096];
        if (read_frame(fd, resp, sizeof resp, NULL)) {
            if (strstr(resp, "STATUS ok")) {
                const char* v = line_value(resp, "EXIT_CODE");
                if (out_code) *out_code = v ? atoi(v) : -1;
                rc = 0;
            } else {
                const char* m = line_value(resp, "MSG");
                set_err("%s", m ? m : "WAIT 失败");
            }
        }
    }
    close(fd);
    return rc;
}

int bsh_procmgr_ping(void) {
    g_last_error[0] = '\0';
    int fd = connect_ctrl();
    if (fd < 0) return 0;
    int ok = 0;
    static const char kPing[] = "CMD PING\nEND";
    if (send_frame(fd, kPing, sizeof kPing - 1, NULL, 0)) {
        char resp[256];
        if (read_frame(fd, resp, sizeof resp, NULL))
            ok = strstr(resp, "PONG") != NULL;
    }
    close(fd);
    return ok;
}

/* 取进程表:响应是多行 "LIST / INFO pid=… alive=… code=… cmd=… / END",
 * 原样交给调用方(它自己决定怎么显示)。 */
int bsh_procmgr_list(char* buf, size_t cap) {
    g_last_error[0] = '\0';
    if (!buf || cap == 0) { set_err("bad args"); return 0; }
    static const char kReq[] = "CMD LIST\nEND";
    int fd = connect_ctrl();
    if (fd < 0) return 0;
    int ok = 0;
    if (send_frame(fd, kReq, sizeof kReq - 1, NULL, 0))
        ok = read_frame(fd, buf, cap, NULL);
    close(fd);
    return ok;
}

/* 请求 procmgr 结束某个进程(它先 SIGTERM,800ms 后 SIGKILL)。 */
int bsh_procmgr_terminate(int pid) {
    g_last_error[0] = '\0';
    if (pid <= 0) { set_err("bad pid"); return 0; }
    char req[64];
    int n = snprintf(req, sizeof req, "CMD TERMINATE\nPID %d\nEND", pid);
    if (n <= 0) { set_err("bad req"); return 0; }
    int fd = connect_ctrl();
    if (fd < 0) return 0;
    int ok = 0;
    if (send_frame(fd, req, (size_t)n, NULL, 0)) {
        char resp[256];
        if (read_frame(fd, resp, sizeof resp, NULL))
            ok = strstr(resp, "STATUS ok") != NULL;
    }
    close(fd);
    return ok;
}

/* 让 procmgr 把 sig 交给**那个会话**当前前台的进程(见 bsh_client.h 与 procmgr.h)。
 *
 * 会话号与 tty_request 同一个来源(BSH_SESSION 环境变量):pty_shim 在 guest 里跑,
 * 它属于哪个会话只有环境知道;不带这个号就会把 tab B 的 Ctrl+C 打到 tab A 的前台。
 * 缺席按 0(主窗口),与加这个维度之前完全一致。 */
int bsh_procmgr_signal_fg(int sig) {
    g_last_error[0] = '\0';
    if (sig <= 0) { set_err("bad sig"); return 0; }
    const char* sid = getenv(BSH_SESSION_ENV);
    char req[96];
    int n;
    if (sid && *sid)
        n = snprintf(req, sizeof req, "CMD SIGNAL\nSID %s\nSIG %d\nEND", sid, sig);
    else
        n = snprintf(req, sizeof req, "CMD SIGNAL\nSIG %d\nEND", sig);
    if (n <= 0) { set_err("bad req"); return 0; }
    int fd = connect_ctrl();
    if (fd < 0) return 0;
    int ok = 0;
    if (send_frame(fd, req, (size_t)n, NULL, 0)) {
        char resp[256];
        if (read_frame(fd, resp, sizeof resp, NULL))
            ok = strstr(resp, "STATUS ok") != NULL;
    }
    close(fd);
    return ok;
}

/* ---------- 会话软 tty 的远端读写 ---------- */
static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static void hex_encode(const unsigned char* p, size_t n, char* out) {
    static const char* d = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        out[i * 2] = d[p[i] >> 4];
        out[i * 2 + 1] = d[p[i] & 0xf];
    }
    out[n * 2] = '\0';
}

static int hex_decode(const char* s, unsigned char* out, size_t n) {
    for (size_t i = 0; i < n; i++) {
        int hi = hex_nibble(s[i * 2]);
        int lo = hex_nibble(s[i * 2 + 1]);
        if (hi < 0 || lo < 0) return 0;
        out[i] = (unsigned char)((hi << 4) | lo);
    }
    return 1;
}

/* 取一行值并填进错误信息(去掉行尾),避免把后续行也带进去 */
static void set_err_line(const char* m) {
    char tmp[200];
    size_t i = 0;
    if (m) {
        while (m[i] && m[i] != '\n' && i + 1 < sizeof tmp) { tmp[i] = m[i]; i++; }
    }
    tmp[i] = '\0';
    set_err("%s", i ? tmp : "tty op failed");
}

/* 发一条 CMD TTY 请求,响应原文写进 resp。
 *
 * SID 由这里统一插进去(而不是让五个 op 各自带):会话号是"我是谁"的属性,与具体
 * 是哪个 op 无关。值从 BSH_SESSION 环境变量读 —— procmgr 在 fork 命令 so 时按
 * SpawnRequest.sid 注入(见 bsh_client.h 的 BSH_SESSION_ENV)。没有这个变量
 * (宿主自己调、老的调用方)就整行不写,服务端按 0(主窗口的 bsh 会话)处理。
 *
 * ⚠ SID 必须插在**第一行之后**:服务端是按 `lines[0]` 分派请求的
 *   (ctrl_socket.cpp 的 HandleClient 先 SplitKV(lines[0]) 再挑分支),插到最前面
 *   会把 "CMD TTY" 挤走,整条请求被当成 unknown_command 回一个 STATUS error。
 *   实测症状(这就是我第一版写错的样子):主窗口里敲 `sh` 进 mksh 报
 *       sh: j_init: tcgetpgrp failed: No such file or directory
 *   —— tcgetpgrp 走 ioctl(TIOCGPGRP) → 本函数的远端查询失败 → 返回 -1 但没设
 *   errno,那里留着的是 connect 之后的旧值 ENOENT。 */
static int tty_request(const char* body, char* resp, size_t cap) {
    int fd = connect_ctrl();
    if (fd < 0) return 0;
    const char* sid = getenv(BSH_SESSION_ENV);
    char full[1280];
    const char* payload = body;
    const char* nl = strchr(body, '\n');
    if (sid && *sid && nl) {
        int head = (int)(nl - body) + 1;          /* 第一行 + 它的换行 */
        int n = snprintf(full, sizeof full, "%.*sSID %s\n%s", head, body, sid, nl + 1);
        if (n > 0 && (size_t)n < sizeof full) payload = full;
    }
    int ok = 0;
    if (send_frame(fd, payload, strlen(payload), NULL, 0))
        ok = read_frame(fd, resp, cap, NULL);
    close(fd);
    return ok;
}

/* 从响应里取 hex 值;长度必须正好是 len*2 字节 */
static int hex_value_of(const char* resp, const char* key, unsigned char* out,
                        size_t len) {
    const char* v = line_value(resp, key);
    if (!v) return 0;
    size_t vl = 0;
    while (v[vl] && v[vl] != '\n') vl++;
    if (vl != len * 2) return 0;
    return hex_decode(v, out, len);
}

int bsh_tty_remote_tcgetattr(void* tio, size_t len) {
    g_last_error[0] = '\0';
    if (!tio || len == 0 || len > 256) { set_err("bad args"); return -1; }
    char resp[4096];
    if (!tty_request("CMD TTY\nOP termios_get\nEND", resp, sizeof resp)) return -1;
    if (!strstr(resp, "STATUS ok")) { set_err_line(line_value(resp, "MSG")); return -1; }
    if (!hex_value_of(resp, "TIO", (unsigned char*)tio, len)) {
        set_err("响应里没有可用的 TIO");
        return -1;
    }
    return 0;
}

int bsh_tty_remote_tcsetattr(const void* tio, size_t len) {
    g_last_error[0] = '\0';
    if (!tio || len == 0 || len > 256) { set_err("bad args"); return -1; }
    char hex[520];
    hex_encode((const unsigned char*)tio, len, hex);
    char body[768];
    snprintf(body, sizeof body,
             "CMD TTY\nOP termios_set\nTIOLEN %u\nTIO %s\nEND",
             (unsigned)len, hex);
    char resp[2048];
    if (!tty_request(body, resp, sizeof resp)) return -1;
    if (strstr(resp, "STATUS ok")) return 0;
    set_err_line(line_value(resp, "MSG"));
    return -1;
}

int bsh_tty_remote_get_winsize(unsigned short* rows, unsigned short* cols) {
    g_last_error[0] = '\0';
    char resp[1024];
    if (!tty_request("CMD TTY\nOP ws_get\nEND", resp, sizeof resp)) return -1;
    if (!strstr(resp, "STATUS ok")) { set_err_line(line_value(resp, "MSG")); return -1; }
    const char* r = line_value(resp, "ROWS");
    const char* c = line_value(resp, "COLS");
    if (!r || !c) { set_err("响应里缺 ROWS/COLS"); return -1; }
    if (rows) *rows = (unsigned short)atoi(r);
    if (cols) *cols = (unsigned short)atoi(c);
    return 0;
}

int bsh_tty_remote_set_winsize(unsigned short rows, unsigned short cols) {
    g_last_error[0] = '\0';
    char body[128];
    snprintf(body, sizeof body, "CMD TTY\nOP ws_set\nROWS %u\nCOLS %u\nEND",
             (unsigned)rows, (unsigned)cols);
    char resp[1024];
    if (!tty_request(body, resp, sizeof resp)) return -1;
    if (strstr(resp, "STATUS ok")) return 0;
    set_err_line(line_value(resp, "MSG"));
    return -1;
}

int bsh_tty_remote_get_pgrp(int* pgrp) {
    g_last_error[0] = '\0';
    char resp[1024];
    if (!tty_request("CMD TTY\nOP pgrp_get\nEND", resp, sizeof resp)) return -1;
    if (!strstr(resp, "STATUS ok")) { set_err_line(line_value(resp, "MSG")); return -1; }
    const char* v = line_value(resp, "PGRP");
    if (!v) { set_err("响应里缺 PGRP"); return -1; }
    if (pgrp) *pgrp = atoi(v);
    return 0;
}

int bsh_tty_remote_set_pgrp(int pgrp) {
    g_last_error[0] = '\0';
    char body[128];
    snprintf(body, sizeof body, "CMD TTY\nOP pgrp_set\nPGRP %d\nEND", pgrp);
    char resp[1024];
    if (!tty_request(body, resp, sizeof resp)) return -1;
    if (strstr(resp, "STATUS ok")) return 0;
    set_err_line(line_value(resp, "MSG"));
    return -1;
}
