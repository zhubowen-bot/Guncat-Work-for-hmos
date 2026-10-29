// exec/exec_ncp.h — starting a program in a process the platform creates.
//
// On HarmonyOS a process can be started by the system instead of by fork(): the
// caller names a library in the bundle and an entry in it, the platform creates a
// process of the application's own kind, loads the library there and calls the
// entry. The process never inherits the application's address space, which matters
// for a command object that is a second copy of a runtime the host already has
// (node inside Electron is the case in point) and is also the only way to get the
// memory back.
#pragma once

#include <sys/types.h>

#include <string>

#include "exec_types.h"

// True when this build can use the API and the platform offers the entry point
// that takes arguments. A device can ship the library without the entry; half of
// an API is no API, so both are required.
bool NcpSupported();

// Starts `req` in a native child process. Only the launcher mechanism (kSo) is
// supported: the point of this route is loading the object in a fresh process, and
// the entry of any other mechanism would have to be reimplemented in the loaded
// library.
//
// The pid the platform returns is not a child of this process, so waitpid() cannot
// collect it; the ending arrives through the platform's exit callback and is drained
// by DrainNcpExits(). Returns -1 with the reason in *err (err may be null).
pid_t SpawnNcp(const SpawnRequest& req, LaunchKind kind, std::string* err);

// Takes the endings collected since the last call and hands each to the handler as
// (pid, wait status). The platform calls its exit callback on a thread of its own,
// so that callback only queues; the server's own loop drains the queue and is the
// only place the process table is touched.
void DrainNcpExits(void (*handler)(pid_t pid, int status));
