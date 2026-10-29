// common/proc.h — one question about another process that both services ask.
//
// The tty service uses it to tell a program the exec service started (a child
// of the application process) from the stand-in a shell put in the foreground
// group (a child of the shell). The exec service uses it to file a new process
// where the exec'd caller was, under the caller's parent rather than under the
// stand-in.
#ifndef IEC_PROC_H
#define IEC_PROC_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Parent pid of `pid`, read from /proc/<pid>/stat. Returns 0 when the file
// cannot be read or the line cannot be parsed -- no errno is promised, because
// every caller treats "unknown" the same way.
pid_t iec_parent_pid(pid_t pid);

#ifdef __cplusplus
}
#endif

#endif /* IEC_PROC_H */
