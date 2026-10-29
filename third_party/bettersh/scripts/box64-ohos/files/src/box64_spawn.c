/* OHOS_PATCH_BOX64_SPAWN
 *
 * Three-strategy spawn dispatcher for OHOS HAP environment.
 *
 * Strategy chosen by env BOX64_SPAWN_STRATEGY:
 *   native  - direct execve / posix_spawn (only valid in hnp mode)
 *   fork    - fork + box64_run (self-recursion)
 *   sock    - delegate to HAP main process via control socket (default)
 *
 * Sock path (sock strategy): BOX64_PROCMGR_SOCK if set, else BSH_CTRL_SOCK — the same
 * variable procmgr/bsh_client.c reads, exported by the host session. No hardcoded
 * default: the device-side path hangs off the module name (haps/tablet|phone/files),
 * so a literal is guaranteed to rot.
 *
 * Auto fallback: sock failure (incl. no sock path at all) -> fork. Marked sticky in s_sock_broken.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/uio.h>      /* OHOS_PATCH_SOCK_FD_INHERIT */
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>


/* OHOS_PATCH_LOG_GATE */
#include <stdlib.h>
#include <stdio.h>
static int ohos_spawn_log_level(void) {
    static int cached = -1;
    if (cached < 0) {
        const char* v = getenv("BOX64_LOG");
        cached = (v && *v) ? atoi(v) : 0;
        if (cached < 0) cached = 0;
    }
    return cached;
}
#define OHOS_SPAWN_INFO(...)  do { if (ohos_spawn_log_level() >= 1) { fprintf(stderr, __VA_ARGS__); fflush(stderr); } } while (0)
#define OHOS_SPAWN_DEBUG(...) do { if (ohos_spawn_log_level() >= 2) { fprintf(stderr, __VA_ARGS__); fflush(stderr); } } while (0)
extern char** environ;
extern int box64_run(int argc, const char** argv, const char** env);

/* ================================================================
 * [1] strategy config
 * ================================================================ */
enum spawn_strategy { SP_NATIVE = 0, SP_FORK = 1, SP_SOCK = 2 };
static int s_strategy    = -1;
static int s_sock_broken = 0;

/* 到主进程 procmgr 的控制 sock。
 * 顺序：BOX64_PROCMGR_SOCK(显式覆盖/调试用) → BSH_CTRL_SOCK(宿主导出的**标准通道**，
 * 与 procmgr/bsh_client.c 读的是同一个变量) → 都没有则回 NULL，由上层退回 fork。
 *
 * 以前这里写死了 "/data/storage/el2/base/haps/entry/files/.procmgr.sock"：模块名(entry)
 * 与文件名(.procmgr.sock)双双过期 —— 真正的 sock 是 <资源根>/bsh-ctrl.sock，而资源根挂在
 * 模块名下(tablet/phone)，写死必然指错。写死的"兜底"比没有兜底更坏：它会连到一个不存在的
 * 文件，白白浪费一次 connect，还留一条误导人的日志。 */
static const char* get_sock_path(void) {
    const char* v = getenv("BOX64_PROCMGR_SOCK");
    if (v && *v) return v;
    const char* c = getenv("BSH_CTRL_SOCK");
    if (c && *c) return c;
    return NULL;
}

static enum spawn_strategy get_strategy(void) {
    if (s_strategy != -1) return (enum spawn_strategy)s_strategy;
    const char* v = getenv("BOX64_SPAWN_STRATEGY");
    enum spawn_strategy s;
    if      (!v || !*v)            s = SP_SOCK;
    else if (!strcmp(v, "native")) s = SP_NATIVE;
    else if (!strcmp(v, "fork"))   s = SP_FORK;
    else if (!strcmp(v, "sock"))   s = SP_SOCK;
    else                           s = SP_SOCK;
    s_strategy = (int)s;
    OHOS_SPAWN_INFO("[box64-spawn] strategy=%s\n",
        s == SP_NATIVE ? "native" : s == SP_FORK ? "fork" : "sock");
    return s;
}

