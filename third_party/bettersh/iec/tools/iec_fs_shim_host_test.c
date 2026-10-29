// tools/iec_fs_shim_host_test.c — 宿主机验证 fs/shim.c 的绝对路径映射。
//
// 构建成普通程序，运行时用 LD_PRELOAD 注入 dist/libiec_preload.so，并设置
// IEC_SYSROOT 指向一个临时根。要钉住的判据（对应 fs/shim.c 的 kPathMap 与
// map_path()）：
//
//   * open("/tmp/x")、stat("/etc/passwd") 必须落到 $IEC_SYSROOT/tmp/x、
//     $IEC_SYSROOT/etc/passwd，而不是宿主的 /tmp、/etc；
//   * 相对路径不加重前缀（仍在进程的当前目录里解析）；
//   * 已经在 sysroot 下的绝对路径不被再加一次前缀；
//   * 不匹配映射表的绝对路径原样透传；
//   * IEC_SHIM_LINK_STRICT=1 时宿主支持的硬链接保持“同 inode”语义。
//
// 临时根必须放在不被 kPathMap 命中的位置（/var/tmp 下），否则根自身以 /tmp
// 开头，会把“已映射路径”也匹配进映射表，测不出“不重复加前缀”。
//
// 用法: iec_fs_shim_host_test <临时根目录>
// 失败行以 FAIL 开头，退出码非 0。
#define _GNU_SOURCE 1

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static int g_checks = 0;
static int g_failures = 0;
static int g_skips = 0;

static void check(int ok, const char* what) {
    g_checks++;
    if (!ok) {
        g_failures++;
        printf("FAIL  %s\n", what);
    } else {
        printf("ok    %s\n", what);
    }
}

static void skip(const char* why) {
    g_skips++;
    printf("SKIP  %s\n", why);
}

/* 把 root 与一个 / 开头的相对片段拼起来；rel 为空时返回 root 本身。 */
static void join(char* out, size_t outsz, const char* root, const char* rel) {
    snprintf(out, outsz, "%s%s", root, rel);
}

static int write_file(const char* path, const char* data) {
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return -1;
    const size_t n = strlen(data);
    const ssize_t w = write(fd, data, n);
    close(fd);
    return (w == (ssize_t)n) ? 0 : -1;
}

