// common/sock_server.h - 
//
// Protocol (all multi-byte integers are in network byte order/big endian):
//     [0-3] Total packet length (including header)
//     [4-5] Header length (currently 16)
//     [6-7] Protocol version
//     [8-11] Operation type
//     [12-15] Reserved
//     [16..] Packet content
//
// File descriptors travel out of band: they are attached with SCM_RIGHTS to the
// same message as the bytes of one packet, and are not counted in any length.
// A message carrying fds must therefore contain exactly one whole packet.
//
// Declarations only; the definitions live in common/sock_server.cpp.
#pragma once

#include <poll.h>

#include <cstddef>
#include <csignal>
#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <thread>
#include <vector>

constexpr uint32_t kHeaderLen = 16;
constexpr uint16_t kVersion = 1;
constexpr uint32_t kMaxPacketLen = 1u << 20;
constexpr uint32_t kOpError = 0xFFFFFFFF;
// Caps both the SCM_RIGHTS payload of one message and Reply::fds.
constexpr int kMaxFds = 8;

struct Packet {
    uint32_t length = 0;      // Total length
    uint16_t header_len = 0;
    uint16_t version = 0;
    uint32_t op = 0;
    uint32_t reserved = 0;
    uint32_t caller = 0;
    std::vector<uint8_t> body;  // Content
    // Fds that arrived with this packet. The framework owns them and closes them
    // as soon as the handler returns, so dup any you want to keep.
    std::vector<int> fds;
};

// What a handler answers with. The framework sends body as the packet body and
// fds over SCM_RIGHTS, then closes every fd listed here.
struct Reply {
    std::vector<uint8_t> body;
    std::vector<int> fds;
};

void put32(std::vector<uint8_t>& v, uint32_t x);
void put16(std::vector<uint8_t>& v, uint16_t x);
// The body boundary is given by length in the packet header, so no length prefix is added here:
// the raw bytes are appended as-is. sendError's error text and OP_PING's echo follow this rule, and the client appends '\0' itself on receipt.
void putStr(std::vector<uint8_t>& v, const std::string& s);
uint32_t get32(const uint8_t* p);
uint16_t get16(const uint8_t* p);
std::string getStr(const uint8_t* p, size_t len);
// Convenience overload: use the whole packet body as a string
std::string getStr(const Packet& p);

std::vector<uint8_t> encode(uint32_t op, const std::vector<uint8_t>& body);

class SockServer {
public:
    // Handler: read req and fill in reply; returning false means the handler failed (an error packet is sent back)
    using Handler = std::function<bool(const Packet& req, Reply& reply)>;

    explicit SockServer(std::string path);
    virtual ~SockServer();
    SockServer(const SockServer&) = delete;
    SockServer& operator=(const SockServer&) = delete;

    // Called by derived classes: register a handler for an operation type
    void registerHandler(uint32_t op, Handler h);

    // Create the socket and start listening
    void start();

    // Single-threaded poll event loop, until stop()
    void run();

    // Only sets the stop flag, so it is the one call that is safe from a signal
    // handler; see stopAndJoin() for the blocking counterpart.
    void stop();

    // Runs run() on a thread of its own and returns at once. start() must have
    // been called first, so the socket is already bound and listening. The thread
    // is reaped by stopAndJoin() or by the destructor.
    //
    // A word of warning for derived classes: the derived destructor runs *before*
    // the base one, and until the thread is joined it is still inside run(),
    // reaching that half-destroyed derived object through the virtual
    // addPollFds()/pollEvent() hooks. A derived class that owns an fd run() polls
    // (a pty end, say) and releases it in its own destructor therefore has to call
    // stopAndJoin() as the first thing that destructor does. The call made in
    // ~SockServer() comes too late to save it.
    void startThread();

    // Asks the loop to stop (same flag as stop()) and joins the thread. Safe to
    // call more than once, and safe on a server whose thread was never started.
    void stopAndJoin();

protected:
    // Fds a derived class owns (the pty pairs, for the tty server). run()
    // rebuilds the whole poll set every round and only knows about the listen
    // socket and the client connections, so anything that has to be watched
    // must be appended again on every call.
    virtual void addPollFds(std::vector<pollfd>& fds) { (void)fds; }

    // Called once per pass of the event loop, before it blocks in poll(). A derived
    // class uses it for work that must happen even when nothing arrives, which is
    // what pollEvent() cannot cover: poll() timing out wakes nobody.
    virtual void onTick() {}

    // Called for a ready fd that is neither the listen socket nor a client
    // connection, i.e. one added by addPollFds.
    virtual void pollEvent(int fd, short revents) { (void)fd; (void)revents; }

private:
    // Per-connection receive state.
    struct Conn {
        std::vector<uint8_t> buf;
        // Absolute stream offset of buf.front(), i.e. how many bytes this
        // connection has already consumed.
        uint64_t consumed = 0;
        // Fds that arrived but whose packet is not complete yet, keyed by the
        // absolute stream offset they were attached to.
        std::map<uint64_t, std::vector<int>> fds;
        // The peer pid read when this connection was accepted. Fixed for the life of
        // the connection, so it is stamped on every packet that arrives on it; see
        // PeerPidOf().
        int peer_pid = 0;
    };

    // Extract all complete packets from the buffer and dispatch them; returning false means the connection should be closed
    bool drain(int fd, Conn& c);

    static const char* validate(const Packet& p);

    void dispatch(int fd, const Packet& req);

    void sendError(int fd, const char* msg);

    static void sendAll(int fd, const std::vector<uint8_t>& d, const std::vector<int>& fds);

    static void closeFds(std::vector<int>& fds);

    std::string path_;
    int listen_fd_ = -1;
    bool bound_ = false;   // whether bind succeeded (decides whether to remove the socket file on destruction)
    // Read and written by the signal handler, so use sig_atomic_t rather than std::atomic
    volatile sig_atomic_t running_ = 1;
    // Only ever touched by the calling thread; empty until startThread() runs and
    // after stopAndJoin() has joined it, which is what makes the latter idempotent.
    std::thread thread_;
    std::map<uint32_t, Handler> handlers_;
};
