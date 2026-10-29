// peer.c — 测试用裸 socket 对端。
//
// nc 的“stdin 先 EOF、对端随后才发数据”这类时序没法用 nc 自己构造（对端一
// shutdown 写，另一端就跟着结束了），所以这里用一个几十行的小程序精确控制时序，
// 不引入 python/perl 依赖。
//
// 用法：
//   peer probe PORT              连接一次：连上退出 0（端口在用），拒绝退出 1
//   peer listen PORT DELAY_MS    监听 -> accept -> 停 DELAY_MS -> 发 PAYLOAD -> 关闭
//   peer connect PORT DELAY_MS   连接（最多重试 2s）-> 停 DELAY_MS -> 发 PAYLOAD -> 关闭
//   peer listen-eof PORT         监听 -> accept -> 读到 EOF 打印 SAW_EOF（3s 超时打印 TIMEOUT）
//   peer connect-eof PORT        连接 -> 读到 EOF 打印 SAW_EOF / TIMEOUT
//
// PAYLOAD 固定为 "LATE-PAYLOAD\n"。
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define PAYLOAD "LATE-PAYLOAD\n"
#define EOF_TIMEOUT_MS 3000

static void msleep(int ms) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
    }
}

static int make_addr(struct sockaddr_in* sa, const char* port) {
    memset(sa, 0, sizeof *sa);
    sa->sin_family = AF_INET;
    sa->sin_port = htons((unsigned short)atoi(port));
    if (sa->sin_port == 0) return -1;
    return inet_pton(AF_INET, "127.0.0.1", &sa->sin_addr) == 1 ? 0 : -1;
}

static int listen_on(const char* port) {
    struct sockaddr_in sa;
    int one = 1;
    int fd;

    if (make_addr(&sa, port) != 0) return -1;
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (bind(fd, (struct sockaddr*)&sa, sizeof sa) != 0 || listen(fd, 1) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int connect_once(const char* port) {
    struct sockaddr_in sa;
    int fd;

    if (make_addr(&sa, port) != 0) return -1;
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr*)&sa, sizeof sa) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int connect_retry(const char* port) {
    int tries;
    for (tries = 0; tries < 200; tries++) {
        const int fd = connect_once(port);
        if (fd >= 0) return fd;
        msleep(10);
    }
    return -1;
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

static int read_until_eof(int fd) {
    char buf[4096];
    for (;;) {
        struct pollfd pfd;
        int rc;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        rc = poll(&pfd, 1, EOF_TIMEOUT_MS);
        if (rc < 0 && errno == EINTR) continue;
        if (rc <= 0) return -1;
        {
            const ssize_t n = read(fd, buf, sizeof buf);
            if (n == 0) return 0;
            if (n < 0) {
                if (errno == EINTR) continue;
                return -1;
            }
        }
    }
}

int main(int argc, char** argv) {
    const char* mode;
    const char* port;
    int delay = 0;
    int fd = -1;

    if (argc < 3) {
        fprintf(stderr, "usage: peer probe|listen|connect|listen-eof|connect-eof PORT [DELAY_MS]\n");
        return 2;
    }
    mode = argv[1];
    port = argv[2];
    if (argc > 3) delay = atoi(argv[3]);

    if (strcmp(mode, "probe") == 0) {
        fd = connect_once(port);
        if (fd < 0) return 1;
        close(fd);
        return 0;
    }

    if (strcmp(mode, "listen") == 0) {
        int conn;
        fd = listen_on(port);
        if (fd < 0) {
            perror("peer: listen");
            return 1;
        }
        conn = accept(fd, NULL, NULL);
        close(fd);
        if (conn < 0) {
            perror("peer: accept");
            return 1;
        }
        msleep(delay);
        if (write_all(conn, PAYLOAD, strlen(PAYLOAD)) != 0) {
            close(conn);
            return 1;
        }
        close(conn);
        return 0;
    }

    if (strcmp(mode, "connect") == 0) {
        fd = connect_retry(port);
        if (fd < 0) {
            fprintf(stderr, "peer: connect %s failed\n", port);
            return 1;
        }
        msleep(delay);
        if (write_all(fd, PAYLOAD, strlen(PAYLOAD)) != 0) {
            close(fd);
            return 1;
        }
        close(fd);
        return 0;
    }

    if (strcmp(mode, "listen-eof") == 0) {
        int conn;
        fd = listen_on(port);
        if (fd < 0) {
            perror("peer: listen");
            return 1;
        }
        conn = accept(fd, NULL, NULL);
        close(fd);
        if (conn < 0) {
            perror("peer: accept");
            return 1;
        }
        printf("%s\n", read_until_eof(conn) == 0 ? "SAW_EOF" : "TIMEOUT");
        fflush(stdout);
        close(conn);
        return 0;
    }

    if (strcmp(mode, "connect-eof") == 0) {
        fd = connect_retry(port);
        if (fd < 0) {
            fprintf(stderr, "peer: connect %s failed\n", port);
            return 1;
        }
        printf("%s\n", read_until_eof(fd) == 0 ? "SAW_EOF" : "TIMEOUT");
        fflush(stdout);
        close(fd);
        return 0;
    }

    fprintf(stderr, "peer: unknown mode %s\n", mode);
    return 2;
}
