// pty_shim_selftest.c — shim/pty_shim.c 的可对比自测。
//
// 与 fs_shim_selftest.c 同一个套路：自己建资源、自己清理、输出固定（不打裸 fd 号、
// 不用 strerror()，免得 glibc/musl 措辞差别混进来），跑完打印 checks/failed 汇总，
// 有 FAIL 就非 0 退出。
//
// 本机（x86_64）验收假路径的用法：
//   gcc -O2 -std=gnu11 -shared -fPIC -o /tmp/ptyshim/libpty_shim.so pty_shim.c -ldl
//   gcc -O2 -std=gnu11 -o /tmp/ptyshim/selftest pty_shim_selftest.c
//   cd /tmp/ptyshim && BSH_FAKE_PTY=1 LD_PRELOAD=./libpty_shim.so ./selftest
//
// 注意本机只验**不依赖宿主**的那几条语义：isatty、master<->slave 数据通路、控制
// 终端、pts 号。termios 在设备上走的是会话的远端软 tty（control socket），本机没有
// 那个 socket，所以这里**不验** tcgetattr/tcsetattr —— 那两项在设备侧由 guest shim
// 的 tty_shim 负责（见 README）。

#define _GNU_SOURCE 1

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

static int g_checks;
static int g_failed;

// 判据行：通过记 ok，不通过记 FAIL 并计数。名字固定宽度，输出稳定。
static void check(const char* what, int ok) {
    g_checks++;
    if (!ok) g_failed++;
    printf("%-44s %s\n", what, ok ? "ok" : "FAIL");
}

static const char* en(int e) {
    switch (e) {
    case 0: return "0";
    case ENOENT: return "ENOENT";
    case EACCES: return "EACCES";
    case ENXIO: return "ENXIO";
    case EBADF: return "EBADF";
    default: return "OTHER";
    }
}

// ─────────────────── 控制终端子用例（放进 setsid 过的孙进程）───────────────────
//
// 为什么用到两层 fork：setsid() 要求调用者**不是进程组长**。交互 shell 把每条命令
// 放进自己的进程组，所以直接 fork 出来的子进程往往就是组长、setsid 会 EPERM；
// 中间层再 fork 一次、自己立刻退出，孙子一定不是组长，setsid 稳定成功。
// 结论用退出码的位带回来，打印仍在父进程做，输出顺序才确定。
static int g_slave_fd = -1;          // 父进程打开的 slave，孙进程继承
static char g_slave_path[64];        // ptsname 的结果

#define BIT_SETSID   1
#define BIT_AUTO     2   // setsid 后重新 open(slave) —— 应自动成为控制终端
#define BIT_TTY_AUTO 4   // 依赖上面的 auto-ctty，open("/dev/tty") 应成功
#define BIT_SCTTY    8   // 显式 ioctl(TIOCSCTTY) 成功
#define BIT_TTY_EXP  16  // 依赖显式的 TIOCSCTTY，open("/dev/tty") 应成功

