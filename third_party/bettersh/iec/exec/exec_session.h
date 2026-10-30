// exec/exec_session.h — running a program as a session rather than as an exec.
//
// exec/shim.c exists for a program that *becomes* another one: the caller's image
// is replaced, its stdio is a terminal, and the only thing it wants back is the
// exit status. A caller that runs commands on behalf of somebody else -- an
// agent, a task runner, a UI that shows output as it appears -- needs the other
// shape: a child of its own, pipes it can read at its own pace, a deadline, and
// a handle it can cancel.
//
// That is what this file provides. It is a client of the same exec service the
// shim talks to, so both routes start programs the same way, resolve PATH and the
// fake root the same way, and agree on what an exit status is. What is added here
// is only the part the shim has no use for: the pipes, the buffers, the deadline,
// and the job id that makes a whole process tree cancellable.
//
// A session is identified by an int that this module assigns; the pid is the
// program's, and the job is the name every process of the tree carries in
// IEC_JOB. Sessions are process-wide: one registry, one id space.
//
// Lifetime: Start() returns an id, Poll()/Wait() consume it, Release() frees it.
// A session that is still running may be Released only after Terminate() has
// been asked for and the program has been seen to end; Release() refuses
// otherwise, because dropping the pipes of a live child would leave it writing
// into a closed descriptor (SIGPIPE) with nobody to collect its status.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace iec {

struct ExecOptions {
    // The program. A bare name is looked up on PATH exactly as execvp() would;
    // a name containing '/' is a path. Never empty.
    std::string cmd;

    // argv[1..]. argv[0] is cmd itself -- there is deliberately no way to give the
    // program a different argv[0], because every caller that wants one is really
    // asking for a shell, and a shell can do it.
    std::vector<std::string> args;

    // Working directory. Empty means the fake root's home (IEC_DEFAULT_HOME),
    // which is where an agent's files usually are; a relative path is resolved
    // against it. The service's own cwd is the application's, which is not a
    // useful default for a command runner.
    std::string cwd;

    // "NAME=VALUE" overrides. By default they are laid over this process's
    // environment (the same inheritance execve() would give); env_replace makes
    // them the whole environment.
    std::vector<std::string> env;
    bool env_replace = false;

    // Written to the child's stdin before the first byte of output is read. The
    // pipe is closed afterwards unless keep_stdin_open is set, which is what
    // makes a program that reads to EOF see one.
    std::string stdin_data;
    bool keep_stdin_open = false;

    // Wall-clock deadline. 0 means none. When it passes the job is terminated --
    // SIGTERM, then SIGKILL after an internal grace period -- and the state says
    // timed_out. This is the only deadline in the system that is enforced even if
    // the caller stops polling, which is the point of having it here rather than
    // in the caller.
    int timeout_ms = 0;

    // Bytes the caller may receive per stream over the session's whole life.
    // Output beyond it is read and dropped (a pipe that is not drained would
    // block the program), and the state reports how much was dropped. 0 selects
    // the default; the cap exists because a command that prints for an hour must
    // not become an hour of memory. Draining the buffer with Poll() does not
    // restore the budget: a caller that polls while the program runs still sees
    // at most this many bytes.
    size_t max_output_bytes = 0;

    // The job id. Empty means this module generates one. Every process of the
    // tree carries it in IEC_JOB, and Terminate() ends all of them; a caller that
    // wants several sessions to share a fate can pass the same id.
    std::string job;
};

struct ExecState {
    int         id = -1;
    int         pid = -1;
    std::string job;

    bool running = false;      // the program has not been seen to end
    bool exited = false;       // ... and it has
    int  exit_code = -1;       // 0-255, or 128+signal as a shell renders it
    int  signal = 0;           // the signal that ended it, or 0

    bool timed_out = false;    // this session's own deadline fired
    bool out_eof = false;
    bool err_eof = false;
    size_t out_dropped = 0;    // bytes read and discarded because of the cap
    size_t err_dropped = 0;
};

// One Poll()'s worth of output. The bytes are consumed: the next call returns only
// what has arrived since. Empty when nothing is new.
struct ExecChunk {
    std::string out;
    std::string err;
};

// Starts a program. On success returns a session id and fills *state with the pid
// and job; on failure returns -1 and, when error is not null, a message that says
// what went wrong (the service's own refusal, or a transport failure).
int Start(const ExecOptions& options, ExecState* state, std::string* error);

// Consumes up to max_out / max_err bytes of output and reports the state.
// Returns false when the id is unknown (already released).
bool Poll(int id, size_t max_out, size_t max_err, ExecChunk* chunk,
          ExecState* state);

// Waits until the program ends or timeout_ms passes (0 = wait for ever). The
// state says which happened; a timeout here does not end the program by itself --
// that is ExecOptions::timeout_ms. Returns false only for an unknown id.
bool Wait(int id, int timeout_ms, ExecState* state);

// Writes to the child's stdin without blocking: returns the number of bytes
// accepted (0 when the pipe is full), or -1 when the session has no stdin left.
long Write(int id, const void* data, size_t size);

// Closes the child's stdin, which is how a program that reads to EOF is told
// there is no more. Idempotent.
bool CloseStdin(int id);

// Ends every process of the session's job: SIGTERM now, SIGKILL after grace_ms
// (0 = SIGKILL at once). This is the cancellation path; the state's timed_out is
// not set, because the caller asked rather than the deadline.
bool Terminate(int id, int grace_ms);

// Sends one signal to the program and its process group, without the escalation.
// SIGINT from a UI's stop button is this; SIGKILL is Terminate(id, 0).
bool Signal(int id, int signo);

// Frees a session. Refused while the program is still running; after that it
// closes the pipes and drops the buffers. The id becomes invalid.
bool Release(int id);

// The service's process table as one text line per process, exactly as OP_LIST
// renders it. Empty when the service cannot be reached. For diagnostics.
std::string List();

// Number of live sessions this process knows about (running or not released).
size_t Count();

}  // namespace iec
