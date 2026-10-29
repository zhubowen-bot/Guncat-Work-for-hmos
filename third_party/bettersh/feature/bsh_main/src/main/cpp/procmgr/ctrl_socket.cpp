// procmgr/ctrl_socket.cpp — control socket 服务端(帧协议 + SCM_RIGHTS)
//
// 为什么要有它:沙箱里没有真 exec,而"起进程"的代码只能活在主进程(libentry)
// 里 —— 命令 so 被 fork 出来之后,它自己不能 dlopen 别的 so 当作"新程序"跑
// (那样父子关系、fd、前台 pid 全乱)。所以命令 so 把"我要 exec 什么"写成请求,
// 经这个 socket 交给主进程的 procmgr,由它统一创建。
//
// 线协议(帧 = [4B 大端长度] + 文本行 payload;cmsg 只附在首段):
//
// ⚠ **第一行必须是 `CMD <动词>`** —— HandleClient 是按 `SplitKV(lines[0])` 分派的,
//   客户端往它前面插附加值(比如把 SID 插在第一行)会让整条请求落进 unknown_command
//   分支,只回一个 STATUS error。剩下的行顺序随意(各 handler 自己扫全部行)。
//   踩过:给 CMD TTY 加会话号时把 `SID` 插到了最前面 —— mksh 进不去作业控制初始化,
//   报 `j_init: tcgetpgrp failed: No such file or directory`(远端查询失败返回 -1
//   但没设 errno,那里留着 connect 之后的旧值)。
//
//   CMD CREATE
//   PROTO_VER 1
//   REQ_ID <int>
//   EXE <命令名|路径>
//   ARG <arg>            可重复;第一个是 argv[0]
//   ENV <K=V>            可重复;叠加在继承环境之上
//   CWD <path>           空 = 继承
//   KIND auto|so|elf
//   WAIT 0|1
//   FDREF <target_fd>    与 SCM_RIGHTS 收到的 fd 顺序一一对应
//   END
//
// 响应:
//   RESULT / REQ_ID <int> / STATUS ok|error / PID <int> / KIND so|elf
//   / EXIT_CODE <int>(仅 WAIT=1) / MSG <text>(仅 error) / END
//
// 另有 CMD PING(→PONG)、CMD LIST(→INFO pid=… alive=… code=…)、
// CMD TERMINATE + PID <int>(先 SIGTERM,800ms 后 SIGKILL)、
// CMD SIGNAL + SIG <int>(把信号交给当前前台进程,给 guest 里的 pty_shim 用)。
#include "procmgr.h"
#include "../common/bsh_paths.h"   /* BSH_SESSION_ENV */
#include "../common/bsh_thread.h"
#include "../tty/bsh_tty.h"

#include <termios.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/uio.h>
#include <unistd.h>

#undef LOG_TAG
#define LOG_TAG "BSH_ProcMgr"
#include <hilog/log.h>

