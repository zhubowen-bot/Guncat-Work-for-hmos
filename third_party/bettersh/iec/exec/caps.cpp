// exec/caps.cpp — probing what this host can do.
//
// The five answers are taken once, before any request is served, because they
// decide which route a program will be started by (see ResolveKind). Most probes
// answer by observation rather than by guessing from an errno:
//
//   fork  — a child writes one byte through a pipe. A signal handler installed by
//           the host (a runtime's SIGCHLD reaper, say) can collect the child
//           before we do, so waitpid() alone would report a false negative.
//   path  — what is visible, because that is what a rewritten absolute path has
//           to be looked up in.
//   exec  — a forked child tries execve("/bin/sh"). The write end of the pipe is
//           close-on-exec, so EOF means the image was replaced and a number means
//           it was not.
//   jit   — the code below is actually mapped and jumped into. A mapping with
//           PROT_EXEC on it can still fault, and the only way to know is to run
//           something. A fault is caught and turned into "no", not a crash.
//   chmod — a policy level rather than an observation: what the shims will let a
//           guest change, limited by the device class. See ProbeChmod().
#include "caps.h"

#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__linux__)
#  include <sys/prctl.h>
#endif

#include <dlfcn.h>

#include "logger/logger.h"

// execve() takes the environment as a plain array; the C library owns it.
extern char** environ;

namespace {

HostCapabilities g_caps;

constexpr size_t kProbePage = 4096;

// The 'jit' prctl option HarmonyOS uses to open its W^X gate: the same value the
// elfloader's jit_toggle passes. It is spelled out rather than included from a
// header because the option is not in the toolchain's headers.
constexpr long kJitPrctlOpt = 0x6a6974L;

void LogCaps(const char* source) {
    Logger::GetInstance()->LogI(
        "[exec] capabilities (%s): chmod=%d fork=%d exec=%d jit=%d path=%d ncp=%d (0x%llx)",
        source, g_caps.chmod, g_caps.fork, g_caps.exec, g_caps.jit, g_caps.path,
        g_caps.ncp,
        static_cast<unsigned long long>(PackCaps(g_caps)));
}

/* ------------------------------------------------------------------ */
/* fork                                                               */
/* ------------------------------------------------------------------ */

// A child that writes one byte and leaves. The byte is the observation: a child
// that never ran writes nothing, and a child that a runtime's SIGCHLD handler
// reaped still wrote it. waitpid() is attempted afterwards only to avoid a
// zombie; it is not part of the answer.
static int ProbeFork() {
    int fds[2];
    if (pipe(fds) != 0) return 0;

    pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return 0;
    }
    if (pid == 0) {
        close(fds[0]);
        const char b = 'f';
        ssize_t w = write(fds[1], &b, 1);
        (void)w;
        _exit(0);
    }

    close(fds[1]);
    char b = 0;
    ssize_t n = read(fds[0], &b, 1);
    close(fds[0]);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}

    return n == 1 && b == 'f';
}

/* ------------------------------------------------------------------ */
/* path                                                               */
/* ------------------------------------------------------------------ */

// 0: only what an app is given. 1: the system paths a sandbox keeps. 2: the disk
// at large. /bin/sh is the file a sandbox leaves executable, so it is the one
// worth asking about first.
static int ProbePath() {
    struct stat st;
    if (stat("/bin/sh", &st) != 0) return 0;
    if (stat("/usr", &st) == 0 && stat("/etc", &st) == 0) return 2;
    return 1;
}

/* ------------------------------------------------------------------ */
/* chmod                                                              */
/* ------------------------------------------------------------------ */

// This one is policy rather than an observation: a sandbox may accept chmod on
// files it owns while refusing it everywhere else, and whether the system user
// directories accept it is a property of the device class. A phone or tablet is
// therefore limited to its own tree (1). A 2in1 additionally accepts the user's
// files (2); the app layer pins that value, because the same native library runs
// on both. A host build can change anything (3).
static int ProbeChmod() {
#if defined(__OHOS__)
    return 1;
#else
    return 3;
#endif
}

/* ------------------------------------------------------------------ */
/* exec                                                               */
/* ------------------------------------------------------------------ */

