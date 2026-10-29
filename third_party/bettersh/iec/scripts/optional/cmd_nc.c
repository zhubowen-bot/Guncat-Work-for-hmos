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

static int relay(int sock) {
    char buf[65536];
    for (;;) {
        struct pollfd pfd[2];
        pfd[0].fd = STDIN_FILENO;
        pfd[0].events = POLLIN;
        pfd[1].fd = sock;
        pfd[1].events = POLLIN;
        const int rc = poll(pfd, 2, -1);
        if (rc < 0) {
            if (errno == EINTR) continue;
            return 1;
        }
        if (pfd[0].revents & (POLLIN | POLLHUP)) {
            const ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
            if (n <= 0) {
                shutdown(sock, SHUT_WR);
                pfd[0].fd = -1;
            } else {
                size_t off = 0;
                while (off < (size_t)n) {
                    const ssize_t w = write(sock, buf + off, (size_t)n - off);
                    if (w <= 0) return 1;
                    off += (size_t)w;
                }
            }
        }
        if (pfd[1].revents & (POLLIN | POLLHUP)) {
            const ssize_t n = read(sock, buf, sizeof buf);
            if (n <= 0) break;
            size_t off = 0;
            while (off < (size_t)n) {
                const ssize_t w = write(STDOUT_FILENO, buf + off, (size_t)n - off);
                if (w <= 0) return 1;
                off += (size_t)w;
            }
        }
        if (pfd[0].fd < 0 && (pfd[1].revents & POLLIN) == 0) break;
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
    const int rc = relay(conn);
    close(conn);
    return rc;
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
    for (struct addrinfo* ai = res; ai != NULL; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (timeout_sec > 0) {
            struct timeval tv;
            tv.tv_sec = timeout_sec;
            tv.tv_usec = 0;
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        }
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        perror("nc: connect");
        return 1;
    }
    const int rc = relay(fd);
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