namespace bsh {
namespace procmgr {

// procmgr.cpp 提供的内部访问
namespace detail {
const char* KindName(LaunchKind k);
bool LookupInManager(pid_t pid, ProcessInfo* out);
}  // namespace detail

namespace {

constexpr uint32_t kProtoVer = 1;
/* 同时在线的客户端上限。
 *
 * 2026-10-04 从 32 提到 512：exec_shim 现在是**两段式**（WAIT 0 建进程 + 单独的
 * `CMD WAIT` 等退出码），而那个等待连接**在目标整个运行期间都是开着的** ——
 * 于是"并发跑多少个进程"直接等于"同时占多少个连接"。numpy 的 meson 构建会按核数
 * 并发起编译，32 一下就满了，症状是
 *     /…/bin/python: cannot exec: too_many_clients
 *     /bin/sh: /…/bin/python: Permission denied
 * （后半句是 shell 把它当成了 EACCES）。512 对这台设备（8 核上下）够用有余。 */
constexpr int kMaxClients = 512;
constexpr size_t kMaxFrame = 1024 * 1024;
constexpr int kMaxCmsgFds = 16;

struct ControlState {
    std::atomic<bool> running{false};
    std::atomic<int>  active{0};
    int               listen_fd = -1;
    std::string       sock_path;
    std::thread       accept_thread;
};
ControlState g_ctrl;

bool ReadExact(int fd, void* buf, size_t n) {
    auto* p = (uint8_t*)buf;
    while (n) {
        ssize_t r = recv(fd, p, n, 0);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return false; }
        p += r; n -= (size_t)r;
    }
    return true;
}

bool WriteExact(int fd, const void* buf, size_t n) {
    auto* p = (const uint8_t*)buf;
    while (n) {
        ssize_t r = send(fd, p, n, MSG_NOSIGNAL);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return false; }
        p += r; n -= (size_t)r;
    }
    return true;
}

bool WriteFrame(int fd, const std::string& payload) {
    uint32_t len = (uint32_t)payload.size();
    uint8_t hdr[4] = { (uint8_t)(len >> 24), (uint8_t)(len >> 16),
                       (uint8_t)(len >> 8), (uint8_t)len };
    return WriteExact(fd, hdr, 4) && WriteExact(fd, payload.data(), len);
}

// 收一帧,并把首段 cmsg 里的 SCM_RIGHTS fd 收下来(已清 FD_CLOEXEC)。
bool ReadFrameWithFds(int fd, std::string* out, std::vector<int>* out_fds) {
    out->clear();
    out_fds->clear();
    char first[4096];
    char cmsg_buf[CMSG_SPACE(sizeof(int) * kMaxCmsgFds)];
    struct iovec iov { first, sizeof(first) };
    struct msghdr msg {};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg_buf;
    msg.msg_controllen = sizeof(cmsg_buf);

    ssize_t n;
    do { n = recvmsg(fd, &msg, 0); } while (n < 0 && errno == EINTR);
    if (n < 4) return false;

    for (auto* cm = CMSG_FIRSTHDR(&msg); cm; cm = CMSG_NXTHDR(&msg, cm)) {
        if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS) {
            size_t cnt = (cm->cmsg_len - CMSG_LEN(0)) / sizeof(int);
            const int* fds = (const int*)CMSG_DATA(cm);
            for (size_t i = 0; i < cnt; i++) {
                int fl = fcntl(fds[i], F_GETFD);
                if (fl >= 0) fcntl(fds[i], F_SETFD, fl & ~FD_CLOEXEC);
                out_fds->push_back(fds[i]);
            }
        }
    }

    uint32_t total = ((uint32_t)(uint8_t)first[0] << 24) |
                     ((uint32_t)(uint8_t)first[1] << 16) |
                     ((uint32_t)(uint8_t)first[2] << 8) |
                     ((uint32_t)(uint8_t)first[3]);
    if (total > kMaxFrame) {
        for (int f : *out_fds) close(f);
        out_fds->clear();
        return false;
    }
    size_t got = (size_t)(n - 4);
    if (got > total) got = total;
    out->assign(first + 4, got);
    if (got < total) {
        out->resize(total);
        if (!ReadExact(fd, &(*out)[got], total - got)) {
            for (int f : *out_fds) close(f);
            out_fds->clear();
            return false;
        }
    }
    return true;
}

std::pair<std::string, std::string> SplitKV(const std::string& line) {
    auto sp = line.find(' ');
    return sp == std::string::npos
               ? std::make_pair(line, std::string())
               : std::make_pair(line.substr(0, sp), line.substr(sp + 1));
}

