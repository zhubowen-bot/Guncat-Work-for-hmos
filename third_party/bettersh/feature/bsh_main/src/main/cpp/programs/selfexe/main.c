// programs/selfexe/main.c — /proc/self/exe 自测（readlink / stat / lstat / open / fork / exec-self）
//
// 为什么单写它：guest 是"别人的二进制"、由 elfloader 在宿主进程里装载，内核看到的
// /proc/self/exe 是宿主 appspawn，不是 guest 自己。而"自省自己是谁"全靠这条路径 ——
// 设备侧 hdc 一碰它就 SIGSYS/rc=159（连输出都没有），所以这里给一组**能定位到哪一条**
// 的最小用例：范围覆盖 readlink / stat / lstat / open / fopen / access / realpath、
// fork 之后再读（fd 与地址空间继承），以及 fork+execv("/proc/self/exe") 起自己
// （hdc 那条"自拉起"的路径）。
//
// 期望值按真 Linux 的 procfs 语义写：/proc/self/exe 是**魔法符号链接** ——
//   readlink 给真实路径；stat 给目标文件的属性；lstat 给 S_IFLNK|0777 且 size=0。
//
// 跑法（BetterSH 终端里）：
//     cd $HOME/testprogs && ./selfexe-aarch64-musl-dynamic     # 或 -glibc-dynamic
//     ./selfexe-aarch64-musl-dynamic --child                   # 子模式（被 exec 用）
// 末行固定 "selfexe: PASS=n FAIL=n"，便于 grep；退出码 = FAIL 数（0 表示全过）。
//
// 静态链接的 guest 请**不要**拿它当判据：LD_PRELOAD 对静态无效，替身不生效，
// 那属于已知不支持的情形（见 shim/README.md）。
#define _GNU_SOURCE
#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define EXE_PATH "/proc/self/exe"

static int g_pass, g_fail;

static void ok(const char* what) {
    g_pass++;
    printf("  [PASS] %s\n", what);
}
static void bad(const char* what, const char* detail) {
    g_fail++;
    printf("  [FAIL] %s%s%s\n", what, (detail && *detail) ? " — " : "",
           detail ? detail : "");
}
static void chk(int cond, const char* what, const char* detail) {
    if (cond) ok(what);
    else bad(what, detail);
}
static void skip(const char* what) { printf("  [SKIP] %s\n", what); }

/* readlink(EXE_PATH)，成功返回长度并把结果写进 out（已补 NUL）。 */
static ssize_t read_exe(char* out, size_t cap) {
    if (cap == 0) return -1;
    ssize_t n = readlink(EXE_PATH, out, cap - 1);
    if (n < 0) { out[0] = 0; return -1; }
    out[n] = 0;
    return n;
}

static int elf_magic(const char* path, char out4[4]) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    char m[4] = {0};
    ssize_t n = read(fd, m, sizeof m);
    close(fd);
    if (n != 4) return 0;
    if (out4) memcpy(out4, m, 4);
    return (unsigned char)m[0] == 0x7f && m[1] == 'E' && m[2] == 'L' && m[3] == 'F';
}

