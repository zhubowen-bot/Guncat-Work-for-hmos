// bshutil/bsh_util_server.cpp — 见 bsh_util_server.h
//
// 形状照抄 procmgr/ctrl_socket.cpp(同样的 bind/chmod 0600/listen/accept 套路),
// 两处刻意的不同:
//   1) 没有 SCM_RIGHTS —— 输出走"原始字节 + 末尾 4 字节退出码"的回传,不需要传 fd;
//   2) 没有 per-connection 线程 —— 串行处理(accept → handle → close → 再 accept)。
#include "bsh_util_server.h"

#include "../common/bsh_thread.h"

#include "bsh_util_proto.h"
#include "bshutil.h"          // bshutil_exec

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <string>
#include <thread>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "BSH_Bshutil"
#include <hilog/log.h>

namespace bsh {
namespace bshutil {
namespace {

std::atomic<bool> g_running{false};
int               g_listen = -1;
std::string       g_path;
pthread_t         g_accept = 0;

/* 连接级超时。串行服务端最怕"一个卡住的客户端把后面所有人堵住",所以两个方向都设。
 * 注意这管不到 bshutil 自己等界面(picker 的 300s 阻塞发生在 bsh_ui_request 里,
 * 不是 socket 操作)。 */
const int kRecvTimeoutSec = 5;
const int kSendTimeoutSec = 10;

bool ReadExact(int fd, void* buf, size_t n) {
    char* p = static_cast<char*>(buf);
    while (n > 0) {
        ssize_t r = recv(fd, p, n, 0);
        if (r == 0) return false;
        if (r < 0) { if (errno == EINTR) continue; return false; }
        p += r;
        n -= (size_t)r;
    }
    return true;
}

bool ReadFrame(int fd, std::string* out) {
    unsigned char hdr[4];
    if (!ReadExact(fd, hdr, 4)) return false;
    uint32_t len = ((uint32_t)hdr[0] << 24) | ((uint32_t)hdr[1] << 16) |
                   ((uint32_t)hdr[2] << 8) | (uint32_t)hdr[3];
    if (len > BSHUTIL_MAX_FRAME) return false;
    out->resize(len);
    if (len == 0) return true;
    return ReadExact(fd, &(*out)[0], len);
}

bool WriteAll(int fd, const void* buf, size_t n) {
    const char* p = static_cast<const char*>(buf);
    while (n > 0) {
        /* MSG_NOSIGNAL:客户端中途死掉时拿 EPIPE,而不是被 SIGPIPE 杀掉整个应用 */
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w <= 0) { if (w < 0 && errno == EINTR) continue; return false; }
        p += w;
        n -= (size_t)w;
    }
    return true;
}

void WriteText(int fd, const char* s) { WriteAll(fd, s, strlen(s)); }

std::vector<std::string> SplitLines(const std::string& s) {
    std::vector<std::string> out;
    size_t st = 0;
    while (st <= s.size()) {
        size_t nl = s.find('\n', st);
        if (nl == std::string::npos) {
            if (st < s.size()) out.push_back(s.substr(st));
            break;
        }
        out.push_back(s.substr(st, nl - st));
        st = nl + 1;
    }
    return out;
}

/* 请求 → argv。行格式:ARGC <n>,ARG <下标> <值>(值里不能有换行;空白是安全的 ——
 * 取值是"第一个空格之后的全部",所以带空格的路径也能原样传到)。
 * CWD / SID 是"调用方的处境",只有请 UI 办事的子命令用得上。 */
bool ParseExec(const std::vector<std::string>& lines, std::vector<std::string>* argv,
               std::string* cwd, int* sid) {
    int argc = -1;
    std::vector<std::string> tmp;
    for (size_t i = 1; i < lines.size(); i++) {
        const std::string& ln = lines[i];
        if (ln == "END") break;
        if (ln.compare(0, 5, "ARGC ") == 0) {
            argc = atoi(ln.c_str() + 5);
            if (argc > 0) tmp.assign((size_t)argc, std::string());
        } else if (ln.compare(0, 4, "CWD ") == 0) {
            /* 调用方的当前目录。getcwd 失败时客户端整行不写,所以缺席是正常的。 */
            *cwd = ln.substr(4);
        } else if (ln.compare(0, 4, "SID ") == 0) {
            /* 调用方所在的会话号(客户端从 BSH_SESSION 读)。缺席 = 0 = 主窗口。 */
            *sid = atoi(ln.c_str() + 4);
        } else if (ln.compare(0, 4, "ARG ") == 0) {
            const char* p = ln.c_str() + 4;
            int idx = atoi(p);
            const char* sp = strchr(p, ' ');
            if (!sp) continue;
            if (idx < 0 || (size_t)idx >= tmp.size()) continue;
            tmp[(size_t)idx] = sp + 1;
        }
    }
    if (argc <= 0) return false;
    for (const std::string& a : tmp) if (a.empty()) return false;   // 缺参:直接拒,不猜
    *argv = std::move(tmp);
    return true;
}

void HandleClient(int fd) {
    struct timeval tv {};
    tv.tv_sec = kRecvTimeoutSec;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    tv.tv_sec = kSendTimeoutSec;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

    std::string frame;
    if (ReadFrame(fd, &frame)) {
        std::vector<std::string> lines = SplitLines(frame);
        const std::string verb = lines.empty() ? std::string() : lines[0];
        int rc = 2;
        if (verb == "EXEC") {
            std::vector<std::string> args;
            std::string cwd;
            int sid = 0;
            if (ParseExec(lines, &args, &cwd, &sid)) {
                std::vector<char*> av;
                av.reserve(args.size() + 1);
                for (std::string& s : args) av.push_back(&s[0]);
                av.push_back(nullptr);
                /* out_fd 就是这条连接:bshutil 的输出直接流回客户端,服务端不攒。
                 * bshutil_exec 只用 vdprintf 写这个 fd(不 seek/不 isatty),socket 无碍。 */
                rc = bshutil_exec((int)args.size(), av.data(), fd,
                                  cwd.empty() ? nullptr : cwd.c_str(), sid);
            } else {
                WriteText(fd, "bshutil: 请求格式错误\n");
            }
        } else {
            WriteText(fd, "bshutil: 未知请求\n");
        }
        unsigned char code[4] = {
            (unsigned char)((rc >> 24) & 0xff), (unsigned char)((rc >> 16) & 0xff),
            (unsigned char)((rc >> 8) & 0xff),  (unsigned char)(rc & 0xff),
        };
        WriteAll(fd, code, sizeof code);
    }
    shutdown(fd, SHUT_WR);   // 客户端据此读到 EOF,取末尾 4 字节当退出码
    close(fd);
}

void AcceptLoop() {
    /* 只在本线程屏蔽 SIGPIPE:客户端中途死掉时,上面往 socket 的写会拿到 EPIPE,
     * 而不是把信号送到整个进程(那会连累 ArkTS 一起挂)。不动进程级设置。 */
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &set, nullptr);