void HandleCreate(const std::vector<std::string>& lines,
                  std::vector<int>& cmsg_fds, pid_t peer_pid, std::string* resp) {
    SpawnRequest req;
    int req_id = 0;
    bool proto_ok = false;
    std::vector<int> fdref_targets;

    /* "BSH_SESSION=" —— 会话号在 env 行里的前缀(见下面 ENV 分支) */
    static const char kSidPrefix[] = BSH_SESSION_ENV "=";
    constexpr size_t kSidPrefixLen = sizeof(kSidPrefix) - 1;

    for (const auto& ln : lines) {
        auto kv = SplitKV(ln);
        if      (kv.first == "PROTO_VER") proto_ok = (atoi(kv.second.c_str()) == (int)kProtoVer);
        else if (kv.first == "REQ_ID") req_id = atoi(kv.second.c_str());
        else if (kv.first == "EXE")    req.cmd = kv.second;
        else if (kv.first == "ARG")    req.argv.push_back(kv.second);
        else if (kv.first == "ENV") {
            req.env.push_back(kv.second);
            /* 会话号就从环境里取 —— 与"子进程会看到的 BSH_SESSION"同一个来源,免得
             * 两处各说各话(ENV 行是调用方 environ 的原样转发,见 bsh_client.c)。
             * 协议里**不单开一行**:这个号本来就只在 env 里存在。 */
            if (kv.second.compare(0, kSidPrefixLen, kSidPrefix) == 0)
                req.sid = atoi(kv.second.c_str() + kSidPrefixLen);
        }
        else if (kv.first == "CWD")    req.cwd = kv.second;
        else if (kv.first == "WAIT")   req.sync_wait = (kv.second == "1");
        else if (kv.first == "FDREF")  fdref_targets.push_back(atoi(kv.second.c_str()));
        else if (kv.first == "KIND") {
            if      (kv.second == "so")  req.kind_hint = KindHint::kForceSo;
            else if (kv.second == "elf") req.kind_hint = KindHint::kForceElf;
        }
    }

    auto fail = [&](const char* msg) {
        for (int f : cmsg_fds) close(f);
        cmsg_fds.clear();
        *resp = "RESULT\nREQ_ID " + std::to_string(req_id) +
                "\nSTATUS error\nMSG " + msg + "\nEND";
    };

    if (!proto_ok) { fail("proto_ver_mismatch"); return; }
    if (fdref_targets.size() != cmsg_fds.size()) { fail("fdref_count_mismatch"); return; }

    // FDREF 与 cmsg 顺序一一对应,按目标号分流:0/1/2 → stdio,>2 → extra
    for (size_t i = 0; i < cmsg_fds.size(); i++) {
        int tgt = fdref_targets[i];
        SpawnRequest::InheritedFd f { cmsg_fds[i], tgt };
        if (tgt >= 0 && tgt <= 2) req.stdio_fds.push_back(f);
        else                      req.extra_fds.push_back(f);
    }
    /* 取证：调用方到底递了哪些 fd 过来（BSH_SPAWN_TRACE=1 时打）。
     * ⚠ 开关要从 **req.env** 里找，不能用 getenv：ApplyEnv() 是在 ForkChild 里
     * （fork 之后）才把请求的环境叠加进 procmgr 的 environ，此刻还看不到。
     * 与 procmgr 侧那条 spawn-detail 配对看：一个是"我这时开着什么"，
     * 一个是"调用方指名要继承什么"，两个场景的差异一眼能对出来。 */
    bool trace = getenv("BSH_SPAWN_TRACE") != nullptr;
    for (const auto& kv : req.env)
        if (kv == "BSH_SPAWN_TRACE=1") trace = true;
    if (trace) {
        std::string s;
        for (size_t i = 0; i < cmsg_fds.size(); i++) {
            char tgt[256] = {0};
            char lnk[64];
            snprintf(lnk, sizeof lnk, "/proc/self/fd/%d", cmsg_fds[i]);
            ssize_t n = readlink(lnk, tgt, sizeof tgt - 1);
            if (n > 0) tgt[n] = 0; else tgt[0] = 0;
            s += " " + std::to_string(cmsg_fds[i]) + "->" + std::to_string(fdref_targets[i]);
            if (tgt[0]) { s += "("; s += tgt; s += ")"; }
        }
        OH_LOG_INFO(LOG_APP, "create-recv cmd=%{public}s fds=[%{public}s]",
                    req.cmd.empty() ? "?" : req.cmd.c_str(), s.c_str());
    }
    cmsg_fds.clear();   // 所有权已移交(见下方统一 close)

    if (peer_pid > 0) {
        ProcessInfo parent{};
        if (detail::LookupInManager(peer_pid, &parent)) req.caller_pid = peer_pid;
    }

    SpawnResult r = Spawn(req);

    // procmgr 侧的 source_fd 拷贝统一关闭(子进程已 dup2,自己那份也关了)
    for (const auto& f : req.stdio_fds) close(f.source_fd);
    for (const auto& f : req.extra_fds) close(f.source_fd);

    std::string& s = *resp;
    s = "RESULT\nREQ_ID " + std::to_string(req_id) + "\n";
    if (r.pid > 0) {
        s += "STATUS ok\nPID " + std::to_string(r.pid) + "\n";
        s += std::string("KIND ") + detail::KindName(r.kind) + "\n";
        if (req.sync_wait) s += "EXIT_CODE " + std::to_string(r.exit_code) + "\n";
    } else {
        s += "STATUS error\nMSG " + (r.error.empty() ? "unknown" : r.error) + "\n";
    }
    s += "END";
}

