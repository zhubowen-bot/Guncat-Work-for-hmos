// fs_shim_selftest.c — fs_shim.c 的可对比自测。
//
// 思路:同一段场景**跑两遍**,输出必须逐字节一致 ——
//   ① 不设 LD_PRELOAD:用的是**真**符号链接(普通 Linux);
//   ② LD_PRELOAD=./libfs_shim.so:用的是模拟链接(foo.BSH_SYMLINK)。
// 两遍的差别只有"链接怎么表示",程序看到的语义应当一模一样;输出一旦不同,
// 就说明 shim 在某一条语义上和真实现对不上。
//
// 为了两遍可比:
//   * 自己 mkdtemp 一个临时目录并 chdir 进去,打印出来的一律是**相对路径**;
//     万一要打印绝对路径(realpath),就把临时目录前缀剥掉。
//   * errno / 文件类型 / d_type 全部用本地映射表转成固定字符串 —— 不用 strerror(),
//     因为 glibc 与 musl 的措辞不同,那会让两遍的差别与 libc 有关而与 shim 无关。
//   * readdir 的返回顺序依赖文件系统,所以先收集再按名字排序后打印。
//   * 清理时用同样的 readdir 视图递归删除,顺带验证"列出来的名字能用 unlink 删掉"。
//
// 编译:见 README.md(不链接任何库,只要 libc)。

#define _GNU_SOURCE 1

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static char g_root[PATH_MAX];   // 临时目录绝对路径,打印时剥掉

// ─────────────────────────────── 打印小工具 ───────────────────────────────

static const char* en(int e) {
    switch (e) {
    case 0: return "OK";
    case ENOENT: return "ENOENT";
    case EEXIST: return "EEXIST";
    case ELOOP: return "ELOOP";
    case ENAMETOOLONG: return "ENAMETOOLONG";
    case EINVAL: return "EINVAL";
    case ENOTDIR: return "ENOTDIR";
    case EACCES: return "EACCES";
    case EISDIR: return "EISDIR";
    default: return "OTHER";
    }
}

static const char* ftype(mode_t m) {
    if (S_ISLNK(m)) return "LNK";
    if (S_ISREG(m)) return "REG";
    if (S_ISDIR(m)) return "DIR";
    return "OTHER";
}

// 把 errno 抓住再打印,免得中间又调了什么把 errno 覆盖掉
static void line(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
}

static void res(const char* what, long rc) {
    int e = errno;
    if (rc < 0) line("%-38s rc=-1  errno=%s", what, en(e));
    else line("%-38s rc=%ld  ok", what, rc);
}

// 剥掉临时目录前缀,只留相对形状;不在前缀下的原样返回
static const char* trim(const char* p) {
    size_t n = strlen(g_root);
    if (strncmp(p, g_root, n) == 0) {
        const char* r = p + n;
        while (*r == '/') r++;
        return *r ? r : ".";
    }
    return p;
}

// ─────────────────────────────── 用例片段 ───────────────────────────────

static void show_lstat(const char* what, const char* path) {
    struct stat st;
    errno = 0;
    int r = lstat(path, &st);
    if (r < 0) { res(what, r); return; }
    line("%-38s type=%s size=%lld nlink=%ld mode=%04o",
         what, ftype(st.st_mode), (long long)st.st_size, (long)st.st_nlink,
         (unsigned)(st.st_mode & 07777));
}

static void show_stat(const char* what, const char* path) {
    struct stat st;
    errno = 0;
    int r = stat(path, &st);
    if (r < 0) { res(what, r); return; }
    line("%-38s type=%s size=%lld", what, ftype(st.st_mode), (long long)st.st_size);
}

static void show_readlink(const char* what, const char* path) {
    char buf[256];
    errno = 0;
    ssize_t n = readlink(path, buf, sizeof buf - 1);
    if (n < 0) { res(what, -1); return; }
    buf[n] = 0;
    line("%-38s \"%s\" (%zd)", what, buf, n);
}

static void show_readlink0(const char* what, const char* path) {
    char buf[8];
    errno = 0;
    ssize_t n = readlink(path, buf, 0);      // bufsiz=0:真实现给 EINVAL
    if (n < 0) res(what, -1);
    else line("%-38s %zd", what, n);
}

