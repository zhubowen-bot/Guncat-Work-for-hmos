/* hello.c — BetterSH 冒烟测试用小程序
 * 用法:clang hello.c -o hello && ./hello
 * (clang 入口已默认带 --sysroot/-static-pie/-fuse-ld=lld,无需额外参数) */
#include <stdio.h>
#include <unistd.h>

int main(int argc, char** argv) {
    printf("hello from BetterSH guest (pid=%d, argc=%d)\n", (int)getpid(), argc);
    for (int i = 0; i < argc; i++) printf("  argv[%d] = %s\n", i, argv[i]);
    return 0;
}
