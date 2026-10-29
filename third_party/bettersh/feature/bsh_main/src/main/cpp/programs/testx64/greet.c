/* greet.c — 被 dlhost / dlopen 用例加载的共享库（每个组合编一份，见 build_testprogs.sh）
 *
 * 存在的意义：给"动态链接"这一块两个独立的观察面 ——
 *   - dlhost-<combo>  把库**链接期**写进 DT_NEEDED，运行期由 guest 的动态链接器装载；
 *   - 主程序          用 dlopen(路径) **运行期**显式装载，再 dlsym 取符号。
 * 两条都从同一个 .so 取同一个函数，返回值固定 42，调用方按它判成功。
 */
#include <stdio.h>

/* 数据符号：顺带验 dlsym 取"对象"而不是"函数"这一路 */
int tgreet_yes = 1;

int greet(const char *who) {
    printf("[tgreet] hello %s（这句 printf 在库里）\n", who ? who : "?");
    fflush(stdout);
    return 42;
}
