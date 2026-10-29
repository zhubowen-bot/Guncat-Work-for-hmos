// exec/exec_shebang.h — the route for a file whose first line is #!
#pragma once

#include <sys/types.h>

#include <string>

#include "exec_types.h"

// Whether the file is one, and -- in the three-argument form -- what it names: the
// interpreter, and the single optional argument the kernel allows between it and the
// script's path. One read answers both, of the first line only and only for a regular
// file: the path comes from whoever asked, and opening a fifo would block the thread
// serving the request. The first form is what the kind decision asks.
bool ReadShebang(const std::string& path);
bool ReadShebang(const std::string& path, std::string& interp, std::string& arg);

// Starts what the script names, with the script as its first argument, which is what the
// kernel does with a file of this kind. Runs in the child of fork(), under the same rules
// as the other routes: the caller has installed the inherited descriptors, cleared the
// signal mask and given the child a process group of its own.
//
// The interpreter is started by the route its own kind names, so this either leaves through
// that route -- which does not come back -- or returns -1 for a script that cannot be
// followed, which the caller of the routes reports.
pid_t SpawnShebang(const SpawnRequest& req);
