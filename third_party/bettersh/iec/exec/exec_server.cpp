// exec/exec_server.cpp — ExecServer implementation
#include "exec_server.h"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <functional>
#include <atomic>
#include <thread>
#include <unordered_map>

#include "caps.h"
#include "constant.h"
#include "elf.h"
#include "exec_loader.h"
#include "exec_ncp.h"
#include "exec_ncp_refusal.h"
#include "exec_qemu.h"
#include "exec_route.h"
#include "exec_shebang.h"
#include "exec_so.h"
#include "exec_types.h"
#include "logger/logger.h"
#include "proc.h"

struct SpawnResult {
    pid_t      pid = -1;
    LaunchKind kind = LaunchKind::kAuto;    // what the child was actually started as
    int        exit_code = -1;
    std::string error;
};

struct ProcessInfo {
    pid_t       pid = 0;
    pid_t       parent_pid = 0;
    pid_t       standin_pid = 0;
    PrimaryLaunchKind prikind = PrimaryLaunchKind::kAuto;
    LaunchKind  kind = LaunchKind::kAuto; // todo: seckind
    std::string cmd;
    std::string job;      // IEC_JOB at creation time; empty when the caller did not set one
    int64_t     start_time_ms = 0;
    bool        alive = true;
    // The raw status word waitpid() returned, which is what OP_WAIT answers with:
    // it is the only form that still carries _how_ the child ended, so the client
    // can tell an ordinary exit from a signal death. Meaningful once alive is
    // false; both fields are filled at the same moment, from the same call.
    int         status = 0;
    // The same ending rendered for a human -- an exit code, or 128 + signal for a
    // signal death. Kept beside the raw word rather than instead of it because the
    // raw word alone cannot be read at a glance in a log; nothing branches on it.
    int         exit_code = -1;
};

// Every child this server started, keyed by pid. The spawn path writes it, and the
// request handlers (onWait, onSignal) read it alongside the reaper in onTick().
// All of them run on the thread that executes run(), so there is no second thread
// to race with and this deliberately has no lock; anything added here has to stay
// on that thread, or the first thing it needs is a mutex.
static std::unordered_map<pid_t, ProcessInfo> procmap;

// The caller runs in a child forked from this server, so /proc/self/exe in it
// names the server rather than the program the caller really is. 
static const std::string& ServerExePath() {
    static const std::string path = [] {
        char buf[4096];
        ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
        if (n <= 0) return std::string();
        buf[n] = '\0';
        return std::string(buf);
    }();
    return path;
}

static bool IsServerSelfPath(const std::string& path) {
    if (path == "/proc/self/exe") return true;
    const std::string& self = ServerExePath();
    return !self.empty() && path == self;
}

static bool ResolveSelfPath(std::string* path, pid_t caller) {
    if (!IsServerSelfPath(*path)) return false;

    const ProcessInfo* best = nullptr;
    for (const auto& kv : procmap) {
        const ProcessInfo& info = kv.second;
        if (info.standin_pid != caller || info.cmd.empty()) continue;
        if (best == nullptr ||
            (info.alive && !best->alive) ||
            (info.alive == best->alive && info.start_time_ms > best->start_time_ms))
            best = &info;
    }

    if (best == nullptr) {
        auto it = procmap.find(caller);
        if (it != procmap.end() && !it->second.cmd.empty()) best = &it->second;
    }

    if (best == nullptr || best->cmd == *path) return false;
    *path = best->cmd;
    return true;
}

/* ------------------------------------------------------------------ */
/* Resolver                                                           */
/* ------------------------------------------------------------------ */
/* ResolveKind() itself lives in exec_route.cpp: it is a pure question about a path
 * and the capability word, and keeping it in a file of its own is what lets a host
 * test link it without dragging in the whole server. */

static bool SearchesPath(CallMethod method) {
    switch (method) {
        case CALL_EXECVP:
        case CALL_EXECVPE:
        case CALL_EXECLP:
            return true;
        default:
            break;
    }
    return false;
}

/* ------------------------------------------------------------------ */
/* Common Helpers                                                     */
/* ------------------------------------------------------------------ */

// CLOCK_MONOTONIC rather than the wall clock: these stamps are only ever compared
// with each other, and a clock step must not make one process look older than the
// parent that started it.
static int64_t NowMillis() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

static bool ReplacesCaller(CallMethod method) {
    switch (method) {
        case CALL_EXECVE:
        case CALL_EXECV:
        case CALL_EXECVP:
        case CALL_EXECVPE:
        case CALL_EXECL:
        case CALL_EXECLP:
        case CALL_EXECLE:
            return true;
        case CALL_METHOD_END:
            break;
    }
    return false;
}

// The pid to record as the parent of the program a request asks for.
//
// An exec replaces the caller, so the program belongs where the caller was: under
// the caller's parent, not under the caller. Recording the caller instead would
// put the program one level too deep -- as a child of a process that is only
// standing in for it -- and the tree would then say the caller still exists and
// owns a child, which is exactly what an exec has just undone.
static pid_t ParentPidFor(const SpawnRequest& req) {
    pid_t ppid = 0;

    if (!ReplacesCaller(req.call_method)) return req.caller_pid;

    ppid = iec_parent_pid(req.caller_pid);
    if (ppid > 0) return ppid;

    // The caller can be gone by now: a stand-in that was killed outright, or one
    // whose exec raced its own exit. There is no parent to name in that case, and
    // refusing the request would turn a vanished client into a failure to start a
    // program that is perfectly startable. The caller's own pid is the fallback --
    // it is at least the process the request came from -- and it is reported, so
    // that a table full of entries filed under a dead pid is not a silent thing.
    Logger::GetInstance()->LogW(
        "[exec] no parent for caller %d; recording the caller as the parent",
        (int)req.caller_pid);
    return req.caller_pid;
}

