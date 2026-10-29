//
#include "terminal.h"

#include <fcntl.h>
#include <pty.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstring>
#include <mutex>
#include <thread>

struct terminal_session {
    int master_fd = -1;
    pid_t child_pid = -1;

    terminal_output_cb output_cb = nullptr;
    terminal_exit_cb exit_cb = nullptr;
    void* user_data = nullptr;

    std::atomic<bool> stopping{false};
    std::atomic<bool> stopped{false};

    std::mutex write_mutex;
    std::mutex stop_mutex;
    std::thread reader_thread;
};

static bool valid_size(int cols, int rows) {
    return cols > 0 && rows > 0 &&
           cols <= 65535 && rows <= 65535;
}

static int normalize_exit_status(int status) {
    if (WIFEXITED(status))
        return WEXITSTATUS(status);

    if (WIFSIGNALED(status))
        return 128 + WTERMSIG(status);

    return 1;
}

static void reader_loop(terminal_session_t* session) {
    char buffer[16 * 1024];

    while (!session->stopping.load()) {
        struct pollfd pfd {};
        pfd.fd = session->master_fd;
        pfd.events = POLLIN | POLLHUP | POLLERR;

        const int poll_result = poll(&pfd, 1, 100);

        if (poll_result < 0) {
            if (errno == EINTR)
                continue;
            break;
        }

        if (poll_result == 0) {
            int status = 0;
            const pid_t result =
                waitpid(session->child_pid, &status, WNOHANG);

            if (result == session->child_pid)
                break;

            continue;
        }

        if (pfd.revents & (POLLIN | POLLHUP | POLLERR)) {
            for (;;) {
                const ssize_t count =
                    read(session->master_fd, buffer, sizeof(buffer));

                if (count > 0) {
                    if (session->output_cb) {
                        session->output_cb(
                            session,
                            buffer,
                            static_cast<size_t>(count),
                            session->user_data
                        );
                    }
                    continue;
                }

                if (count < 0 &&
                    (errno == EINTR ||
                     errno == EAGAIN ||
                     errno == EWOULDBLOCK)) {
                    continue;
                }

                // PTY master 在 slave 关闭时通常返回 EIO。
                break;
            }

            break;
        }
    }

    int status = 0;

    while (waitpid(session->child_pid, &status, 0) < 0) {
        if (errno != EINTR)
            break;
    }

    session->stopped.store(true);

    if (session->exit_cb) {
        session->exit_cb(
            session,
            normalize_exit_status(status),
            session->user_data
        );
    }
}

extern "C" terminal_session_t* terminal_start(
    int cols,
    int rows,
    terminal_output_cb output_cb,
    terminal_exit_cb exit_cb,
    void* user_data
) {
    if (!valid_size(cols, rows)) {
        errno = EINVAL;
        return nullptr;
    }

    auto* session = new terminal_session;
    session->output_cb = output_cb;
    session->exit_cb = exit_cb;
    session->user_data = user_data;

    struct winsize size {};
    size.ws_col = static_cast<unsigned short>(cols);
    size.ws_row = static_cast<unsigned short>(rows);

    int master_fd = -1;

    const pid_t pid = forkpty(
        &master_fd,
        nullptr,
        nullptr,
        &size
    );

    if (pid < 0) {
        delete session;
        return nullptr;
    }

    if (pid == 0) {
        execl(
            "/bin/sh",
            "sh",
            "-i",
            static_cast<char*>(nullptr)
        );

        _exit(127);
    }

    session->master_fd = master_fd;
    session->child_pid = pid;

    // 设置为非阻塞，reader 线程使用 poll 读取。
    const int flags = fcntl(master_fd, F_GETFL, 0);
    if (flags >= 0)
        fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);

    session->reader_thread = std::thread(
        reader_loop,
        session
    );

    return session;
}

extern "C" ssize_t terminal_input(
    terminal_session_t* session,
    const char* data,
    size_t size
) {
    if (!session || (!data && size != 0)) {
        errno = EINVAL;
        return -1;
    }

    if (session->stopping.load()) {
        errno = ENOTCONN;
        return -1;
    }

    std::lock_guard<std::mutex> lock(session->write_mutex);

    ssize_t result;

    do {
        result = write(session->master_fd, data, size);
    } while (result < 0 && errno == EINTR);

    return result;
}

extern "C" int terminal_resize(
    terminal_session_t* session,
    int cols,
    int rows
) {
    if (!session || !valid_size(cols, rows)) {
        errno = EINVAL;
        return -1;
    }

    struct winsize size {};
    size.ws_col = static_cast<unsigned short>(cols);
    size.ws_row = static_cast<unsigned short>(rows);

    return ioctl(session->master_fd, TIOCSWINSZ, &size);
}

extern "C" int terminal_pid(terminal_session_t* session) {
    if (!session) {
        errno = EINVAL;
        return -1;
    }

    return static_cast<int>(session->child_pid);
}

extern "C" void terminal_stop(terminal_session_t* session) {
    if (!session)
        return;

    std::lock_guard<std::mutex> lock(session->stop_mutex);

    if (session->stopping.exchange(true))
        return;

    // 结束 shell 进程组。
    kill(-session->child_pid, SIGHUP);
    kill(session->child_pid, SIGHUP);

    if (session->reader_thread.joinable())
        session->reader_thread.join();

    close(session->master_fd);
    session->master_fd = -1;

    delete session;
}
