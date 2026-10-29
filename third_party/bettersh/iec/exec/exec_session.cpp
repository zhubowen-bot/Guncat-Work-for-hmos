// exec/exec_session.cpp — see exec_session.h.
//
// The shape of one session:
//
//   client (this file)                exec service (exec_server.cpp)
//      |  OP_EXECUTE + 3 pipe fds  ->      |  fork / native child, dup2 onto 0,1,2
//      |  <- pid                            |
//      |  read(stdout), read(stderr)        |  program runs
//      |  OP_WAIT (poll) --------------->   |  waitpid(pid)
//      |  <- [done][raw status]             |
//      |  OP_TERMINATE_JOB ------------->   |  SIGTERM every process of the job
//
// Everything that is policy lives here: the buffers, the deadline, the job id,
// the non-blocking stdin. The service is left with only the part it must do --
// creating the process -- which is what keeps this route and the exec shim from
// disagreeing about how a program is started.
#include "exec_session.h"

#include "constant.h"
#include "sock_operation.h"

// The client and the wire helpers are C: the service is a C++ translation unit,
// these two are not, and a declaration without C linkage would be looked for
// under a mangled name that nothing defines.
extern "C" {
#include "rpc.h"
#include "sock_client.h"

// The process environment, as the C library defines it. Declared here rather than
// inside the anonymous namespace below: a block-scope `extern` in an unnamed
// namespace would give the symbol internal linkage, and the link would fail with
// "internal linkage but not defined" -- which is exactly what happened first.
extern char** environ;
}

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace iec {
namespace {

using Clock = std::chrono::steady_clock;

constexpr size_t kDefaultOutputCap = 4u << 20;      // 4 MiB per stream
constexpr size_t kMinOutputCap = 64u << 10;
constexpr size_t kMaxOutputCap = 64u << 20;
constexpr size_t kMaxRequestBytes = 256u << 10;     // the packet limit is 1 MiB
constexpr size_t kMaxStdinBytes = 16u << 20;
constexpr size_t kMaxArgs = 4096;
constexpr size_t kMaxEnvEntries = 4096;
constexpr int    kMaxTimeoutMs = 24 * 60 * 60 * 1000;
constexpr int    kTerminateGraceMs = 800;
constexpr int    kReaderPollMs = 200;
constexpr int    kWatchdogHardWaitMs = 10 * 1000;

int64_t NowMs() {
    const auto now = Clock::now().time_since_epoch();
    return std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
}

void Append32(std::vector<uint8_t>& out, uint32_t value) {
    out.push_back(static_cast<uint8_t>(value >> 24));
    out.push_back(static_cast<uint8_t>(value >> 16));
    out.push_back(static_cast<uint8_t>(value >> 8));
    out.push_back(static_cast<uint8_t>(value));
}

void AppendString(std::vector<uint8_t>& out, const std::string& value) {
    out.insert(out.end(), value.begin(), value.end());
    out.push_back('\0');
}

/* ------------------------------------------------------------------ */
/* Session                                                             */
/* ------------------------------------------------------------------ */

struct Session {
    int         id = -1;
    int         pid = -1;
    std::string job;
    size_t      cap = kDefaultOutputCap;

    int in_w = -1;       // parent end of the child's stdin

    std::mutex mu;
    std::condition_variable cv;

    std::string out;
    std::string err;
    size_t      out_dropped = 0;
    size_t      err_dropped = 0;
    bool        out_eof = false;
    bool        err_eof = false;

    bool done = false;
    bool timed_out = false;
    int  exit_code = -1;
    int  signal = 0;

    std::atomic<bool> stop{false};

    std::thread feeder;      // writes stdin_data, then closes unless asked not to
    std::thread reader_out;
    std::thread reader_err;
    std::thread waiter;
    std::thread watchdog;

    ~Session() {
        // The read ends belong to the reader threads, which close them when the
        // pipe ends; only stdin is left for this object to own. Closing an
        // already-closed descriptor would be a bug, so every closer sets the
        // field to -1 first (see Finish/Release/CloseStdin).
        if (in_w >= 0) close(in_w);
    }
};

std::mutex g_registry_mu;
std::map<int, std::shared_ptr<Session>> g_sessions;
int g_next_id = 1;

std::shared_ptr<Session> Find(int id) {
    std::lock_guard<std::mutex> lock(g_registry_mu);
    const auto it = g_sessions.find(id);
    return it == g_sessions.end() ? nullptr : it->second;
}

void FillState(const std::shared_ptr<Session>& s, ExecState* state) {
    if (state == nullptr) return;

    std::lock_guard<std::mutex> lock(s->mu);
    state->id = s->id;
    state->pid = s->pid;
    state->job = s->job;
    state->running = !s->done;
    state->exited = s->done;
    state->exit_code = s->exit_code;
    state->signal = s->signal;
    state->timed_out = s->timed_out;
    state->out_eof = s->out_eof;
    state->err_eof = s->err_eof;
    state->out_dropped = s->out_dropped;
    state->err_dropped = s->err_dropped;
}

// Sets the ending and wakes everyone. status is waitpid()'s raw word; the
// rendering rules are the ones a shell uses, so 128 + signal and the exit code
// mean the same thing here as they do in $?.
void Finish(const std::shared_ptr<Session>& s, int status) {
    int code = -1;
    int sig = 0;

    if (WIFEXITED(status)) {
        code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        sig = WTERMSIG(status);
        code = 128 + sig;
    }

    std::lock_guard<std::mutex> lock(s->mu);
    if (s->done) return;
    s->done = true;
    s->exit_code = code;
    s->signal = sig;
    if (s->in_w >= 0) { close(s->in_w); s->in_w = -1; }
    s->cv.notify_all();
}

// The service no longer knows this pid -- it was restarted, or the transport
// failed. -1 is the only honest code: 0 would claim a success nobody observed,
// and 127 would claim "command not found" for a command that ran.
void FinishLost(const std::shared_ptr<Session>& s) {
    std::lock_guard<std::mutex> lock(s->mu);
    if (s->done) return;
    s->done = true;
    s->exit_code = -1;
    s->signal = 0;
    if (s->in_w >= 0) { close(s->in_w); s->in_w = -1; }
    s->cv.notify_all();
}

/* ------------------------------------------------------------------ */
/* Threads                                                             */
/* ------------------------------------------------------------------ */

void AppendOutput(const std::shared_ptr<Session>& s, bool is_err,
                  const char* data, size_t size) {
    std::lock_guard<std::mutex> lock(s->mu);

    std::string& dst = is_err ? s->err : s->out;
    const size_t room = dst.size() < s->cap ? s->cap - dst.size() : 0;
    const size_t take = std::min(room, size);
    if (take > 0) dst.append(data, take);
    if (take < size) {
        (is_err ? s->err_dropped : s->out_dropped) += size - take;
    }
    s->cv.notify_all();
}

// Reads one pipe until it ends. poll() rather than a bare read() so that stop
// (Release, or the process ending) is noticed even when the write end is held by
// a grandchild that outlived the program: the session must not pin a thread for
// ever just because something it started still has the descriptor open.
void ReadLoop(std::shared_ptr<Session> s, int fd, bool is_err) {
    char buffer[16 * 1024];

    while (!s->stop.load()) {
        struct pollfd pfd {};
        pfd.fd = fd;
        pfd.events = POLLIN;

        const int ready = poll(&pfd, 1, kReaderPollMs);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ready == 0) continue;

        const ssize_t n = read(fd, buffer, sizeof buffer);
        if (n > 0) {
            AppendOutput(s, is_err, buffer, static_cast<size_t>(n));
            continue;
        }
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        break;   // 0 = EOF, anything else = the pipe is gone
    }

    {
        std::lock_guard<std::mutex> lock(s->mu);
        (is_err ? s->err_eof : s->out_eof) = true;
        s->cv.notify_all();
    }
    close(fd);
}

// Asks OP_WAIT until the service says the child ended.
//
// The interval grows because a command that runs for a second and a command that
// runs for an hour want different polling rates: the first should report its
// output and status without a visible delay, the second should not cost a
// connection round trip fifty times a second for an hour.
void WaitLoop(std::shared_ptr<Session> s) {
    const int64_t started = NowMs();

    sock_client client {};
    if (sock_connect(&client, EXEC_SOCK_PATH) < 0) {
        FinishLost(s);
        return;
    }

    uint8_t request[4];
    iec_put32(request, static_cast<uint32_t>(s->pid));

    while (!s->stop.load()) {
        sock_reply reply {};
        const int rc = sock_call(&client, OP_WAIT, request, sizeof request, &reply);

        if (rc == 0 && reply.len >= 8) {
            const uint32_t state = iec_get32(reply.body);
            const uint32_t status = iec_get32(reply.body + 4);
            sock_reply_free(&reply);
            if (state == 1) {
                Finish(s, static_cast<int>(status));
                break;
            }
        } else {
            // A refusal is not a retryable event: the service answers "not a
            // process this server spawned" and will keep answering it. A
            // transport failure is the same kind of dead end.
            if (rc >= 0) sock_reply_free(&reply);
            FinishLost(s);
            break;
        }

        const int64_t age = NowMs() - started;
        const int delay_ms = age < 200 ? 10 : (age < 2000 ? 25 : 50);

        // Sleep in slices so stop is honoured promptly; the deadline thread may
        // be asking for a cancellation at any moment.
        for (int slept = 0; slept < delay_ms && !s->stop.load(); slept += 10)
            usleep(10 * 1000);
    }

    sock_close(&client);
}

// Writes stdin_data once, then closes stdin unless the caller asked to keep it
// open. Done on a thread of its own so a program that writes a lot before it
// reads can never deadlock Start().
void FeedLoop(std::shared_ptr<Session> s, std::string data, bool keep_open) {
    size_t off = 0;

    while (off < data.size() && !s->stop.load()) {
        int fd = -1;
        {
            std::lock_guard<std::mutex> lock(s->mu);
            fd = s->in_w;
        }
        if (fd < 0) break;   // the child closed its end, or Release/Finish did

        const ssize_t n = write(fd, data.data() + off, data.size() - off);
        if (n > 0) { off += static_cast<size_t>(n); continue; }
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) {
            struct pollfd pfd {};
            pfd.fd = fd;
            pfd.events = POLLOUT;
            poll(&pfd, 1, 100);
            continue;
        }
        break;
    }

    if (!keep_open) CloseStdin(s->id);
}