// ── CMD WAIT:等一个**已经建好**的进程结束 ────────────────────────
// 请求:CMD WAIT / PID <int> / END
// 响应:RESULT / STATUS ok / EXIT_CODE <int> / END,或 error + MSG
//
// 为什么要有它:配合 CREATE 的 `WAIT 0` 用。exec_shim 必须"建好就走",趁目标还
// 活着的时候先关掉自己的 FD_CLOEXEC fd(模拟 exec 成功时内核的动作),然后才回来
// 等退出码 —— 不这么做,subprocess 那根 error pipe 就一直开着,父进程卡死。
// 详见 shim/exec_shim.c 文件头。
//
// 这里**不自己 waitpid**:用 WAIT 0 建进程时 procmgr 已经派了后台线程回收,
// 两边抢会出乱子。所以只查进程表(那张表由那个线程更新)。
// 轮询 10ms:这就是个"等退出"的调用,进程表没有条件变量,不值得为它加一套。
static std::string HandleWait(const std::vector<std::string>& lines) {
    pid_t pid = -1;
    for (const auto& ln : lines) {
        auto kv = SplitKV(ln);
        if (kv.first == "PID") pid = (pid_t)atoi(kv.second.c_str());
    }
    if (pid <= 0) return "RESULT\nSTATUS error\nMSG bad_pid\nEND";

    for (int i = 0; i < 100 * 3600; i++) {   /* 上限 1 小时,防手滑挂死一个连接 */
        ProcessInfo info{};
        if (!detail::LookupInManager(pid, &info))
            return "RESULT\nSTATUS error\nMSG no_such_pid\nEND";
        if (!info.alive)
            return "RESULT\nSTATUS ok\nEXIT_CODE " + std::to_string(info.exit_code) + "\nEND";
        usleep(10 * 1000);
    }
    return "RESULT\nSTATUS error\nMSG wait_timeout\nEND";
}

// ── CMD TTY:会话软 tty 状态的远端读写 ──────────────────────────
// 命令 so 里的 tty_shim 不链接宿主(拿不到 bsh_tty_*),而"哪些 fd 是 tty"这类
// fd 身份只能本地判断 —— 所以本地留一张小表;termios/winsize/前台进程组这些
// 共享状态则经这里读写,主进程的 bsh_tty 是唯一真相。
//
// 请求:CMD TTY / [SID n] / OP <op> / [TIOLEN n / TIO <hex>] / [ROWS r] / [COLS c] / [PGRP n] / END
// 响应:TTY / STATUS ok|error / [TIO <hex>] / [ROWS r] / [COLS c] / [PGRP n] / MSG / END
//
// SID = 会话号(0 = 主窗口的 bsh;>0 = `bshutil newtab` 开的 tab),客户端从
// BSH_SESSION 环境变量读出来带上(见 bsh_client.h)。缺席按 0 —— 宿主自己发的请求
// 与老的调用方都属于这种。为什么要它:每个会话的 tty 状态是**分开的**
// (见 tty/bsh_tty.h),不带会话号就会把 tab B 里 vim 的网格尺寸问到 tab A 头上。
std::string ToHex(const unsigned char* p, size_t n) {
    static const char* d = "0123456789abcdef";
    std::string s;
    s.reserve(n * 2);
    for (size_t i = 0; i < n; i++) {
        s.push_back(d[p[i] >> 4]);
        s.push_back(d[p[i] & 0xf]);
    }
    return s;
}

