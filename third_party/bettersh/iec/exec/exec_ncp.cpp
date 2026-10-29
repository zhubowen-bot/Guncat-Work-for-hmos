// exec/exec_ncp.cpp — the native child process route.
//
// The platform owns the process: OH_Ability_StartNativeChildProcess() names a
// library and an entry, creates a process of the application's own kind, loads the
// library there and calls the entry with one string and a list of descriptors. What
// this file does is pack a SpawnRequest into that string and that list, and keep the
// ending the platform reports afterwards.
#include "exec_ncp.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <mutex>
#include <string>
#include <vector>

#include "common/constant.h"
#include "exec_ncp_protocol.h"
#include "exec_so.h"
#include "logger/logger.h"

#if defined(__OHOS__)
#include <AbilityKit/native_child_process.h>
#endif

namespace {

// One ending, as the platform reported it and as the exit file refined it. The
// status word is in waitpid()'s form so that the rest of the server -- and the
// client that polls OP_WAIT -- cannot tell this route from the forked one.
struct NcpExit {
    pid_t pid;
    int status;
};

std::mutex g_exit_lock;
std::vector<NcpExit> g_pending_exits;

// The exit file the loaded library writes, or 0 when it is gone. The file holds the
// decimal exit code the program returned; a program killed by a signal leaves none.
int ReadExitStatus(pid_t pid) {
    const std::string path = std::string(FAKE_SYSROOT) + IEC_NCP_EXIT_PREFIX +
                             std::to_string(pid);
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;

    char buf[32];
    const ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    unlink(path.c_str());
    if (n <= 0) return 0;

    buf[n] = '\0';
    const long code = strtol(buf, nullptr, 10);
    return static_cast<int>((code & 0xff) << 8);
}

// The platform's callback, on the platform's thread. Nothing here may touch the
// server's tables; the ending is queued and left for the loop that owns them.
//
// The second argument is documented as a signal, but what a device actually reports
// for an ordinary exit is that exit's code (0 for success, 1 for "printenv with an
// unknown name" ...). The file the loaded library writes is exact and is preferred;
// the argument is the fallback, read as an exit code. A program that dies of a
// signal therefore reads as an exit with that number instead of "killed by", which
// is the one thing this route cannot tell apart.
void OnNcpExit(int32_t pid, int32_t signal) {
    int status = ReadExitStatus(static_cast<pid_t>(pid));
    if (status == 0) status = static_cast<int>((signal & 0xff) << 8);

    std::lock_guard<std::mutex> lock(g_exit_lock);
    g_pending_exits.push_back({static_cast<pid_t>(pid), status});
}

#if defined(__OHOS__)
using StartFunc = Ability_NativeChildProcess_ErrCode (*)(
    const char*, NativeChildProcess_Args, NativeChildProcess_Options, int32_t*);
using RegisterExitFunc = Ability_NativeChildProcess_ErrCode (*)(
    void (*)(int32_t, int32_t));

struct NcpApi {
    StartFunc start = nullptr;
    RegisterExitFunc register_exit = nullptr;
    bool usable = false;
    bool exit_registered = false;
};

// The library is opened once. It is a system library, not something the app ships,
// so it is looked up by name; a device that does not have it answers "no support"
// rather than failing a request.
NcpApi& Api() {
    static NcpApi api = [] {
        NcpApi a;
        // By name first, which is how the application's own copy is found (it is
        // dlopen()ed here exactly as the adapter does it), then the two places a
        // release build keeps it.
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
        if (lib == nullptr) return a;

        a.start = reinterpret_cast<StartFunc>(
            dlsym(lib, "OH_Ability_StartNativeChildProcess"));
        a.register_exit = reinterpret_cast<RegisterExitFunc>(
            dlsym(lib, "OH_Ability_RegisterNativeChildProcessExitCallback"));
        // Without the exit callback a native child can be started but never waited
        // for, which is worse than the fork route: the caller would hang.
        a.usable = a.start != nullptr && a.register_exit != nullptr;
        return a;
    }();
    return api;
}
#endif  // __OHOS__

// Appends one field, and the separator that follows it.
void AddField(std::string* out, const std::string& value) {
    *out += value;
    *out += kIecNcpField;
}

// Appends one section, ending it.
void AddSection(std::string* out, const std::vector<std::string>& fields) {
    for (const std::string& field : fields) AddField(out, field);
    *out += kIecNcpSection;
}

}  // namespace