static int run_ctty_child(void) {
    fflush(stdout);
    pid_t c = fork();
    if (c < 0) return -1;
    if (c == 0) {
        pid_t g = fork();
        if (g < 0) _exit(0);
        if (g > 0) { int st = 0; waitpid(g, &st, 0); _exit(WIFEXITED(st) ? WEXITSTATUS(st) : 0); }

        if (setsid() < 0) _exit(0);
        int bits = BIT_SETSID;

        // 会话组长第一次打开 tty → 真 pty 会自动把它当控制终端（我们照做）。
        int a = open(g_slave_path, O_RDWR);
        if (a >= 0) {
            bits |= BIT_AUTO;
            int t = open("/dev/tty", O_RDWR | O_NOCTTY);
            if (t >= 0) { bits |= BIT_TTY_AUTO; close(t); }
            close(a);
        }
        // 显式设控制终端（真程序拿不准时都会补这一步）。
#ifdef TIOCSCTTY
        if (ioctl(g_slave_fd, TIOCSCTTY, 0) == 0) {
            bits |= BIT_SCTTY;
            int t2 = open("/dev/tty", O_RDWR | O_NOCTTY);
            if (t2 >= 0) { bits |= BIT_TTY_EXP; close(t2); }
        }
#endif
        _exit(bits);
    }
    int st = 0;
    if (waitpid(c, &st, 0) != c) return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

int main(void) {
    printf("== pty_shim selftest ==\n");
    printf("BSH_FAKE_PTY=%s\n", getenv("BSH_FAKE_PTY") ? "set" : "unset");

    // ① open /dev/ptmx → 假 master
    int master = open("/dev/ptmx", O_RDWR | O_NOCTTY);
    check("open(/dev/ptmx)", master >= 0);
    if (master < 0) { printf("  errno=%s\n", en(errno)); goto done; }

    // 真 pty 的 master 不是 tty：我们也不登记它，应与内核一致（本机即可对比）。
    check("isatty(master) == 0", isatty(master) == 0);

    // ② grantpt / unlockpt：假成功
    errno = 0;
    check("grantpt(master) == 0", grantpt(master) == 0);
    errno = 0;
    check("unlockpt(master) == 0", unlockpt(master) == 0);

    // ③ ptsname / TIOCGPTN：两边给的号要一致
    char* sn = ptsname(master);
    check("ptsname(master) != NULL", sn != NULL);
    if (!sn) goto done;
    printf("%-44s \"%s\"\n", "ptsname(master)", sn);
    check("ptsname 形如 /dev/pts/<N>", strncmp(sn, "/dev/pts/", 9) == 0);
    snprintf(g_slave_path, sizeof g_slave_path, "%s", sn);

    unsigned int ptn = 0xffffffffu;
    errno = 0;
    int r = ioctl(master, TIOCGPTN, &ptn);
    check("ioctl(master, TIOCGPTN)", r == 0);
    if (r == 0) {
        printf("%-44s n=%u\n", "TIOCGPTN", ptn);
        char want[64];
        snprintf(want, sizeof want, "/dev/pts/%u", ptn);
        check("ptsname == /dev/pts/<TIOCGPTN>", strcmp(sn, want) == 0);
    }
    check("ioctl(master, TIOCSPTLCK) == 0", ioctl(master, TIOCSPTLCK, 0) == 0);

    // ④ open slave → 应登记成 tty
    int slave = open(g_slave_path, O_RDWR);
    check("open(slave)", slave >= 0);
    if (slave < 0) { printf("  errno=%s\n", en(errno)); goto done; }
    g_slave_fd = slave;
    check("isatty(slave) == 1", isatty(slave) == 1);

    char* tn = ttyname(slave);
    check("ttyname(slave) != NULL", tn != NULL);
    if (tn) check("ttyname(slave) == ptsname", strcmp(tn, sn) == 0);

    // 不是我们的 pts 号：必须落回真 open（内核会拒），不能拿我们的 master 顶上
    errno = 0;
    int bad = open("/dev/pts/424242", O_RDWR);
    check("open(/dev/pts/424242) 落回真 open 并失败", bad < 0);
    if (bad >= 0) close(bad);

    // ⑤ 数据通路：master -> slave 与 slave -> master 各验一次
    {
        const char* m2s = "hello-from-master\n";
        const char* s2m = "hello-from-slave\n";
        size_t nm = strlen(m2s), ns = strlen(s2m);
        char buf[64];
        memset(buf, 0, sizeof buf);
        ssize_t w = write(master, m2s, nm);
        ssize_t rd = read(slave, buf, sizeof buf - 1);
        check("write(master) -> read(slave) 内容一致",
              w == (ssize_t)nm && rd == (ssize_t)nm && memcmp(buf, m2s, nm) == 0);

        memset(buf, 0, sizeof buf);
        w = write(slave, s2m, ns);
        rd = read(master, buf, sizeof buf - 1);
        check("write(slave) -> read(master) 内容一致",
              w == (ssize_t)ns && rd == (ssize_t)ns && memcmp(buf, s2m, ns) == 0);
    }

    // ⑥ 控制终端：setsid + (auto-ctty / TIOCSCTTY) + open("/dev/tty")
    printf("== 控制终端（setsid 过的孙进程）==\n");
    {
        int bits = run_ctty_child();
        if (bits < 0) { check("fork/waitpid 子用例", 0); }
        else {
            check("setsid()", (bits & BIT_SETSID) != 0);
            check("setsid 后 open(slave) 自动成为控制终端 (auto-ctty)", (bits & BIT_AUTO) != 0);
            check("auto-ctty 后 open(/dev/tty) 成功", (bits & BIT_TTY_AUTO) != 0);
            check("ioctl(slave, TIOCSCTTY) == 0", (bits & BIT_SCTTY) != 0);
            check("TIOCSCTTY 后 open(/dev/tty) 成功", (bits & BIT_TTY_EXP) != 0);
        }
    }

    // ⑦ close(master)：slave 应读到 EOF（socketpair 对端没了）
    // 注意 g_slave_fd 与 slave 是同一个 fd（子用例直接继承了它，无需另开一份），
    // 这里只关 master。
    close(master);
    master = -1;
    {
        char buf[8];
        ssize_t rd = read(slave, buf, sizeof buf);
        check("close(master) 后 read(slave) == EOF(0)", rd == 0);
    }
    close(slave);
    slave = -1;

    // ⑧ 开关本身：不设 BSH_FAKE_PTY 时开 /dev/ptmx 应落回真实现。
    //    这一条依赖宿主真有 /dev/ptmx，所以只作 INFO（不判分）。
    {
        unsetenv("BSH_FAKE_PTY");
        errno = 0;
        int real = open("/dev/ptmx", O_RDWR | O_NOCTTY);
        int e = errno;
        printf("%-44s rc=%s\n", "BSH_FAKE_PTY 未设时 open(/dev/ptmx)",
               real >= 0 ? "real-ok" : en(e));
        if (real >= 0) close(real);
        setenv("BSH_FAKE_PTY", "1", 1);
    }

done:
    printf("checks=%d failed=%d\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}