/* ------------------------------------------------------------------ */
/* Routers for All Spawn Kind                                         */
/* ------------------------------------------------------------------ */

pid_t SpawnExec(const SpawnRequest& req) {
    // execve() takes plain C arrays, and a vector<string> is not one. The strings
    // themselves stay valid for the duration of the call, which is all that is
    // needed: a successful execve never comes back here.
    std::vector<char*> argv;
    std::vector<char*> envp;
    argv.reserve(req.argv.size() + 1);
    envp.reserve(req.env.size() + 1);
    for (const std::string& s : req.argv) argv.push_back(const_cast<char*>(s.c_str()));
    for (const std::string& s : req.env)  envp.push_back(const_cast<char*>(s.c_str()));
    argv.push_back(nullptr);
    envp.push_back(nullptr);

    if (!req.cwd.empty() && chdir(req.cwd.c_str()) != 0) {
        static const char msg[] = "[exec] chdir failed, started in default path.\n";
        if (write(STDERR_FILENO, msg, sizeof msg - 1)) {}
    }

    execve(req.path.c_str(), argv.data(), envp.data());
    return -1;   // reached only when execve failed
}

/* ------------------------------------------------------------------ */
/* Inherited fds                                                      */
/* ------------------------------------------------------------------ */

// A temporary copy of a source fd is taken at or above this number. It only has
// to sit above every target the request may name (0, 1 and 2), so that taking
// the copy cannot itself overwrite a descriptor that is still to be filled in.
constexpr int kTempFdFloor = 10;

// Moves the fds the request carried into the descriptors the request named.
// Reports whether that worked; a false is fatal for the child.
//
// This runs in the child of fork(), before execve(), where only async-signal-safe
// calls are allowed: dup2(), close() and fcntl() are on that list, printf() and
// malloc() are not. That is why a failure comes back as a return value instead of
// a message, and why the caller reports it with write(2).
//
// The fds that arrived with the request but were not named as targets need no
// closing. The server's poll loop receives them with MSG_CMSG_CLOEXEC, so every
// one of them is close-on-exec and the execve() below drops it; the descriptors
// dup2() creates in their place do not carry that flag -- dup2() clears
// FD_CLOEXEC on the new fd, which is POSIX behaviour -- and that is exactly what
// the child wants, so nothing has to clear or set it by hand here.
bool InstallInheritedFds(const SpawnRequest& req) {
    const size_t n = req.stdio_fds.size();
    int temp[kMaxFds];
    size_t i, j;

    for (i = 0; i < n; i++) temp[i] = -1;

    // dup2(src, tgt) closes tgt before it duplicates onto it, so an entry whose
    // source is also the target of another entry would lose that source before it
    // is used: with {5 -> 0, 0 -> 1}, the first dup2 destroys the fd the second
    // one is supposed to read. The traffic this shim sends cannot look like that
    // -- the sources are the descriptors recvmsg() just installed in the server,
    // far above the 0/1/2 targets -- but the mapping arrives in a request, so it
    // is checked instead of assumed: a source that some other entry targets is
    // duplicated to a free high fd first, and the targets are then filled from
    // the copies.
    for (i = 0; i < n; i++) {
        for (j = 0; j < n; j++)
            if (j != i && req.stdio_fds[j].target_fd == req.stdio_fds[i].source_fd) break;
        if (j == n) continue;
        temp[i] = fcntl(req.stdio_fds[i].source_fd, F_DUPFD, kTempFdFloor);
        if (temp[i] < 0) return false;
    }

    for (i = 0; i < n; i++) {
        int source = temp[i] >= 0 ? temp[i] : req.stdio_fds[i].source_fd;
        if (dup2(source, req.stdio_fds[i].target_fd) < 0) return false;
    }

    // Each target holds its own copy of the descriptor now, so the temporary
    // names can go; leaving them would be a leak into the exec'd program.
    for (i = 0; i < n; i++)
        if (temp[i] >= 0) close(temp[i]);
    return true;
}

/* ------------------------------------------------------------------ */
/* Overall Spawn and Terimate Function                                */
/* ------------------------------------------------------------------ */

// Exit code of a child that never got to run the program at all. 127 is the
// shell's "command not found", so it cannot be confused with a status the program
// produced itself.
constexpr int kExecFailedExit = 127;

// Puts the child's signal mask back the way a program is entitled to start: empty.
//
// The child is forked from an event loop thread, and those run with SIGINT and
// SIGTERM blocked -- main.cpp blocks them so that a second signal cannot cut the
// server's own shutdown short (see the sigsuspend there). A mask is inherited
// across fork() and survives execve(), so without this every program started here
// would begin life unable to take those two at all: a ^C forwarded to it (see
// onSignal) would sit pending in the kernel until something unblocked it, which
// for most programs is never, and the signal would look like it had been ignored.
//
// Only the mask needs this. execve() gives every caught signal its default
// disposition on its own, and the server ignores none of them. A disposition of
// SIG_IGN such as nohup leaves behind is inherited by design, and is not the
// server's to override.
//
// sigprocmask() is on the list of calls a child of fork() may make.
void ClearInheritedSignalMask() {
    sigset_t empty;
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, nullptr);
}

// execve resets every caught signal to its default disposition; an ignored
// signal stays ignored. kExec gets that from the kernel, but the routes that do
// not exec (kSo, kLoader) run in a child of this process and would otherwise
// keep the app's handlers -- including the runtime's shutdown handler, which
// asserts that it runs in the main process and aborts with SIGTRAP when it is
// not. Do what execve would have done before entering the program.
void ResetSignalDispositions() {
    struct sigaction old, dfl;

    for (int sig = 1; sig < NSIG; sig++) {
        if (sigaction(sig, nullptr, &old) != 0) continue;
        if (old.sa_handler == SIG_IGN || old.sa_handler == SIG_DFL) continue;
        memset(&dfl, 0, sizeof dfl);
        dfl.sa_handler = SIG_DFL;
        sigemptyset(&dfl.sa_mask);
        sigaction(sig, &dfl, nullptr);
    }
}

