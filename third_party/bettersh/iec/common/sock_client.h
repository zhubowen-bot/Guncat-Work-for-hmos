// common/sock_client.h UDS client library: connect, encode, send/receive.
// Business clients embed a sock_client in their own struct to reuse it.
//
// Replies may carry file descriptors (SCM_RIGHTS); they land in sock_reply::fds.
#ifndef SOCK_CLIENT_H
#define SOCK_CLIENT_H
#include <stdint.h>

#define SOCK_HDR_LEN   16
#define SOCK_VERSION   1
#define SOCK_OP_ERROR  0xFFFFFFFFu

/* Maximum fds a single reply may carry. */
#define SOCK_MAX_FDS   8

typedef struct {
    int      fd;
    uint16_t version;       /* protocol version used when sending; SOCK_VERSION by default, change it to test bad packets */
} sock_client;

typedef struct {
    uint32_t op;
    uint32_t len;
    uint8_t *body;          /* NUL-terminated; the caller releases it with sock_reply_free */
    int      fds[SOCK_MAX_FDS];  /* fds received with this reply; -1 means the slot is empty */
    int      nfds;
} sock_reply;

/* Returns 0 on success, -1 on a communication/system error. */
int  sock_connect(sock_client *c, const char *path);

/* Sends a request and waits for the reply.
 * Returns 0 on success, 1 if the server answered with an error packet
 * (out->body holds the error text), -1 on a communication error.
 * Same as sock_call_fds() with no fds attached. */
int  sock_call(sock_client *c, uint32_t op, const void *body, uint32_t len, sock_reply *out);

/* Same, but sends nfds file descriptors of this process along with the request
 * (SCM_RIGHTS). Only the first SOCK_MAX_FDS are sent; the rest are ignored.
 * The fds themselves are not part of the body: they arrive on the server side in
 * the same order, and it is the body that says what each one is for. Passing 0
 * fds makes this behave exactly like sock_call(). */
int  sock_call_fds(sock_client *c, uint32_t op, const void *body, uint32_t len,
                   const int *fds, int nfds, sock_reply *out);

/* Detaches fds[i] from the reply so sock_reply_free will not close it.
 * Returns the fd, or -1 if the index is out of range or already taken. */
int  sock_reply_take_fd(sock_reply *r, int i);

/* Frees the body and closes every fd still held by the reply. */
void sock_reply_free(sock_reply *r);

void sock_close(sock_client *c);
#endif /* SOCK_CLIENT_H */