    while (g_running.load()) {
        int cli = accept(g_listen, nullptr, nullptr);
        if (cli < 0) {
            if (errno == EINTR) continue;
            if (!g_running.load()) break;
            continue;
        }
        HandleClient(cli);   // 串行:一次只服务一个连接
    }
}

}  // namespace

bool StartService(const std::string& sock_path) {
    if (g_running.load()) return true;
    if (sock_path.empty()) return false;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return false;

    struct sockaddr_un addr {};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path.c_str(), sizeof(addr.sun_path) - 1);
    unlink(sock_path.c_str());           // 上次异常退出留下的
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        OH_LOG_ERROR(LOG_APP, "bind(%{public}s) failed: %{public}s",
                     sock_path.c_str(), strerror(errno));
        close(fd);
        return false;
    }
    chmod(sock_path.c_str(), 0600);
    if (listen(fd, 8) < 0) {
        close(fd);
        unlink(sock_path.c_str());
        return false;
    }

    g_listen = fd;
    g_path = sock_path;
    g_running.store(true);
    // 大栈：这条线程串行地跑 bshutil_exec（会 fork 子进程），见 common/bsh_thread.h
    g_accept = bsh::StartThread([] { AcceptLoop(); });

    OH_LOG_INFO(LOG_APP, "bshutil service at %{public}s", sock_path.c_str());
    return true;
}

void StopService() {
    if (!g_running.exchange(false)) return;
    if (g_listen >= 0) {
        shutdown(g_listen, SHUT_RDWR);
        close(g_listen);
        g_listen = -1;
    }
    if (!g_path.empty()) unlink(g_path.c_str());
    if (g_accept) { pthread_join(g_accept, nullptr); g_accept = 0; }
}

}  // namespace bshutil
}  // namespace bsh
