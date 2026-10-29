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
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

extern char** environ;

#define DEFAULT_SOCK "/data/storage/el2/base/files/py-runner.sock"
#define MAX_STDIN (16u * 1024 * 1024)

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
    return write_full(fd, s, strlen(s) + 1);
}

static int fail(const char* what) {
    dprintf(STDERR_FILENO, "python3: %s\n", what);
    return 127;
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

    // stdin 先读进来（runner 需要知道长度；上限 16MB）。
    char* input = (char*)malloc(65536);
    if (input == NULL) { close(fd); return fail("out of memory"); }
    size_t input_len = 0;
    size_t input_cap = 65536;
    for (;;) {
        if (input_len == input_cap) {
            if (input_cap >= MAX_STDIN) break;
            size_t next = input_cap * 2;
            if (next > MAX_STDIN) next = MAX_STDIN;
            char* grown = (char*)realloc(input, next);
            if (grown == NULL) { free(input); close(fd); return fail("out of memory"); }
            input = grown;
            input_cap = next;
        }
        ssize_t n = read(STDIN_FILENO, input + input_len, input_cap - input_len);
        if (n <= 0) break;
        input_len += (size_t)n;
    }

    uint32_t envc = 0;
    for (char** e = environ; e != NULL && *e != NULL; e++) envc++;

    uint32_t head[3];
    head[0] = (uint32_t)argc;
    head[1] = envc;
    head[2] = (uint32_t)input_len;
    if (write_full(fd, head, sizeof head) != 0) { free(input); close(fd); return fail("write failed"); }
    for (int i = 0; i < argc; i++) {
        if (send_string(fd, argv[i]) != 0) { free(input); close(fd); return fail("write failed"); }
    }
    for (char** e = environ; e != NULL && *e != NULL; e++) {
        if (send_string(fd, *e) != 0) { free(input); close(fd); return fail("write failed"); }
    }
    char cwd[4096];
    if (getcwd(cwd, sizeof cwd) == NULL) cwd[0] = '\0';
    if (send_string(fd, cwd) != 0) { free(input); close(fd); return fail("write failed"); }
    if (input_len > 0 && write_full(fd, input, input_len) != 0) {
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
