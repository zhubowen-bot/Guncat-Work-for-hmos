// exec/caps.h — what this host can do, and the one word the probes are packed into.
//
// The five answers decide how a program is started (see ResolveKind in
// exec_server.cpp), so they are taken once at start-up and read from here after
// that. Each field is one hexadecimal digit -- four bits -- in the packed word:
//
//     chmod << 16 | fork << 12 | exec << 8 | jit << 4 | path
//
// written as five hexadecimal digits. 0x12322 therefore means chmod=1, fork=2,
// exec=3, jit=2, path=2; 0x11030 means chmod=1, fork=1, jit=3 and everything
// else zero. Hexadecimal rather than the earlier octal packing is used so the
// same word can be written as 0x... from C, C++, ArkTS and scripts alike. The
// packing exists so the whole answer can be written down as one number --
// logged at start-up, or carried in a bug report -- without a struct having to
// travel with it.
#pragma once

#include <cstdint>

struct HostCapabilities {
    /* CHMOD: how far the host's own chmod reaches. 0 = nowhere, 1 = only inside
     * the application sandbox, 2 = also inside the system user directories (for
     * example /storage/Users/currentUser), 3 = anywhere. */
    int chmod = 0;

    /* FORK: 0 = fork is unavailable, 1 = fork + waitpid work. */
    int fork = 0;

    /* EXEC: 0 = execve is unavailable, 1 = only the paths a sandbox keeps (the
     * one /bin/sh lives in) may be executed, 2 = the disk at large may be. */
    int exec = 0;

    /* JIT: 0 = no writable-executable memory can be obtained, 1 = RW then
     * mprotect(PROT_EXEC), 2 = memfd, 3 = anonymous RWX, 4 = prctl(jit) + RWX,
     * 5 = prctl(jit) + RX. Only "zero or not" is used for routing today; the
     * exact route is kept for diagnostics. */
    int jit = 0;

    /* PATH: 0 = only the app sandbox is reachable, 1 = part of the system path
     * is reachable, 2 = the disk at large is reachable. This is what decides
     * whether an absolute path has to be rewritten into the fake root. */
    int path = 0;

    /* NCP: 0 = disabled, 1 = enabled. 
     * Whether to use Native Child Process (in HarmonyOS). */
    int ncp = 0;
};

constexpr int kCapNcpShift   = 20;
constexpr int kCapChmodShift = 16;
constexpr int kCapForkShift  = 12;
constexpr int kCapExecShift  = 8;
constexpr int kCapJitShift   = 4;
constexpr int kCapPathShift  = 0;
constexpr uint64_t kCapMask = 0xF;

uint64_t PackCaps(const HostCapabilities& caps);
HostCapabilities UnpackCaps(uint64_t cap);

// The answers the rest of the server reads. Zero-initialised until a probe or an
// explicit set has run.
const HostCapabilities& Caps();

// Probes the host and returns the packed word.
uint64_t ProbeCapabilities();

// Compatibility with the earlier signature: probe and write the word out.
void ProbeCapabilities(uint64_t* cap);

// Pins the answers explicitly. This is what main.cpp uses to make the routing of
// a build reproducible. There is no "already probed" flag beside it, so a later
// call to ProbeCapabilities() would overwrite this value.
void setCaps(uint64_t cap);