bool NcpSupported() {
#if defined(__OHOS__)
    return Api().usable;
#else
    return false;
#endif
}

pid_t SpawnNcp(const SpawnRequest& req, LaunchKind kind, std::string* err) {
    auto fail = [err](const std::string& why) -> pid_t {
        if (err != nullptr) *err = why;
        return -1;
    };

#if defined(__OHOS__)
    NcpApi& api = Api();
    if (!api.usable) return fail("the platform has no native child process API");
    if (kind != LaunchKind::kSo) return fail("only so file for now!");

    SoLauncher launcher;
    std::string why;
    if (!ResolveSoLauncher(req.path, launcher, &why)) {
        return fail("bad launcher " + req.path + ": " + why);
    }
    if (launcher.arity != 2 && launcher.arity != 3) {
        return fail("launcher arity must be 2 or 3");
    }

    // The payload: which object and entry, then the environment, then the argument
    // vector. The arity travels with the object so the child calls the entry the
    // way the object expects.
    std::string params;
    AddSection(&params, {launcher.so, launcher.entry,
                         std::to_string(launcher.arity), req.cwd, req.proc_name});
    AddSection(&params, req.env);
    AddSection(&params, req.argv);

    // The stdio the caller sent: the platform carries the source descriptor into the
    // child under the name the entry reads as the child-side number.
    std::vector<std::string> fd_names;
    fd_names.reserve(req.stdio_fds.size());
    std::vector<NativeChildProcess_Fd> nodes;
    nodes.reserve(req.stdio_fds.size());
    for (const InheritedFd& fd : req.stdio_fds) {
        fd_names.push_back(std::to_string(fd.target_fd));
        NativeChildProcess_Fd node{};
        node.fdName = const_cast<char*>(fd_names.back().c_str());
        node.fd = fd.source_fd;
        node.next = nullptr;
        nodes.push_back(node);
    }
    for (size_t i = 1; i < nodes.size(); i++) nodes[i - 1].next = &nodes[i];

    NativeChildProcess_Args args{};
    args.entryParams = const_cast<char*>(params.c_str());
    args.fdList.head = nodes.empty() ? nullptr : &nodes.front();

    NativeChildProcess_Options options{};
    options.isolationMode = NCP_ISOLATION_MODE_NORMAL;

    int32_t pid = -1;
    const Ability_NativeChildProcess_ErrCode rc =
        api.start(IEC_NCP_ENTRY_FULL, args, options, &pid);
    if (rc != NCP_NO_ERROR || pid <= 0) {
        return fail("start native child failed: " + std::to_string(static_cast<int>(rc)) +
                    ", pid " + std::to_string(pid));
    }

    if (!api.exit_registered) {
        const Ability_NativeChildProcess_ErrCode r = api.register_exit(&OnNcpExit);
        if (r != NCP_NO_ERROR) {
            return fail("cannot register the exit callback: " +
                        std::to_string(static_cast<int>(r)));
        }
        api.exit_registered = true;
    }
    return static_cast<pid_t>(pid);
#else
    (void)req;
    (void)kind;
    return fail("not a HarmonyOS build");
#endif
}

void DrainNcpExits(void (*handler)(pid_t pid, int status)) {
    if (handler == nullptr) return;

    std::vector<NcpExit> taken;
    {
        std::lock_guard<std::mutex> lock(g_exit_lock);
        taken.swap(g_pending_exits);
    }
    for (const NcpExit& exit : taken) handler(exit.pid, exit.status);
}