static int count_argv(char* const argv[]) {
    int n = 0;
    if (!argv) return 0;
    while (argv[n]) n++;
    return n;
}

/* ================================================================
 * [2] socket client (used by sock strategy)
 * ================================================================ */

/* ==== OHOS_PATCH_SOCK_FD_INHERIT helpers ====
 * Whitelist envp keys whose value is "an fd number" we must forward
 * via SCM_RIGHTS so the procmgr-spawned child sees the same fd
 * number its parent did. */

#define BOX64_FD_REF_MAX 16

typedef struct {
    int  target_fd;
    int  source_fd;
    char name[64];
} box64_fd_ref_t;

static const char* const kBox64FdInheritVars[] = {
    "WINESERVERSOCKET",
    NULL
};

static int collect_envp_fd_refs(char* const envp[],
                                box64_fd_ref_t* out, int max) {
    if (!envp || !out || max <= 0) return 0;
    int n = 0;
    int log_lvl = ohos_spawn_log_level();
    for (int i = 0; envp[i] && n < max; i++) {
        const char* e = envp[i];
        const char* eq = strchr(e, '=');
        if (!eq) continue;
        size_t name_len = (size_t)(eq - e);
        for (int j = 0; kBox64FdInheritVars[j]; j++) {
            const char* vn = kBox64FdInheritVars[j];
            if (strlen(vn) != name_len) continue;
            if (memcmp(e, vn, name_len) != 0) continue;
            const char* val = eq + 1;
            if (!*val) break;
            char* end = NULL;
            long fd = strtol(val, &end, 10);
            if (end == val || fd < 3 || fd > 65535) break;
            if (fcntl((int)fd, F_GETFD) < 0) {
                /* real error: keep unconditional */
                fprintf(stderr,
                    "[spawn-sock] WARN env %s=%ld fd invalid: %s\n",
                    vn, fd, strerror(errno));
                break;
            }
            out[n].target_fd = (int)fd;
            out[n].source_fd = (int)fd;
            snprintf(out[n].name, sizeof(out[n].name), "%s", vn);
            /* diagnostic: gated by BOX64_LOG>=1 */
            if (log_lvl >= 1) {
                fprintf(stderr,
                    "[spawn-sock] FDREF %s=%d (will SCM_RIGHTS)\n",
                    vn, (int)fd);
            }
            n++;
            break;
        }
    }
    return n;
}

static int sock_send_with_fds(int sockfd, const char* payload, size_t len,
                              const box64_fd_ref_t* fds, int n_fds) {
    if (n_fds < 0) n_fds = 0;
    if (n_fds > BOX64_FD_REF_MAX) n_fds = BOX64_FD_REF_MAX;

    uint8_t hdr[4] = {
        (uint8_t)(len >> 24), (uint8_t)(len >> 16),
        (uint8_t)(len >>  8), (uint8_t) len
    };

    struct iovec iov[2];
    iov[0].iov_base = hdr;            iov[0].iov_len = 4;
    iov[1].iov_base = (void*)payload; iov[1].iov_len = len;

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov    = iov;
    msg.msg_iovlen = 2;

    char cmsg_buf[CMSG_SPACE(sizeof(int) * BOX64_FD_REF_MAX)];
    memset(cmsg_buf, 0, sizeof(cmsg_buf));

    if (n_fds > 0) {
        msg.msg_control    = cmsg_buf;
        msg.msg_controllen = CMSG_SPACE(sizeof(int) * n_fds);
        struct cmsghdr* cm = CMSG_FIRSTHDR(&msg);
        cm->cmsg_level = SOL_SOCKET;
        cm->cmsg_type  = SCM_RIGHTS;
        cm->cmsg_len   = CMSG_LEN(sizeof(int) * n_fds);
        int* fdp = (int*)CMSG_DATA(cm);
        for (int i = 0; i < n_fds; i++) fdp[i] = fds[i].source_fd;
    }

    while (1) {
        ssize_t w = sendmsg(sockfd, &msg, MSG_NOSIGNAL);
        if (w == (ssize_t)(4 + len)) return 0;
        if (w < 0 && errno == EINTR) continue;
        return -1;
    }
}
/* ==== OHOS_PATCH_SOCK_FD_INHERIT helpers END ==== */