// Enforces ExecOptions::timeout_ms. This is the part of the deadline that cannot
// be delegated to the caller: an agent that stops polling -- because it crashed,
// because the user closed the window -- must not leave a program running.
void WatchLoop(std::shared_ptr<Session> s, int timeout_ms) {
    const auto deadline = Clock::now() + std::chrono::milliseconds(timeout_ms);

    {
        std::unique_lock<std::mutex> lock(s->mu);
        if (s->cv.wait_until(lock, deadline,
                             [&] { return s->done || s->stop.load(); }))
            return;
        s->timed_out = true;
    }

    Terminate(s->id, kTerminateGraceMs);

    // Give the escalation time to be observed. If it is not, the waiter is
    // still running and will fill the state in when it does; nothing here needs
    // to block the session for ever.
    std::unique_lock<std::mutex> lock(s->mu);
    s->cv.wait_for(lock, std::chrono::milliseconds(kWatchdogHardWaitMs),
                   [&] { return s->done || s->stop.load(); });
}

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

bool RpcTerminateJob(const std::string& job, int grace_ms) {
    std::vector<uint8_t> body;
    Append32(body, static_cast<uint32_t>(grace_ms));
    AppendString(body, job);

    uint8_t reply[4] = {0};
    uint32_t len = 0;
    if (iec_rpc_call(EXEC_SOCK_PATH, OP_TERMINATE_JOB, body.data(),
                     static_cast<uint32_t>(body.size()), reply, sizeof reply,
                     &len) < 0) {
        return false;
    }
    return len >= 4;
}

