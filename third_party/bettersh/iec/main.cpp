// main.cpp — server entry point
#include <csignal>
#include <cstdio>
#include <exception>

#include "common/constant.h"
#include "exec/caps.h"
#include "exec/exec_server.h"
#include "logger/logger.h"
#include "tty/tty_server.h"

static TtyServer*  g_tty_server  = nullptr;
static ExecServer* g_exec_server = nullptr;
static volatile sig_atomic_t g_stop = 0;

// The capability word this build pins. The default means chmod=1, fork=1 and
// exec=jit=path=0; a test build can pass e.g. -DIEC_PINNED_CAPS=0x11032 to
// exercise the loader route (chmod=1, fork=1, jit=3, path=2).
#ifndef IEC_PINNED_CAPS
#define IEC_PINNED_CAPS 0x11000
#endif

// Runs in signal context, so the only thing it may do is set flags: joining a
// thread in here is not async-signal-safe. The main thread does the joining once
// this flag has woken it up.
static void onSignal(int) {
    g_stop = 1;
    if (g_tty_server)  g_tty_server->stop();
    if (g_exec_server) g_exec_server->stop();
}

int main(int argc, char** argv) {
    // One argument cannot name both services: each listens on its own socket, so
    // the tty path comes first and the exec path second.
    const char* tty_path  = argc > 1 ? argv[1] : TTY_SOCK_PATH;
    const char* exec_path = argc > 2 ? argv[2] : EXEC_SOCK_PATH;

    // 0x11000 means chmod=1 (sandbox only), fork=1 and exec=jit=path=0.
    // See IEC_PINNED_CAPS above for test overrides.
    setCaps(IEC_PINNED_CAPS);

    try {
        TtyServer tty_srv(tty_path);
        ExecServer exec_srv(exec_path);
        g_tty_server = &tty_srv;
        g_exec_server = &exec_srv;

        // Both sockets have to be up before the handlers go in: a signal arriving
        // in between would stop the service that is already running and leave the
        // other one listening until the process dies.
        tty_srv.start();
        exec_srv.start();

        // Masked across the installation of the handlers, and left masked
        // afterwards so a second signal cannot cut the shutdown short; the mask is
        // lifted again for the wait below and put back by sigsuspend.
        sigset_t stop_signals, prev_mask;
        sigemptyset(&stop_signals);
        sigaddset(&stop_signals, SIGINT);
        sigaddset(&stop_signals, SIGTERM);
        sigprocmask(SIG_BLOCK, &stop_signals, &prev_mask);
        signal(SIGINT, onSignal);
        signal(SIGTERM, onSignal);

        // run() is a blocking poll loop, so each service gets a thread of its own
        // and the main thread is left with nothing to do but wait for the signal.
        tty_srv.startThread();
        exec_srv.startThread();

        // sigsuspend swaps the old mask in and waits in one step, so a signal
        // delivered before this point is taken here rather than missed in the
        // gap between testing the flag and entering the wait.
        while (!g_stop) sigsuspend(&prev_mask);

        // stopAndJoin() sets the same flag stop() does, so these calls are what
        // really end the loops -- and what lets the destructors below run safely.
        tty_srv.stopAndJoin();
        exec_srv.stopAndJoin();
    } catch (const std::exception& e) {
        Logger::GetInstance()->LogE("error: %s", e.what());
        return 1;
    }
    return 0;
}