// Whether one path may be executed. Returns 0 when the exec went through, -1
// with *out_errno set otherwise. The child's three descriptors point at
// /dev/null: a probe must not read from the server's own stdin.
static int TryExec(const char* path, int* out_errno) {
    int fds[2];
    if (pipe(fds) != 0) {
        *out_errno = errno;
        return -1;
    }
    // The pipe is the only channel for a failure, so it must not be inherited by
    // a successful exec. fcntl() rather than pipe2() keeps this portable.
    (void)fcntl(fds[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        *out_errno = errno;
        return -1;
    }
    if (pid == 0) {
        close(fds[0]);

        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            if (devnull > STDERR_FILENO) close(devnull);
        }

        // -c "exit 0" so a successful exec ends on its own instead of waiting on
        // the terminal a second time.
        char* argv[] = {
            const_cast<char*>(path),
            const_cast<char*>("-c"),
            const_cast<char*>("exit 0"),
            nullptr,
        };
        execve(path, argv, environ);

        const int e = errno;
        ssize_t w = write(fds[1], &e, sizeof e);
        (void)w;
        _exit(127);
    }

    close(fds[1]);
    int e = 0;
    ssize_t n = read(fds[0], &e, sizeof e);
    close(fds[0]);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}

    if (n == (ssize_t)sizeof e) {
        *out_errno = e;
        return -1;
    }
    *out_errno = 0;
    return 0;
}

// 0: not even the one path a sandbox keeps. 1: that path and no more -- /bin/sh
// is what a sandbox leaves executable, which is what makes a shebang reachable
// and nothing else. 2: the disk at large.
static int ProbeExec(int path_caps, int fork_ok) {
    if (!fork_ok) return 0;

    int e = 0;
    if (TryExec("/bin/sh", &e) != 0) return 0;
    return path_caps >= 2 ? 2 : 1;
}

/* ------------------------------------------------------------------ */
/* jit                                                                */
/* ------------------------------------------------------------------ */

// The instructions the probe runs. Both return 42, which is what tells "the page
// was really executed" apart from "the mapping was created".
static const unsigned char kJitCode[] = {
#if defined __aarch64__
    0x40, 0x05, 0x80, 0x52,   // mov w0, #42
    0xc0, 0x03, 0x5f, 0xd6,   // ret
#elif defined __x86_64__
    0xb8, 0x2a, 0x00, 0x00, 0x00,   // mov eax, 42
    0xc3,                            // ret
#else
#  error "no JIT probe code for this architecture: write the two instructions here"
#endif
};

static sigjmp_buf g_jit_jump;

static void OnJitFault(int sig) {
    (void)sig;
    siglongjmp(g_jit_jump, 1);
}

// Runs the code at p and reports whether it returned 42. A fault is a no, not a
// crash: the three signals a bad mapping or a bad instruction raises are caught
// here and turned back into an answer, because the failing case has to be
// survivable for the probe to be worth anything.
static bool RunJitCode(void* p) {
    struct sigaction sa;
    struct sigaction old_segv, old_bus, old_ill;

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = OnJitFault;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGBUS, &sa, &old_bus);
    sigaction(SIGILL, &sa, &old_ill);

    volatile bool ok = false;
    if (sigsetjmp(g_jit_jump, 1) == 0) {
        int (*fn)(void) = reinterpret_cast<int (*)(void)>(p);
        ok = (fn() == 42);
    }

    sigaction(SIGSEGV, &old_segv, nullptr);
    sigaction(SIGBUS, &old_bus, nullptr);
    sigaction(SIGILL, &old_ill, nullptr);
    return ok;
}

#if defined(__linux__)
static int JitToggle(int on) {
    return prctl(kJitPrctlOpt, 0, on, 0, 0);
}
#endif