std::string MakeJobId() {
    static std::atomic<uint32_t> counter{0};
    char buffer[64];
    snprintf(buffer, sizeof buffer, "j%x-%x-%llx", static_cast<unsigned>(getpid()),
             static_cast<unsigned>(counter.fetch_add(1) + 1),
             static_cast<unsigned long long>(NowMs()));
    return std::string(buffer);
}

// Replaces NAME=VALUE in place, or appends it. Keeps the environment's shape:
// one entry per name, last writer wins, which is what setenv() would have done.
void PutEnv(std::vector<std::string>& env, const std::string& entry) {
    const size_t eq = entry.find('=');
    if (eq == std::string::npos || eq == 0) return;

    const std::string prefix = entry.substr(0, eq + 1);
    for (std::string& existing : env) {
        if (existing.compare(0, prefix.size(), prefix) == 0) {
            existing = entry;
            return;
        }
    }
    env.push_back(entry);
}

bool EnvHas(const std::vector<std::string>& env, const std::string& name) {
    const std::string prefix = name + "=";
    for (const std::string& entry : env)
        if (entry.compare(0, prefix.size(), prefix) == 0) return true;
    return false;
}

std::vector<std::string> BuildEnv(const ExecOptions& options,
                                  const std::string& job) {
    std::vector<std::string> env;

    if (!options.env_replace) {
        for (char** e = environ; e && *e; ++e) env.push_back(*e);
    }

    for (const std::string& entry : options.env)
        if (entry.size() <= kMaxRequestBytes) PutEnv(env, entry);

    // A program started without a PATH would fail every lookup, and a command
    // runner whose first act is to explain PATH would be a poor one. The fallback
    // is the POSIX default; the service rewrites it into the fake root when that
    // is what the host allows (see UnderFakeRoot).
    if (!EnvHas(env, "PATH")) PutEnv(env, "PATH=/usr/bin:/bin");
    if (!EnvHas(env, "HOME")) PutEnv(env, std::string("HOME=") + IEC_DEFAULT_HOME);

    // The job id goes last so it wins over anything the caller passed under the
    // same name: this is the value the server will file the process under.
    PutEnv(env, "IEC_JOB=" + job);
    return env;
}

