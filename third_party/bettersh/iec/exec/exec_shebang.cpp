// exec/exec_shebang.cpp — the route for a file whose first line is #!
//
// The kernel does not run such a file either: it reads the interpreter's path out of the
// first line and runs that, with the script as its first argument. Where exec is not how
// programs are started, that has to be done here, and the interpreter is then started the
// way any other program is -- including the case where it is itself a script.
#include "exec_shebang.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstring>
#include <string>
#include <vector>

#include "exec_route.h"

namespace {

// The kernel's own bound on the first line, and on how many interpreters one may lead to
// another. Both are there for the same reason they are here: a line longer than that is
// not a header anyone can read, and a pair of scripts naming each other must not be able to
// take the service with it.
constexpr ssize_t kHeaderMax = 256;
constexpr int kMaxDepth = 4;

// How far the chain has already gone in this process. It never comes back to zero and does
// not have to: a process handles one request and then leaves through _exit(), as every
// route's child does.
int g_depth = 0;

}  // namespace

bool ReadShebang(const std::string& path, std::string& interp, std::string& arg) {
    char buf[kHeaderMax + 1];
    struct stat st;
    const char* p;
    const char* e;
    ssize_t n;
    int fd;

    // Only a regular file can be one, and asking anything else has no defined answer: a
    // fifo named as a program would block the thread serving the request.
    if (stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) return false;
    fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;
    n = read(fd, buf, kHeaderMax);
    close(fd);
    if (n < 3 || buf[0] != '#' || buf[1] != '!') return false;
    buf[n] = '\0';

    // The kernel refuses a program whose first line does not end inside what it read, and a
    // truncated interpreter path is worse than a refusal: it would name some other file.
    if (strchr(buf, '\n') == nullptr && n == kHeaderMax) return false;

    p = buf + 2;
    while (*p == ' ' || *p == '\t') p++;
    e = p;
    while (*e && *e != '\n' && *e != '\r' && *e != ' ' && *e != '\t') e++;
    interp.assign(p, static_cast<size_t>(e - p));
    if (interp.empty()) return false;

    while (*e == ' ' || *e == '\t') e++;
    p = e;
    while (*p && *p != '\n' && *p != '\r' && *p != ' ' && *p != '\t') p++;
    arg.assign(e, static_cast<size_t>(p - e));
    return true;
}

bool ReadShebang(const std::string& path) {
    std::string interp, arg;
    return ReadShebang(path, interp, arg);
}

pid_t SpawnShebang(const SpawnRequest& req) {
    std::string interp, arg;
    SpawnRequest next;

    if (!ReadShebang(req.path, interp, arg)) return -1;
    if (g_depth >= kMaxDepth) {
        static const char msg[] = "[exec] shebang: too many levels\n";
        if (write(STDERR_FILENO, msg, sizeof msg - 1)) {}
        return -1;
    }
    g_depth++;

    // What the kernel would start: the interpreter, the optional argument, the script as
    // the caller named it -- so that the interpreter can open it -- and then the caller's
    // arguments, whose own argv[0] is what the interpreter takes the place of.
    next = req;
    next.path = UnderFakeRoot(interp);
    if (next.path.find('/') == std::string::npos) {
        // A shebang names a path, and the kernel takes it as one; a bare name turns up
        // often enough in the wild that searching PATH beats refusing a program the kernel
        // would have run.
        next.path = ResolveFilePath(interp, req.env, req.cwd);
        if (next.path.empty()) return -1;
    }

    next.argv.clear();
    next.argv.push_back(next.path);
    if (!arg.empty()) next.argv.push_back(arg);
    next.argv.push_back(req.path);
    for (size_t i = 1; i < req.argv.size(); i++) next.argv.push_back(req.argv[i]);

    const LaunchKind kind = ResolveKind(next.path);
    StartByKind(kind, next);
}
