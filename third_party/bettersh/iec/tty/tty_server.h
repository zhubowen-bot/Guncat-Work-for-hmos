// tty/tty_server.h — TtyServer declaration
//
// Implementation in tty/tty_server.cpp. main.cpp only needs this header.
#pragma once

#include <poll.h>

#include <cstdint>
#include <string>
#include <vector>

#include "sock_operation.h"
#include "sock_server.h"

class TtyServer : public SockServer {
public:
    explicit TtyServer(const std::string& path);

private:
    bool onPing(const Packet& req, Reply& reply);
    bool onPong(const Packet& req, Reply& reply);
    bool onForkpty(const Packet& req, Reply& reply);
    bool onOpenPtmx(const Packet& req, Reply& reply);
    bool onOpenPts(const Packet& req, Reply& reply);
    bool onTcgetattr(const Packet& req, Reply& reply);
    bool onTcsetattr(const Packet& req, Reply& reply);
    bool onTcgetpgrp(const Packet& req, Reply& reply);
    bool onTcsetpgrp(const Packet& req, Reply& reply);
    bool onGetWinsz(const Packet& req, Reply& reply);
    bool onSetWinsz(const Packet& req, Reply& reply);
    bool onIdentify(const Packet& req, Reply& reply);

    // The pty ends this server holds are its own kind of connection; run() knows
    // nothing about them, so they are polled through these two hooks.
    void addPollFds(std::vector<pollfd>& fds) override;
    void pollEvent(int fd, short revents) override;
};
