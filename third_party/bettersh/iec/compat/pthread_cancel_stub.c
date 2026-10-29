/* pthread_cancel_stub.c — the pthread cancellation entry points musl declares
 * but does not implement.
 *
 * git's run-command.c calls pthread_setcancelstate around fork (atfork_prepare
 * / atfork_parent), and musl does not implement thread cancellation at all: the
 * extern declarations in the OHOS pthread.h are a glibc facade with no symbols
 * in libc.so. Without these definitions the link fails with
 *
 *     ld.lld: error: undefined symbol: pthread_setcancelstate
 *
 * Returning 0 is the correct answer here, not a workaround: there is no
 * cancellation to disable or restore, so both operations are no-ops. git gets
 * success and behaves as if cancellation is always off, which is true.
 *
 * A static inline in a header cannot be used: pthread.h already declares these
 * names extern, and a same-signature static definition would collide. Compile
 * this object and link it in.
 */
#include <pthread.h>

int pthread_setcancelstate(int state, int *oldstate)
{
	(void)state;
	(void)oldstate;
	return 0;
}

int pthread_setcanceltype(int type, int *oldtype)
{
	(void)type;
	(void)oldtype;
	return 0;
}