std::string Strerror(int err) {
    return std::string(strerror(err));
}

}  // namespace

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

int Start(const ExecOptions& options, ExecState* state, std::string* error) {
    if (options.cmd.empty()) {
        if (error) *error = "cmd is empty";
        return -1;
    }
    if (options.args.size() > kMaxArgs) {
        if (error) *error = "too many arguments";
        return -1;
    }
    if (options.env.size() > kMaxEnvEntries) {
        if (error) *error = "too many environment entries";
        return -1;
    }
    if (options.timeout_ms < 0 || options.timeout_ms > kMaxTimeoutMs) {
        if (error) *error = "timeout_ms is out of range";
        return -1;
    }
    if (options.stdin_data.size() > kMaxStdinBytes) {
        if (error) *error = "stdin_data is too large";
        return -1;
    }

    const std::string job =
        options.job.empty() ? MakeJobId() : options.job;
    if (job.find('\n') != std::string::npos || job.find('\0') != std::string::npos) {
        if (error) *error = "job id must not contain newlines or NUL";
        return -1;
    }

    const std::vector<std::string> env = BuildEnv(options, job);

    // The three pipes. All ends are close-on-exec so a later exec in this process
    // cannot leak them; the service installs its copies with dup2(), which clears
    // the flag for the child (see InstallInheritedFds).
    int in_pipe[2] = {-1, -1};
    int out_pipe[2] = {-1, -1};
    int err_pipe[2] = {-1, -1};

    auto fail = [&](const std::string& why) -> int {
        for (int fd : {in_pipe[0], in_pipe[1], out_pipe[0], out_pipe[1],
                       err_pipe[0], err_pipe[1]})
            if (fd >= 0) close(fd);
        if (error) *error = why;
        return -1;
    };

    if (pipe(in_pipe) != 0 || pipe(out_pipe) != 0 || pipe(err_pipe) != 0)
        return fail("pipe: " + Strerror(errno));

    for (int fd : {in_pipe[0], in_pipe[1], out_pipe[0], out_pipe[1],
                   err_pipe[0], err_pipe[1]})
        fcntl(fd, F_SETFD, FD_CLOEXEC);

    // Where the program starts. The fake root's home is the useful default on a
    // device; a build host (and a first boot before the home exists) has no such
    // directory, so fall back to the one path that always exists rather than
    // asking the service to start a program in a directory it cannot enter.
    std::string cwd = options.cwd;
    if (cwd.empty()) {
        struct stat home {};
        cwd = (stat(IEC_DEFAULT_HOME, &home) == 0 && S_ISDIR(home.st_mode))
                  ? std::string(IEC_DEFAULT_HOME)
                  : std::string("/");
    }

    // The request body, byte for byte the shape exec/shim.c sends:
    //   [flags][call_method][argc][envc][fd_count][targets...][file][cwd]
    //   [argv...][env...]
    std::vector<uint8_t> body;
    const uint32_t argc = static_cast<uint32_t>(1 + options.args.size());
    const uint32_t envc = static_cast<uint32_t>(env.size());
    const uint32_t fd_count = 3;   // stdin, stdout, stderr -- always all three

    Append32(body, 0);                          // flags: nothing extra asked for
    Append32(body, static_cast<uint32_t>(CALL_EXECVP));
    Append32(body, argc);
    Append32(body, envc);
    Append32(body, fd_count);
    Append32(body, 0);                          // stdin
    Append32(body, 1);                          // stdout
    Append32(body, 2);                          // stderr

    AppendString(body, options.cmd);
    AppendString(body, cwd);
    AppendString(body, options.cmd);
    for (const std::string& arg : options.args) AppendString(body, arg);
    for (const std::string& entry : env) AppendString(body, entry);

    if (body.size() > kMaxRequestBytes)
        return fail("request is too large (environment and arguments)");

    const int child_fds[3] = {in_pipe[0], out_pipe[1], err_pipe[1]};

    sock_client client {};
    if (sock_connect(&client, EXEC_SOCK_PATH) < 0) {
        const int err = errno;
        return fail("cannot reach the exec service: " + Strerror(err));
    }

    sock_reply reply {};
    const int rc = sock_call_fds(&client, OP_EXECUTE, body.data(),
                                 static_cast<uint32_t>(body.size()), child_fds, 3,
                                 &reply);
    if (rc != 0) {
        const std::string why = rc > 0
            ? "the exec service refused: " +
                  std::string(reply.body ? reinterpret_cast<char*>(reply.body)
                                         : "no message")
            : "exec request failed: " + Strerror(errno);
        if (rc >= 0) sock_reply_free(&reply);
        sock_close(&client);
        return fail(why);
    }

    int pid = -1;
    int err_no = 0;
    std::string refused_text;
    if (reply.len >= 8) {
        // The refusal shape: no pid, then the errno the call should fail with.
        err_no = static_cast<int>(iec_get32(reply.body + 4));
        // A server that knows why appends the reason after the two words; older
        // servers send exactly eight bytes. The text is what a human can act on,
        // so it is preferred over the errno when it is there.
        if (reply.len > 8) {
            const char* text = reinterpret_cast<const char*>(reply.body + 8);
            size_t n = reply.len - 8;
            if (n > 0 && text[n - 1] == '\0') n--;
            refused_text.assign(text, n);
        }
    } else if (reply.len >= 4) {
        pid = static_cast<int>(iec_get32(reply.body));
    }
    sock_reply_free(&reply);
    sock_close(&client);

    if (pid <= 0) {
        std::string why = "the program could not be started";
        if (!refused_text.empty()) {
            why += ": " + refused_text;
        } else if (err_no > 0) {
            why += ": " + Strerror(err_no);
        }
        return fail(why);
    }

    // From here on the child owns its ends; the parent keeps the other three.
    close(in_pipe[0]);
    close(out_pipe[1]);
    close(err_pipe[1]);
    in_pipe[0] = out_pipe[1] = err_pipe[1] = -1;

    auto session = std::make_shared<Session>();
    session->pid = pid;
    session->job = job;
    session->in_w = in_pipe[1];
    session->cap = options.max_output_bytes == 0
                       ? kDefaultOutputCap
                       : std::min(std::max(options.max_output_bytes, kMinOutputCap),
                                  kMaxOutputCap);

    // The reader threads own the read ends from here on; the session keeps only
    // the stdin descriptor (which Finish/Release close). Handing ownership over
    // explicitly is what keeps the destructor from closing a descriptor that has
    // been closed and recycled underneath it.
    const int out_fd = out_pipe[0];
    const int err_fd = err_pipe[0];
    in_pipe[1] = out_pipe[0] = err_pipe[0] = -1;

    // stdin becomes non-blocking before any caller can write to it: a Write that
    // blocks a UI thread because the child is busy is not acceptable, and the
    // partial-write answer is something the caller can act on.
    const int flags = fcntl(session->in_w, F_GETFL, 0);
    if (flags >= 0) fcntl(session->in_w, F_SETFL, flags | O_NONBLOCK);

    {
        std::lock_guard<std::mutex> lock(g_registry_mu);
        session->id = g_next_id++;
        if (g_next_id <= 0) g_next_id = 1;
        g_sessions[session->id] = session;
    }

    const int id = session->id;

    if (!options.stdin_data.empty())
        session->feeder = std::thread(FeedLoop, session, options.stdin_data,
                                      options.keep_stdin_open);
    else if (!options.keep_stdin_open)
        CloseStdin(id);

    session->reader_out = std::thread(ReadLoop, session, out_fd, false);
    session->reader_err = std::thread(ReadLoop, session, err_fd, true);
    session->waiter = std::thread(WaitLoop, session);
    if (options.timeout_ms > 0)
        session->watchdog = std::thread(WatchLoop, session, options.timeout_ms);

    // Detached by design: a session outlives the call that created it, and the
    // shared_ptr in each thread keeps it alive until the thread is done. Nothing
    // joins here, because a reader may be waiting for a grandchild that still
    // holds the pipe -- see ReadLoop.
    if (session->feeder.joinable()) session->feeder.detach();
    session->reader_out.detach();
    session->reader_err.detach();
    session->waiter.detach();
    if (session->watchdog.joinable()) session->watchdog.detach();

    if (state) {
        *state = ExecState{};
        state->id = id;
        state->pid = pid;
        state->job = job;
        state->running = true;
    }
    return id;
}