bool FromHex(const std::string& s, unsigned char* out, size_t n) {
    if (s.size() != n * 2) return false;
    auto v = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    for (size_t i = 0; i < n; i++) {
        int hi = v(s[i * 2]), lo = v(s[i * 2 + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (unsigned char)((hi << 4) | lo);
    }
    return true;
}

void HandleTty(const std::vector<std::string>& lines, std::string* resp) {
    std::string op;
    std::string tio_hex;
    long tio_len = -1;
    int rows = 0, cols = 0, pgrp = 0, sid = 0;
    for (const auto& ln : lines) {
        auto kv = SplitKV(ln);
        if      (kv.first == "OP")     op = kv.second;
        else if (kv.first == "SID")    sid = atoi(kv.second.c_str());
        else if (kv.first == "TIO")    tio_hex = kv.second;
        else if (kv.first == "TIOLEN") tio_len = atol(kv.second.c_str());
        else if (kv.first == "ROWS")   rows = atoi(kv.second.c_str());
        else if (kv.first == "COLS")   cols = atoi(kv.second.c_str());
        else if (kv.first == "PGRP")   pgrp = atoi(kv.second.c_str());
    }

    std::string s = "TTY\n";
    auto ok  = [&]() { s += "STATUS ok\n"; };
    auto bad = [&](const char* why) { s += std::string("STATUS error\nMSG ") + why + "\n"; };

    if (op == "termios_get") {
        struct termios t {};
        if (bsh_tty_session_tcgetattr(sid, &t) != 0) { bad("tcgetattr_failed"); }
        else {
            ok();
            s += "TIO " + ToHex((const unsigned char*)&t, sizeof t) + "\n";
        }
    } else if (op == "termios_set") {
        // 双方是同一份 SDK/musl,布局一致;长度对不上直接拒(防止 ABI 漂移)
        if (tio_len != (long)sizeof(struct termios)) { bad("termios_size_mismatch"); }
        else {
            struct termios t {};
            if (!FromHex(tio_hex, (unsigned char*)&t, sizeof t)) { bad("bad_tio_hex"); }
            else if (bsh_tty_session_tcsetattr(sid, &t) != 0) { bad("tcsetattr_failed"); }
            else ok();
        }
    } else if (op == "ws_get") {
        uint16_t r = 0, c = 0;
        bsh_tty_session_get_winsize(sid, &r, &c);
        ok();
        s += "ROWS " + std::to_string(r) + "\n";
        s += "COLS " + std::to_string(c) + "\n";
    } else if (op == "ws_set") {
        bsh_tty_session_set_winsize(sid, (uint16_t)rows, (uint16_t)cols);
        ok();
    } else if (op == "pgrp_get") {
        ok();
        s += "PGRP " + std::to_string(bsh_tty_session_get_pgrp(sid)) + "\n";
    } else if (op == "pgrp_set") {
        bsh_tty_session_set_pgrp(sid, pgrp);
        ok();
    } else {
        bad("unknown_tty_op");
    }
    s += "END";
    *resp = s;
}

void HandleClient(int fd) {
    int n = g_ctrl.active.fetch_add(1) + 1;
    if (n > kMaxClients) {
        WriteFrame(fd, "RESULT\nSTATUS error\nMSG too_many_clients\nEND");
        close(fd);
        g_ctrl.active.fetch_sub(1);
        return;
    }

    struct ucred peer {};
    socklen_t plen = sizeof(peer);
    pid_t peer_pid = -1;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &plen) == 0) peer_pid = peer.pid;

    while (g_ctrl.running.load()) {
        std::string frame;
        std::vector<int> cmsg_fds;
        if (!ReadFrameWithFds(fd, &frame, &cmsg_fds)) break;

        std::vector<std::string> lines;
        size_t st = 0;
        while (st <= frame.size()) {
            size_t nl = frame.find('\n', st);
            if (nl == std::string::npos) {
                if (st < frame.size()) lines.push_back(frame.substr(st));
                break;
            }
            lines.push_back(frame.substr(st, nl - st));
            st = nl + 1;
        }
        if (lines.empty()) { for (int f : cmsg_fds) close(f); continue; }

        std::string resp;
        auto cmd = SplitKV(lines[0]);
        if (cmd.first == "CMD" && cmd.second == "CREATE") {
            HandleCreate(lines, cmsg_fds, peer_pid, &resp);
        } else {
            for (int f : cmsg_fds) close(f);
            if (cmd.first == "CMD" && cmd.second == "PING") {
                resp = "PONG\nEND";
            } else if (cmd.first == "CMD" && cmd.second == "TERMINATE") {
                for (const auto& ln : lines) {
                    auto kv = SplitKV(ln);
                    if (kv.first == "PID") Terminate((pid_t)atoi(kv.second.c_str()));
                }
                resp = "RESULT\nSTATUS ok\nEND";
            } else if (cmd.first == "CMD" && cmd.second == "SIGNAL") {
                /* 把信号交给**那个会话**当前前台的进程。给 guest 里的 pty_shim 用:它
                 * 收到 Ctrl+C 时只能杀掉自己那侧的委托中间体,真正干活的进程是 procmgr
                 * fork 出来的、不在它的进程组里(见 procmgr.h 的 SignalForeground)。
                 * SID 由客户端从 BSH_SESSION 插进请求(见 bsh_client.c),缺席按 0。 */
                int sig = 0, sid = 0;
                for (const auto& ln : lines) {
                    auto kv = SplitKV(ln);
                    if      (kv.first == "SIG") sig = atoi(kv.second.c_str());
                    else if (kv.first == "SID") sid = atoi(kv.second.c_str());
                }
                resp = SignalForeground(sid, sig)
                     ? "RESULT\nSTATUS ok\nEND"
                     : "RESULT\nSTATUS error\nMSG no_foreground\nEND";
            } else if (cmd.first == "CMD" && cmd.second == "LIST") {
                resp = "LIST\n";
                for (auto& p : ListProcesses()) {
                    resp += "INFO pid=" + std::to_string(p.pid)
                          + " alive=" + (p.alive ? "1" : "0")
                          + " code=" + std::to_string(p.exit_code)
                          + " cmd=" + p.cmd + "\n";
                }
                resp += "END";
            } else if (cmd.first == "CMD" && cmd.second == "WAIT") {
                resp = HandleWait(lines);
            } else if (cmd.first == "CMD" && cmd.second == "TTY") {
                HandleTty(lines, &resp);
            } else {
                resp = "RESULT\nSTATUS error\nMSG unknown_command\nEND";
            }
        }
        if (!WriteFrame(fd, resp)) break;
    }
    close(fd);
    g_ctrl.active.fetch_sub(1);
}