void ApplyRequestEnvironment(const SpawnRequest& req) {
    for (const std::string& entry : req.env) {
        const size_t eq = entry.find('=');
        if (eq == std::string::npos || eq == 0) continue;
        setenv(entry.substr(0, eq).c_str(), entry.substr(eq + 1).c_str(), 1);
    }
}

[[noreturn]] void StartByKind(LaunchKind kind, const SpawnRequest& req) {
    switch (kind) {
        case LaunchKind::kExec:
            SpawnExec(req);   /* returns when execve failed */
            {
                static const char msg[] = "[exec] exec failed\n";
                if (write(STDERR_FILENO, msg, sizeof msg - 1)) {}
            }
            _exit(kExecFailedExit);
        case LaunchKind::kSo:
            SpawnSo(req);
            {
                static const char msg[] = "[exec] so failed\n";
                if (write(STDERR_FILENO, msg, sizeof msg - 1)) {}
            }
            _exit(kExecFailedExit);
        case LaunchKind::kQemu_x86_64:
        case LaunchKind::kQemu_aarch64:
            SpawnQemu(req);
            {
                static const char msg[] = "[exec] qemu failed\n";
                if (write(STDERR_FILENO, msg, sizeof msg - 1)) {}
            }
            _exit(kExecFailedExit);
        case LaunchKind::kLoader:
            SpawnLoader(req);
            {
                static const char msg[] = "[exec] loader failed\n";
                if (write(STDERR_FILENO, msg, sizeof msg - 1)) {}
            }
            _exit(kExecFailedExit);
        case LaunchKind::kShebang:
            SpawnShebang(req);   /* returns for a script that cannot be followed */
            {
                static const char msg[] = "[exec] shebang failed\n";
                if (write(STDERR_FILENO, msg, sizeof msg - 1)) {}
            }
            _exit(kExecFailedExit);
        default:
            // kAuto is settled before this is reached, and kUnexecutable has no
            // router.
            {
                static const char msg[] = "[exec] launch kind unsupported\n";
                if (write(STDERR_FILENO, msg, sizeof msg - 1)) {}
            }
            _exit(kExecFailedExit);
    }
}

/* Set once the platform has refused a native child process on this device.
 *
 * The probe only proves the API is present; an application can still be told
 * "not allowed" (a code like 16010004) on every attempt. Remembering that turns
 * a per-command delay and a per-command warning into one line at startup, and it
 * is what makes the fork fallback cheap rather than merely correct.
 *
 * It is latched only for failures that say something about the device. A request
 * the NCP route cannot carry (a non-.so launch kind, a malformed launcher) must
 * not be remembered, or the next perfectly startable command pays for it. */
static std::atomic<bool> g_ncp_refused{false};

static pid_t StartChild(SpawnRequest* req, LaunchKind kind, std::string* why) {
    // The launcher may name the relationship it needs; 0 leaves the choice here.
    if (kind == LaunchKind::kSo) {
        SoLauncher launcher;
        if (ResolveSoLauncher(req->path, launcher, nullptr)) {
            req->prikind = launcher.primary;
        }
    }
    const PrimaryLaunchKind requested = req->prikind;
    
    if (requested == PrimaryLaunchKind::kNcp ||
        (requested == PrimaryLaunchKind::kAuto && Caps().ncp == 1 &&
         !g_ncp_refused.load())) {
        req->prikind = PrimaryLaunchKind::kNcp;
        std::string ncp_error;
        const pid_t pid = SpawnNcp(*req, kind, &ncp_error);
        if (pid > 0) {
            Logger::GetInstance()->LogI("[exec] started pid %d as a native child process",
                                        (int)pid);
            return pid;
        }
        Logger::GetInstance()->LogW("[exec] native child process refused: %s",
                                    ncp_error.c_str());
        // Only a refusal by the platform itself is worth remembering. A message
        // such as "only so file for now!" or "bad launcher ..." describes *this
        // request* rather than the device, and latching on it would disable a
        // working NCP route for every later launcher -- on a device without fork,
        // for every command after the first non-.so one. The prefix list lives in
        // exec_ncp_refusal.h so a host test can pin it.
        if (IsNcpPlatformRefusal(ncp_error)) g_ncp_refused.store(true);
        // A launcher that asked for "auto" must not lose the route that works:
        // the probe only proves the library exports the entry point, not that this
        // application is allowed to start a child with it. Fall through to fork --
        // which is what auto would have chosen had the probe answered 0. An
        // explicit kNcp still fails, because that is what it asked for.
        if (requested == PrimaryLaunchKind::kNcp) {
            if (why) *why = "native child process refused: " + ncp_error;
            return -1;
        }
    }

    if (requested == PrimaryLaunchKind::kFork ||
        (requested == PrimaryLaunchKind::kAuto && Caps().fork == 1)) {
        req->prikind = PrimaryLaunchKind::kFork;

        pid_t pid = fork();
        if (pid < 0) {
            const int err = errno;
            Logger::GetInstance()->LogE("[exec] fork failed: %s", strerror(err));
            if (why) *why = "fork failed: " + std::string(strerror(err));
            return -1;
        }
        if (pid != 0) return pid;

        ClearInheritedSignalMask();
        ResetSignalDispositions();

        setpgid(0, 0);

        if (!InstallInheritedFds(*req)) {
            static const char msg[] = "[exec] inherited fd setup failed\n";
            if (write(STDERR_FILENO, msg, sizeof msg - 1)) {}
            _exit(kExecFailedExit);
        }
        ApplyRequestEnvironment(*req);
        StartByKind(kind, *req);
    }

    if (requested == PrimaryLaunchKind::kInProc) {
        // Running a program in this process is not implemented.
        if (why) *why = "in-process launch is not implemented";
        return -1;
    }

    req->prikind = PrimaryLaunchKind::kInProc;
    if (why) {
        *why = "no launch route (fork=" + std::to_string(Caps().fork) +
               ", ncp=" + std::to_string(Caps().ncp) + ")";
    }
    return -1;
}

