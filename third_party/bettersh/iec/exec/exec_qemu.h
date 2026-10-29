// exec/exec_qemu.h — starting a program that has to be emulated.
//
// The route exists for the architecture-shaped half of the kind decision. A host where
// execve is not how programs are started, and where the JIT probe came back zero, has no
// way to run a foreign binary except by emulation, and qemu-user is that emulator. It is
// built as a shared object rather than as a program because such a host cannot start
// programs either way -- see scripts/build_qemu.sh, which builds one object per guest
// architecture and installs the entry point this uses.
#pragma once

#include <sys/types.h>

#include "exec_types.h"

// Starts the guest program in this process, by loading the object that emulates its
// architecture and calling qemu_entry in it. Returns only on failure: every path that
// cannot start it calls _exit(), with the statuses the launcher route uses (125 for an
// object that will not load, 126 for an entry point that is not there -- see exec_so.h).
//
// It runs in the child of fork(), after the caller has installed the inherited
// descriptors, cleared the signal mask and given the child a process group of its own,
// under the same rules as SpawnSo(): what the guest does must not become the server's.
// The object is looked up by bare soname, so the search path has to be able to find it;
// scripts/build_qemu.sh prints the LD_LIBRARY_PATH that does.
pid_t SpawnQemu(const SpawnRequest& req);
