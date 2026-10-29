// ncploader/main.cpp — the entry the platform calls in a native child process.
//
// The process this runs in was created by the system and has loaded this library,
// nothing else. That is the point: a command object that is a second copy of a
// runtime the application already has (node inside Electron) only initialises when
// there is no earlier copy in the symbol scope, and a process of its own is also
// the only way to give the application's memory back.
//
// The payload, and the exit file, are described in exec/exec_ncp_protocol.h.
#include <AbilityKit/native_child_process.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#include <string>
#include <vector>

#include "common/constant.h"
#include "exec/exec_ncp_protocol.h"

// execve() takes the environment as a plain array; the C library owns it.
extern char** environ;

namespace {

std::vector<std::string> Split(const std::string& text, char separator) {
    std::vector<std::string> out;
    size_t start = 0;
    while (start <= text.size()) {
        const size_t at = text.find(separator, start);
        if (at == std::string::npos) {
            if (start < text.size()) out.push_back(text.substr(start));
            break;
        }
        out.push_back(text.substr(start, at - start));
        start = at + 1;
    }
    return out;
}

// The payload as three sections: the launcher, the environment, the arguments.
bool ParsePayload(const char* text, std::vector<std::string>* sections) {
    if (text == nullptr) return false;
    *sections = Split(text, kIecNcpSection);
    return sections->size() >= 3;
}

// The descriptors the platform carried over. A descriptor that is still open is
// moved to the number the caller asked for; one that is not was already put there
// by the platform, and its number is what the entry reads as 0/1/2.
void InstallDescriptors(NativeChildProcess_Args args) {
    for (NativeChildProcess_Fd* node = args.fdList.head; node != nullptr;
         node = node->next) {
        if (node->fdName == nullptr || node->fd < 0) continue;
        const int target = atoi(node->fdName);
        if (target < 0 || target == node->fd) continue;
        if (fcntl(node->fd, F_GETFD) < 0) continue;
        dup2(node->fd, target);
    }
}

// The exit code, for the server. The platform's callback only reports a signal, so
// an ordinary exit has to come back this way; a program that dies by a signal leaves
// nothing here and the callback's signal is used instead.
void WriteExitCode(int code) {
    char path[256];
    snprintf(path, sizeof path, "%s" IEC_NCP_EXIT_PREFIX "%d", FAKE_SYSROOT,
             (int)getpid());
    const int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0664);
    if (fd < 0) return;
    char text[16];
    const int n = snprintf(text, sizeof text, "%d", code);
    if (n > 0) {
        ssize_t rc = write(fd, text, (size_t)n);
        (void)rc;
    }
    close(fd);
}

}  // namespace

extern "C" __attribute__((visibility("default"))) void IecNcpMain(
    NativeChildProcess_Args args) {
    std::vector<std::string> sections;
    if (!ParsePayload(args.entryParams, &sections)) _exit(125);

    const std::vector<std::string> launcher = Split(sections[0], kIecNcpField);
    if (launcher.size() < 3) _exit(125);

    const std::string& so = launcher[0];
    const std::string& entry = launcher[1];
    const int arity = atoi(launcher[2].c_str());
    const std::string cwd = launcher.size() > 3 ? launcher[3] : std::string();
    const std::string proc_name = launcher.size() > 4 ? launcher[4] : std::string();

    // The caller's environment, applied before the object is loaded: its
    // constructors read it, exactly as in the fork route.
    for (const std::string& setting : Split(sections[1], kIecNcpField)) {
        const size_t eq = setting.find('=');
        if (eq == std::string::npos || eq == 0) continue;
        setenv(setting.substr(0, eq).c_str(), setting.substr(eq + 1).c_str(), 1);
    }
    if (!cwd.empty()) {
        if (chdir(cwd.c_str()) != 0) {
            static const char msg[] = "[ncp] chdir failed\n";
            if (write(STDERR_FILENO, msg, sizeof msg - 1)) {}
        }
    }
    if (!proc_name.empty()) prctl(PR_SET_NAME, proc_name.c_str(), 0, 0, 0);

    InstallDescriptors(args);

    void* handle = dlopen(so.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (handle == nullptr) {
        const char* why = dlerror();
        fprintf(stderr, "[ncp] dlopen %s: %s\n", so.c_str(), why ? why : "unknown");
        _exit(125);
    }

    const std::vector<std::string> arguments = Split(sections[2], kIecNcpField);
    std::vector<char*> argv;
    argv.reserve(arguments.size() + 1);
    for (const std::string& argument : arguments) {
        argv.push_back(const_cast<char*>(argument.c_str()));
    }
    argv.push_back(nullptr);
    const int argc = static_cast<int>(arguments.size());

    int rc;
    if (arity == 3) {
        using EntryFn3 = int (*)(int, char**, char**);
        auto fn = reinterpret_cast<EntryFn3>(dlsym(handle, entry.c_str()));
        if (fn == nullptr) {
            fprintf(stderr, "[ncp] %s has no entry %s\n", so.c_str(), entry.c_str());
            _exit(126);
        }
        rc = fn(argc, argv.data(), environ);
    } else {
        using EntryFn2 = int (*)(int, char**);
        auto fn = reinterpret_cast<EntryFn2>(dlsym(handle, entry.c_str()));
        if (fn == nullptr) {
            fprintf(stderr, "[ncp] %s has no entry %s\n", so.c_str(), entry.c_str());
            _exit(126);
        }
        rc = fn(argc, argv.data());
    }

    WriteExitCode(rc);
    _exit(rc & 0xff);
}