SpawnResult Spawn(SpawnRequest req) {
    SpawnResult res;
    if (req.path.empty()) { res.error = "path is empty"; return res; }

    // kAuto means the caller left the decision to us. It is settled before the
    // fork so that both sides agree on what is being started.
    res.kind = req.kind_hint == LaunchKind::kAuto ? ResolveKind(req.path) : req.kind_hint;

    std::string start_error;
    const pid_t pid = StartChild(&req, res.kind, &start_error);
    if (pid < 0) {
        res.error = start_error.empty() ? ("cannot start " + req.path) : start_error;
        return res;
    }

    // parent
    ProcessInfo info;
    info.pid = pid;
    // Where the program belongs in the process tree, which the call method decides;
    // see ParentPidFor. Deliberately not getpid(): that is the kernel's answer to
    // "who forked this", and nothing here asks that question.
    info.parent_pid = ParentPidFor(req);
    info.standin_pid = req.caller_pid;
    info.kind = res.kind;
    info.prikind = req.prikind;
    info.cmd = req.path;
    info.job = req.job;
    info.start_time_ms = NowMillis();
    info.alive = true;
    procmap[info.pid] = info;

    // sync_wait is still not honoured here: this call returns to the client as soon
    // as the fork is done. The waiting is done by the client, which polls OP_WAIT
    // for this pid once it has the reply. The entry above starts out alive, and its
    // exit is filled in later -- by the reaper in onTick(), or by onWait() for a
    // client that is polling harder than the event loop passes.
    res.pid = pid;
    return res;
}

// Ends a child this server started, gently first and with SIGKILL if it is still
// there 800 ms later. Nothing calls it: the signal a stand-in forwards now goes
// straight out through kill() in onSignal() below, because there is nothing to
// escalate to -- the signal has already been chosen by whoever sent it. It is
// left here as the place a policy would go if one is ever wanted (a deadline on
// a child that ignored what it was sent, say).
void Terminate(pid_t pid) {
    if (pid <= 0) return;
    kill(pid, SIGTERM);
    std::thread([pid]() {
        usleep(800 * 1000);
        if (kill(pid, 0) == 0) kill(pid, SIGKILL);
    }).detach();
}

/* ------------------------------------------------------------------ */
/* Jobs                                                                */
/* ------------------------------------------------------------------ */

// The job id carried by an environment, or an empty string.
//
// The value is whatever followed "IEC_JOB=" in the request, which is the same
// value the child will see. Only the first entry counts: an environment cannot
// hold two values for one name, and a request that does is malformed rather
// than ambiguous.
static std::string JobOfEnv(const std::vector<std::string>& env) {
    static const char kPrefix[] = "IEC_JOB=";

    for (const std::string& entry : env)
        if (entry.compare(0, sizeof kPrefix - 1, kPrefix) == 0)
            return entry.substr(sizeof kPrefix - 1);
    return std::string();
}

// Every live process of one job. Only called on the server thread, which is the
// only place procmap is touched.
static std::vector<pid_t> JobPids(const std::string& job) {
    std::vector<pid_t> pids;

    if (job.empty()) return pids;
    for (const auto& kv : procmap)
        if (kv.second.alive && kv.second.job == job) pids.push_back(kv.first);
    return pids;
}

// Sends a signal to each process, and to its process group when it leads one.
//
// The group is what makes a single SIGTERM reach a pipeline or a build: the
// routes that fork put each program in a group of its own (setpgid(0, 0) in
// StartChild), and the programs a shell starts stay in that group. A pid that
// does not lead a group answers ESRCH for the group form, which is not a
// failure -- the pid form above still reaches it.
static void SignalPids(const std::vector<pid_t>& pids, int sig) {
    for (pid_t pid : pids) {
        if (pid <= 0) continue;
        if (getpgid(pid) == pid) kill(-pid, sig);
        kill(pid, sig);
    }
}


/* ------------------------------------------------------------------ */
/* Exec Server                                                        */
/* ------------------------------------------------------------------ */

ExecServer::ExecServer(const std::string& path) : SockServer(path) {
    using namespace std::placeholders;
    registerHandler(OP_PING,       std::bind(&ExecServer::onPing,       this, _1, _2));
    registerHandler(OP_PONG,       std::bind(&ExecServer::onPong,       this, _1, _2));
    registerHandler(OP_EXECUTE,    std::bind(&ExecServer::onExecute,    this, _1, _2));
    registerHandler(OP_WAIT,       std::bind(&ExecServer::onWait,       this, _1, _2));
    registerHandler(OP_SIGNAL,     std::bind(&ExecServer::onSignal,     this, _1, _2));
    registerHandler(OP_TERMINATE_JOB,
                    std::bind(&ExecServer::onTerminateJob, this, _1, _2));
    registerHandler(OP_LIST,       std::bind(&ExecServer::onList,       this, _1, _2));
}

// Notes how a child ended. This is one function rather than two copies because
// the same waitpid() result reaches procmap from two directions: onTick() reaps a
// child before anybody asked about it, and onWait() reaps one on demand because a
// client is waiting for it. Both have to leave the entry saying the same thing.
static void RecordExit(ProcessInfo& info, int status) {
    info.alive = false;
    // The raw word, which is what OP_WAIT hands back: it is the only form that
    // still says whether the child exited or was killed by a signal.
    info.status = status;
    // The same ending made readable for a log. A signal death has no exit code of
    // its own, so it is rendered the way a shell renders it -- 128 + the signal
    // number -- which stops "killed by SIGTERM" from looking like an ordinary exit.
    // With WNOHANG and no WUNTRACED/WCONTINUED, waitpid() only ever returns exits
    // and signal deaths, so the last arm is unreachable and only there to leave the
    // field defined.
    info.exit_code = WIFEXITED(status)   ? WEXITSTATUS(status)
                   : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
                                         : -1;
}