static int sock_write_all(int fd, const void* p, size_t n) {
    const uint8_t* b = (const uint8_t*)p;
    while (n) {
        ssize_t w = send(fd, b, n, MSG_NOSIGNAL);
        if (w <= 0) { if (w < 0 && errno == EINTR) continue; return -1; }
        b += w; n -= (size_t)w;
    }
    return 0;
}
static int sock_read_all(int fd, void* p, size_t n) {
    uint8_t* b = (uint8_t*)p;
    while (n) {
        ssize_t r = recv(fd, b, n, 0);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return -1; }
        b += r; n -= (size_t)r;
    }
    return 0;
}
static int frame_write(int fd, const char* p, size_t n) {
    uint8_t h[4] = {
        (uint8_t)(n >> 24), (uint8_t)(n >> 16),
        (uint8_t)(n >>  8), (uint8_t) n
    };
    if (sock_write_all(fd, h, 4) < 0) return -1;
    return sock_write_all(fd, p, n);
}

static int frame_read(int fd, char* buf, size_t cap, size_t* out_len) {
    uint8_t h[4];
    if (sock_read_all(fd, h, 4) < 0) return -1;
    size_t n = ((size_t)h[0]<<24)|((size_t)h[1]<<16)
             | ((size_t)h[2]<< 8)|(size_t)h[3];
    if (n >= cap) return -1;
    if (sock_read_all(fd, buf, n) < 0) return -1;
    buf[n] = 0;
    if (out_len) *out_len = n;
    return 0;
}

static int sock_connect(void) {
    const char* path = get_sock_path();
    if (!path) {
        /* 两条环境变量都没有：不假装能连。返回失败让上层把 s_sock_broken 立起来、
           回退到 fork —— 那才是这种情况下的正解（以前靠写死的默认值兜底，结果是连一个
           不存在的文件，白费一次 connect 还留一条误导日志）。 */
        OHOS_SPAWN_INFO("[box64-spawn] 没有 procmgr sock"
                        "(BOX64_PROCMGR_SOCK / BSH_CTRL_SOCK 都没设) → 回退 fork\n");
        errno = ENOENT;
        return -1;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        int e = errno;
        close(fd);
        errno = e;
        return -1;
    }
    return fd;
}

/* Append "KEY value\n" to *buf. *off / cap protected. */
static int buf_appendf(char* buf, size_t cap, size_t* off,
                       const char* fmt, ...) {
    if (*off >= cap) return -1;
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(buf + *off, cap - *off, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= cap - *off) return -1;
    *off += (size_t)n;
    return 0;
}