bool Poll(int id, size_t max_out, size_t max_err, ExecChunk* chunk,
          ExecState* state) {
    const std::shared_ptr<Session> session = Find(id);
    if (!session) return false;

    if (chunk) {
        chunk->out.clear();
        chunk->err.clear();

        std::lock_guard<std::mutex> lock(session->mu);
        const size_t take_out = std::min(max_out, session->out.size());
        const size_t take_err = std::min(max_err, session->err.size());
        chunk->out = session->out.substr(0, take_out);
        chunk->err = session->err.substr(0, take_err);
        session->out.erase(0, take_out);
        session->err.erase(0, take_err);
    }

    FillState(session, state);
    return true;
}

bool Wait(int id, int timeout_ms, ExecState* state) {
    const std::shared_ptr<Session> session = Find(id);
    if (!session) return false;

    std::unique_lock<std::mutex> lock(session->mu);
    if (timeout_ms <= 0) {
        session->cv.wait(lock, [&] { return session->done; });
    } else {
        session->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                             [&] { return session->done; });
    }
    lock.unlock();

    FillState(session, state);
    return true;
}

long Write(int id, const void* data, size_t size) {
    const std::shared_ptr<Session> session = Find(id);
    if (!session || (data == nullptr && size != 0)) return -1;

    std::lock_guard<std::mutex> lock(session->mu);
    if (session->in_w < 0) return -1;

    for (;;) {
        const ssize_t n = write(session->in_w, data, size);
        if (n >= 0) return static_cast<long>(n);
        if (errno == EINTR) continue;
        if (errno == EAGAIN) return 0;   // the pipe is full; try again later
        return -1;
    }
}

