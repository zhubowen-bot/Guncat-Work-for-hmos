// cmd_nc.c — 精简 netcat（IEC 命令 so）。
//
// 支持：
//   nc host port            连接并转发 stdin/stdout
//   nc -l -p port [-v]      监听一个连接并转发
//   nc -l port              同上（端口作位置参数）
//   -w sec                  连接/读写超时
// 不做 UDP / 代理 / TLS：需要 TLS 请用 python requests 或 web_fetch。
//
// 入口 iec_nc_main，由 IEC launcher 调用。
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

static void usage(void) {
    fprintf(stderr,
            "usage: nc [-l] [-p port] [-w sec] [host] [port]\n"
            "  -l        listen for one connection\n"
            "  -p PORT   port (listen or connect)\n"
            "  -w SEC    timeout in seconds\n");
}

static int write_all(int fd, const char* buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        const ssize_t w = write(fd, buf + off, n - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (w == 0) return -1;
        off += (size_t)w;
    }
    return 0;
}

// 双向转发，直到两个方向都结束。
//
// TCP 半关闭是两个独立的“写方向”：stdin EOF 只表示本端不再发送（要向对端
// shutdown(SHUT_WR) 让对端读到 EOF），对端读到 0 也只表示对端不再发送。任何
// 一侧先结束都不能把整个 relay 收掉，否则另一方向迟到的数据会被丢掉：
//   - `echo q | nc host port`：stdin 先 EOF，对端稍后的应答仍要读出来；
//   - 对端 shutdown(SHUT_WR) 后，本端 stdin 稍后才产生的数据仍要能发过去。
// 因此分别记录 stdin_open / peer_open，两者都关闭才退出。
//
// POLLNVAL 说明 fd 已经不可用（例如调用方关掉了 stdin），按 EOF 处理，避免
// poll 一直返回但读不到任何东西导致空转。
static int relay(int sock, int timeout_sec) {
    char buf[65536];
    int stdin_open = 1;
    int peer_open = 1; /* 对端的写方向是否还开着（读到 0 后关闭） */
    const int poll_ms = timeout_sec > 0 ? timeout_sec * 1000 : -1;

    while (stdin_open || peer_open) {
        struct pollfd pfd[2];
        int rc;
        pfd[0].fd = stdin_open ? STDIN_FILENO : -1;
        pfd[0].events = POLLIN;
        pfd[0].revents = 0;
        pfd[1].fd = peer_open ? sock : -1;
        pfd[1].events = POLLIN;
        pfd[1].revents = 0;
        rc = poll(pfd, 2, poll_ms);
        if (rc < 0) {
            if (errno == EINTR) continue;
            perror("nc: poll");
            return 1;
        }
        if (rc == 0) return 0; /* -w 指定的空闲超时 */

        if (stdin_open && (pfd[0].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL))) {
            if (pfd[0].revents & POLLNVAL) {
                stdin_open = 0;
                shutdown(sock, SHUT_WR);
                continue;
            }
            const ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
            if (n < 0) {
                if (errno == EINTR) continue;
                stdin_open = 0;
                shutdown(sock, SHUT_WR);
            } else if (n == 0) {
                stdin_open = 0;
                shutdown(sock, SHUT_WR);
            } else if (write_all(sock, buf, (size_t)n) != 0) {
                return 1;
            }
        }
        if (peer_open && (pfd[1].revents & (POLLIN | POLLHUP | POLLERR))) {
            const ssize_t n = read(sock, buf, sizeof buf);
            if (n < 0) {
                if (errno == EINTR) continue;
                return 1;
            }
            if (n == 0) {
                /* 对端不再发送，但本端仍可以继续把 stdin 发过去。 */
                peer_open = 0;
                /* 交互式终端没有“稍后才有”的数据；若继续等用户 EOF，
                   `nc host port` 会在对端关闭后挂住。管道/文件则保留半关闭语义。 */
                if (isatty(STDIN_FILENO)) stdin_open = 0;
                continue;
            }
            if (write_all(STDOUT_FILENO, buf, (size_t)n) != 0) return 1;
        }
    }
    return 0;
}

