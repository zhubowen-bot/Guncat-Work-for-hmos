// common/sock_operation.h - wire operation numbers.
//
// Shared by the C shims and the C++ servers so the two cannot drift apart. The
// values are part of the wire protocol: keep them explicit and only ever append.
//
// Each service is reached over its own socket, so numbers only have to be unique
// within one service -- except for OpCommon, which every service answers with the
// same number. That shared block is also why the per-service enums start at 2:
// enum members live in the surrounding scope, so two enums that both defined
// OP_PING would collide at compile time rather than politely coexist.
//
// Plain enums, not "enum : uint32_t", so that this header also compiles as C.
#ifndef SOCK_OPERATION_H
#define SOCK_OPERATION_H

#include <assert.h>

#define OP_COMMON_START 1
#define OP_TTY_START    101
#define OP_EXEC_START   201

/* Answered by every service, on every socket. */
enum OpCommon {
    OP_PING = OP_COMMON_START,
    OP_PONG = OP_COMMON_START + 1,

    OP_COMMON_END,
};

enum OpTty {
    // Reserved. The shim implements forkpty() as openpty() + fork() + login_tty()
    // locally, so the server is never asked to fork.
    OP_FORKPTY  = OP_TTY_START,
    // Reserved. The tty state lives on the server now, so this op is unused.
    OP_IOCTL    = OP_TTY_START + 1,
    OP_OPENPTMX = OP_TTY_START + 2,   /* open("/dev/ptmx")   -> master fd + pts number */
    OP_OPENPTS  = OP_TTY_START + 3,   /* open("/dev/pts/<n>") -> slave fd */

    // The server owns the termios, the window size and the foreground process
    // group of every pty, so the client asks for them instead of keeping a copy
    // that would drift. Every request names its pts in the first 4 body bytes,
    // because the client's fd numbers mean nothing on the server.
    //
    // termios and winsize travel as plain struct bytes: both processes run on
    // the same machine and the same ABI, and the struct is a fixed-size value
    // type with no padding traps.
    OP_TCGETATTR = OP_TTY_START + 4,  /* [pts]              -> struct termios */
    OP_TCSETATTR = OP_TTY_START + 5,  /* [pts][action][termios] */
    OP_TCGETPGRP = OP_TTY_START + 6,  /* [pts]              -> pid */
    OP_TCSETPGRP = OP_TTY_START + 7,  /* [pts][pid] */
    OP_GETWINSZ  = OP_TTY_START + 8,  /* [pts]              -> struct winsize */
    OP_SETWINSZ  = OP_TTY_START + 9,  /* [pts][winsize] */

    /* One fd attached (SCM_RIGHTS), no body -> [pts][is_master], or an empty body
     * for "not one of mine". Which pty a descriptor belongs to, asked by a shim that
     * has lost the mapping: an exec replaces the image and the table with it, and
     * only the three descriptors login_tty takes over can have their pts number
     * carried in the environment. The service recognises the fd by the socket it is
     * (see TtyServer::onIdentify), so the descriptor is the whole of the request. */
    OP_IDENTIFY  = OP_TTY_START + 10,

    OP_TTY_END,
};

/* How a client entered the exec service, i.e. which member of the exec family it
 * called. The family all means the same thing -- the program takes the caller's
 * place -- and the seven members differ only in how the program is named and
 * where the environment comes from, so a server that wants to know where the
 * program belongs in the process tree needs the distinction rather than a single
 * "exec happened" flag. A future spawn-family call (one that gives the caller a
 * child instead of replacing it) would need its own method here, and then the
 * act of spawning really would differ, not just the argument list.
 *
 * Plain enum like the op enums above, so this header also compiles as C. */
enum CallMethod {
    CALL_EXECVE, CALL_EXECV, CALL_EXECVP, CALL_EXECVPE,
    CALL_EXECL, CALL_EXECLP, CALL_EXECLE,

