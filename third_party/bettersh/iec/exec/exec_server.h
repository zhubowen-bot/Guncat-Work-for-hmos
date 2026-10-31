// exec/exec_server.h — ExecServer declaration
//
// Implementation in exec/exec_server.cpp. main.cpp only needs this header.
#pragma once

#include <poll.h>

#include <cstdint>
#include <string>
#include <vector>

#include "sock_operation.h"
#include "sock_server.h"

class ExecServer : public SockServer {
public:
    explicit ExecServer(const std::string& path);

private:
    bool onPing(const Packet& req, Reply& reply);
    bool onPong(const Packet& req, Reply& reply);
    bool onExecute(const Packet& req, Reply& reply);
    bool onWait(const Packet& req, Reply& reply);
    bool onSignal(const Packet& req, Reply& reply);

    // Ends every process started under one job id; see OP_TERMINATE_JOB. The
    // request names the job rather than a pid because a job is the only handle
    // that survives an exec chain (the pid of the program a shell started is not
    // the pid the caller was given).
    bool onTerminateJob(const Packet& req, Reply& reply);

    // Sends one signal to every process of a job; see OP_SIGNAL_JOB. Used by
    // toybox timeout: TERM now, KILL after its own grace period.
    bool onSignalJob(const Packet& req, Reply& reply);

    // One text line per known process; see OP_LIST.
    bool onList(const Packet& req, Reply& reply);

    // A SIGTERM was answered with silence and the grace period has run out; the
    // entry names enough to tell the same process from a recycled pid. Handled in
    // onTick() rather than on a timer thread because procmap belongs to the
    // server thread alone (see the note above it).
    struct PendingKill {
        pid_t       pid = 0;
        std::string job;
        int64_t     start_ms = 0;
        int64_t     due_ms = 0;
    };
    std::vector<PendingKill> pending_kills_;

    // Reaps children that have exited since the previous pass of the event loop;
    // see the note above the definition for why this is a loop hook rather than a
    // SIGCHLD handler.
    void onTick() override;
};
