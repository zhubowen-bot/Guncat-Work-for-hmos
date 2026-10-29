// common/sock_server.cpp - implementation of the UDS server framework declared in sock_server.h
#include "sock_server.h"

#include <arpa/inet.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <utility>

#include "logger/logger.h"

namespace {

// Sends fds over SCM_RIGHTS attached to the given bytes. On a stream socket the
// fds must ride along with at least one data byte, so this is only ever used for
// the first send of a packet; the rest of the packet goes out with plain send().
ssize_t sendWithFds(int fd, const void* data, size_t len, const std::vector<int>& fds) {
    struct msghdr msg = {};
    struct iovec iov = {};
    char cbuf[CMSG_SPACE(sizeof(int) * kMaxFds)] = {};
    struct cmsghdr* cm;
    size_t nfds = fds.size() > static_cast<size_t>(kMaxFds)
                      ? static_cast<size_t>(kMaxFds) : fds.size();
    ssize_t w;

    iov.iov_base = const_cast<void*>(data);
    iov.iov_len = len;
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cbuf;
    msg.msg_controllen = CMSG_SPACE(sizeof(int) * nfds);

    cm = CMSG_FIRSTHDR(&msg);
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type = SCM_RIGHTS;
    cm->cmsg_len = CMSG_LEN(sizeof(int) * nfds);
    memcpy(CMSG_DATA(cm), fds.data(), sizeof(int) * nfds);

    do {
        w = sendmsg(fd, &msg, MSG_NOSIGNAL);
    } while (w < 0 && errno == EINTR);
    return w;
}

// Receives bytes and collects any fds that came with them.
ssize_t recvWithFds(int fd, void* data, size_t len, std::vector<int>& out_fds) {
    struct msghdr msg = {};
    struct iovec iov = {};
    char cbuf[CMSG_SPACE(sizeof(int) * kMaxFds)];
    ssize_t r;

    iov.iov_base = data;
    iov.iov_len = len;
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cbuf;
    msg.msg_controllen = sizeof cbuf;

#ifdef MSG_CMSG_CLOEXEC
    r = recvmsg(fd, &msg, MSG_CMSG_CLOEXEC);
#else
    r = recvmsg(fd, &msg, 0);
#endif
    if (r <= 0) return r;

    for (struct cmsghdr* cm = CMSG_FIRSTHDR(&msg); cm != nullptr; cm = CMSG_NXTHDR(&msg, cm)) {
        if (cm->cmsg_level != SOL_SOCKET || cm->cmsg_type != SCM_RIGHTS) continue;
        if (cm->cmsg_len < CMSG_LEN(0)) continue;
        size_t n = (cm->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        const int* received = reinterpret_cast<const int*>(CMSG_DATA(cm));
        for (size_t i = 0; i < n; ++i) {
            if (out_fds.size() < static_cast<size_t>(kMaxFds)) {
                out_fds.push_back(received[i]);
            } else {
                close(received[i]);  // no room: close rather than leak
            }
        }
    }
    return r;
}

int PeerPidOf(int fd) {
    struct ucred cred;
    socklen_t len = sizeof cred;

    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) < 0) {
        Logger::GetInstance()->LogW("[server] SO_PEERCRED failed: %s", strerror(errno));
        return 0;
    }
    return static_cast<int>(cred.pid);
}

}  // namespace

void put32(std::vector<uint8_t>& v, uint32_t x) {
    uint32_t n = htonl(x);
    const uint8_t* p = reinterpret_cast<const uint8_t*>(&n);
    v.insert(v.end(), p, p + 4);
}

void put16(std::vector<uint8_t>& v, uint16_t x) {
    uint16_t n = htons(x);
    const uint8_t* p = reinterpret_cast<const uint8_t*>(&n);
    v.insert(v.end(), p, p + 2);
}

void putStr(std::vector<uint8_t>& v, const std::string& s) {
    v.insert(v.end(), s.begin(), s.end());
}

uint32_t get32(const uint8_t* p) { uint32_t n; memcpy(&n, p, 4); return ntohl(n); }
uint16_t get16(const uint8_t* p) { uint16_t n; memcpy(&n, p, 2); return ntohs(n); }

std::string getStr(const uint8_t* p, size_t len) {
    return std::string(reinterpret_cast<const char*>(p), len);
}

std::string getStr(const Packet& p) {
    if (p.body.empty()) return std::string();
    return getStr(p.body.data(), p.body.size());
}

std::vector<uint8_t> encode(uint32_t op, const std::vector<uint8_t>& body) {
    std::vector<uint8_t> out;
    out.reserve(kHeaderLen + body.size());
    put32(out, kHeaderLen + static_cast<uint32_t>(body.size()));
    put16(out, kHeaderLen);
    put16(out, kVersion);
    put32(out, op);
    put32(out, 0);
    out.insert(out.end(), body.begin(), body.end());
    return out;
}

