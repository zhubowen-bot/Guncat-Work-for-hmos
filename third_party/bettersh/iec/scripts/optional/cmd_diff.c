// cmd_diff.c — `diff`，后端用随包的 git。
//
// 为什么不是 GNU diffutils：git 已经在包里，`git diff --no-index` 的输出是标准
// unified diff，退出码语义与 diff 一致（0 相同 / 1 有差异 / 2 出错），而且不需要
// 再引入一套 gnulib。这里只做 argv 转发，exec 走 IEC 的 exec 服务（命令 so 链接
// exec shim，execvp 会被服务接管，不会真的 execve）。
//
// 支持：diff [-u|-U n|-q|-s] a b（选项翻译后交给 git）。
// 注意：git diff 默认输出 unified 格式；需要传统 normal diff 请用 `git diff --no-index`。
//
// 转发时必须把选项放在 `--` 之前：`git diff --no-index -- -u a b` 会把 `-u` 当成
// 路径（退出码 129），选项就全部失效了。另外 git 对“路径不存在”只给退出码 1，
// 而 diff 约定是 2，所以转发前先用 stat 检查两个操作数。
//
// 入口 iec_diff_main。
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// 逐字节比较两个普通文件。返回 1 相同 / 0 不同 / -1 无法判断（目录、打开失败等）。
static int files_identical(const char* a, const char* b) {
    unsigned char ba[65536];
    unsigned char bb[65536];
    struct stat sa;
    struct stat sb;
    FILE* fa;
    FILE* fb;
    int same = 1;

    if (stat(a, &sa) != 0 || stat(b, &sb) != 0) return -1;
    if (!S_ISREG(sa.st_mode) || !S_ISREG(sb.st_mode)) return -1;
    if (sa.st_size != sb.st_size) return 0;
    fa = fopen(a, "rb");
    fb = fopen(b, "rb");
    if (fa == NULL || fb == NULL) {
        if (fa != NULL) fclose(fa);
        if (fb != NULL) fclose(fb);
        return -1;
    }
    for (;;) {
        const size_t na = fread(ba, 1, sizeof ba, fa);
        const size_t nb = fread(bb, 1, sizeof bb, fb);
        if (na != nb || (na > 0 && memcmp(ba, bb, na) != 0)) {
            same = 0;
            break;
        }
        if (na == 0) break;
    }
    fclose(fa);
    fclose(fb);
    return same;
}

int iec_diff_main(int argc, char** argv) {
    // git diff --no-index [options] -- <path> <path>
    char** args;
    char** opts;
    char** paths;
    int n = 0;
    int nopt = 0;
    int npath = 0;
    int report_same = 0;
    int endopts = 0;
    int i;

    args = (char**)calloc((size_t)argc + 8, sizeof(char*));
    opts = (char**)calloc((size_t)argc + 1, sizeof(char*));
    paths = (char**)calloc((size_t)argc + 1, sizeof(char*));
    if (args == NULL || opts == NULL || paths == NULL) {
        fprintf(stderr, "diff: out of memory\n");
        return 2;
    }

    for (i = 1; i < argc; i++) {
        const char* a = argv[i];
        if (!endopts && strcmp(a, "--") == 0) {
            endopts = 1;
            continue;
        }
        if (!endopts && strcmp(a, "-q") == 0) {
            opts[nopt++] = (char*)"--quiet";
            continue;
        }
        if (!endopts && strcmp(a, "-s") == 0) {
            // git 的 -s 是 --no-patch，语义不同；-s 由本进程判断，不转发。
            report_same = 1;
            continue;
        }
        if (!endopts && strcmp(a, "-U") == 0 && i + 1 < argc) {
            // GNU diff 允许 `-U n` 分开写，git 只认 `-Un`，这里拼起来。
            const size_t len = strlen(argv[i + 1]) + 3;
            char* combined = (char*)malloc(len);
            if (combined == NULL) {
                fprintf(stderr, "diff: out of memory\n");
                return 2;
            }
            snprintf(combined, len, "-U%s", argv[++i]);
            opts[nopt++] = combined;
            continue;
        }
        if (!endopts && a[0] == '-' && a[1] != '\0') {
            opts[nopt++] = argv[i];
            continue;
        }
        paths[npath++] = argv[i];
    }

    // 与 GNU diff 对齐：操作数不存在报错并返回 2（git 只返回 1）。
    for (i = 0; i < npath && i < 2; i++) {
        struct stat st;
        if (stat(paths[i], &st) != 0) {
            fprintf(stderr, "diff: %s: %s\n", paths[i], strerror(errno));
            return 2;
        }
    }

    if (report_same && npath >= 2 && files_identical(paths[0], paths[1]) == 1) {
        printf("Files %s and %s are identical\n", paths[0], paths[1]);
        return 0;
    }

    args[n++] = (char*)"git";
    args[n++] = (char*)"diff";
    args[n++] = (char*)"--no-index";
    for (i = 0; i < nopt; i++) args[n++] = opts[i];
    args[n++] = (char*)"--";
    for (i = 0; i < npath; i++) args[n++] = paths[i];
    args[n] = NULL;

    execvp("git", args);
    fprintf(stderr, "diff: cannot run git: %s\n", strerror(errno));
    return 2;
}
