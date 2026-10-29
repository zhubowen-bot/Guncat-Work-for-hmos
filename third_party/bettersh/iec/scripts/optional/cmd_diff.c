// cmd_diff.c — `diff`，后端用随包的 git。
//
// 为什么不是 GNU diffutils：git 已经在包里，`git diff --no-index` 的输出是标准
// unified diff，退出码语义与 diff 一致（0 相同 / 1 有差异 / 2 出错），而且不需要
// 再引入一套 gnulib。这里只做 argv 转发，exec 走 IEC 的 exec 服务（命令 so 链接
// exec shim，execvp 会被服务接管，不会真的 execve）。
//
// 支持：diff [-u|-U n|-q|-s] a b（选项原样交给 git）。
// 注意：git diff 默认输出 unified 格式；需要传统 normal diff 请用 `git diff --no-index`。
//
// 入口 iec_diff_main。
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int iec_diff_main(int argc, char** argv) {
    // git diff --no-index [options] -- <path> <path>
    char** args = (char**)calloc((size_t)argc + 8, sizeof(char*));
    if (args == NULL) {
        fprintf(stderr, "diff: out of memory\n");
        return 2;
    }
    int n = 0;
    args[n++] = (char*)"git";
    args[n++] = (char*)"diff";
    args[n++] = (char*)"--no-index";
    args[n++] = (char*)"--";
    for (int i = 1; i < argc; i++) {
        args[n++] = argv[i];
    }
    args[n] = NULL;
    execvp("git", args);
    fprintf(stderr, "diff: cannot run git: %s\n", strerror(errno));
    free(args);
    return 2;
}