// Folds the endings of native child processes into the table. They are not this
// process's children, so waitpid() never reports them; the platform's callback queues
// them and this is the only place that touches the table.
static void DrainNativeExits() {
    DrainNcpExits([](pid_t pid, int status) {
        auto it = procmap.find(pid);
        if (it != procmap.end()) RecordExit(it->second, status);
    });
}

// Runs once per pass of the poll loop, whether or not anything arrived, which is
// what makes it the right place to notice children that exited while the server
// was idle: a request-driven handler would only run again on the next request,
// and by then a pile of zombies is already sitting there.
//
// Reaping here rather than in a SIGCHLD handler is deliberate. waitpid() is itself
// async-signal-safe, but the bookkeeping that has to follow it is not: updating
// procmap can allocate, and the allocator is not reentrant. The signal can also be
// delivered to any thread, including one that is in the middle of touching that
// map. Neither problem exists here -- this runs on the thread that runs run(), the
// same one that runs onExecute, so procmap needs no lock.
//
// waitpid(-1, ...) collects any child of this process, whoever started it, so this
// rests on exec being the only service that forks: the tty service forks nothing
// (forkpty() is done on the client side). If that ever changes, the new forker has
// to reap its own children, or its exit statuses would be consumed here. A pid
// that is not in procmap is skipped for the same reason rather than treated as an
// error.
//
// One ending this hook does not catch: a stand-in killed outright, with SIGKILL or
// by the machine going down. No handler runs in the client for SIGKILL, so nothing
// is ever asked of this server and the child stays here as a live entry with
// nobody left to collect it. What it would take is a check in this same loop --
// the only place with the whole table in hand -- that drops the children of a
// client that is gone: for every entry still alive, test whether the client that
// asked for it is still there, and end the child if not. The pid to test is
// ProcessInfo::standin_pid, which Spawn() fills from SpawnRequest::caller_pid, and
// the request carries it now. Not implemented.
void ExecServer::onTick() {
    // Native child processes are not this process's children, so waitpid() below
    // never reports them; their endings arrive through the platform's callback and
    // are folded into the same table here.
    DrainNativeExits();

    // Escalate the SIGTERMs whose grace period has run out. Checked against the
    // table rather than fired blindly: by the time this passes, an entry that is
    // gone may have been replaced by a different process with the same pid, and
    // signing that one would be killing a stranger. The start time is what tells
    // the two apart.
    if (!pending_kills_.empty()) {
        const int64_t now = NowMillis();
        for (auto it = pending_kills_.begin(); it != pending_kills_.end();) {
            if (it->due_ms > now) { ++it; continue; }

            const auto found = procmap.find(it->pid);
            if (found != procmap.end() && found->second.alive &&
                found->second.job == it->job &&
                found->second.start_time_ms == it->start_ms) {
                // A group of its own if it leads one; the pid form covers the
                // routes that do not (a native child process, for one).
                if (getpgid(it->pid) == it->pid) kill(-it->pid, SIGKILL);
                kill(it->pid, SIGKILL);
            }
            it = pending_kills_.erase(it);
        }
    }

    // In a loop, because several children can have exited since the previous pass
    // and waitpid() reports them one at a time. WNOHANG so this can never stall
    // the loop on a child that is still running.
    for (;;) {
        int status = 0;
        pid_t pid = waitpid(-1, &status, WNOHANG);
        // 0 means children exist but none has exited yet, -1 that there are none
        // left or the call failed; both end the loop.
        if (pid <= 0) break;

        auto it = procmap.find(pid);
        if (it == procmap.end()) continue;
        RecordExit(it->second, status);
    }
}

bool ExecServer::onPing(const Packet& req, Reply& reply) {
    reply.body = req.body;
    return true;
}

bool ExecServer::onPong(const Packet& req, Reply& reply) {
    // The client never sends a pong; this only occupies the op number.
    (void)req;
    (void)reply;
    return true;
}