/* Build CMD CREATE payload. Returns length, or -1 on overflow. */
static int build_create_req(char* buf, size_t cap,
                            const char* exe,
                            char* const argv[], char* const envp[],
                            int wait_flag,
                            const box64_fd_ref_t* fdrefs, int n_fdrefs) {
    size_t off = 0;
    if (buf_appendf(buf, cap, &off, "CMD CREATE\n")             < 0) return -1;
    /* 版本号必须与 procmgr 的 kProtoVer 一致（procmgr/ctrl_socket.cpp）。
     * 这里原来写的是 2 —— 服务端认 1，于是每次都被拒成 proto_ver_mismatch；
     * 而 sock 失败会**静默**退化到 fork（见 box64_self_execve 的 s_sock_broken），
     * 所以这条策略实际上从来没跑通过，bug 也一直被盖着。字段集与 v1 完全一致
     * （REQ_ID/EXE/ARG/ENV/WAIT/FDREF），应答解析也对得上 STATUS ok / PID / EXIT_CODE。 */
    if (buf_appendf(buf, cap, &off, "PROTO_VER 1\n")            < 0) return -1;
    if (buf_appendf(buf, cap, &off, "REQ_ID 1\n")               < 0) return -1;
    if (buf_appendf(buf, cap, &off, "EXE %s\n", exe ? exe : "") < 0) return -1;
    if (buf_appendf(buf, cap, &off, "KIND box64\n")             < 0) return -1;
    if (buf_appendf(buf, cap, &off, "WAIT %d\n", wait_flag)     < 0) return -1;
    if (argv) {
        for (int i = 0; argv[i]; i++) {
            if (buf_appendf(buf, cap, &off, "ARG %s\n", argv[i]) < 0) return -1;
        }
    }
    if (envp) {
        for (int i = 0; envp[i]; i++) {
            if (buf_appendf(buf, cap, &off, "ENV %s\n", envp[i]) < 0) return -1;
        }
    }
    for (int i = 0; i < n_fdrefs; i++) {
        if (buf_appendf(buf, cap, &off, "FDREF %d\n",
                        fdrefs[i].target_fd) < 0) return -1;
    }
    if (buf_appendf(buf, cap, &off, "END") < 0) return -1;
    return (int)off;
}

/* Parse RESULT response. status_ok: 1=ok, 0=error. */
static int parse_create_resp(const char* p, size_t n,
                             int* status_ok, pid_t* out_pid,
                             int* out_exit_code, char* msg, size_t msg_cap) {
    *status_ok = 0;
    if (out_pid)       *out_pid = -1;
    if (out_exit_code) *out_exit_code = -1;
    if (msg && msg_cap) msg[0] = 0;

    size_t i = 0;
    while (i < n) {
        size_t j = i;
        while (j < n && p[j] != '\n') j++;
        size_t llen = j - i;
        const char* line = p + i;

        if      (llen == 9 && !strncmp(line, "STATUS ok", 9))    *status_ok = 1;
        else if (llen >= 4 && !strncmp(line, "PID ", 4) && out_pid) {
            *out_pid = (pid_t)atol(line + 4);
        }
        else if (llen >= 10 && !strncmp(line, "EXIT_CODE ", 10) && out_exit_code) {
            *out_exit_code = atoi(line + 10);
        }
        else if (llen >= 4 && !strncmp(line, "MSG ", 4) && msg && msg_cap) {
            size_t cp = llen - 4;
            if (cp >= msg_cap) cp = msg_cap - 1;
            memcpy(msg, line + 4, cp);
            msg[cp] = 0;
        }
        else if (llen == 3 && !strncmp(line, "END", 3)) {
            return 0;
        }
        i = j + 1;
    }
    return 0;
}

/* ================================================================
 * [3] FORK: child wine prereserve cleanup
 * ================================================================ */
struct unmap_region { unsigned long base; unsigned long size; const char* name; };
static const struct unmap_region s_wine_reserve[] = {
    { 0x00010000UL, 0x00008000UL,    "low-stub" },
    { 0x00110000UL, 0x30000000UL,    "low-heap" },
    { 0x7f000000UL, 0x00fe0000UL,    "high-pre-kuser" },
    { 0x7ffe1000UL, 0x0201f000UL,    "high-post-kuser" },
};

static void child_unmap_wine_reserve(const char* tag) {
    for (unsigned i = 0; i < sizeof(s_wine_reserve)/sizeof(s_wine_reserve[0]); i++) {
        int rc = munmap((void*)s_wine_reserve[i].base, s_wine_reserve[i].size);
        int e  = rc ? errno : 0;
        OHOS_SPAWN_DEBUG("[child-unmap %s] %s @0x%lx+0x%lx rc=%d errno=%d\n",
            tag, s_wine_reserve[i].name,
            s_wine_reserve[i].base, s_wine_reserve[i].size, rc, e);
    }
    fflush(stderr);
}