bool CloseStdin(int id) {
    const std::shared_ptr<Session> session = Find(id);
    if (!session) return false;

    std::lock_guard<std::mutex> lock(session->mu);
    if (session->in_w >= 0) {
        close(session->in_w);
        session->in_w = -1;
    }
    return true;
}

bool Terminate(int id, int grace_ms) {
    const std::shared_ptr<Session> session = Find(id);
    if (!session) return false;

    int pid = -1;
    std::string job;
    {
        std::lock_guard<std::mutex> lock(session->mu);
        pid = session->pid;
        job = session->job;
    }

    // The service is the authority: it knows every process of the job, including
    // the ones a program started after its own exec, and it escalates without
    // this process having to keep a timer. The direct signals are the fallback
    // for a service that cannot be reached, which is also the only case in which
    // a job id buys nothing.
    if (!job.empty() && RpcTerminateJob(job, grace_ms)) return true;

    if (pid <= 0) return false;
    if (getpgid(pid) == pid) kill(-pid, SIGTERM);
    kill(pid, SIGTERM);
    if (grace_ms <= 0) {
        if (getpgid(pid) == pid) kill(-pid, SIGKILL);
        kill(pid, SIGKILL);
    } else {
        std::thread([pid, grace_ms] {
            usleep(static_cast<useconds_t>(grace_ms) * 1000);
            if (getpgid(pid) == pid) kill(-pid, SIGKILL);
            kill(pid, SIGKILL);
        }).detach();
    }
    return true;
}

