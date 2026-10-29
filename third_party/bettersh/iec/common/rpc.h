// common/rpc.h — request/reply helpers shared by both shims
//
// The pty shim and the exec shim talk to their own service over their own Unix
// domain socket, but they do it exactly the same way: one request, one reply,
// optionally with a file descriptor attached to it. Only the socket path
// differs, so the path is a parameter here rather than a constant, and each
// shim wraps these with its own path (see tty/shim.c and exec/shim.c).
#ifndef IEC_RPC_H
#define IEC_RPC_H

#include <stdint.h>

/* Big-endian accessors for the fixed-width words inside a packet body. The wire
 * protocol numbers every multi-byte integer in network byte order, so these are
 * deliberately not memcpy/htons: the shim is not the only reader that has to
 * agree with the server about the byte order. */
uint32_t iec_get32(const uint8_t *p);
void     iec_put32(uint8_t *p, uint32_t v);

/* Sends one request to the service listening on path and returns 0, or -1 with
 * errno set on failure. The reply body is copied into out (at most out_max
 * bytes) and its real length is left in out_len when out_len is not NULL. */
int iec_rpc_call(const char *path, uint32_t op, const void *body, uint32_t len,
                 void *out, uint32_t out_max, uint32_t *out_len);

/* Same, but nfds file descriptors of the calling process are sent along with the
 * request (SCM_RIGHTS). The fds are not part of the body and the server receives
 * them in the order they are listed here, so it is up to the body to say what
 * each one is for. nfds == 0 behaves exactly like iec_rpc_call(). */
int iec_rpc_call_fds(const char *path, uint32_t op, const void *body, uint32_t len,
                     const int *fds, int nfds,
                     void *out, uint32_t out_max, uint32_t *out_len);

/* Same, for a reply that is one struct: a short answer would leave a
 * half-initialised struct behind, so the length has to match exactly. */
int iec_rpc_fixed(const char *path, uint32_t op, const uint8_t *req, uint32_t len,
                  void *out, uint32_t out_size);

/* Sends one request and returns the fd the server sent back, or -1 on failure.
 * If out_word is not NULL it receives the first 4 body bytes as a big-endian
 * word (the pts number for OP_OPENPTMX). Ownership of the returned fd passes to
 * the caller. */
int iec_rpc_take_fd(const char *path, uint32_t op, const void *body, uint32_t len,
                    uint32_t *out_word);

#endif /* IEC_RPC_H */
