/* hello.c — 最小的动态 glibc guest(对照组,和 zz-glibc 里那份同一个形状)。
 * 退出码固定 7,方便 elfloader/qemu 两边对结果。 */
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    printf("glibc-guest pid=%d argc=%d argv0=%s\n", (int)getpid(), argc,
           argc > 0 ? argv[0] : "(none)");
    fflush(stdout);
    return 7;
}
