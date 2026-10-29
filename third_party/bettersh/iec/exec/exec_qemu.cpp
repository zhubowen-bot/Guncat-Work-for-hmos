// exec/exec_qemu.cpp — the emulated route: load the qemu that emulates this guest, and
// hand it the program.
#include "exec_qemu.h"

#include "constant.h"
#include "elf.h"

#include <dlfcn.h>
#include <unistd.h>

#include <cstdio>
#include <string>
#include <vector>

// What this route leaves with when it cannot start the program at all: the same two the
// launcher route uses, and for the same reason -- neither is a status the program itself
// produced.
constexpr int kQemuLoadFailedExit = 125;
constexpr int kQemuEntryMissingExit = 126;

namespace {

// One object per guest architecture, named for the guest rather than for the host that
// runs it: the aarch64 object is the emulator that runs aarch64 programs, whichever host
// it is loaded on. The paths, the names and the entry point are in constant.h, which is
// also where the script that builds the objects takes them from.
const char* ObjectFor(uint16_t machine) {
    switch (machine) {
        case EM_AARCH64: return PATH_QEMU_AARCH64_SO;
        case EM_X86_64:  return PATH_QEMU_X86_64_SO;
        default:         return nullptr;
    }
}

const char* NameFor(uint16_t machine) {
    switch (machine) {
        case EM_AARCH64: return QEMU_NAME_AARCH64;
        case EM_X86_64:  return QEMU_NAME_X86_64;
        default:         return nullptr;
    }
}

}  // namespace

pid_t SpawnQemu(const SpawnRequest& req) {
    // The caller routed us here by this field, and it is read again rather than carried
    // through the request: one function is the whole of this route, as with SpawnSo().
    const uint16_t machine = ElfMachine(req.path);
    const char* object = ObjectFor(machine);
    const char* qemu_name = NameFor(machine);
    std::vector<std::string> args;
    std::vector<char*> argv;
    std::vector<char*> envp;
    int argc;
    int rc;

    if (!object || !qemu_name) _exit(kQemuLoadFailedExit);

    if (!req.cwd.empty() && chdir(req.cwd.c_str()) != 0) {
        static const char msg[] = "[exec] chdir failed, started in default path\n";
        if (write(STDERR_FILENO, msg, sizeof msg - 1)) {}
    }

    // What a qemu-user program is handed, and why the request's own argv cannot go
    // straight through:
    //
    //   argv[0]   the qemu binary's name, which qemu uses to name itself in messages
    //   argv[1]   the guest program
    //   argv[2..] the guest's arguments
    //
    // -0 sets the guest's own argv[0]. Without it a guest would find the path of its
    // program there, which is not what the same program sees when it is started any
    // other way, and programs that branch on argv[0] -- busybox, a login shell counting
    // itself -- do notice the difference.
    args.push_back(qemu_name);
    if (!req.argv.empty()) {
        args.push_back("-0");
        args.push_back(req.argv[0]);
    }
    args.push_back(req.path);
    for (size_t i = 1; i < req.argv.size(); i++) args.push_back(req.argv[i]);

    // The pointers are taken after the list is complete, so nothing here can move.
    argv.reserve(args.size() + 1);
    envp.reserve(req.env.size() + 1);
    for (const std::string& s : args)    argv.push_back(const_cast<char*>(s.c_str()));
    for (const std::string& s : req.env) envp.push_back(const_cast<char*>(s.c_str()));
    argc = (int)argv.size();
    argv.push_back(nullptr);
    envp.push_back(nullptr);

    // qemu_entry() takes no environment and passes this process's on, so the request's
    // takes its place here: the guest should see what the caller asked for, not whatever
    // the server was started with.
    environ = envp.data();

    // Loaded here, in the child, so that nothing qemu or the guest does becomes the
    // server's. By soname, so this is where the search path has to lead.
    void* h = dlopen(object, RTLD_NOW | RTLD_GLOBAL);
    if (!h) _exit(kQemuLoadFailedExit);

    using EntryFn = int (*)(int, char**);
    auto entry = (EntryFn)dlsym(h, QEMU_ENTRY);
    if (!entry) _exit(kQemuEntryMissingExit);

    rc = entry(argc, argv.data());

    // The program's buffered output still has to go somewhere, and the _exit() below
    // would throw it away; the same trade-off as in SpawnSo(), for the same reason.
    fflush(nullptr);
    _exit(rc & 0xFF);
    return -1;  // not reached: every path above leaves through _exit()
}