bool ExecServer::onExecute(const Packet& req, Reply& reply) {
    // The request is decoded into a SpawnRequest and goes no further; see the note
    // in front of the reply at the end of this function.
    SpawnRequest sr;
    // Layout: [flags][call_method][argc][envc][fd_count] then fd_count target
    // words, then NUL-terminated strings in the order file, cwd, argv..., env...;
    // see the encoder in exec/shim.c for the detail. Only what the caller asks for
    // is in these words: who the caller is comes from the connection the request
    // arrived on, not from the request itself (see Packet::caller).
    const uint8_t* b = req.body.data();
    size_t n = req.body.size();
    uint32_t flags, method, argc, envc, fd_count;
    size_t off;

    if (n < 20) {
        Logger::GetInstance()->LogE("[exec] request too short: %zu bytes", n);
        return false;
    }
    flags = get32(b);
    // Which exec the client called. Every value the shim can send is known here,
    // and anything else is a request this server cannot interpret: the field picks
    // the rule that decides where the program is filed, so guessing a method would
    // be guessing at the shape of the table. Such a request is refused.
    method = get32(b + 4);
    if (method >= CALL_METHOD_END) {
        Logger::GetInstance()->LogE("[exec] unknown call method %u", method);
        return false;
    }
    sr.call_method = static_cast<CallMethod>(method);
    // The pid of the client that sent the request, read off the connection it
    // arrived on (Packet::caller, from SO_PEERCRED -- see PeerPidOf). It is what
    // ties a child to the client that asked for it -- and, for an exec, what says
    // where the program belongs in the tree -- so a request without a usable one is
    // refused: 0 and the values that read back as negative are not pids a live
    // caller can have, and accepting one would file the child under an owner that
    // cannot be tested for liveness later.
    sr.caller_pid = static_cast<pid_t>(req.caller);
    if (sr.caller_pid <= 0) {
        // SO_PEERCRED is how the server learns who asked, and not every platform
        // build answers it for AF_UNIX. Refusing on the missing answer would turn
        // a diagnostic gap into a dead service -- every request would come back as
        // "handler failed" -- while the child would still be this server's. File
        // it under the server and say so, rather than refuse the command.
        Logger::GetInstance()->LogW(
            "[exec] SO_PEERCRED unavailable (caller %u); filing under the server",
            req.caller);
        sr.caller_pid = getpid();
    }
    argc = get32(b + 8);
    envc = get32(b + 12);
    fd_count = get32(b + 16);

    // The refusal shape the client understands: [0][errno][text NUL]. Saying why
    // is the difference between a field report that can be acted on and one that
    // only says "handler failed".
    auto refuse = [&](const std::string& why) -> bool {
        put32(reply.body, 0);
        put32(reply.body, static_cast<uint32_t>(EINVAL));
        reply.body.insert(reply.body.end(), why.begin(), why.end());
        reply.body.push_back('\0');
        return true;
    };

    // One target word per fd that arrived with the request, in the order the
    // framework received them, so the two lists have to be the same length. A
    // disagreement cannot be resolved -- whichever way the targets were then
    // matched up, they might be off by one, and the child would get the caller's
    // stderr on its stdout -- so the request is refused rather than guessed at.
    if (fd_count != req.fds.size()) {
        Logger::GetInstance()->LogE(
            "[exec] fd_count %u does not match %zu attached fds", fd_count, req.fds.size());
        return refuse("fd_count does not match the attached descriptors");
    }
    if (n < 20 + (size_t)fd_count * 4) {
        Logger::GetInstance()->LogE("[exec] request too short for %u fd targets", fd_count);
        return refuse("request too short for its descriptor targets");
    }

    // The strings start after the header and the target list, so every offset
    // below moves with fd_count.
    off = 20 + (size_t)fd_count * 4;
    for (uint32_t i = 0; i < fd_count; i++) {
        uint32_t target = get32(b + 20 + (size_t)i * 4);
        // Only the three standard descriptors are inherited for now. A target
        // beyond them would need a launch path that does not exist yet, and
        // taking the entry while ignoring it would silently drop what the caller
        // asked for, so an unknown target is an invalid request.
        if (target > STDERR_FILENO) {
            Logger::GetInstance()->LogE(
                "[exec] fd target %u is not a standard descriptor", target);
            return refuse("descriptor target is not one of 0/1/2");
        }
        sr.stdio_fds.push_back(InheritedFd{req.fds[i], static_cast<int>(target)});
    }

    // Walks one NUL-terminated string. The length is checked as it goes, so a
    // truncated or hostile request cannot run off the end of the buffer.
    auto next = [&](const char* what, std::string& out) -> bool {
        size_t start = off;
        while (off < n && b[off] != '\0') off++;
        if (off >= n) {
            Logger::GetInstance()->LogE("[exec] %s: string is not terminated", what);
            return false;
        }
        out.assign(reinterpret_cast<const char*>(b + start), off - start);
        off++;
        return true;
    };

    std::string file, cwd;
    if (!next("file", file)) return false;
    if (!next("cwd", cwd)) return false;
    sr.cwd = cwd;
    sr.sid = 0; // todo: multisession in future.

    // A working directory that cannot be entered is refused here rather than
    // discovered after the fork. Every launch route chdir()s in the child and
    // treats a failure as "stay where you are", which for a programmatic caller
    // means "your command ran somewhere you did not ask for" -- and the only
    // trace was a line on the child's stderr, i.e. inside the output the caller
    // is collecting. Refusing turns that into an error the caller can see.
    if (!sr.cwd.empty()) {
        struct stat st {};
        // Existing is not the same as enterable: chdir() also needs search
        // permission, and the launch routes treat a failed chdir() as "stay in the
        // server's directory", which is exactly the silent wrong-cwd this refusal
        // exists to prevent.
        if (stat(sr.cwd.c_str(), &st) != 0 || !S_ISDIR(st.st_mode) ||
            access(sr.cwd.c_str(), X_OK) != 0) {
            Logger::GetInstance()->LogW("[exec] cwd %s is not an enterable directory: %s",
                                        sr.cwd.c_str(), strerror(errno));
            put32(reply.body, 0);
            put32(reply.body, static_cast<uint32_t>(ENOENT));
            return true;
        }
    }

    const bool self_path = ResolveSelfPath(&file, sr.caller_pid);
    if (self_path)
        Logger::GetInstance()->LogI("[exec] self path -> %s (caller %d)",
                                    file.c_str(), (int)sr.caller_pid);

    // Every request passes through here, whatever member of the family sent it, which is
    // why the fake root is applied at this point rather than inside the path search. That
    // search is only reached by the three calls whose names end in p, and the calls that
    // name an absolute path -- the shell a terminal starts, for one -- never go near it.
    // Logged after this, so what the log shows is what will be started.
    if (!self_path) file = UnderFakeRoot(file);
    // The remaining fields keep their defaults: sync_wait is true (a foreground
    // command on a terminal always waits), and no process name is carried by the
    // request yet.

    std::string fd_map;
    for (const InheritedFd& fd : sr.stdio_fds)
        fd_map += " " + std::to_string(fd.source_fd) + "->" + std::to_string(fd.target_fd);
    Logger::GetInstance()->LogI(
        "[exec] file=%s cwd=%s flags=0x%x method=%d caller=%d argc=%u envc=%u fds=%zu%s",
        file.c_str(), cwd.empty() ? "(inherit)" : cwd.c_str(),
        flags, (int)sr.call_method, (int)sr.caller_pid, argc, envc, req.fds.size(),
        fd_map.c_str());

    for (uint32_t i = 0; i < argc; i++) {
        std::string a;
        if (!next("argv", a)) return false;
        Logger::GetInstance()->LogI("[exec]   argv[%u] = %s", i, a.c_str());
        sr.argv.push_back(a);
    }
    for (uint32_t i = 0; i < envc; i++) {
        std::string e;
        if (!next("env", e)) return false;
        Logger::GetInstance()->LogI("[exec]   env[%u] = %s", i, e.c_str());
        sr.env.push_back(e);
    }

    // The job a request belongs to travels in the environment, not in a field of
    // its own; see the note on SpawnRequest::job. Read before IEC_SYSROOT is
    // appended so that the value recorded is the one the caller sent, not one
    // this function invented.
    sr.job = JobOfEnv(sr.env);

    // The client-side fs shim maps absolute paths (including the PATH entries a
    // shell stats before exec) relative to this root. A real execve() replaces
    // the environment with sr.env, and the shared-object route installs sr.env
    // in the child, so the root has to travel with the request rather than be
    // set only in the server's own process.
    bool has_iec_root = false;
    const std::string iec_root = std::string("IEC_SYSROOT=") + FAKE_SYSROOT;
    for (const std::string& e : sr.env) {
        if (e.compare(0, 12, "IEC_SYSROOT=") == 0) { has_iec_root = true; break; }
    }
    if (!has_iec_root) {
        sr.env.push_back(iec_root);
        Logger::GetInstance()->LogI("[exec]   env[] = %s (added)", iec_root.c_str());
    }
    if (off != n)
        Logger::GetInstance()->LogW("[exec] %zu trailing bytes ignored", n - off);

    if (SearchesPath(sr.call_method)) {
        sr.path = ResolveFilePath(file, sr.env, sr.cwd);
        if (sr.path.empty()) {
            Logger::GetInstance()->LogW("[exec] %s: no such file on PATH (method %d)",
                                        file.c_str(), (int)sr.call_method);
            put32(reply.body, 0);                        // no pid: nothing was started
            put32(reply.body, static_cast<uint32_t>(ENOENT));
            return true;
        }
        if (sr.path != file)
            Logger::GetInstance()->LogI("[exec] %s resolved to %s",
                                        file.c_str(), sr.path.c_str());
    } else {
        sr.path = file;
    }
    sr.kind_hint = ResolveKind(sr.path);

    // A request turns into a real process whose stdio is the caller's: the fds
    // that came with the request are dup2'd onto the targets the request named, in
    // the child, before it execs (see InstallInheritedFds). The pid goes back in
    // the reply, and it is the whole point of the reply: the caller has no other
    // way to name this child, and OP_WAIT is how it collects the exit status.
    SpawnResult res = Spawn(sr);
    if (res.pid < 0) {
        Logger::GetInstance()->LogE(
            "[exec] spawn failed: %s",
            res.error.empty() ? "unknown error" : res.error.c_str());
        // Tell the client why, not just "handler failed": at the far end this is
        // the difference between "your shell is broken" and "the native child
        // process API refused and fork is unavailable too". Shape:
        // [0][errno][message NUL]: the first two words are the refusal shape the
        // client already understands, the text is what it can show a human.
        put32(reply.body, 0);
        put32(reply.body, static_cast<uint32_t>(ENOENT));
        const std::string why = res.error.empty() ? "cannot start" : res.error;
        reply.body.insert(reply.body.end(), why.begin(), why.end());
        reply.body.push_back('\0');
        return true;
    }
    Logger::GetInstance()->LogI("[exec] spawned pid %d", (int)res.pid);
    put32(reply.body, static_cast<uint32_t>(res.pid));
    return true;
}

