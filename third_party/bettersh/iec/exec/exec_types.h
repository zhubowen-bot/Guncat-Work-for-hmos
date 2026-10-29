// exec/exec_types.h — what a request to start a program carries, and the ways one
// can be started.
//
// Both halves of the exec service need these: exec_server.cpp builds the requests
// and decides how to serve them, and the launcher for a shared object (exec_so.cpp)
// reads one to run its entry. They live here so that the launcher can see the shape
// without including the server.
#pragma once

#include <sys/types.h>

#include <string>
#include <vector>

#include "sock_operation.h"

// How a program is started. Two questions, kept apart because the platform offers
// more than one way to get a separate process at all:
//
//   primary   -- what the new process *is* with respect to this one: a fork of the
//                server (kFork), a process the platform creates and loads a library
//                into (kNcp, HarmonyOS's native child process), or no new process
//                at all (kInProc, not implemented).
//   secondary -- how the program is entered once that process exists: execve, a
//                shared object's entry, a loader, a script's interpreter, qemu.
//
// ResolveKind() answers the secondary question from the path; ChoosePrimary()
// answers the primary one from the capabilities and from the launcher.
enum class PrimaryLaunchKind {
    kAuto    = 0,   // the launcher left the choice to the server
    kFork    = 1,
    kNcp     = 2,
    kInProc  = 3,
};

enum class SecondaryLaunchKind {
    kAuto         = 0,   // nobody has decided yet
    kExec         = 1,    // plain execve
    kSo           = 2,    // a shared object, entered through the dlopen
    kLoader       = 3,
    kShebang      = 4,
    kQemu_x86_64  = 5,    // emulated, qemu in the program's place
    kQemu_aarch64 = 6,
    kUnexecutable = 0xff, // no way to run this path
};

// The mechanism is what most of the code names; keep the concise spelling.
using LaunchKind = SecondaryLaunchKind;

struct InheritedFd {
    int source_fd;
    int target_fd;
};

struct SpawnRequest {
    std::string path;                       // The path of the executable file
    std::vector<std::string> argv;          // argv[0] is the command name
    std::vector<std::string> env;           // "K=V"
    std::string cwd;                        // empty is inherit
    PrimaryLaunchKind prikind = PrimaryLaunchKind::kAuto;
    LaunchKind kind_hint = LaunchKind::kAuto;   // kAuto = the caller did not decide
    std::vector<InheritedFd> stdio_fds;     // target ∈ {0,1,2}
    std::vector<InheritedFd> extra_fds;     // target > 2; no request fills this yet
    int         sid = 0;
    bool        sync_wait = true;           // A foreground terminal command always waits.
    std::string proc_name;                  // prctl(PR_SET_NAME)
    CallMethod  call_method = CALL_METHOD_END;
    pid_t       caller_pid = 0;

    /* Which job this program belongs to, if any.
     *
     * Not a separate field on the wire: it is derived from the environment the
     * request already carries (IEC_JOB=<id>), for the same reason the terminal
     * session number is -- the child sees the variable, and the server records
     * the value the child actually got, so the two cannot disagree. A request
     * without the variable has an empty job, which is every request the shim
     * sends today; only a programmatic caller (exec_session.cpp) sets one.
     *
     * The point of carrying it in the environment rather than in a field the
     * server copies is inheritance: a program that execs something else sends
     * its own environment, so the next request arrives carrying the same
     * IEC_JOB and lands in the same job without the server having to reconstruct
     * a process tree (which it cannot do faithfully -- see ParentPidFor()). */
    std::string job;
};
