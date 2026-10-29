// py_runner.cpp — `python3` 的独立解释器进程。
//
// 为什么需要它：shell 命令是 fork 出来的，而应用进程里已经有一个初始化好的
// CPython（run_python）。在 fork 子进程里再初始化/收尾解释器会被父进程的锁状态
// 影响（实测：SIGKILL 一次之后入口永久挂死；sys.exit(n) 的退出码也会丢）。
//
// 这里换一条彻底隔离的路：应用启动时（Python 还没初始化）fork 一个常驻 runner，
// 它自己**从不加载 libpython**；每来一个请求，它再 fork 一个孙进程，孙进程才
// dlopen libpython 并跑 Py_BytesMain。于是：
//   * 孙进程的 CPython 永远是全新的，不继承任何父进程解释器状态；
//   * 客户端/libpycmd 被 SIGKILL 只影响那一次请求，runner 不受影响；
//   * 退出码由 runner 原样回传，不会被吞。
//
// 协议（本机 UDS，小端）：
//   请求: u32 argc, u32 envc, u32 stdin_len
//         argc 个 NUL 结尾 argv；envc 个 NUL 结尾 "K=V"；cwd 一个 NUL 结尾字符串
//         stdin_len 字节 stdin
//   响应: u32 exit_code, u32 out_len, out bytes, u32 err_len, err bytes
#include "py_runner.h"

#include <arpa/inet.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "common/constant.h"

namespace {

constexpr const char* kLibPython =
    "/data/storage/el1/bundle/libs/arm64/libpython3.12.so";

bool g_started = false;

bool ReadFull(int fd, void* buf, size_t len) {
    char* p = static_cast<char*>(buf);
    while (len > 0) {
        const ssize_t n = read(fd, p, len);
        if (n <= 0) return false;
        p += n;
        len -= static_cast<size_t>(n);
    }
    return true;
}

bool WriteFull(int fd, const void* buf, size_t len) {
    const char* p = static_cast<const char*>(buf);
    while (len > 0) {
        const ssize_t n = write(fd, p, len);
        if (n <= 0) return false;
        p += n;
        len -= static_cast<size_t>(n);
    }
    return true;
}

uint32_t Get32(const char* p) {
    uint32_t v = 0;
    std::memcpy(&v, p, sizeof v);
    return v;
}

bool ReadString(int fd, std::string* out) {
    out->clear();
    char c = 0;
    while (true) {
        if (!ReadFull(fd, &c, 1)) return false;
        if (c == '\0') return true;
        out->push_back(c);
        if (out->size() > 64 * 1024) return false;
    }
}

// Runs one python request. Returns after the response has been written.
void HandleClient(int fd) {
    char head[12];
    if (!ReadFull(fd, head, sizeof head)) {
        close(fd);
        return;
    }
    const uint32_t argc = Get32(head + 0);
    const uint32_t envc = Get32(head + 4);
    const uint32_t stdin_len = Get32(head + 8);
    if (argc == 0 || argc > 256 || envc > 4096 || stdin_len > 16u * 1024 * 1024) {
        close(fd);
        return;
    }

    std::vector<std::string> args;
    std::vector<std::string> envs;
    std::string cwd;
    for (uint32_t i = 0; i < argc; i++) {
        std::string s;
        if (!ReadString(fd, &s)) { close(fd); return; }
        args.push_back(std::move(s));
    }
    for (uint32_t i = 0; i < envc; i++) {
        std::string s;
        if (!ReadString(fd, &s)) { close(fd); return; }
        envs.push_back(std::move(s));
    }
    if (!ReadString(fd, &cwd)) { close(fd); return; }
    std::string stdin_data;
    if (stdin_len > 0) {
        stdin_data.resize(stdin_len);
        if (!ReadFull(fd, stdin_data.data(), stdin_len)) { close(fd); return; }
    }

    int in_pipe[2], out_pipe[2], err_pipe[2];
    if (pipe(in_pipe) != 0 || pipe(out_pipe) != 0 || pipe(err_pipe) != 0) {
        close(fd);
        return;
    }

    const pid_t pid = fork();
    if (pid == 0) {
        // 孙进程：这里才第一次加载 libpython，解释器状态是全新的。
        dup2(in_pipe[0], STDIN_FILENO);
        dup2(out_pipe[1], STDOUT_FILENO);
        dup2(err_pipe[1], STDERR_FILENO);
        close(in_pipe[0]); close(in_pipe[1]);
        close(out_pipe[0]); close(out_pipe[1]);
        close(err_pipe[0]); close(err_pipe[1]);
        close(fd);
        for (const std::string& e : envs) {
            const size_t eq = e.find('=');
            if (eq != std::string::npos) {
                setenv(e.substr(0, eq).c_str(), e.substr(eq + 1).c_str(), 1);
            }
        }
        if (!cwd.empty()) {
            if (chdir(cwd.c_str()) != 0) { /* 保持 runner 的 cwd，和 shell 的语义一致 */ }
        }
        std::vector<char*> argv;
        argv.reserve(args.size() + 1);
        for (std::string& a : args) argv.push_back(const_cast<char*>(a.c_str()));
        argv.push_back(nullptr);

        void* lib = dlopen(kLibPython, RTLD_NOW | RTLD_LOCAL);
        if (lib == nullptr) {
            std::fprintf(stderr, "python3: cannot load %s: %s\n", kLibPython, dlerror());
            _exit(127);
        }
        using PyBytesMain = int (*)(int, char**);
        PyBytesMain entry = reinterpret_cast<PyBytesMain>(dlsym(lib, "Py_BytesMain"));
        if (entry == nullptr) {
            std::fprintf(stderr, "python3: Py_BytesMain not found\n");
            _exit(127);
        }
        _exit(entry(static_cast<int>(argv.size() - 1), argv.data()));
    }

    close(in_pipe[0]);
    close(out_pipe[1]);
    close(err_pipe[1]);

    // stdin 交给孙进程后关闭，让它看到 EOF。
    if (!stdin_data.empty()) {
        WriteFull(in_pipe[1], stdin_data.data(), stdin_data.size());
    }
    close(in_pipe[1]);

    std::string out;
    std::string err;
    char buf[65536];
    // 同时读 stdout/stderr，避免任一管道写满把孙进程卡住。
    int open_fds = 2;
    while (open_fds > 0) {
        struct pollfd pfd[2];
        pfd[0].fd = out_pipe[0]; pfd[0].events = POLLIN;
        pfd[1].fd = err_pipe[0]; pfd[1].events = POLLIN;
        const int rc = poll(pfd, 2, -1);
        if (rc <= 0) break;
        for (int i = 0; i < 2; i++) {
            if (pfd[i].fd < 0 || (pfd[i].revents & (POLLIN | POLLHUP | POLLERR)) == 0) continue;
            const ssize_t n = read(pfd[i].fd, buf, sizeof buf);
            if (n > 0) {
                (i == 0 ? out : err).append(buf, static_cast<size_t>(n));
            } else {
                close(pfd[i].fd);
                pfd[i].fd = -1;
                open_fds--;
            }
        }
    }
    close(out_pipe[0]);
    close(err_pipe[0]);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    int code = -1;
    if (WIFEXITED(status)) code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);