// Answers whether one child has finished, and with what status. It is the second
// half of the exec handshake: the client's stand-in polls this until the state
// word flips, then leaves with the same status, so that its caller's waitpid()
// sees what the real program did (see the wait loop in exec/shim.c).
//
// Only a pid this server really spawned may be waited for, and procmap is the
// authority on that, not waitpid() itself: waitpid() would happily answer for any
// child of this process, and the request names the pid as a plain unsigned word,
// so a request for -1 -- which collects an arbitrary child -- or for a child of
// some future feature has to be refused here rather than looked up and passed on.
bool ExecServer::onWait(const Packet& req, Reply& reply) {
    if (req.body.size() < 4) {
        Logger::GetInstance()->LogE("[exec] wait request too short: %zu bytes", req.body.size());
        return false;
    }
    pid_t pid = static_cast<pid_t>(get32(req.body.data()));

    // A native child's ending may already have arrived through the platform's
    // callback; fold those in before asking the kernel about anything.
    DrainNativeExits();

    auto it = procmap.find(pid);
    if (it == procmap.end()) {
        Logger::GetInstance()->LogW(
            "[exec] wait for pid %d: not a process this server spawned", (int)pid);
        return false;
    }

    int status = 0;
    pid_t reaped = waitpid(pid, &status, WNOHANG);
    if (reaped == pid) {
        // Exited by now, and this call is what collected it. The same recording
        // the reaper does, so the entry reads the same either way.
        RecordExit(it->second, status);
        put32(reply.body, 1);
        put32(reply.body, static_cast<uint32_t>(status));
        return true;
    }
    if (reaped == 0) {
        // Still running. There is no status yet, so the second word is sent as 0
        // and the client goes by the state word alone.
        put32(reply.body, 0);
        put32(reply.body, 0);
        return true;
    }

    // A native child is never this process's to collect: waitpid() answers ECHILD
    // for it from the first call. Until the platform has reported the ending, the
    // program is still running, which is the same answer a forked child that has not
    // exited gives.
    if (it->second.prikind == PrimaryLaunchKind::kNcp) {
        put32(reply.body, it->second.alive ? 0 : 1);
        put32(reply.body, it->second.alive ? 0 : static_cast<uint32_t>(it->second.status));
        return true;
    }

    // waitpid() failed. ECHILD says the pid is no longer this process's to
    // collect, and onTick() is the only thing here that collects children, so the
    // status it recorded is the answer. It is only used when the entry agrees that
    // the child is gone: a live entry would mean the table and the kernel disagree,
    // and then the recorded status is not something that was ever observed, so it
    // must not be passed off as one.
    if (errno == ECHILD && !it->second.alive) {
        put32(reply.body, 1);
        put32(reply.body, static_cast<uint32_t>(it->second.status));
        return true;
    }
    Logger::GetInstance()->LogE("[exec] waitpid(%d) failed: %s", (int)pid, strerror(errno));
    return false;
}