static int do_listen(const char* port, int timeout_sec) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    struct addrinfo* res = NULL;
    if (getaddrinfo(NULL, port, &hints, &res) != 0) {
        fprintf(stderr, "nc: bad port %s\n", port);
        return 1;
    }
    int fd = -1;
    for (struct addrinfo* ai = res; ai != NULL; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0 && listen(fd, 1) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        perror("nc: listen");
        return 1;
    }
    struct timeval tv;
    tv.tv_sec = timeout_sec > 0 ? timeout_sec : 0;
    tv.tv_usec = 0;
    if (timeout_sec > 0) setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    const int conn = accept(fd, NULL, NULL);
    close(fd);
    if (conn < 0) {
        perror("nc: accept");
        return 1;
    }
    if (timeout_sec > 0) {
        struct timeval tv;
        tv.tv_sec = timeout_sec;
        tv.tv_usec = 0;
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    }
    const int rc = relay(conn, timeout_sec);
    close(conn);
    return rc;
}

// 带超时的 connect：-w 不能只设 SO_RCVTIMEO（那只管 read/write），否则连一个
// 不回 RST 的地址会卡在内核默认重传时间（分钟级）。这里用非阻塞 connect + poll。
static int connect_timeout(int fd, const struct sockaddr* sa, socklen_t len, int timeout_sec) {
    int flags = fcntl(fd, F_GETFL, 0);
    int err = 0;
    socklen_t elen = sizeof err;
    int rc;

    if (flags < 0) return -1;
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    if (connect(fd, sa, len) != 0) {
        if (errno != EINPROGRESS && errno != EINTR) {
            const int saved = errno;
            fcntl(fd, F_SETFL, flags);
            errno = saved;
            return -1;
        }
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLOUT;
        pfd.revents = 0;
        do {
            rc = poll(&pfd, 1, timeout_sec * 1000);
        } while (rc < 0 && errno == EINTR);
        if (rc < 0) {
            const int saved = errno;
            fcntl(fd, F_SETFL, flags);
            errno = saved;
            return -1;
        }
        if (rc == 0) {
            fcntl(fd, F_SETFL, flags);
            errno = ETIMEDOUT;
            return -1;
        }
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen) < 0) {
            const int saved = errno;
            fcntl(fd, F_SETFL, flags);
            errno = saved;
            return -1;
        }
        if (err != 0) {
            fcntl(fd, F_SETFL, flags);
            errno = err;
            return -1;
        }
    }
    fcntl(fd, F_SETFL, flags);
    return 0;
}

static int do_connect(const char* host, const char* port, int timeout_sec) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo* res = NULL;
    const int gai = getaddrinfo(host, port, &hints, &res);
    if (gai != 0) {
        fprintf(stderr, "nc: %s: %s\n", host, gai_strerror(gai));
        return 1;
    }
    int fd = -1;
    int last_errno = 0;
    for (struct addrinfo* ai = res; ai != NULL; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            last_errno = errno;
            continue;
        }
        if (timeout_sec > 0) {
            struct timeval tv;
            tv.tv_sec = timeout_sec;
            tv.tv_usec = 0;
            if (connect_timeout(fd, ai->ai_addr, ai->ai_addrlen, timeout_sec) == 0) {
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
                break;
            }
        } else if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
            break;
        }
        last_errno = errno;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        if (last_errno != 0) {
            fprintf(stderr, "nc: connect: %s\n", strerror(last_errno));
        } else {
            fprintf(stderr, "nc: connect: failed\n");
        }
        return 1;
    }
    const int rc = relay(fd, timeout_sec);
    close(fd);
    return rc;
}

int iec_nc_main(int argc, char** argv) {
    int listen_mode = 0;
    int timeout_sec = 0;
    const char* port = NULL;
    const char* host = NULL;

    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];
        if (strcmp(a, "-l") == 0) {
            listen_mode = 1;
        } else if (strcmp(a, "-p") == 0 && i + 1 < argc) {
            port = argv[++i];
        } else if (strcmp(a, "-w") == 0 && i + 1 < argc) {
            timeout_sec = atoi(argv[++i]);
        } else if (strcmp(a, "-v") == 0 || strcmp(a, "-n") == 0 || strcmp(a, "-z") == 0) {
            /* 接受但忽略：-z 只做连接测试，这里退化成连接后立即关闭 */
            if (strcmp(a, "-z") == 0) timeout_sec = timeout_sec > 0 ? timeout_sec : 1;
        } else if (a[0] == '-' && a[1] != '\0') {
            usage();
            return 1;
        } else if (port == NULL && listen_mode && host == NULL) {
            port = a;
        } else if (host == NULL) {
            host = a;
        } else if (port == NULL) {
            port = a;
        } else {
            usage();
            return 1;
        }
    }

    if (listen_mode) {
        if (port == NULL) {
            usage();
            return 1;
        }
        return do_listen(port, timeout_sec);
    }
    if (host == NULL || port == NULL) {
        usage();
        return 1;
    }
    return do_connect(host, port, timeout_sec);
}
