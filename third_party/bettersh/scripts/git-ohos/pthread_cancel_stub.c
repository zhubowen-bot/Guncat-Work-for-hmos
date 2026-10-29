/* pthread_cancel_stub.c — 补上 musl 只声明、不实现的那几个 pthread 取消 API
 *
 * 为什么需要：git 的 run-command.c 在 fork 前后要用 pthread_setcancelstate 把
 * 当前线程的取消状态关掉再恢复（atfork_prepare / atfork_parent），而 **musl 根本
 * 不实现线程取消** —— OHOS 的 pthread.h 里那几行 extern 声明是从 glibc 抄过来的
 * 门面，libc.so 里对应的符号一个都没有：
 *
 *     $ llvm-nm -D --defined-only <sysroot>/libc.so | grep pthread_setcancelstate
 *     （空）
 *
 * 于是链接期就炸：ld.lld: error: undefined symbol: pthread_setcancelstate
 *
 * 为什么"返回 0"就是正确语义：这几个函数的作用是**改变本线程的取消状态**，而 musl
 * 里压根不存在"取消"这回事（pthread_cancel 也是 no-op）。所以"禁止取消"和"恢复取消"
 * 在这里都是无事发生，返回成功（0）即可 —— 不是权宜之计的假实现，而是这个 libc 下
 * 唯一说得通的答案。git 拿到 0 就继续往下走，行为与"取消永远关着"一致。
 *
 * 为什么不做成静态内联塞进头文件（-include）：OHOS 的 pthread.h 已经把这些名字
 * `extern` 声明过了，再写一个 `static inline` 同签名定义会撞 "static declaration
 * follows non-static declaration"；只能另编一个 .o 参与链接（经 git 的
 * LDFLAGS_APPEND 钩子）。
 *
 * 只定义链接期真正缺的 —— 多定义的会遮蔽 libc（对象文件优先于库），少定义则链接报错。
 * 每加一个，都要在设备上跑一遍 git 的基本命令确认没把别的路径带坏。
 */
#include <pthread.h>

int pthread_setcancelstate(int state, int *oldstate)
{
	(void)state;
	(void)oldstate;
	return 0;   /* musl 没有取消机制：禁用/恢复都是无事发生 */
}

int pthread_setcanceltype(int type, int *oldtype)
{
	(void)type;
	(void)oldtype;
	return 0;
}