static void child_reserve_wine_holes(const char* tag) {
    for (unsigned i = 0; i < sizeof(s_wine_reserve)/sizeof(s_wine_reserve[0]); i++) {
        void* got = mmap((void*)s_wine_reserve[i].base, s_wine_reserve[i].size,
                         PROT_NONE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
        int rc = (got == MAP_FAILED) ? -1
               : (got != (void*)s_wine_reserve[i].base) ? -2 : 0;
        int e  = (got == MAP_FAILED) ? errno : 0;
        OHOS_SPAWN_DEBUG("[child-reserve %s] %s @0x%lx+0x%lx -> %p rc=%d errno=%d\n",
            tag, s_wine_reserve[i].name,
            s_wine_reserve[i].base, s_wine_reserve[i].size, got, rc, e);
    }
    fflush(stderr);
}

static void apply_envp(char* const envp[]) {
    if (!envp || envp == environ) return;
    for (int i = 0; envp[i]; ++i) {
        char* kv = envp[i];
        char* eq = strchr(kv, '=');
        if (!eq) continue;
        size_t klen = (size_t)(eq - kv);
        char keybuf[256];
        if (klen == 0 || klen >= sizeof(keybuf)) continue;
        memcpy(keybuf, kv, klen);
        keybuf[klen] = 0;
        setenv(keybuf, eq + 1, 1);
    }
}

/* Copy argv into a fresh blob so the child's later free()s on the parent
 * heap don't corrupt our argv array. */
static int build_argv_blob(char* const argv[], int argc,
                           const char*** out_argv, char** out_blob) {
    size_t total = 0;
    for (int i = 0; i < argc; i++) total += strlen(argv[i]) + 1;
    char* blob = (char*)malloc(total + 64);
    const char** av = (const char**)malloc(sizeof(char*) * (argc + 1));
    if (!blob || !av) { free(blob); free(av); return -1; }
    size_t off = 0;
    for (int i = 0; i < argc; i++) {
        size_t n = strlen(argv[i]) + 1;
        memcpy(blob + off, argv[i], n);
        av[i] = blob + off;
        off += n;
    }
    av[argc] = NULL;
    *out_argv = av;
    *out_blob = blob;
    return 0;
}

/* ================================================================
 * [4] strategy: NATIVE
 * ================================================================ */
static int execve_native(const char* path,
                         char* const argv[], char* const envp[]) {
    OHOS_SPAWN_INFO("[spawn-native] execve(%s)\n", path ? path : "(null)");
    return execve(path, argv, envp ? envp : environ);
}

static int spawn_native(int* outpid, const char* path,
                        char* const argv[], char* const envp[]) {
    OHOS_SPAWN_INFO("[spawn-native] posix_spawn(%s)\n", path ? path : "(null)");
    pid_t pid = -1;
    int rc = posix_spawn(&pid, path, NULL, NULL,
                         argv, envp ? envp : environ);
    if (rc == 0 && outpid) *outpid = (int)pid;
    return rc;
}

/* ================================================================
 * [5] strategy: FORK (fork + box64_run)
 * ================================================================ */
static int execve_fork(const char* path,
                       char* const argv[], char* const envp[]) {
    (void)path;
    int argc = count_argv(argv);
    if (argc == 0) { errno = EINVAL; return -1; }

    OHOS_SPAWN_INFO(
        "[spawn-fork] execve fork+box64_run argc=%d argv[0]=%s argv[1]=%s\n",
        argc, argv[0], argc > 1 ? argv[1] : "(none)");
    fflush(stderr);

    pid_t pid = fork();
    if (pid < 0) return -1;

    if (pid == 0) {
        /* ---- child ---- */
        apply_envp(envp);
        child_unmap_wine_reserve("exec");
        child_reserve_wine_holes("exec");

        const char** argv2 = NULL; char* blob = NULL;
        if (build_argv_blob(argv, argc, &argv2, &blob) < 0) {
            fprintf(stderr, "[spawn-fork child] OOM, _exit 126\n");
            _exit(126);
        }
        int rc = box64_run(argc, argv2, (const char**)environ);
        fprintf(stderr,
            "[spawn-fork child] box64_run returned %d, _exit\n", rc);
        fflush(NULL);
        _exit(rc & 0xff);
    }

    /* ---- parent ---- */
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) _exit(127);
    }
    int code;
    if      (WIFEXITED(status))   code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
    else                          code = 1;

    OHOS_SPAWN_INFO("[spawn-fork] child pid=%d exited code=%d, _exit(self)\n",
        (int)pid, code);
    fflush(NULL);
    _exit(code);   /* execve semantics: never return on success */
}