static void show_open_read(const char* what, const char* path) {
    errno = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) { res(what, -1); return; }
    char buf[64];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    int saved = errno;
    close(fd);
    if (n < 0) { errno = saved; res(what, -1); return; }
    buf[n] = 0;
    for (ssize_t i = 0; i < n; i++) if (buf[i] == '\n') buf[i] = '|';
    line("%-38s \"%s\" (%zd)", what, buf, n);
}

// 只报读到的字节数 —— 给"目标内容是二进制、又必须两遍可比"的用例用
static void show_open_size(const char* what, const char* path) {
    errno = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) { res(what, -1); return; }
    char buf[4096];
    long long total = 0;
    ssize_t n;
    while ((n = read(fd, buf, sizeof buf)) > 0) total += n;
    int saved = errno;
    close(fd);
    if (n < 0) { errno = saved; res(what, -1); return; }
    line("%-38s %lld bytes", what, total);
}

static void show_open_nofollow(const char* what, const char* path) {    errno = 0;
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) { res(what, -1); return; }
    close(fd);
    line("%-38s rc=0  ok", what);
}

struct dent {
    char name[300];
    unsigned char type;
};

static int dent_cmp(const void* a, const void* b) {
    return strcmp(((const struct dent*)a)->name, ((const struct dent*)b)->name);
}

// 列目录:名字 + d_type,排序后打印。*.BSH_SYMLINK 必须已变成去掉后缀的名字 + DT_LNK。
static void put_file(const char* path, const char* data, size_t len) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    ssize_t n = write(fd, data, len);
    (void)n;
    close(fd);
}

static void show_dir(const char* what, const char* dir) {
    DIR* d = opendir(dir);
    if (!d) { res(what, -1); return; }
    struct dent v[64];
    size_t n = 0;
    struct dirent* e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        if (n >= sizeof v / sizeof v[0]) break;
        snprintf(v[n].name, sizeof v[n].name, "%s", e->d_name);
        v[n].type = e->d_type;
        n++;
    }
    closedir(d);
    qsort(v, n, sizeof v[0], dent_cmp);
    char buf[4096];
    size_t off = 0;
    buf[0] = 0;
    for (size_t i = 0; i < n; i++) {
        const char* t = v[i].type == DT_LNK ? "LNK" :
                        v[i].type == DT_REG ? "REG" :
                        v[i].type == DT_DIR ? "DIR" : "?";
        off += (size_t)snprintf(buf + off, sizeof buf - off, "%s%s:%s", i ? " " : "", v[i].name, t);
    }
    line("%-38s %s", what, buf);
}

// 递归删除(用 readdir 的视图,所以两遍都能删干净)
static void rm_rf(const char* path) {
    DIR* d = opendir(path);
    if (!d) { unlink(path); return; }
    struct dirent* e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        char sub[PATH_MAX];
        snprintf(sub, sizeof sub, "%s/%s", path, e->d_name);
        int isdir = (e->d_type == DT_DIR);
        if (e->d_type == DT_UNKNOWN) {
            struct stat st;
            isdir = lstat(sub, &st) == 0 && S_ISDIR(st.st_mode);
        }
        if (isdir) rm_rf(sub);
        else unlink(sub);
    }
    closedir(d);
    rmdir(path);
}

