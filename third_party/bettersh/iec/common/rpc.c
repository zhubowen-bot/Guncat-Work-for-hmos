// common/rpc.c — request/reply helpers shared by both shims
//
// Moved here from tty/shim.c, where exec/shim.c had taken a copy of it. The
// three helpers below are the whole client side of the protocol: connect, send
// one packet, turn the reply into either bytes or an fd.
#include "rpc.h"

#include "sock_client.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

uint32_t iec_get32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

void iec_put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

/* Sends one request and returns 0, or -1 with errno set on failure. The reply
 * body is copied into out (at most out_max bytes) and its real length is left in
 * out_len when out_len is not NULL. Same as iec_rpc_call_fds() without fds. */
int iec_rpc_call(const char *path, uint32_t op, const void *body, uint32_t len,
                 void *out, uint32_t out_max, uint32_t *out_len) {
    return iec_rpc_call_fds(path, op, body, len, NULL, 0, out, out_max, out_len);
}

/* Sends one request, with nfds file descriptors of this process attached to it,
 * and returns 0 or -1 with errno set. The reply is handled as in
 * iec_rpc_call(). */
int iec_rpc_call_fds(const char *path, uint32_t op, const void *body, uint32_t len,
                     const int *fds, int nfds,
                     void *out, uint32_t out_max, uint32_t *out_len) {
    sock_client c;
    sock_reply r;
    int rc;

    if (sock_connect(&c, path) < 0) {
        fprintf(stderr, "[shim] connect %s failed: %s\n", path, strerror(errno));
        errno = EIO;
        return -1;
    }

    rc = sock_call_fds(&c, op, body, len, fds, nfds, &r);
    if (rc < 0) {
        fprintf(stderr, "[shim] op %u failed: %s\n", (unsigned)op, strerror(errno));
        sock_close(&c);
        errno = EIO;
        return -1;
    }
    if (rc > 0) {
        fprintf(stderr, "[shim] op %u: server error: %s\n", (unsigned)op,
                r.body ? (char *)r.body : "(no message)");
        sock_reply_free(&r);
        sock_close(&c);
        errno = EIO;
        return -1;
    }

    if (out_len) *out_len = r.len;
    if (out && r.len) {
        uint32_t n = r.len < out_max ? r.len : out_max;
        memcpy(out, r.body, n);
    }
    sock_reply_free(&r);
    sock_close(&c);
    return 0;
}

/* Same, for a reply that is one struct: a short answer would leave a
 * half-initialised struct behind, so the length has to match exactly. */
int iec_rpc_fixed(const char *path, uint32_t op, const uint8_t *req, uint32_t len,
                  void *out, uint32_t out_size) {
    uint32_t got = 0;

    if (iec_rpc_call(path, op, req, len, out, out_size, &got) < 0) return -1;
    if (got != out_size) {
        fprintf(stderr, "[shim] op %u: reply is %u bytes, expected %u\n",
                (unsigned)op, (unsigned)got, (unsigned)out_size);
        errno = EIO;
        return -1;
    }
    return 0;
}

/* Sends one request and returns the fd the server sent back (-1 on failure).
 * If out_word is not NULL it receives the first 4 body bytes as a big-endian
 * word (the pts number for OP_OPENPTMX). */
int iec_rpc_take_fd(const char *path, uint32_t op, const void *body, uint32_t len,
                    uint32_t *out_word) {
    sock_client c;
    sock_reply r;
    int rc, fd;

    if (sock_connect(&c, path) < 0) {
        fprintf(stderr, "[shim] connect %s failed: %s\n", path, strerror(errno));
        errno = EIO;
        return -1;
    }

    rc = sock_call(&c, op, body, len, &r);
    if (rc < 0) {
        fprintf(stderr, "[shim] op %u failed: %s\n", (unsigned)op, strerror(errno));
        sock_close(&c);
        errno = EIO;
        return -1;
    }
    if (rc > 0) {
        fprintf(stderr, "[shim] op %u: server error: %s\n", (unsigned)op,
                r.body ? (char *)r.body : "(no message)");
        sock_reply_free(&r);
        sock_close(&c);
        errno = EIO;
        return -1;
    }
    if (r.nfds < 1) {
        fprintf(stderr, "[shim] op %u: reply carried no fd\n", (unsigned)op);
        sock_reply_free(&r);
        sock_close(&c);
        errno = EIO;
        return -1;
    }

    if (out_word && r.body && r.len >= 4) *out_word = iec_get32(r.body);
    /* Take ownership: the reply must not close the fd we are about to return. */
    fd = sock_reply_take_fd(&r, 0);
    sock_reply_free(&r);
    sock_close(&c);
    return fd;
}