bool Signal(int id, int signo) {
    const std::shared_ptr<Session> session = Find(id);
    if (!session || signo <= 0) return false;

    int pid = -1;
    {
        std::lock_guard<std::mutex> lock(session->mu);
        pid = session->pid;
    }
    if (pid <= 0) return false;

    bool sent = false;
    if (getpgid(pid) == pid) sent = kill(-pid, signo) == 0;
    if (kill(pid, signo) == 0) sent = true;
    return sent;
}

bool Release(int id) {
    std::shared_ptr<Session> session;
    {
        std::lock_guard<std::mutex> lock(g_registry_mu);
        const auto it = g_sessions.find(id);
        if (it == g_sessions.end()) return false;
        session = it->second;

        // Refuse to drop a live child: its pipes would be closed under it and its
        // status would have nobody to go to. Terminate first, then Release.
        {
            std::lock_guard<std::mutex> session_lock(session->mu);
            if (!session->done) return false;
        }
        g_sessions.erase(it);
    }

    session->stop.store(true);
    {
        std::lock_guard<std::mutex> lock(session->mu);
        if (session->in_w >= 0) { close(session->in_w); session->in_w = -1; }
        session->cv.notify_all();
    }

    // The readers notice stop within kReaderPollMs and then close their ends; the
    // waiter notices after its current OP_WAIT round trip. Nothing is joined, so
    // this call cannot hang on a grandchild that still holds a pipe.
    return true;
}

std::string List() {
    char buffer[256 * 1024];
    uint32_t len = 0;

    if (iec_rpc_call(EXEC_SOCK_PATH, OP_LIST, nullptr, 0, buffer, sizeof buffer,
                     &len) < 0) {
        return std::string();
    }
    return std::string(buffer, len);
}

size_t Count() {
    std::lock_guard<std::mutex> lock(g_registry_mu);
    return g_sessions.size();
}

}  // namespace iec
