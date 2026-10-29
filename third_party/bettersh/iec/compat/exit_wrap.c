// compat/exit_wrap.c — make exit() inside a spawned object leave with its code.
//
// A #IECSO program is entered in a fork() of the app process, not a fresh
// process. libc's exit() runs the atexit handlers and static destructors
// inherited from that process; the ArkTS runtime registers some, and one of
// them ends the child with 0 before the requested code is applied. The symptom
// is that every program which calls exit() reports success -- `sh -c 'exit 7'`
// returns 0 and a failing git helper is indistinguishable from a successful
// one -- while programs whose main() simply returns are unaffected.
//
// Linking a command object with -Wl,--wrap=exit turns those calls into
// __wrap_exit(), which does what exit() was supposed to do: flush stdio, then
// leave with exactly the code that was asked for.
#include <stdio.h>
#include <unistd.h>

__attribute__((noreturn)) void __wrap_exit(int status) {
    fflush(NULL);
    _exit(status & 0xFF);
}
