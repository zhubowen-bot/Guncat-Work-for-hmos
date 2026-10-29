// exec/exec_so.h — the launcher for a shared object.
//
// Where execve is not the way to start things but loading one still is, a program is
// started by naming a small text file -- the launcher -- that says which shared object
// to load and which entry point in it to call. exec_so.cpp is the whole of it;
// exec_server.cpp decides when this route applies (see ResolveKind) and calls it in
// the forked child.
#pragma once

#include <string>

#include "exec_types.h"

// What a launcher names: the object to load, the entry point to call in it, the
// shape that entry takes (2 for (argc, argv), 3 for (argc, argv, envp)), and whether
// the program wants a process of its own instead of a fork of the server.
struct SoLauncher {
    std::string so;
    std::string entry;
    int arity = 0;
    PrimaryLaunchKind primary = PrimaryLaunchKind::kAuto;
};

// Whether a path claims to be a launcher: its first line, and nothing more. A file
// that claims to be one and is then malformed is a launcher with something wrong in
// it, and that is worth reporting to whoever asked for the program -- which is why
// this is deliberately not the full check. See ResolveSoLauncher().
bool IsSoLauncher(const std::string& path);

// Reads a launcher in full. Returns false with the reason in *err when the file is
// not one or is not well formed; err may be null for a caller that only wants the
// answer.
bool ResolveSoLauncher(const std::string& path, SoLauncher& out, std::string* err);

// Starts the program a launcher names, in this process: it reads the launcher, loads
// the object it names and calls the entry, and is that program from then on. Returns
// only on failure -- every path that cannot start it calls _exit() -- and the status is
// what the caller's shell sees (125 when the launcher cannot be read as a launcher at
// all or the object will not load, 126 when the entry point is not in the object).
//
// This runs in the child of fork(), after the caller has installed the inherited
// descriptors, cleared the inherited signal mask and put the child in a process group
// of its own. Everything this route needs is here and not in the caller, so a launcher
// that does not parse reads to the client the same way an object that does not load
// does: as a status, rather than as a reply to its request.
//
// Reading a launcher allocates, and so does loading an object, and both happen in this
// child rather than in the server. That is deliberate: what the object does is the
// program's business and must not become the server's, and the loader's lock -- which
// this child shares with threads of the parent that no longer exist -- is the price of
// loading it here. The route pays that price once, for the whole of itself.
pid_t SpawnSo(const SpawnRequest& req);
