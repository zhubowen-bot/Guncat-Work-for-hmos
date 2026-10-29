// exec/exec_route.cpp — the kind decision, kept where a host test can reach it.
//
// ResolveKind() answers only "how would this path be entered?" from the path and
// the capability word; it starts nothing and touches no server state. It used to
// live in exec_server.cpp, where reaching it meant linking the whole service (and
// its sockets, threads and tables). The definition moved here so that
// scripts/test_iec_native_host.sh can pin the routing rules. One rule changed in
// the move: a #IECSOv2 launcher now resolves to kSo even when fork is unavailable,
// because gating it on fork was a real regression (every command on a no-fork
// device resolved to kUnexecutable even though the NCP route could start it).
#include "exec_route.h"

#include "caps.h"
#include "elf.h"
#include "exec_shebang.h"
#include "exec_so.h"

LaunchKind ResolveKind(const std::string& path) {
    const HostCapabilities& caps = Caps();

    if (caps.fork == 1 && ReadShebang(path))  return LaunchKind::kShebang;
    // A launcher is not an executable image: it is a text file naming a .so and an
    // entry point. Recognising it therefore must not depend on fork -- the native
    // child process route loads the same launcher (SpawnNcp handles kSo too), so
    // gating this on fork made every command on a no-fork device resolve to
    // kUnexecutable while an NCP route was available.
    if (IsSoLauncher(path)) return LaunchKind::kSo;

    const uint16_t machine = ElfMachine(path);
    const bool host_arch = machine == HOST_ARCH;

    // An executable bit that exists only in <path>.IEC_CHMOD is not visible to
    // execve(): the kernel will still see the old mode and fail. Route such a
    // file through a loader that does not ask the kernel about the bit.
    const bool emulated_exec = EmulatedExecutable(path);

    if (host_arch && caps.fork == 1) {
        if (caps.exec == 2 && !emulated_exec) return LaunchKind::kExec;
        if (caps.jit > 0) return LaunchKind::kLoader;
    }

    if (machine == EM_AARCH64) return LaunchKind::kQemu_aarch64;
    if (machine == EM_X86_64) return LaunchKind::kQemu_x86_64;
    return LaunchKind::kUnexecutable;
}