    char resp[8];
    const uint32_t ucode = static_cast<uint32_t>(code);
    const uint32_t out_len = static_cast<uint32_t>(out.size());
    std::memcpy(resp + 0, &ucode, 4);
    std::memcpy(resp + 4, &out_len, 4);
    WriteFull(fd, resp, sizeof resp);
    WriteFull(fd, out.data(), out.size());
    const uint32_t err_len = static_cast<uint32_t>(err.size());
    std::memcpy(resp, &err_len, 4);
    WriteFull(fd, resp, 4);
    WriteFull(fd, err.data(), err.size());
    close(fd);
}

}  // namespace

bool StartPyRunner() {
    if (g_started) {
        return true;
    }
    const std::string sock_path = std::string(FAKE_SYSROOT) + "/py-runner.sock";
    const int listen_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (listen_fd < 0) {
        return false;
    }
    struct sockaddr_un addr {};
    addr.sun_family = AF_UNIX;
    std::snprintf(addr.sun_path, sizeof addr.sun_path, "%s", sock_path.c_str());
    unlink(sock_path.c_str());
    if (bind(listen_fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof addr) != 0 ||
        listen(listen_fd, 16) != 0) {
        close(listen_fd);
        return false;
    }

    const pid_t pid = fork();
    if (pid < 0) {
        close(listen_fd);
        return false;
    }
    if (pid > 0) {
        // 父进程只保留监听 fd 给子进程；子进程自己会关掉无关 fd。
        close(listen_fd);
        g_started = true;
        return true;
    }

    // 子进程：runner。绝不加载 libpython。
    setsid();
    for (int fd = 0; fd < 1024; fd++) {
        if (fd != listen_fd) close(fd);
    }
    signal(SIGCHLD, SIG_IGN);  // 孙进程由 handler waitpid，SIG_IGN 会冲突，改为 DEFAULT
    signal(SIGCHLD, SIG_DFL);

    for (;;) {
        // 父进程（应用）死了就退出，避免留下孤儿 runner。
        if (getppid() == 1) _exit(0);
        struct pollfd pfd { listen_fd, POLLIN, 0 };
        const int rc = poll(&pfd, 1, 5000);
        if (rc < 0) continue;
        if (rc == 0) continue;
        const int fd = accept4(listen_fd, nullptr, nullptr, SOCK_CLOEXEC);
        if (fd < 0) continue;
        const pid_t handler = fork();
        if (handler == 0) {
            close(listen_fd);
            HandleClient(fd);
            _exit(0);
        }
        close(fd);
        while (waitpid(-1, nullptr, WNOHANG) > 0) {}
    }
}