int main(void) {
    char tmpl[] = "/tmp/fs_shim_selftest.XXXXXX";
    if (!mkdtemp(tmpl)) { perror("mkdtemp"); return 1; }
    if (!getcwd(g_root, sizeof g_root)) return 1;
    if (chdir(tmpl) != 0) { perror("chdir"); return 1; }
    if (!getcwd(g_root, sizeof g_root)) return 1;

    line("== 环境 ==");
    line("root=<tmpdir>");

    // 目标文件与子目录
    put_file("target1", "hello-target\n", 13);
    mkdir("sub", 0755);
    put_file("sub/inner", "inner\n", 6);

    line("");
    line("== 建链接 / lstat / readlink ==");
    errno = 0;
    res("symlink(target1, link1)", symlink("target1", "link1"));
    errno = 0;
    res("symlink(/bin/sh, linkabs)", symlink("/bin/sh", "linkabs"));
    show_lstat("lstat(link1)", "link1");
    show_lstat("lstat(linkabs)", "linkabs");
    show_readlink("readlink(link1)", "link1");
    show_readlink("readlink(linkabs)", "linkabs");
    show_readlink0("readlink(link1, bufsiz=0)", "link1");

    line("");
    line("== 跟随解析:stat / open ==");
    show_stat("stat(link1)", "link1");
    show_stat("stat(linkabs)", "linkabs");
    show_open_read("open+read(link1)", "link1");
    show_open_size("open+read(linkabs) [binary]", "linkabs");

    line("");
    line("== 目录视图:d_type 与名字 ==");
    show_dir("readdir(.)", ".");

    line("");
    line("== EEXIST / O_NOFOLLOW ==");
    errno = 0;
    res("symlink(target1, link1) again", symlink("target1", "link1"));
    errno = 0;
    res("symlink(x, target1) onto real file", symlink("x", "target1"));
    errno = 0;
    res("symlink(x, sub) onto real dir", symlink("x", "sub"));
    errno = 0;
    res("symlink(\"\", empty-t)", symlink("", "empty-t"));
    char big[6000];
    memset(big, 'x', sizeof big - 1);
    big[sizeof big - 1] = 0;
    errno = 0;
    res("symlink(5999-byte target)", symlink(big, "toolong"));

    show_open_nofollow("open(link1, O_NOFOLLOW)", "link1");
    show_open_nofollow("open(target1, O_NOFOLLOW)", "target1");

    line("");
    line("== 悬空目标 ==");
    errno = 0;
    res("symlink(nope, dang)", symlink("nope", "dang"));
    show_lstat("lstat(dang)", "dang");
    show_stat("stat(dang)", "dang");
    errno = 0;
    int acc = access("dang", F_OK);
    line("%-38s rc=%d  (F_OK=%d)", "access(dang, F_OK)", acc, F_OK);
    errno = 0;
    acc = access("link1", F_OK);
    line("%-38s rc=%d  (F_OK=%d)", "access(link1, F_OK)", acc, F_OK);

    line("");
    line("== 链式链接(链接指向链接)==");
    errno = 0;
    res("symlink(link1, chain)", symlink("link1", "chain"));
    show_readlink("readlink(chain)", "chain");
    show_stat("stat(chain)", "chain");
    show_open_read("open+read(chain)", "chain");

    line("");
    line("== 相对目标 ==");
    errno = 0;
    res("symlink(sub/inner, rel1)", symlink("sub/inner", "rel1"));
    show_readlink("readlink(rel1)", "rel1");
    show_open_read("open+read(rel1)", "rel1");
    errno = 0;
    res("symlink(../target1, up1)", symlink("../target1", "up1"));
    show_readlink("readlink(up1)", "up1");

    line("");
    line("== 中间目录是链接 ==");
    errno = 0;
    res("symlink(sub, dirlink)", symlink("sub", "dirlink"));
    show_open_read("open(dirlink/inner)", "dirlink/inner");
    show_stat("stat(dirlink/inner)", "dirlink/inner");
    show_dir("readdir(dirlink)", "dirlink");
    show_lstat("lstat(dirlink/inner)", "dirlink/inner");

    line("");
    line("== fstatat / realpath ==");
    struct stat st;
    errno = 0;
    int r = fstatat(AT_FDCWD, "link1", &st, AT_SYMLINK_NOFOLLOW);
    if (r < 0) res("fstatat(link1, NOFOLLOW)", r);
    else line("%-38s type=%s size=%lld", "fstatat(link1, NOFOLLOW)", ftype(st.st_mode), (long long)st.st_size);
    errno = 0;
    r = fstatat(AT_FDCWD, "link1", &st, 0);
    if (r < 0) res("fstatat(link1, follow)", r);
    else line("%-38s type=%s size=%lld", "fstatat(link1, follow)", ftype(st.st_mode), (long long)st.st_size);

    char rp[PATH_MAX];
    errno = 0;
    char* got = realpath("link1", rp);
    if (!got) res("realpath(link1)", -1);
    else line("%-38s \"%s\"", "realpath(link1)", trim(got));
    errno = 0;
    got = realpath("chain", rp);
    if (!got) res("realpath(chain)", -1);
    else line("%-38s \"%s\"", "realpath(chain)", trim(got));
    errno = 0;
    got = realpath("dang", rp);
    if (!got) res("realpath(dang)", -1);
    else line("%-38s \"%s\"", "realpath(dang)", trim(got));

    line("");
    line("== link:另一个名字指向同一个链接 ==");
    errno = 0;
    res("link(link1, link1b)", link("link1", "link1b"));
    show_lstat("lstat(link1b)", "link1b");
    show_readlink("readlink(link1b)", "link1b");
    show_dir("readdir(.) after link", ".");

    line("");
    line("== rename 链接 ==");
    errno = 0;
    res("rename(link1, renamed)", rename("link1", "renamed"));
    show_lstat("lstat(link1) after rename", "link1");
    show_lstat("lstat(renamed)", "renamed");
    show_readlink("readlink(renamed)", "renamed");
    show_stat("stat(renamed)", "renamed");
    errno = 0;
    res("rename(renamed, target1) over file", rename("renamed", "target1"));
    show_lstat("lstat(target1) after rename", "target1");
    show_readlink("readlink(target1)", "target1");
    show_lstat("lstat(renamed) after rename", "renamed");

    line("");
    line("== 自环 → ELOOP ==");
    errno = 0;
    res("symlink(loop, loop)", symlink("loop", "loop"));
    show_lstat("lstat(loop)", "loop");
    show_stat("stat(loop)", "loop");
    show_open_read("open(loop)", "loop");

    line("");
    line("== unlink ==");
    errno = 0;
    res("unlink(linkabs)", unlink("linkabs"));
    show_lstat("lstat(linkabs) after unlink", "linkabs");
    errno = 0;
    res("unlink(linkabs) again", unlink("linkabs"));
    errno = 0;
    res("unlink(readlink-target link1b)", unlink("link1b"));
    show_lstat("lstat(link1b) after unlink", "link1b");

    line("");
    line("== 多条目压力:dir 流没被改坏 ==");
    // 造足够多的目录项,逼 readdir 底下的 getdents64 缓冲翻好几次页;条目总数、
    // 名字内容、d_type 任一被我们的改名搞错,最后的计数/校验和就对不上。
    // 两遍(真符号链接 / 模拟链接)必须给出同一个数。
    {
        static struct dent v[4096];
        char nm[64];
        for (int i = 0; i < 2000; i++) {
            snprintf(nm, sizeof nm, "f%04d", i);
            int f = open(nm, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (f >= 0) close(f);
        }
        for (int i = 0; i < 200; i++) {
            snprintf(nm, sizeof nm, "l%04d", i);
            if (symlink("target1", nm) != 0) line("stress symlink failed: %s", nm);
        }
        DIR* d = opendir(".");
        size_t n = 0;
        int overflow = 0;
        struct dirent* e;
        while ((e = readdir(d)) != NULL) {
            if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
            if (n >= sizeof v / sizeof v[0]) { overflow = 1; break; }
            snprintf(v[n].name, sizeof v[n].name, "%s", e->d_name);
            v[n].type = e->d_type;
            n++;
        }
        closedir(d);
        qsort(v, n, sizeof v[0], dent_cmp);
        unsigned long long h = 1469598103934665603ULL;
        int lnk = 0;
        for (size_t i = 0; i < n; i++) {
            for (const char* p = v[i].name; *p; p++) { h ^= (unsigned char)*p; h *= 1099511628211ULL; }
            h ^= (unsigned long long)v[i].type; h *= 1099511628211ULL;
            if (v[i].type == DT_LNK) lnk++;
        }
        line("entries=%zu overflow=%d links=%d checksum=%016llx", n, overflow, lnk, h);
        // 列出来的链接名必须能直接拿回去 readlink
        int good = 0;
        char tb[64];
        for (int i = 0; i < 200; i++) {
            snprintf(nm, sizeof nm, "l%04d", i);
            ssize_t k = readlink(nm, tb, sizeof tb - 1);
            if (k > 0) { tb[k] = 0; if (strcmp(tb, "target1") == 0) good++; }
        }
        line("readlink(l*0..199) == target1 : %d/200", good);
        for (int i = 0; i < 2000; i++) { snprintf(nm, sizeof nm, "f%04d", i); unlink(nm); }
        for (int i = 0; i < 200; i++) { snprintf(nm, sizeof nm, "l%04d", i); unlink(nm); }
    }

    line("");
    line("== 目录最终视图 ==");
    show_dir("readdir(.) final", ".");

    errno = 0;
    if (chdir("/") != 0) line("chdir to / failed");
    rm_rf(tmpl);
    line("");
    line("== done ==");
    return 0;
}
