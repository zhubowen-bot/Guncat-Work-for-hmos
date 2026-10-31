// python_entry.c — `python3` 的客户端。
//
// 解释器不在本进程里跑：应用启动时会 fork 一个独立的 runner（exec/py_runner.cpp），
// 本文件只是把 argv/stdin/env 发过去、把 stdout/stderr/退出码收回来。
//
// 这样彻底避开了「fork 子进程继承 run_python 已初始化的 CPython」导致的两个坑：
// 被 SIGKILL 后入口挂死、sys.exit(n) 退出码丢失。
//
// 入口符号是 iec_python_main，由 IEC launcher 调用。
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

extern char** environ;

#define DEFAULT_SOCK "/data/storage/el2/base/files/py-runner.sock"
// stdin 上限分两条路：
//   * 普通文件：只把路径发给 runner，由它自己边读边喂管道，不进内存、不设上限；
//   * 管道/终端等不可回放的输入：只能先缓冲，上限 64MB。超过就明确报错，
//     绝不静默截断——旧实现停在 16MB 后直接 break，压缩出来的流少一截，
//     解压时才发现 md5 不对。
#define MAX_STDIN (64u * 1024 * 1024)
#define STDIN_BY_PATH 0xffffffffu

static int write_full(int fd, const void* buf, size_t len) {
    const char* p = (const char*)buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n <= 0) return -1;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

// 写 runner 的连接必须用 send(MSG_NOSIGNAL)：runner 拒绝请求（如 argc=0）
// 或中途退出时会先关掉这一端，随后 write() 触发的 SIGPIPE 会按默认处置直接
// 杀掉本进程，连下面那些 "python3: ..." 的错误提示都来不及打。
static int send_full(int fd, const void* buf, size_t len) {
    const char* p = (const char*)buf;
    while (len > 0) {
        ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static int read_full(int fd, void* buf, size_t len) {
    char* p = (char*)buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n <= 0) return -1;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static int send_string(int fd, const char* s) {
    return send_full(fd, s, strlen(s) + 1);
}

static int fail(const char* what) {
    dprintf(STDERR_FILENO, "python3: %s\n", what);
    return 127;
}

// stdin 是普通文件时，把 /proc/self/fd/0 指向的路径交给 runner 流式读取。
// 这样 20MB/200MB 的 `python3 script < big` 不需要先读进客户端内存，也不受
// MAX_STDIN 限制。readlink 不可用（沙箱限制）时返回 0，退回缓冲路径。
static int stdin_regular_path(char* out, size_t cap) {
    struct stat st;
    if (fstat(STDIN_FILENO, &st) != 0 || !S_ISREG(st.st_mode)) return 0;
    ssize_t n = readlink("/proc/self/fd/0", out, cap - 1);
    if (n <= 0 || (size_t)n >= cap - 1) return 0;
    out[n] = '\0';
    return 1;
}

int iec_python_main(int argc, char** argv) {
    const char* path = getenv("IEC_PY_SOCK");
    if (path == NULL || *path == '\0') path = DEFAULT_SOCK;

    const int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return fail("socket failed");
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof addr.sun_path, "%s", path);
    if (connect(fd, (struct sockaddr*)&addr, sizeof addr) != 0) {
        dprintf(STDERR_FILENO,
                "python3: cannot reach the interpreter runner (%s): %s\n"
                "python3: use run_python instead\n",
                path, strerror(errno));
        close(fd);
        return 127;
    }

    // stdin 若是普通文件只传路径；否则先读进来（runner 需要知道长度）。管道
    // 输入超过 MAX_STDIN 时必须报错：静默截断会让压缩/校验类的命令产出
    // “看起来成功、内容少一截”的结果，比直接失败更难查。
    char stdin_path[4096];
    const int by_path = stdin_regular_path(stdin_path, sizeof stdin_path);
    char* input = NULL;
    size_t input_len = 0;
    if (!by_path) {
        input = (char*)malloc(65536);
        if (input == NULL) { close(fd); return fail("out of memory"); }
        size_t input_cap = 65536;
        for (;;) {
            if (input_len == input_cap) {
                if (input_cap >= MAX_STDIN) {
                    // 先确认后面确实还有数据；恰好读满上限不算截断。
                    char probe = 0;
                    ssize_t extra = read(STDIN_FILENO, &probe, 1);
                    if (extra > 0) {
                        free(input);
                        close(fd);
                        return fail("stdin is larger than 64MB and is not a regular file; "
                                    "redirect from a file instead");
                    }
                    if (extra < 0 && errno == EINTR) continue;
                    break;
                }
                size_t next = input_cap * 2;
                if (next > MAX_STDIN) next = MAX_STDIN;
                char* grown = (char*)realloc(input, next);
                if (grown == NULL) { free(input); close(fd); return fail("out of memory"); }
                input = grown;
                input_cap = next;
            }
            ssize_t n = read(STDIN_FILENO, input + input_len, input_cap - input_len);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            input_len += (size_t)n;
        }
    }

    uint32_t envc = 0;
    for (char** e = environ; e != NULL && *e != NULL; e++) envc++;

    uint32_t head[3];
    head[0] = (uint32_t)argc;
    head[1] = envc;
    head[2] = by_path ? STDIN_BY_PATH : (uint32_t)input_len;
    if (send_full(fd, head, sizeof head) != 0) { free(input); close(fd); return fail("write failed"); }
    for (int i = 0; i < argc; i++) {
        if (send_string(fd, argv[i]) != 0) { free(input); close(fd); return fail("write failed"); }
    }
    for (char** e = environ; e != NULL && *e != NULL; e++) {
        if (send_string(fd, *e) != 0) { free(input); close(fd); return fail("write failed"); }
    }
    char cwd[4096];
    if (getcwd(cwd, sizeof cwd) == NULL) cwd[0] = '\0';
    if (send_string(fd, cwd) != 0) { free(input); close(fd); return fail("write failed"); }
    if (by_path && send_string(fd, stdin_path) != 0) {
        close(fd);
        return fail("write failed");
    }
    if (input_len > 0 && send_full(fd, input, input_len) != 0) {
        free(input);
        close(fd);
        return fail("write failed");
    }
    free(input);

    uint32_t resp[2];
    if (read_full(fd, resp, sizeof resp) != 0) { close(fd); return fail("runner closed"); }
    const int code = (int)resp[0];
    const uint32_t out_len = resp[1];
    char* out = (char*)malloc(out_len == 0 ? 1 : out_len);
    if (out == NULL) { close(fd); return fail("out of memory"); }
    if (out_len > 0 && read_full(fd, out, out_len) != 0) { free(out); close(fd); return fail("runner closed"); }
    if (out_len > 0) write_full(STDOUT_FILENO, out, out_len);
    free(out);

    uint32_t err_len = 0;
    if (read_full(fd, &err_len, sizeof err_len) != 0) { close(fd); return fail("runner closed"); }
    char* err = (char*)malloc(err_len == 0 ? 1 : err_len);
    if (err == NULL) { close(fd); return fail("out of memory"); }
    if (err_len > 0 && read_full(fd, err, err_len) != 0) { free(err); close(fd); return fail("runner closed"); }
    if (err_len > 0) write_full(STDERR_FILENO, err, err_len);
    free(err);

    close(fd);
    return code;
}
