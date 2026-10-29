/* libgreet.c — 被 dlopen 的库:证明"库不必放在系统/bundle 目录"。
 * 编成 libgreet.so,和 guest 一起摆在 $HOME(noexec)下。 */
#include <stdio.h>

int greet(const char *who)
{
    printf("libgreet: hello %s\n", who ? who : "(null)");
    fflush(stdout);
    return 42;
}