// 3: an anonymous mapping that is writable and executable from the start.
static bool ProbeAnonRwx() {
    void* p = mmap(nullptr, kProbePage, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return false;
    memcpy(p, kJitCode, sizeof kJitCode);
    const bool ok = RunJitCode(p);
    munmap(p, kProbePage);
    return ok;
}

// 2: a file that exists only in memory (memfd_create), written and mapped
// executable. On a host that forbids anonymous executable memory this is the
// door that often stays open.
#if defined(__linux__) && defined(SYS_memfd_create)
static bool ProbeMemfd() {
    const int fd = static_cast<int>(syscall(SYS_memfd_create, "iec-jit-probe", 0u));
    if (fd < 0) return false;

    bool ok = false;
    if (ftruncate(fd, static_cast<off_t>(kProbePage)) == 0 &&
        write(fd, kJitCode, sizeof kJitCode) == (ssize_t)sizeof kJitCode) {
        void* p = mmap(nullptr, kProbePage, PROT_READ | PROT_EXEC,
                       MAP_PRIVATE, fd, 0);
        if (p != MAP_FAILED) {
            ok = RunJitCode(p);
            munmap(p, kProbePage);
        }
    }
    close(fd);
    return ok;
}
#endif

// 1/4/5: writable memory first, then asked for execution afterwards. The two
// prctl variants mirror the elfloader's route: on HarmonyOS a bare mprotect can
// be refused while the same call between the JIT gate's off/on pair succeeds.
static bool ProbeMprotect(int prot, bool toggle) {
    void* p = mmap(nullptr, kProbePage, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return false;
    memcpy(p, kJitCode, sizeof kJitCode);

#if defined(__linux__)
    if (toggle) JitToggle(0);
#endif
    const int rc = mprotect(p, kProbePage, prot);
#if defined(__linux__)
    if (toggle) JitToggle(1);
#endif

    bool ok = false;
    if (rc == 0) ok = RunJitCode(p);
    munmap(p, kProbePage);
    return ok;
}

static int ProbeJit() {
    if (ProbeAnonRwx()) return 3;

#if defined(__linux__) && defined(SYS_memfd_create)
    if (ProbeMemfd()) return 2;
#endif

    if (ProbeMprotect(PROT_READ | PROT_WRITE | PROT_EXEC, false)) return 1;

#if defined(__linux__)
    if (ProbeMprotect(PROT_READ | PROT_WRITE | PROT_EXEC, true)) return 4;
    if (ProbeMprotect(PROT_READ | PROT_EXEC, true)) return 5;
#endif

    return 0;
}

/* ------------------------------------------------------------------ */
/* ncp                                                                */
/* ------------------------------------------------------------------ */
// ncp: whether the platform can create a native child process. The capability is
// the library the API lives in plus the entry point itself: a device may ship one
// without the other, and half of an API is no API.
static int ProbeNCP() {
#if defined(__OHOS__)
    static const int capability = [] {
        static const char* kCandidates[] = {
            "libchild_process.so",
            "/system/lib64/ndk/libchild_process.so",
            "/system/lib64/platformsdk/libchild_process.so",
        };
        void* lib = nullptr;
        for (const char* candidate : kCandidates) {
            lib = dlopen(candidate, RTLD_NOW | RTLD_LOCAL);
            if (lib != nullptr) break;
        }
        if (lib == nullptr) return 0;
        const bool ok =
            dlsym(lib, "OH_Ability_StartNativeChildProcess") != nullptr;
        dlclose(lib);
        return ok ? 1 : 0;
    }();
    return capability;
#else
    return 0;
#endif
}

}  // namespace

/* ------------------------------------------------------------------ */
/* the packed word                                                    */
/* ------------------------------------------------------------------ */

uint64_t PackCaps(const HostCapabilities& caps) {
    return (static_cast<uint64_t>(caps.ncp & kCapMask) << kCapNcpShift) |
           (static_cast<uint64_t>(caps.chmod & kCapMask) << kCapChmodShift) |
           (static_cast<uint64_t>(caps.fork & kCapMask) << kCapForkShift) |
           (static_cast<uint64_t>(caps.exec & kCapMask) << kCapExecShift) |
           (static_cast<uint64_t>(caps.jit & kCapMask) << kCapJitShift) |
           (static_cast<uint64_t>(caps.path & kCapMask) << kCapPathShift);
}

HostCapabilities UnpackCaps(uint64_t cap) {
    HostCapabilities caps;
    caps.ncp   = static_cast<int>((cap >> kCapNcpShift) & kCapMask);
    caps.chmod = static_cast<int>((cap >> kCapChmodShift) & kCapMask);
    caps.fork = static_cast<int>((cap >> kCapForkShift) & kCapMask);
    caps.exec = static_cast<int>((cap >> kCapExecShift) & kCapMask);
    caps.jit  = static_cast<int>((cap >> kCapJitShift) & kCapMask);
    caps.path = static_cast<int>((cap >> kCapPathShift) & kCapMask);
    return caps;
}

const HostCapabilities& Caps() {
    return g_caps;
}

uint64_t ProbeCapabilities() {
    g_caps.chmod = ProbeChmod();
    g_caps.fork  = ProbeFork();
    g_caps.path  = ProbePath();
    g_caps.exec  = ProbeExec(g_caps.path, g_caps.fork);
    g_caps.jit   = ProbeJit();
    g_caps.ncp   = ProbeNCP();

    LogCaps("probe");
    return PackCaps(g_caps);
}

void ProbeCapabilities(uint64_t* cap) {
    const uint64_t packed = ProbeCapabilities();
    *cap = packed;
}

void setCaps(uint64_t cap) {
    g_caps = UnpackCaps(cap);
    LogCaps("setCaps");
}
