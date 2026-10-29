// bshutil/bsh_util_client.c — 见 bsh_util_client.h
#include "bsh_util_client.h"
#include "bshutil/bsh_util_proto.h"
#include "common/bsh_paths.h"   // bsh_util_sock_path()

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static char g_err[256];

const char* bsh_util_client_last_error(void) { return g_err; }

static void SetErr(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_err, sizeof g_err, fmt, ap);
    va_end(ap);
}

static int Connect(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        SetErr("socket: %s", strerror(errno));
        return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, bsh_util_sock_path(), sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr*)&addr, sizeof addr) != 0) {
        SetErr("连不上 bshutil 服务(%s): %s", bsh_util_sock_path(), strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static int SendAll(int fd, const char* p, size_t n) {
    while (n > 0) {
        /* MSG_NOSIGNAL:服务端先死掉时拿 EPIPE,而不是被 SIGPIPE 直接杀掉 */
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w <= 0) { if (w < 0 && errno == EINTR) continue; return -1; }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

/* 一帧 = 4 字节大端长度 + payload */
static int SendFrame(int fd, const char* payload, size_t n) {
    unsigned char hdr[4] = {
        (unsigned char)((n >> 24) & 0xff), (unsigned char)((n >> 16) & 0xff),
        (unsigned char)((n >> 8) & 0xff),  (unsigned char)(n & 0xff),
    };
    if (SendAll(fd, (const char*)hdr, 4) != 0) return -1;
    return SendAll(fd, payload, n);
}

static int WriteOut(int fd, const char* p, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w <= 0) { if (w < 0 && errno == EINTR) continue; return -1; }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

/* 收应答:输出流式写到 fd_out,**永远把末尾 4 字节留在手里**(那是退出码),
 * 直到对端 shutdown(SHUT_WR) 给出 EOF。
 *
 * 这里是"滑动窗口":手上的字节拼起来是 tail[0..tn) ++ 本次收到的 buf,只有最后
 * 4 字节不确定(可能是退出码),其余都可以立刻送出去。
 * ⚠ 别写成"先把 tail 攒满 4 字节再说" —— 那会把**流开头**的 4 字节当成退出码
 * 扣住,输出就少了开头 4 个字符(实测:usage 的 "bshutil —" 变成 "til —")。 */
static int RecvReply(int fd, int fd_out) {
    unsigned char buf[8192];
    unsigned char tail[BSHUTIL_CODE_LEN];
    size_t tn = 0;

    for (;;) {
        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n == 0) break;                       // EOF:tail 里就是退出码
        if (n < 0) {
            if (errno == EINTR) continue;
            SetErr("读取应答失败: %s", strerror(errno));
            return -1;
        }
        size_t total = (size_t)n;
        size_t avail = tn + total;
        size_t emit = avail > BSHUTIL_CODE_LEN ? avail - BSHUTIL_CODE_LEN : 0;

        if (emit == 0) {                         // 还不够 4 字节,全攒着
            memcpy(tail + tn, buf, total);
            tn += total;
            continue;
        }

        size_t from_tail = emit < tn ? emit : tn;
        if (from_tail > 0 && WriteOut(fd_out, (const char*)tail, from_tail) != 0) {
            SetErr("写输出失败: %s", strerror(errno));
            return -1;
        }
        size_t from_buf = emit - from_tail;
        if (from_buf > 0 && WriteOut(fd_out, (const char*)buf, from_buf) != 0) {
            SetErr("写输出失败: %s", strerror(errno));
            return -1;
        }

        /* 剩下的正好是整条流的最后 4 字节,原样留到下一次 */
        size_t keep_tail = tn - from_tail;       // 还留在旧 tail 里的部分
        memmove(tail, tail + from_tail, keep_tail);
        memcpy(tail + keep_tail, buf + from_buf, total - from_buf);
        tn = keep_tail + (total - from_buf);
    }

    if (tn < BSHUTIL_CODE_LEN) {
        SetErr("应答不完整(服务端中途断开?)");
        return -1;
    }
    return (int)(((unsigned)tail[0] << 24) | ((unsigned)tail[1] << 16) |
                 ((unsigned)tail[2] << 8) | (unsigned)tail[3]);
}

int bsh_util_call(int argc, char* const argv[], int fd_out) {
    g_err[0] = '\0';
    if (argc <= 0 || !argv) {
        SetErr("用法: bshutil <子命令>");
        return -1;
    }

    /* 请求:EXEC / CWD <绝对路径> / ARGC n / ARG <i> <值> / END。
     * 值里不能有换行;空白是安全的(服务端取"第一个空格之后的全部")。
     *
     * CWD 是**这个进程自己的**当前目录 —— 它由 procmgr 按调用方的 cwd fork 出来的,
     * 所以就是用户在终端里 cd 到的地方。服务端(主进程)那边的 cwd 是应用启动目录,
     * `rawfile get` 之类的相对路径只能靠这里带过去。getcwd 失败就整行不写
     * (同 procmgr 的做法,见 bsh_client.c),那时相对路径会被服务端拒掉。 */
    size_t cap = 64;
    for (int i = 0; i < argc; i++) cap += strlen(argv[i]) + 24;
    char* req = (char*)malloc(cap);
    if (!req) {
        SetErr("内存不足");
        return -1;
    }
    size_t len = (size_t)snprintf(req, cap, "EXEC\n");
    char cwd[4096];
    if (getcwd(cwd, sizeof cwd) != NULL)
        len += (size_t)snprintf(req + len, cap - len, "CWD %s\n", cwd);
    /* SID:本进程所在的会话号(由 procmgr 放进环境,见 common/bsh_paths.h 的
     * BSH_SESSION_ENV 与 pty_shim 的 BSH_FAKE_PTY_ID 是同一个思路)。
     * "请界面做件事"的子命令(picker/newtab)靠它决定在**哪个窗口**发生。
     * 变量没有(宿主自己发的请求、老的调用方)→ 整行不写,服务端按 0(主窗口)处理。 */
    const char* sid = getenv(BSH_SESSION_ENV);
    if (sid && *sid)
        len += (size_t)snprintf(req + len, cap - len, "SID %s\n", sid);
    len += (size_t)snprintf(req + len, cap - len, "ARGC %d\n", argc);
    for (int i = 0; i < argc; i++)
        len += (size_t)snprintf(req + len, cap - len, "ARG %d %s\n", i, argv[i]);
    len += (size_t)snprintf(req + len, cap - len, "END\n");

    int fd = Connect();
    if (fd < 0) {
        free(req);
        return -1;
    }
    if (SendFrame(fd, req, len) != 0) {
        SetErr("发送请求失败: %s", strerror(errno));
        free(req);
        close(fd);
        return -1;
    }
    free(req);

    int rc = RecvReply(fd, fd_out);
    close(fd);
    return rc;
}