    /* Not a call method, and never sent: the count, so that a request carrying a
     * method can be checked against a bound instead of against the last member by
     * name (which would silently widen the check if a member were ever added).
     * Follows the _END convention of the op enums above. */
    CALL_METHOD_END,
};

enum OpExec {
    // [flags][call_method][argc][envc][fd_count], then fd_count 4-byte target_fd
    // words, then the NUL-terminated strings. The caller's pid is not part of this
    // body, nor of the packet: the server reads it off the connection with
    // SO_PEERCRED (see Packet::caller). Both the encoder and the decoder carry the
    // full description: exec/shim.c next to the request buffer, and
    // ExecServer::onExecute().
    OP_EXECUTE = OP_EXEC_START,
    // [4 bytes remote pid] -> [4 bytes state][4 bytes status]; see the wait loop
    // in exec/shim.c for what the client does with the two answer words.
    OP_WAIT    = OP_EXEC_START + 1,
    // [4 bytes remote pid][4 bytes signo] -> empty. Asks for a signal to be
    // delivered to a program this server spawned, on behalf of the stand-in that
    // caught it; see the signal table in exec/shim.c for why the program cannot
    // be reached directly.
    OP_SIGNAL  = OP_EXEC_START + 2,

    // [4 bytes grace_ms][job string, NUL-terminated] -> [4 bytes killed].
    //
    // Ends every program this server started under one job id, and everything
    // they started in turn. A job is a name the caller puts in the child's
    // environment as IEC_JOB=<id>; the server copies it into its process table
    // when the child is created, and because the environment is inherited, a
    // program's own exec calls arrive carrying the same name. That is what makes
    // this reach further than a signal: a plain kill(pid) can only name one
    // process, and the processes a shell or a build tool starts are not this
    // server's children in a way that can be walked back from the pid alone
    // (exec fills the table as if the caller had been replaced -- see
    // ParentPidFor() -- so the recorded tree is deliberately flat).
    //
    // grace_ms is how long a program is given between SIGTERM and SIGKILL; 0
    // means SIGKILL straight away. The reply counts the processes that were
    // named, not the ones that have already been reaped.
    OP_TERMINATE_JOB = OP_EXEC_START + 3,

    // empty -> one text line per process this server started:
    //   "pid <n> job <id> alive <0|1> code <n> cmd <path>"
    // Job ids contain no spaces, so the line can be split on them. This exists
    // for diagnostics and for a caller that wants to reconcile its own sessions
    // after a restart; nothing in the server depends on it.
    OP_LIST = OP_EXEC_START + 4,

    // [4 bytes signo][job string, NUL-terminated] -> [4 bytes signaled].
    //
    // Sends one signal to every live process of a job without ending the job or
    // scheduling a follow-up. OP_TERMINATE_JOB is the blunt form used when the
    // whole tool call is cancelled; this one exists for programs that implement
    // their own deadline (toybox `timeout`): it needs TERM first, then KILL
    // after its own grace period, and it must not reach the shell that started
    // it. A job name may be a sub-job ("<parent>/t<pid>"); JobPids() matches
    // those as part of the parent, so a tool-level cancel still reaches them.
    OP_SIGNAL_JOB = OP_EXEC_START + 5,

    OP_EXEC_END,
};

/* Compile-time guard that the numbering cannot collide. This header is included
 * from C too, where the spelling is _Static_assert (a C11 keyword) and the C++
 * static_assert is not a keyword at all. */
#ifdef __cplusplus
static_assert(OP_COMMON_END <= OP_TTY_START, "OpTty reuses an OpCommon number");
static_assert(OP_TTY_END <= OP_EXEC_START, "OpExec reuses an OpTty number");
#else
_Static_assert(OP_COMMON_END <= OP_TTY_START, "OpTty reuses an OpCommon number");
_Static_assert(OP_TTY_END <= OP_EXEC_START, "OpExec reuses an OpTty number");
#endif

#endif /* SOCK_OPERATION_H */
