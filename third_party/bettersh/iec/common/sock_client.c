// common/sock_client.c
#include "sock_client.h"

#include <arpa/inet.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int read_full(int fd, void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t r = read(fd, (char *)buf + off, n - off);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        off += (size_t)r;
    }
    return 0;
}

static int write_full(int fd, const void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, (const char *)buf + off, n - off);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        off += (size_t)w;
    }
    return 0;
}

/* Pulls any SCM_RIGHTS payload out of a received message into the reply. */
static void collect_fds(struct msghdr *msg, sock_reply *out) {
    for (struct cmsghdr *cm = CMSG_FIRSTHDR(msg); cm != NULL; cm = CMSG_NXTHDR(msg, cm)) {
        if (cm->cmsg_level != SOL_SOCKET || cm->cmsg_type != SCM_RIGHTS) continue;
        if (cm->cmsg_len < CMSG_LEN(0)) continue;
        size_t n = (cm->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        const int *received = (const int *)CMSG_DATA(cm);
        for (size_t i = 0; i < n; i++) {
            if (out->nfds < SOCK_MAX_FDS) {
                out->fds[out->nfds++] = received[i];
            } else {
                /* No room left: close it rather than leak it. */
                close(received[i]);
            }
        }
    }
}

/* Reads the 16-byte reply header. This has to use recvmsg, because any fds the
 * server sends travel attached to the first byte of the reply. */
static int recv_header(int fd, uint8_t *h, sock_reply *out) {
    size_t got = 0;
    while (got < SOCK_HDR_LEN) {
        struct iovec iov;
        struct msghdr msg;
        char cbuf[CMSG_SPACE(sizeof(int) * SOCK_MAX_FDS)];

        memset(&msg, 0, sizeof msg);
        iov.iov_base = h + got;
        iov.iov_len = SOCK_HDR_LEN - got;
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cbuf;
        msg.msg_controllen = sizeof cbuf;

#ifdef MSG_CMSG_CLOEXEC
        ssize_t r = recvmsg(fd, &msg, MSG_CMSG_CLOEXEC);
#else
        ssize_t r = recvmsg(fd, &msg, 0);
#endif
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        collect_fds(&msg, out);
        got += (size_t)r;
    }
    return 0;
}

void sock_reply_free(sock_reply *r) {
    int i;
    if (!r) return;
    free(r->body);
    r->body = NULL;
    for (i = 0; i < r->nfds; i++) {
        if (r->fds[i] >= 0) close(r->fds[i]);
        r->fds[i] = -1;
    }
    r->nfds = 0;
}

int sock_reply_take_fd(sock_reply *r, int i) {
    int fd;
    if (!r || i < 0 || i >= r->nfds) return -1;
    fd = r->fds[i];
    r->fds[i] = -1;
    return fd;
}

int sock_connect(sock_client *c, const char *path) {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof addr.sun_path) return -1;
    strcpy(addr.sun_path, path);

    c->version = SOCK_VERSION;
    c->fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (c->fd < 0) return -1;
    if (connect(c->fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        close(c->fd);
        c->fd = -1;
        return -1;
    }
    return 0;
}

/* Hands the first bytes of the packet to sendmsg() with the fds riding along in
 * an SCM_RIGHTS control message. Returns the number of bytes written, or -1.
 *
 * A stream socket only carries fds on a message that also carries data, which is
 * why this is only ever used for the first send of a packet: every later send
 * would attach a second copy of the same descriptors, and the server would
 * receive the packet several times over. MSG_NOSIGNAL because the server may
 * have died since the previous call, and SIGPIPE would kill the client instead
 * of returning EPIPE for the caller to see. */
static ssize_t send_first_with_fds(int fd, const void *data, size_t len,
                                   const int *fds, int nfds) {
    struct msghdr msg;
    struct iovec iov;
    char cbuf[CMSG_SPACE(sizeof(int) * SOCK_MAX_FDS)];
    struct cmsghdr *cm;
    ssize_t w;

    if (nfds > SOCK_MAX_FDS) nfds = SOCK_MAX_FDS;

    memset(&msg, 0, sizeof msg);
    iov.iov_base = (void *)data;
    iov.iov_len = len;
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cbuf;
    msg.msg_controllen = CMSG_SPACE(sizeof(int) * (size_t)nfds);

    cm = CMSG_FIRSTHDR(&msg);
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type = SCM_RIGHTS;
    cm->cmsg_len = CMSG_LEN(sizeof(int) * (size_t)nfds);
    memcpy(CMSG_DATA(cm), fds, sizeof(int) * (size_t)nfds);

    do {
        w = sendmsg(fd, &msg, MSG_NOSIGNAL);
    } while (w < 0 && errno == EINTR);
    return w;
}

/* Sends the packet. With nfds == 0 this is a plain write; with fds attached the
 * first chunk goes out through sendmsg() and only what sendmsg() did not take is
 * left for write_full(), so the descriptors are attached exactly once. */
static int send_packet(int fd, const uint8_t *pkt, size_t len,
                       const int *fds, int nfds) {
    size_t sent = 0;

    if (nfds > 0 && fds) {
        ssize_t w = send_first_with_fds(fd, pkt, len, fds, nfds);
        if (w <= 0) return -1;   /* w == 0 would mean the fds went nowhere useful */
        sent = (size_t)w;
    }
    return write_full(fd, pkt + sent, len - sent);
}

int sock_call(sock_client *c, uint32_t op, const void *body, uint32_t len, sock_reply *out) {
    return sock_call_fds(c, op, body, len, NULL, 0, out);
}

int sock_call_fds(sock_client *c, uint32_t op, const void *body, uint32_t len,
                  const int *fds, int nfds, sock_reply *out) {
    uint8_t *pkt;
    uint32_t total = htonl(SOCK_HDR_LEN + len);
    uint16_t hl = htons(SOCK_HDR_LEN), ver = htons(c->version);
    uint32_t o = htonl(op), rsv = 0;
    uint8_t h[SOCK_HDR_LEN];
    uint32_t rtotal, rop, blen;
    uint16_t rhl;

    if (!out) return -1;
    out->op = 0;
    out->len = 0;
    out->body = NULL;
    out->nfds = 0;
    memset(out->fds, 0xff, sizeof out->fds);

    /* --- send --- */
    pkt = malloc(SOCK_HDR_LEN + (len ? len : 1));
    if (!pkt) return -1;
    memcpy(pkt, &total, 4);
    memcpy(pkt + 4, &hl, 2);
    memcpy(pkt + 6, &ver, 2);
    memcpy(pkt + 8, &o, 4);
    memcpy(pkt + 12, &rsv, 4);
    if (len && body) memcpy(pkt + SOCK_HDR_LEN, body, len);
    if (send_packet(c->fd, pkt, SOCK_HDR_LEN + len, fds, nfds) < 0) {
        free(pkt);
        return -1;
    }
    free(pkt);

    /* --- receive --- */
    if (recv_header(c->fd, h, out) < 0) {
        sock_reply_free(out);
        return -1;
    }
    memcpy(&rtotal, h, 4);   rtotal = ntohl(rtotal);
    memcpy(&rhl, h + 4, 2);  rhl = ntohs(rhl);
    memcpy(&rop, h + 8, 4);  rop = ntohl(rop);
    if (rhl < SOCK_HDR_LEN || rtotal < rhl || rtotal > (1u << 20)) {
        sock_reply_free(out);
        return -1;
    }

    /* Skip any extended header the server may have added. */
    for (uint32_t left = rhl - SOCK_HDR_LEN; left > 0;) {
        uint8_t skip[64];
        uint32_t n = left < sizeof skip ? left : (uint32_t)sizeof skip;
        if (read_full(c->fd, skip, n) < 0) {
            sock_reply_free(out);
            return -1;
        }
        left -= n;
    }

    blen = rtotal - rhl;
    out->body = malloc(blen + 1);
    if (!out->body) {
        sock_reply_free(out);
        return -1;
    }
    if (blen && read_full(c->fd, out->body, blen) < 0) {
        sock_reply_free(out);
        return -1;
    }
    out->body[blen] = '\0';
    out->len = blen;
    out->op = rop;
    return rop == SOCK_OP_ERROR ? 1 : 0;
}

void sock_close(sock_client *c) {
    if (c->fd >= 0) close(c->fd);
    c->fd = -1;
}