static int spawn_fork(int* outpid, const char* path,
                      char* const argv[], char* const envp[]) {
    (void)path;
    int argc = count_argv(argv);
    if (argc == 0) { return ENOENT; }

    OHOS_SPAWN_INFO(
        "[spawn-fork] posix_spawn fork+box64_run argc=%d argv[0]=%s argv[1]=%s\n",
        argc, argv[0], argc > 1 ? argv[1] : "(none)");
    fflush(stderr);

    pid_t pid = fork();
    if (pid < 0) return errno;

    if (pid == 0) {
        /* ---- child ---- */
        apply_envp(envp);
        child_unmap_wine_reserve("spawn");
        child_reserve_wine_holes("spawn");

        const char** argv2 = NULL; char* blob = NULL;
        if (build_argv_blob(argv, argc, &argv2, &blob) < 0) {
            fprintf(stderr, "[spawn-fork spawn-child] OOM, _exit 126\n");
            _exit(126);
        }
        int rc = box64_run(argc, argv2, (const char**)environ);
        fprintf(stderr,
            "[spawn-fork spawn-child] box64_run returned %d, _exit\n", rc);
        fflush(NULL);
        _exit(rc & 0xff);
    }

    if (outpid) *outpid = (int)pid;
    OHOS_SPAWN_INFO(
        "[spawn-fork] spawn forked child pid=%d, returning 0\n", (int)pid);
    fflush(stderr);
    return 0;
}

/* ================================================================
 * [6] strategy: SOCK (delegate to HAP main process)
 * ================================================================ */
#define SOCK_REQ_BUF_CAP   (256 * 1024)
#define SOCK_RESP_BUF_CAP  (16  * 1024)

static int sock_request(const char* exe, char* const argv[], char* const envp[],
                        int wait_flag,
                        int* out_status_ok, pid_t* out_pid,
                        int* out_exit_code, char* errmsg, size_t errmsg_cap) {
    int fd = sock_connect();
    if (fd < 0) {
        fprintf(stderr, "[spawn-sock] connect failed: %s\n", strerror(errno));
        return -1;
    }

    char* req = (char*)malloc(SOCK_REQ_BUF_CAP);
    char* rsp = (char*)malloc(SOCK_RESP_BUF_CAP);
    if (!req || !rsp) { free(req); free(rsp); close(fd); return -1; }

    box64_fd_ref_t fdrefs[BOX64_FD_REF_MAX];
    int n_fdrefs = collect_envp_fd_refs(envp, fdrefs, BOX64_FD_REF_MAX);

    int rn = build_create_req(req, SOCK_REQ_BUF_CAP,
                              exe, argv, envp, wait_flag,
                              fdrefs, n_fdrefs);
    if (rn < 0) {
        fprintf(stderr, "[spawn-sock] request build overflow\n");
        free(req); free(rsp); close(fd); return -1;
    }

    if (sock_send_with_fds(fd, req, (size_t)rn, fdrefs, n_fdrefs) < 0) {
        fprintf(stderr, "[spawn-sock] sendmsg failed: %s\n", strerror(errno));
        free(req); free(rsp); close(fd); return -1;
    }

    size_t got = 0;
    if (frame_read(fd, rsp, SOCK_RESP_BUF_CAP, &got) < 0) {
        fprintf(stderr, "[spawn-sock] frame_read failed: %s\n", strerror(errno));
        free(req); free(rsp); close(fd); return -1;
    }

    parse_create_resp(rsp, got, out_status_ok, out_pid, out_exit_code,
                      errmsg, errmsg_cap);

    free(req); free(rsp); close(fd);
    return 0;
}

