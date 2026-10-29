// exec/exec_loader.h — the in-process loader route.
//
// A host-architecture ELF is mapped and entered in this process: the caller is
// already a child of the exec server, so a guest that calls exit_group ends
// only that child. SpawnLoader() is the router behind LaunchKind::kLoader; see
// loader/loader.cpp for the mapping and interpreter hand-off.
#pragma once

#include <sys/types.h>

#include "exec_types.h"

// Starts req.path in this process. Returns only on failure -- every successful
// path leaves through _exit(); the caller reports the failure and exits 127.
pid_t SpawnLoader(const SpawnRequest& req);