SockServer::SockServer(std::string path) : path_(std::move(path)) {}

SockServer::~SockServer() {
    // First, before anything else: a thread that is still in run() polls
    // listen_fd_ and calls back into this object, so closing the fd or unlinking
    // the path under it would be a race at best.
    stopAndJoin();
    if (listen_fd_ >= 0) close(listen_fd_);
    // Only an instance that actually bound successfully removes the socket file, otherwise it would wrongly delete one someone else is using
    if (bound_ && !path_.empty()) unlink(path_.c_str());
}

void SockServer::registerHandler(uint32_t op, Handler h) {
    handlers_[op] = std::move(h);
}

void SockServer::start() {
    sockaddr_un addr{};
    if (path_.size() >= sizeof(addr.sun_path)) throw std::runtime_error("path too long");
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, path_.c_str(), path_.size() + 1);

    // First probe whether a live server already owns the path: if connect succeeds one exists, and
    // unlinking it would delete its socket file, leaving two servers with clients connecting by luck; only a failed connect means a stale file.
    // Everything the server opens is close-on-exec, and that matters here: the
    // exec service forks and execs on behalf of clients, so a spawned child would
    // otherwise inherit the server's listening and connection sockets. It could
    // accept() on them, and it would hold the listening socket open after the
    // server is gone. Fds received over SCM_RIGHTS are already CLOEXEC, from
    // MSG_CMSG_CLOEXEC on the receive side.
    int probe = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (probe >= 0) {
        bool alive = connect(probe, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0;
        close(probe);
        if (alive) throw std::runtime_error("already running on " + path_);
    }

    listen_fd_ = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (listen_fd_ < 0) throw std::runtime_error(std::string("socket: ") + strerror(errno));
    unlink(path_.c_str());  // clean up a leftover old socket file
    if (bind(listen_fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0 ||
        listen(listen_fd_, 16) < 0)
        throw std::runtime_error(std::string("bind/listen: ") + strerror(errno));
    bound_ = true;
    // The server is usually put in the background; the logger flushes stderr.
    Logger::GetInstance()->LogI("[server] listening on %s", path_.c_str());
}

void SockServer::run() {
    static constexpr size_t kMaxClients = 64;

    std::map<int, Conn> conns;

    while (running_) {
        // Ahead of poll(), so a derived class still gets its turn on a pass where
        // poll() only times out and no event is delivered at all.
        onTick();

        // Rebuilt from scratch every round rather than kept up to date: a
        // derived class watches and drops fds between rounds, and a pollfd left
        // over from a closed one is a use-after-free waiting to happen.
        std::vector<pollfd> fds;
        fds.push_back(pollfd{listen_fd_, POLLIN, 0});
        for (const auto& kv : conns) fds.push_back(pollfd{kv.first, POLLIN, 0});
        addPollFds(fds);

        int n = poll(fds.data(), fds.size(), 500);
        if (n < 0) { if (errno == EINTR) continue; break; }
        if (n == 0) continue;

        std::vector<int> to_close;
        for (size_t i = 0; i < fds.size(); ++i) {
            short revents = fds[i].revents;
            if (revents == 0) continue;
            int fd = fds[i].fd;

            if (fd == listen_fd_) {
                int c = accept4(listen_fd_, nullptr, nullptr, SOCK_CLOEXEC);
                if (c < 0) {
                    // A failed accept leaves the connection pending, so poll reports it
                    // again right away and the loop would spin at 100% CPU (EMFILE is the
                    // usual cause). Back off briefly instead of retrying immediately.
                    if (errno != EINTR) {
                        Logger::GetInstance()->LogE("[server] accept: %s", strerror(errno));
                        usleep(10 * 1000);
                    }
                } else if (conns.size() >= kMaxClients) {
                    // Without a cap, one client can exhaust the server's memory and fds.
                    Logger::GetInstance()->LogW("[server] too many clients, dropping connection");
                    close(c);
                } else {
                    // The peer credentials are taken once, here, and travel with the
                    // connection for as long as it lives; see Packet::caller.
                    conns[c].peer_pid = PeerPidOf(c);
                }
                continue;
            }

            auto it = conns.find(fd);
            if (it == conns.end()) {
                // Not a connection, so a derived class owns it.
                pollEvent(fd, revents);
                continue;
            }

            if (!(revents & (POLLIN | POLLHUP | POLLERR))) continue;
            uint8_t tmp[4096];
            std::vector<int> got;
            ssize_t r = recvWithFds(fd, tmp, sizeof tmp, got);
            if (r <= 0) {
                if (r < 0 && errno == EINTR) { closeFds(got); continue; }
                closeFds(got);
                to_close.push_back(fd);
                continue;
            }
            Conn& c = it->second;
            // Fds are attached to the first byte of the message, which starts at
            // this offset in the connection's byte stream.
            if (!got.empty()) c.fds[c.consumed + c.buf.size()] = std::move(got);
            c.buf.insert(c.buf.end(), tmp, tmp + r);
            if (!drain(fd, c)) to_close.push_back(fd);
        }

        for (int fd : to_close) {
            close(fd);
            auto it = conns.find(fd);
            if (it != conns.end()) {
                for (auto& kv : it->second.fds) closeFds(kv.second);
                conns.erase(it);
            }
        }
    }

    for (const auto& kv : conns) close(kv.first);
    for (auto& kv : conns)
        for (auto& pending : kv.second.fds) closeFds(pending.second);
}

void SockServer::stop() { running_ = 0; }

void SockServer::startThread() {
    // Assigning over a still-joinable thread would end the process, so a second
    // start while one is running is deliberately a no-op.
    if (thread_.joinable()) return;
    thread_ = std::thread([this] { run(); });
}

void SockServer::stopAndJoin() {
    stop();
    // join() rather than detach(): the loop has to be gone before the destructor
    // frees anything. It leaves thread_ non-joinable, which is what makes a second
    // call -- and a call on a server that never had a thread -- harmless. run()
    // wakes up on its own poll timeout at the latest, so this cannot hang.
    if (thread_.joinable()) thread_.join();
}

bool SockServer::drain(int fd, Conn& c) {
    while (c.buf.size() >= 4) {
        uint32_t total = get32(c.buf.data());
        // Use the length field for a basic check first, to avoid waiting for a packet that will never become complete
        if (total < kHeaderLen || total > kMaxPacketLen) {
            sendError(fd, "invalid packet length");
            return false;
        }
        if (c.buf.size() < total) break;  // partial packet, keep waiting

        Packet p;
        p.length = total;
        p.header_len = get16(&c.buf[4]);
        p.version = get16(&c.buf[6]);
        p.op = get32(&c.buf[8]);
        p.reserved = get32(&c.buf[12]);
        // Not from the wire: the caller is the peer of the connection this packet
        // arrived on, which the kernel told us when the connection was accepted.
        p.caller = static_cast<uint32_t>(c.peer_pid);
        const char* err = validate(p);
        if (err) { sendError(fd, err); return false; }
        p.body.assign(c.buf.begin() + p.header_len, c.buf.begin() + total);

        // Pick up the fds that were attached to this packet's first byte, if any.
        auto it = c.fds.find(c.consumed);
        if (it != c.fds.end()) {
            p.fds = std::move(it->second);
            c.fds.erase(it);
        }

        c.buf.erase(c.buf.begin(), c.buf.begin() + total);
        c.consumed += total;

        dispatch(fd, p);
        closeFds(p.fds);  // the handler owns what it dups; the rest is ours to close
    }
    return true;
}

const char* SockServer::validate(const Packet& p) {
    if (p.version != kVersion) return "unsupported version";
    if (p.header_len < kHeaderLen || p.header_len > p.length) return "invalid header length";
    return nullptr;
}

void SockServer::dispatch(int fd, const Packet& req) {
    auto it = handlers_.find(req.op);
    if (it == handlers_.end()) { sendError(fd, "unknown operation"); return; }

    Reply reply;
    if (!it->second(req, reply)) {
        sendError(fd, "handler failed");
        closeFds(reply.fds);
        return;
    }
    sendAll(fd, encode(req.op, reply.body), reply.fds);
    // The kernel has taken its own reference of every fd it accepted, so ours can go.
    closeFds(reply.fds);
}

void SockServer::sendError(int fd, const char* msg) {
    sendAll(fd, encode(kOpError, std::vector<uint8_t>(msg, msg + strlen(msg))), {});
}

void SockServer::sendAll(int fd, const std::vector<uint8_t>& d, const std::vector<int>& fds) {
    size_t off = 0;
    while (off < d.size()) {
        ssize_t w = (off == 0 && !fds.empty())
                        ? sendWithFds(fd, d.data(), d.size(), fds)
                        : send(fd, d.data() + off, d.size() - off, MSG_NOSIGNAL);
        if (w < 0) { if (errno == EINTR) continue; return; }
        // w == 0 should not happen on a stream socket; bail out rather than spin forever.
        if (w == 0) return;
        off += static_cast<size_t>(w);
    }
}

void SockServer::closeFds(std::vector<int>& fds) {
    for (int fd : fds)
        if (fd >= 0) close(fd);
    fds.clear();
}