// Delivers a signal to a program this server started, on behalf of the stand-in
// that received it. The stand-in is where a terminal's signals land -- it is what
// the caller's shell left in the foreground process group -- while the program
// runs here, in the server's own process group and session, so the kernel never
// hands it the signal and no kill() aimed at the stand-in reaches it either. This
// is the other half of the catch-and-forward the client does (see the signal
// section in exec/shim.c).
//
// The pid is checked against procmap first, exactly as onWait() does and for the
// same reason: the request names it as a plain unsigned word, and without the
// lookup this would be a general-purpose kill() for any client of this socket --
// a request for pid -1 or 0 would reach the server's whole process group, and any
// child of the server could be named. procmap is the authority on which pids this
// server may be asked about, not the kernel.
bool ExecServer::onSignal(const Packet& req, Reply& reply) {
    if (req.body.size() < 8) {
        Logger::GetInstance()->LogE("[exec] signal request too short: %zu bytes", req.body.size());
        return false;
    }
    pid_t pid = static_cast<pid_t>(get32(req.body.data()));
    int signo = static_cast<int>(get32(req.body.data() + 4));

    auto it = procmap.find(pid);
    if (it == procmap.end()) {
        Logger::GetInstance()->LogW(
            "[exec] signal %d for pid %d: not a process this server spawned",
            signo, (int)pid);
        return false;
    }

    // ESRCH is not a failure. The child can exit between the stand-in catching the
    // signal and this request arriving, and that race is the normal case for a
    // signal that ends a program: the status it left behind is what the next
    // OP_WAIT reports, so there is nothing left to do and nothing wrong. Every
    // other failure (EINVAL for a signal number that does not exist, EPERM) is
    // reported to the client rather than swallowed.
    if (kill(pid, signo) < 0 && errno != ESRCH) {
        Logger::GetInstance()->LogE("[exec] kill(%d, %d) failed: %s",
                                    (int)pid, signo, strerror(errno));
        return false;
    }
    // The reply is empty: whether the signal was accepted or refused is the whole
    // answer, and the fate of the program shows up in OP_WAIT like any other end.
    return true;
}

// Ends every process of one job, gently first and with SIGKILL once the grace
// period has passed. See OP_TERMINATE_JOB for why the request names a job rather
// than a pid.
//
// SIGTERM goes out here, on the server thread, and the escalation is left to
// onTick(): a timer thread would have to read procmap to avoid killing a recycled
// pid, and procmap is not shared. The cost is that the SIGKILL lands up to one
// poll pass (500 ms) after the deadline, which is well inside what a caller that
// asked for a grace period is prepared to wait.
bool ExecServer::onTerminateJob(const Packet& req, Reply& reply) {
    if (req.body.size() < 5) {
        Logger::GetInstance()->LogE("[exec] terminate job: request too short: %zu",
                                    req.body.size());
        return false;
    }

    const uint32_t grace_ms = get32(req.body.data());
    std::string job(reinterpret_cast<const char*>(req.body.data() + 4),
                    req.body.size() - 4);
    if (!job.empty() && job.back() == '\0') job.pop_back();
    if (job.empty()) {
        Logger::GetInstance()->LogE("[exec] terminate job: empty id");
        return false;
    }

    const std::vector<pid_t> pids = JobPids(job);
    if (grace_ms == 0) {
        SignalPids(pids, SIGKILL);
    } else {
        SignalPids(pids, SIGTERM);
        const int64_t due = NowMillis() + static_cast<int64_t>(grace_ms);
        for (pid_t pid : pids) {
            const auto it = procmap.find(pid);
            if (it == procmap.end()) continue;
            PendingKill pending;
            pending.pid = pid;
            pending.job = job;
            pending.start_ms = it->second.start_time_ms;
            pending.due_ms = due;
            pending_kills_.push_back(pending);
        }
    }

    Logger::GetInstance()->LogI("[exec] terminate job %s: %zu process(es), grace %u ms",
                                job.c_str(), pids.size(), grace_ms);
    put32(reply.body, static_cast<uint32_t>(pids.size()));
    return true;
}

// One line per process this server started; see OP_LIST. The command goes last
// because it is the only field that may contain spaces.
bool ExecServer::onList(const Packet& req, Reply& reply) {
    (void)req;

    std::string out;
    for (const auto& kv : procmap) {
        const ProcessInfo& p = kv.second;
        out += "pid " + std::to_string(p.pid);
        out += " job " + (p.job.empty() ? std::string("-") : p.job);
        out += " alive " + std::to_string(p.alive ? 1 : 0);
        out += " code " + std::to_string(p.exit_code);
        out += " cmd " + p.cmd + "\n";
    }
    reply.body.assign(out.begin(), out.end());
    return true;
}