/* 打开（不存在则创建）一个文件，返回其 fd 的 inode；失败返回 0。 */
static ino_t make_and_stat(const char* path) {
    int fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0644);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        return 0;
    }
    const ssize_t w = write(fd, "mapped", 6);
    (void)w;
    close(fd);
    return st.st_ino;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        printf("FAIL  用法: %s <临时根目录>\n", argv[0]);
        return 2;
    }
    const char* root = argv[1];

    /* Dijkstra 的“临时根”是空的，这里补出映射目标目录。 */
    char tmp_dir[4096], etc_dir[4096];
    join(tmp_dir, sizeof tmp_dir, root, "/tmp");
    join(etc_dir, sizeof etc_dir, root, "/etc");
    if (mkdir(tmp_dir, 0755) != 0 && errno != EEXIST) {
        printf("FAIL  创建 %s: %s\n", tmp_dir, strerror(errno));
        return 2;
    }
    if (mkdir(etc_dir, 0755) != 0 && errno != EEXIST) {
        printf("FAIL  创建 %s: %s\n", etc_dir, strerror(errno));
        return 2;
    }

    /* /etc/passwd 的假文件：内容长度作为判据，避免读到宿主真的 /etc/passwd。 */
    static const char kFakePasswd[] =
        "iec-fs-shim-host-test:x:1:1:fake passwd for the mapping test:/tmp:/bin/sh\n";
    char fake_passwd[4096];
    join(fake_passwd, sizeof fake_passwd, root, "/etc/passwd");
    check(write_file(fake_passwd, kFakePasswd) == 0, "写入 $IEC_SYSROOT/etc/passwd");

    /* 1. open("/tmp/x") 落到 <root>/tmp/x。 */
    {
        char name[128];
        snprintf(name, sizeof name, "x-%ld", (long)getpid());
        const char* abs = NULL;
        char abs_buf[4096];
        snprintf(abs_buf, sizeof abs_buf, "/tmp/%s", name);
        abs = abs_buf;

        const ino_t opened = make_and_stat(abs);          /* 走 shim 的 open("/tmp/...") */
        check(opened != 0, "open(\"/tmp/...\") 成功");

        char mapped[4096];
        join(mapped, sizeof mapped, root, abs);          /* <root>/tmp/... */
        struct stat st;
        check(stat(mapped, &st) == 0 && st.st_ino == opened,
              "open(\"/tmp/x\") 实际落在 <root>/tmp/x");
    }

    /* 2. stat("/etc/passwd") 看到的是 <root>/etc/passwd（同 inode、同长度）。 */
    {
        struct stat via_shim, direct;
        check(stat("/etc/passwd", &via_shim) == 0, "stat(\"/etc/passwd\") 成功");
        check(stat(fake_passwd, &direct) == 0, "stat(<root>/etc/passwd) 成功");
        check(via_shim.st_ino == direct.st_ino && via_shim.st_dev == direct.st_dev,
              "stat(\"/etc/passwd\") 命中的是 <root>/etc/passwd（同 inode）");
        check(via_shim.st_size == (off_t)strlen(kFakePasswd),
              "stat(\"/etc/passwd\") 的 st_size 等于假文件长度");
    }

    /* 3. 相对路径不重复加前缀：在 <root>/tmp 里 open("rel.txt") 就落在这里。 */
    {
        char cwd[4096], saved[4096], rel_abs[4096];
        if (getcwd(saved, sizeof saved) == NULL) {
            printf("FAIL  getcwd: %s\n", strerror(errno));
            return 2;
        }
        join(cwd, sizeof cwd, root, "/tmp");
        if (chdir(cwd) != 0) {
            printf("FAIL  chdir(%s): %s\n", cwd, strerror(errno));
            return 2;
        }
        const ino_t opened = make_and_stat("rel.txt");
        check(opened != 0, "相对路径 open(\"rel.txt\") 成功");
        join(rel_abs, sizeof rel_abs, cwd, "/rel.txt");
        struct stat st;
        check(stat(rel_abs, &st) == 0 && st.st_ino == opened,
              "相对路径落在 <root>/tmp/rel.txt，没有被加上前缀");
        if (chdir(saved) != 0) {
            printf("FAIL  chdir 回原目录: %s\n", strerror(errno));
            return 2;
        }
    }

    /* 4. 已映射的绝对路径（<root>/tmp/y）不再加一次前缀。 */
    {
        char already[4096], nested[8192];
        join(already, sizeof already, root, "/tmp/y");
        const ino_t opened = make_and_stat(already);
        check(opened != 0, "open(<root>/tmp/y) 成功");
        struct stat st;
        check(stat(already, &st) == 0 && st.st_ino == opened,
              "已映射路径仍指向 <root>/tmp/y");
        snprintf(nested, sizeof nested, "%s%s", root, already);
        check(stat(nested, &st) != 0, "已映射路径没有被重复加前缀");
    }

    /* 5. 不匹配映射表的绝对路径原样透传（写成相对根的路径会失败）。 */
    {
        struct stat st;
        char absent[4096];
        snprintf(absent, sizeof absent, "/iec-fs-shim-host-no-such-%ld", (long)getpid());
        check(stat(absent, &st) != 0 && errno == ENOENT,
              "不匹配映射表的绝对路径原样透传（ENOENT）");
    }

    /* 6. IEC_SHIM_LINK_STRICT=1：宿主支持硬链接时仍是“同 inode”。
     *    “不支持硬链接的环境”在宿主上构造不出来：环境拒绝硬链接要靠 EACCES/
     *    EPERM（protected_hardlinks、只读挂载），前者要跨用户、后者会给 EROFS，
     *    都不在 link_or_copy() 的降级条件里，所以这里只验证 strict 不破坏正常语义，
     *    真正的“失败时不降级”部分明确跳过。 */
    {
        char a[4096], b[4096];
        join(a, sizeof a, root, "/tmp/link-a");
        join(b, sizeof b, root, "/tmp/link-b");
        setenv("IEC_SHIM_LINK_STRICT", "1", 1);   /* 必须在第一次 link() 前设置（内部缓存） */
        check(write_file(a, "hardlink\n") == 0, "写入 link 源文件");
        const int rc = link(a, b);
        struct stat sa, sb;
        check(rc == 0 && stat(a, &sa) == 0 && stat(b, &sb) == 0 &&
                  sa.st_ino == sb.st_ino,
              "IEC_SHIM_LINK_STRICT=1 时宿主硬链接保持同 inode");
        skip("link() 在“环境不支持硬链接”时的 strict 行为：宿主无法构造该失败场景"
             "（见本文件第 6 节注释），不硬造");
    }

    printf("\n=== iec fs shim host: %d checks, %d failed, %d skipped ===\n",
           g_checks, g_failures, g_skips);
    return g_failures == 0 ? 0 : 1;
}