void AcceptLoop() {
    while (g_ctrl.running.load()) {
        int cli = accept(g_ctrl.listen_fd, nullptr, nullptr);
        if (cli < 0) {
            if (errno == EINTR) continue;
            if (!g_ctrl.running.load()) break;
            continue;
        }
        // 大栈：这条线程不但要跑协议解析，还要 **fork** —— fork 只保留调用线程，
        // 子进程（elfloader 装载 guest、命令 so 就地跑）吃的就是这条线程的栈。
        // musl 默认 128KB 对 Electron 那种 guest 直接不够（见 common/bsh_thread.h）。
        bsh::StartThreadDetached([cli] { HandleClient(cli); });
    }
}

}  // namespace

bool StartControlSocket(const std::string& sock_path) {
    if (g_ctrl.running.load()) return true;
    if (sock_path.empty()) return false;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return false;

    struct sockaddr_un addr {};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path.c_str(), sizeof(addr.sun_path) - 1);
    unlink(sock_path.c_str());   // 上次异常退出留下的
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

    g_ctrl.listen_fd = fd;
    g_ctrl.sock_path = sock_path;
    g_ctrl.running.store(true);
    g_ctrl.accept_thread = std::thread(AcceptLoop);

    // 注入环境变量:之后 fork 的子进程天然继承,命令 so 里的 bsh_client
    // 据此找到 socket 反向请求 spawn。必须在第一个子进程之前设好。
    setenv("BSH_CTRL_SOCK", sock_path.c_str(), 1);

    OH_LOG_INFO(LOG_APP, "control socket at %{public}s", sock_path.c_str());
    return true;
}

void StopControlSocket() {
    if (!g_ctrl.running.exchange(false)) return;
    if (g_ctrl.listen_fd >= 0) {
        shutdown(g_ctrl.listen_fd, SHUT_RDWR);
        close(g_ctrl.listen_fd);
        g_ctrl.listen_fd = -1;
    }
    if (!g_ctrl.sock_path.empty()) unlink(g_ctrl.sock_path.c_str());
    if (g_ctrl.accept_thread.joinable()) g_ctrl.accept_thread.join();
}

}  // namespace procmgr
}  // namespace bsh