int main(int argc, char** argv) {
    /* ── 子模式：被 execv(EXE_PATH) 起来的那个进程只报身份，退出码固定 42 ── */
    if (argc >= 2 && strcmp(argv[1], "--child") == 0) {
        char t[4096];
        ssize_t n = read_exe(t, sizeof t);
        printf("  [child] /proc/self/exe = %s (len=%zd)\n",
               n > 0 ? t : "<readlink 失败>", n);
        char m[4];
        printf("  [child] open(/proc/self/exe) 是 ELF = %d\n", elf_magic(EXE_PATH, m));
        fflush(NULL);
        _exit(42);
    }

    /* ── 子模式：--open <path> —— 只测"能不能打开并读"（定位 musl 的预载失败用） ── */
    if (argc >= 3 && strcmp(argv[1], "--open") == 0) {
        int fd = open(argv[2], O_RDONLY);
        if (fd < 0) {
            printf("  [open] %s → 失败 errno=%d(%s)\n", argv[2], errno, strerror(errno));
            fflush(NULL);
            _exit(1);
        }
        char buf[4096];
        long total = 0;
        ssize_t n;
        while ((n = read(fd, buf, sizeof buf)) > 0) total += (long)n;
        close(fd);
        printf("  [open] %s → OK，读到 %ld 字节\n", argv[2], total);
        fflush(NULL);
        _exit(0);
    }

    /* ── 子模式：--dlopen <path> —— 直接问 musl 的 load_library（预载走的是同一段代码，
     *    而且它能给 dlerror() 的错误文案，这正是 LD_PRELOAD 静默失败时拿不到的东西） ── */
    if (argc >= 3 && strcmp(argv[1], "--dlopen") == 0) {
        void* h = dlopen(argv[2], RTLD_NOW | RTLD_GLOBAL);
        if (!h) {
            /* 注意 dlerror() 是"取走"语义：调两次第二次就没了（第一版这里连调两次，
             * 拿到的永远是"(空)"，白跑一轮）。 */
            const char* e = dlerror();
            printf("  [dlopen] %s → 失败: %s\n", argv[2], e ? e : "(dlerror 为空)");
            fflush(NULL);
            _exit(1);
        }
        printf("  [dlopen] %s → OK (handle=%p)\n", argv[2], h);
        void* s = dlsym(h, "readlink");
        printf("  [dlopen] dlsym(readlink)=%p\n", s);
        fflush(NULL);
        _exit(0);
    }

    printf("=== selfexe: /proc/self/exe 自测 (%s) ===\n", argv[0]);
    printf("  argv[0] = %s\n  pid     = %d\n", argv[0], (int)getpid());
    printf("  env: BSH_GUEST_EXE=%s LD_PRELOAD=%s BSH_EXEC_SHIM=%s\n",
           getenv("BSH_GUEST_EXE") ? getenv("BSH_GUEST_EXE") : "(未设)",
           getenv("LD_PRELOAD") ? getenv("LD_PRELOAD") : "(未设)",
           getenv("BSH_EXEC_SHIM") ? getenv("BSH_EXEC_SHIM") : "(未设)");

    char target[4096];
    char detail[4608];
    ssize_t tn = read_exe(target, sizeof target);

    /* ── 用例 1：readlink 必须指向**自己**（存在 + 是 ELF + 名字对得上） ── */
    const char* base = strrchr(argv[0], '/');
    base = base ? base + 1 : argv[0];
    int self_ok = 0;
    if (tn > 0) {
        struct stat st;
        int exists = (stat(target, &st) == 0);
        int magic = elf_magic(target, NULL);
        int name_ok = (strstr(target, base) != NULL);
        snprintf(detail, sizeof detail,
                 "readlink 给了 \"%s\"（存在=%d ELF=%d 名字含\"%s\"=%d）",
                 target, exists, magic, base, name_ok);
        self_ok = exists && magic && name_ok;
        chk(self_ok, "1 readlink(/proc/self/exe) 指向自身", detail);
    } else {
        snprintf(detail, sizeof detail, "readlink 失败 errno=%d(%s)",
                 errno, strerror(errno));
        bad("1 readlink(/proc/self/exe) 指向自身", detail);
    }

    /* 第 1 条不过也**继续**跑 2–7：用 argv[0]（procmgr 给的绝对路径）当参照，
     * 才能分清"整层 shim 都没生效"还是"只有 readlink 没被拦到"。
     * 第 8 条（execv 自己）只在第 1 条通过时才跑 —— 否则它就是去 exec 宿主 appspawn，
     * 那件事本身很危险、也不是我们要测的。 */
    if (!self_ok) {
        if (argv[0][0] == '/' && access(argv[0], F_OK) == 0) {
            snprintf(target, sizeof target, "%s", argv[0]);
            printf("  [提示] 第 1 条不过；下面用 argv[0] 当参照继续测 2–7"
                   "（能过哪几条就说明哪些入口被 shim 拦到了）\n");
        } else {
            printf("  [提示] 连 argv[0] 都不是绝对可执行路径，2–7 无从参照，跳过\n");
            skip("2..7");
            goto summary;
        }
    }

    {
        /* ── 用例 2：stat 跟随 → 目标文件自己的属性 ── */
        struct stat a, b;
        snprintf(detail, sizeof detail, "stat(%s) 与 stat(%s) 不一致", EXE_PATH, target);
        if (stat(EXE_PATH, &a) != 0) {
            snprintf(detail, sizeof detail, "stat(%s) 失败 errno=%d(%s)",
                     EXE_PATH, errno, strerror(errno));
            bad("2 stat(/proc/self/exe) == stat(真实路径)", detail);
        } else if (stat(target, &b) != 0) {
            bad("2 stat(/proc/self/exe) == stat(真实路径)", "真实路径 stat 失败");
        } else {
            snprintf(detail, sizeof detail,
                     "dev %llu/%llu ino %llu/%llu size %lld/%lld",
                     (unsigned long long)a.st_dev, (unsigned long long)b.st_dev,
                     (unsigned long long)a.st_ino, (unsigned long long)b.st_ino,
                     (long long)a.st_size, (long long)b.st_size);
            chk(a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size,
                "2 stat(/proc/self/exe) == stat(真实路径)", detail);
        }

        /* ── 用例 3：lstat 不跟随 → 符号链接（procfs 魔法链接：size=0、nlink=1）
         *   ⚠ 这一条**分辨不出替身有没有生效**：没修的时候内核给的 procfs 魔法链接
         *   也是这个形状（真 Linux 的 inode 是 procfs 的，不是本体的）。留着只是确认
         *   "替身没把 lstat 弄坏"。判别生效与否看 1/2/4/5/6/7。 ── */
        struct stat l;
        if (lstat(EXE_PATH, &l) != 0) {
            snprintf(detail, sizeof detail, "lstat 失败 errno=%d(%s)", errno, strerror(errno));
            bad("3 lstat(/proc/self/exe) 是符号链接(size=0)", detail);
        } else {
            snprintf(detail, sizeof detail, "mode=%o size=%lld nlink=%lld",
                     (unsigned)l.st_mode, (long long)l.st_size, (long long)l.st_nlink);
            chk(S_ISLNK(l.st_mode) && l.st_size == 0 && l.st_nlink == 1,
                "3 lstat(/proc/self/exe) 是符号链接(size=0)", detail);
        }

        /* ── 用例 4：open(/proc/self/exe) 读到的必须是**自己的镜像**
         *   只看 4 字节 ELF 魔数不够：没修的时候读的是宿主 appspawn，那也是个 ELF。
         *   所以连 fstat 出来的大小一起比。 ── */
        char ma[4] = {0}, mb[4] = {0};
        int ea = elf_magic(EXE_PATH, ma);
        int eb = elf_magic(target, mb);
        long long sa = -1, sb = -1;
        {
            int fa_ = open(EXE_PATH, O_RDONLY);
            int fb_ = open(target, O_RDONLY);
            struct stat st;
            if (fa_ >= 0 && fstat(fa_, &st) == 0) sa = (long long)st.st_size;
            if (fb_ >= 0 && fstat(fb_, &st) == 0) sb = (long long)st.st_size;
            if (fa_ >= 0) close(fa_);
            if (fb_ >= 0) close(fb_);
        }
        snprintf(detail, sizeof detail,
                 "自我=%d(%lld B) 真实=%d(%lld B) 前4字节 %02x%02x%02x%02x/%02x%02x%02x%02x",
                 ea, sa, eb, sb, (unsigned char)ma[0], (unsigned char)ma[1],
                 (unsigned char)ma[2], (unsigned char)ma[3], (unsigned char)mb[0],
                 (unsigned char)mb[1], (unsigned char)mb[2], (unsigned char)mb[3]);
        chk(ea && eb && memcmp(ma, mb, 4) == 0 && sa > 0 && sa == sb,
            "4 open(/proc/self/exe) 读到的就是自己的镜像", detail);

        /* ── 用例 5：fopen 全量读（库内部 syscall 路径也要被覆盖） ── */
        FILE* fa = fopen(EXE_PATH, "rb");
        FILE* fb = fopen(target, "rb");
        long la = -1, lb = -1;
        if (fa && fb) {
            char buf[4096];
            size_t n;
            la = lb = 0;
            while ((n = fread(buf, 1, sizeof buf, fa)) > 0) la += (long)n;
            while ((n = fread(buf, 1, sizeof buf, fb)) > 0) lb += (long)n;
        }
        if (fa) fclose(fa);
        if (fb) fclose(fb);
        snprintf(detail, sizeof detail, "fopen 读到的长度 %ld（真实文件 %ld）", la, lb);
        chk(la > 0 && la == lb, "5 fopen(/proc/self/exe) 读到完整镜像", detail);

        /* ── 用例 6：access(R_OK) 与 realpath ── */
        int acc = access(EXE_PATH, R_OK);
        char rp[4096] = {0};
        char rq[4096] = {0};
        int r1 = realpath(EXE_PATH, rp) ? 1 : 0;
        int r2 = realpath(target, rq) ? 1 : 0;
        snprintf(detail, sizeof detail, "access=%d realpath(自我)=%s realpath(真实)=%s",
                 acc, r1 ? rp : "<null>", r2 ? rq : "<null>");
        chk(acc == 0 && r1 && r2 && strcmp(rp, rq) == 0,
            "6 access(R_OK) 与 realpath(/proc/self/exe)", detail);

        /* ── 用例 7：fork 之后（fd 表与地址空间都继承）仍能 self-introspect ── */
        pid_t p = fork();
        if (p == 0) {
            char t2[4096];
            ssize_t n2 = read_exe(t2, sizeof t2);
            int same = (n2 > 0 && strcmp(t2, target) == 0);
            char m[4];
            int o = elf_magic(EXE_PATH, m);
            printf("  [child] fork 后 readlink=%s 与父一致=%d open=%d\n",
                   n2 > 0 ? t2 : "<fail>", same, o);
            fflush(NULL);
            _exit((same && o) ? 0 : 1);
        } else if (p < 0) {
            snprintf(detail, sizeof detail, "fork 失败 errno=%d(%s)", errno, strerror(errno));
            bad("7 fork 后子进程仍能 readlink+open 自己", detail);
        } else {
            int st = 0;
            waitpid(p, &st, 0);
            int rc = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
            snprintf(detail, sizeof detail, "子进程 rc=%d（期望 0）", rc);
            chk(rc == 0, "7 fork 后子进程仍能 readlink+open 自己", detail);
        }

        /* ── 用例 8：fork + execv("/proc/self/exe") 起自己（hdc 的"自拉起"形态） ──
         * 只有第 1 条过了才跑：否则 /proc/self/exe 还是宿主 appspawn，这一 exec 等于
         * 去起 appspawn —— 既危险又不是我们要测的东西。 */
        if (!self_ok) {
            skip("8 fork+execv 起自己（第 1 条没过，不试）");
        } else {
        p = fork();
        if (p == 0) {
            char* av[3];
            av[0] = argv[0];
            av[1] = (char*)"--child";
            av[2] = NULL;
            execv(EXE_PATH, av);
            printf("  [child] execv(%s) 失败：errno=%d(%s)\n", EXE_PATH, errno,
                   strerror(errno));
            fflush(NULL);
            _exit(126);
        } else if (p < 0) {
            snprintf(detail, sizeof detail, "fork 失败 errno=%d(%s)", errno, strerror(errno));
            bad("8 fork+execv(/proc/self/exe) 起自己", detail);
        } else {
            int st = 0;
            waitpid(p, &st, 0);
            int rc = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
            snprintf(detail, sizeof detail,
                     "子进程 rc=%d（期望 42 = --child 的固定退出码；126 = exec 直接失败）", rc);
            chk(rc == 42, "8 fork+execv(/proc/self/exe) 起自己", detail);
        }
        }
    }

summary:
    printf("selfexe: PASS=%d FAIL=%d\n", g_pass, g_fail);
    fflush(NULL);
    return g_fail;
}