static int execve_sock(const char* path,
                       char* const argv[], char* const envp[]) {
    (void)path;
    int status_ok = 0;
    pid_t pid = -1;
    int   exit_code = -1;
    char  msg[256] = {0};
    int rc = sock_request(argv ? argv[0] : path, argv, envp,
                          /*wait_flag=*/1,
                          &status_ok, &pid, &exit_code, msg, sizeof(msg));
    if (rc < 0 || !status_ok) {
        if (!status_ok && rc == 0) {
            fprintf(stderr, "[spawn-sock] server error: %s\n", msg);
        }
        return -1;   /* signal fallback to fork */
    }
    OHOS_SPAWN_INFO(
        "[spawn-sock] sync spawn ok pid=%d exit=%d, _exit(self)\n",
        (int)pid, exit_code);
    fflush(NULL);
    _exit(exit_code & 0xff);
}

static int spawn_sock(int* outpid, const char* path,
                      char* const argv[], char* const envp[]) {
    (void)path;
    int status_ok = 0;
    pid_t pid = -1;
    char  msg[256] = {0};
    int rc = sock_request(argv ? argv[0] : path, argv, envp,
                          /*wait_flag=*/0,
                          &status_ok, &pid, NULL, msg, sizeof(msg));
    if (rc < 0 || !status_ok) {
        if (!status_ok && rc == 0) {
            fprintf(stderr, "[spawn-sock] server error: %s\n", msg);
        }
        return -1;   /* signal fallback to fork */
    }
    if (outpid) *outpid = (int)pid;
    OHOS_SPAWN_INFO("[spawn-sock] async spawn ok pid=%d\n", (int)pid);
    return 0;
}

/* ================================================================
 * [7] public dispatchers
 * ================================================================ */
__attribute__((visibility("default")))
int box64_self_execve(const char* path, char* const argv[], char* const envp[]) {
    enum spawn_strategy s = get_strategy();

    if (s == SP_SOCK && !s_sock_broken) {
        int rc = execve_sock(path, argv, envp);
        /* execve_sock only returns on failure */
        s_sock_broken = 1;
        fprintf(stderr, "[box64-spawn] sock failed, falling back to fork\n");
        (void)rc;
        s = SP_FORK;
    }

    if (s == SP_NATIVE) return execve_native(path, argv, envp);
    if (s == SP_FORK)   return execve_fork(path, argv, envp);
    return execve_fork(path, argv, envp);
}

__attribute__((visibility("default")))
int box64_self_execv(const char* path, char* const argv[]) {
    return box64_self_execve(path, argv, environ);
}

__attribute__((visibility("default")))
int box64_self_posix_spawn(int* outpid, const char* path,
                           const posix_spawn_file_actions_t* facts,
                           const posix_spawnattr_t* attr,
                           char* const argv[], char* const envp[]) {
    (void)facts; (void)attr;
    enum spawn_strategy s = get_strategy();

    if (s == SP_SOCK && !s_sock_broken) {
        int rc = spawn_sock(outpid, path, argv, envp);
        if (rc == 0) return 0;
        s_sock_broken = 1;
        fprintf(stderr, "[box64-spawn] sock failed, falling back to fork\n");
        s = SP_FORK;
    }

    if (s == SP_NATIVE) return spawn_native(outpid, path, argv, envp);
    return spawn_fork(outpid, path, argv, envp);
}

__attribute__((visibility("default")))
int box64_self_posix_spawnp(int* outpid, const char* path,
                            const posix_spawn_file_actions_t* facts,
                            const posix_spawnattr_t* attr,
                            char* const argv[], char* const envp[]) {
    /* path search not done here: callers already resolved to absolute */
    return box64_self_posix_spawn(outpid, path, facts, attr, argv, envp);
}
