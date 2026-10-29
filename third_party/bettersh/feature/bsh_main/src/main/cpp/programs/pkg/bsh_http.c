// bsh_http.c — pkg 用的最小 HTTPS 客户端（mbedTLS）
//
// 为什么是 mbedTLS：纯 C、零依赖、自带 X.509 与 TLS，交叉编译就是"编一堆 .c"，
// 跟本工程其它静态依赖（cairo/expat/…）一个路子；比 OpenSSL 小一个数量级。
// 源码在 thirdparty/mbedtls，由 programs/pkg/CMakeLists.txt 直接编进来（不另写构建脚本）。
//
// 信任锚内建（bsh_ca_pem.h）：沙箱里读不到系统 CA 目录。
//
// 只做一件事：把 https://…/x 取回来。无重定向、无代理、无续传。请求发 HTTP/1.0 ——
// 服务器会带 Content-Length 且发完就关连接，于是不必解析 chunked（少一条出错路径）。
#include "bsh_http.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/error.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"

#include "bsh_ca_pem.h"

#define BSH_HTTP_HDR_MAX 16384   /* 响应头缓冲；超了就当服务器不正常 */

static void err_set(char* err, size_t errlen, const char* fmt, ...)
{
    if (!err || errlen == 0)
        return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errlen, fmt, ap);
    va_end(ap);
}

int bsh_http_parse_url(const char* url, char* host, size_t hostlen,
                       char* port, size_t portlen, char* path, size_t pathlen)
{
    if (!url || strncmp(url, "https://", 8) != 0)
        return -1;
    const char* p = url + 8;
    const char* slash = strchr(p, '/');
    const char* hostend = slash ? slash : p + strlen(p);
    const char* colon = memchr(p, ':', (size_t)(hostend - p));

    size_t hl = colon ? (size_t)(colon - p) : (size_t)(hostend - p);
    if (hl == 0 || hl >= hostlen)
        return -1;
    memcpy(host, p, hl);
    host[hl] = 0;

    if (colon) {
        size_t pl = (size_t)(hostend - colon - 1);
        if (pl == 0 || pl >= portlen)
            return -1;
        memcpy(port, colon + 1, pl);
        port[pl] = 0;
    } else {
        snprintf(port, portlen, "443");
    }

    const char* pa = slash ? slash : "/";
    if (strlen(pa) >= pathlen)
        return -1;
    strcpy(path, pa);
    return 0;
}

/* 在响应头（长度 hdrlen，不含结束空行）里找一个字段，不区分大小写。 */
static int hdr_find(const char* hdr, size_t hdrlen, const char* name,
                    char* out, size_t outlen)
{
    size_t nl = strlen(name);
    size_t i = 0;
    while (i < hdrlen) {
        size_t e = i;
        while (e + 1 < hdrlen && !(hdr[e] == '\r' && hdr[e + 1] == '\n'))
            e++;
        size_t linelen = e - i;
        if (linelen > nl && strncasecmp(hdr + i, name, nl) == 0 && hdr[i + nl] == ':') {
            const char* v = hdr + i + nl + 1;
            size_t vl = linelen - nl - 1;
            while (vl && (*v == ' ' || *v == '\t')) { v++; vl--; }
            if (vl >= outlen)
                vl = outlen - 1;
            memcpy(out, v, vl);
            out[vl] = 0;
            return 0;
        }
        i = e + 2;
    }
    return -1;
}

/* 跟随重定向的最大跳数。够用且能挡住环形重定向。 */
#define BSH_HTTP_MAX_REDIRECT 5

static int http_get_depth(const char* url, bsh_http_write_fn fn, void* ctx,
                          char* err, size_t errlen, int depth);

int bsh_http_get(const char* url, bsh_http_write_fn fn, void* ctx,
                 char* err, size_t errlen)
{
    return http_get_depth(url, fn, ctx, err, errlen, 0);
}

static int http_get_depth(const char* url, bsh_http_write_fn fn, void* ctx,
                          char* err, size_t errlen, int depth)
{
    char host[256], port[16], path[1024];
    if (bsh_http_parse_url(url, host, sizeof host, port, sizeof port,
                           path, sizeof path) != 0) {
        err_set(err, errlen, "URL 不合法（只支持 https://host[:port]/path）：%s",
                url ? url : "(null)");
        return -1;
    }

    mbedtls_net_context net;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_x509_crt ca;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
    mbedtls_net_init(&net);
    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);
    mbedtls_x509_crt_init(&ca);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&drbg);

    int rc = -1;
    char* buf = NULL;

    if (mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy,
                              (const unsigned char*)"bsh-pkg", 7) != 0) {
        err_set(err, errlen, "随机数初始化失败");
        goto done;
    }
    if (mbedtls_x509_crt_parse(&ca, (const unsigned char*)kBshCaPem,
                               sizeof kBshCaPem) != 0) {
        err_set(err, errlen, "内建 CA 解析失败");
        goto done;
    }
    if (mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT,
                                    MBEDTLS_SSL_TRANSPORT_STREAM,
                                    MBEDTLS_SSL_PRESET_DEFAULT) != 0) {
        err_set(err, errlen, "TLS 配置初始化失败");
        goto done;
    }
    mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &drbg);
    mbedtls_ssl_conf_ca_chain(&conf, &ca, NULL);
    mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_REQUIRED);
    if (mbedtls_ssl_setup(&ssl, &conf) != 0) {
        err_set(err, errlen, "TLS 上下文初始化失败");
        goto done;
    }
    if (mbedtls_ssl_set_hostname(&ssl, host) != 0) {   /* SNI + 证书域名校验 */
        err_set(err, errlen, "SNI 设置失败");
        goto done;
    }

    if (mbedtls_net_connect(&net, host, port, MBEDTLS_NET_PROTO_TCP) != 0) {
        err_set(err, errlen, "连接 %s:%s 失败", host, port);
        goto done;
    }
    mbedtls_ssl_set_bio(&ssl, &net, mbedtls_net_send, mbedtls_net_recv, NULL);

    for (;;) {
        int hs = mbedtls_ssl_handshake(&ssl);
        if (hs == 0)
            break;
        if (hs != MBEDTLS_ERR_SSL_WANT_READ && hs != MBEDTLS_ERR_SSL_WANT_WRITE) {
            char e[128] = {0};
            mbedtls_strerror(hs, e, sizeof e);
            err_set(err, errlen, "TLS 握手失败：%s", e);
            goto done;
        }
    }
    {
        uint32_t vr = mbedtls_ssl_get_verify_result(&ssl);
        if (vr != 0) {                       /* REQUIRED 模式下握手已经拦了，这里只为说清原因 */
            char vbuf[256] = {0};
            mbedtls_x509_crt_verify_info(vbuf, sizeof vbuf, "  ", vr);
            err_set(err, errlen, "证书校验未通过：%s", vbuf);
            goto done;
        }
    }

    char req[1600];
    int rl = snprintf(req, sizeof req,
                      "GET %s HTTP/1.0\r\n"
                      "Host: %s\r\n"
                      "User-Agent: bsh-pkg/0.1\r\n"
                      "Accept: */*\r\n"
                      "Connection: close\r\n"
                      "\r\n",
                      path, host);
    if (rl <= 0 || rl >= (int)sizeof req) {
        err_set(err, errlen, "请求路径过长");
        goto done;
    }
    {
        size_t sent = 0;
        while (sent < (size_t)rl) {
            int w = mbedtls_ssl_write(&ssl, (const unsigned char*)req + sent,
                                      (size_t)rl - sent);
            if (w > 0) {
                sent += (size_t)w;
            } else if (w != MBEDTLS_ERR_SSL_WANT_READ && w != MBEDTLS_ERR_SSL_WANT_WRITE) {
                err_set(err, errlen, "发送请求失败");
                goto done;
            }
        }
    }

    /* 先收齐响应头（≤ BSH_HTTP_HDR_MAX），头后那段就是 body 开头 */
    buf = malloc(BSH_HTTP_HDR_MAX);
    if (!buf) {
        err_set(err, errlen, "内存不足");
        goto done;
    }
    size_t hn = 0, body_off = 0;
    for (;;) {
        if (hn + 1 >= BSH_HTTP_HDR_MAX) {
            err_set(err, errlen, "响应头过大（> %d 字节）", BSH_HTTP_HDR_MAX);
            goto done;
        }
        int r = mbedtls_ssl_read(&ssl, (unsigned char*)buf + hn, BSH_HTTP_HDR_MAX - hn - 1);
        if (r > 0) {
            hn += (size_t)r;
            buf[hn] = 0;
            char* end = strstr(buf, "\r\n\r\n");
            if (end) {
                body_off = (size_t)(end - buf) + 4;
                break;
            }
            continue;
        }
        if (r == 0) {
            err_set(err, errlen, "对端在响应头之前关闭了连接");
            goto done;
        }
        if (r != MBEDTLS_ERR_SSL_WANT_READ && r != MBEDTLS_ERR_SSL_WANT_WRITE) {
            err_set(err, errlen, "读取响应失败");
            goto done;
        }
    }

    int status = 0;
    if (sscanf(buf, "HTTP/%*d.%*d %d", &status) != 1) {
        err_set(err, errlen, "响应不是合法 HTTP");
        goto done;
    }
    /* 3xx 跟随。微软的 update.code.visualstudio.com 就是先回 302 再指到 CDN，
     * 不跟就只能拿到一个空的响应头。Location 可能是绝对 URL，也可能是
     * 相对于当前主机（以 / 开头）或相对当前目录的路径。 */
    if (status >= 300 && status < 400) {
        char loc[1024] = {0};
        if (depth >= BSH_HTTP_MAX_REDIRECT) {
            err_set(err, errlen, "重定向超过 %d 次（可能成环）", BSH_HTTP_MAX_REDIRECT);
            goto done;
        }
        if (hdr_find(buf, body_off - 4, "Location", loc, sizeof loc) != 0 || !loc[0]) {
            err_set(err, errlen, "服务器返回 %d 但没有可用的 Location", status);
            goto done;
        }
        char next[1400];
        if (strncmp(loc, "http://", 7) == 0 || strncmp(loc, "https://", 8) == 0) {
            snprintf(next, sizeof next, "%s", loc);
        } else if (loc[0] == '/') {
            snprintf(next, sizeof next, "https://%s%s", host, loc);
        } else {
            char dir[1024];
            snprintf(dir, sizeof dir, "%s", path);
            char* sl = strrchr(dir, '/');
            if (sl) sl[1] = 0;
            else snprintf(dir, sizeof dir, "/");
            snprintf(next, sizeof next, "https://%s%s%s", host, dir, loc);
        }
        mbedtls_ssl_close_notify(&ssl);
        rc = http_get_depth(next, fn, ctx, err, errlen, depth + 1);
        goto done;
    }
    if (status != 200) {
        err_set(err, errlen, "服务器返回 %d", status);
        goto done;
    }

    char clbuf[32] = {0};
    long clen = -1;
    if (hdr_find(buf, body_off - 4, "Content-Length", clbuf, sizeof clbuf) == 0)
        clen = strtol(clbuf, NULL, 10);

    size_t got = hn - body_off;
    if (got && fn && fn(ctx, (const unsigned char*)buf + body_off, got) != 0) {
        err_set(err, errlen, "写入失败");
        goto done;
    }
    {
        unsigned char chunk[16384];
        for (;;) {
            int r = mbedtls_ssl_read(&ssl, chunk, sizeof chunk);
            if (r > 0) {
                got += (size_t)r;
                if (fn && fn(ctx, chunk, (size_t)r) != 0) {
                    err_set(err, errlen, "写入失败");
                    goto done;
                }
                continue;
            }
            if (r == 0 || r == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)
                break;                       /* 对端关闭：正常收尾 */
            if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE)
                continue;
            err_set(err, errlen, "接收响应体失败");
            goto done;
        }
    }
    if (clen >= 0 && got != (size_t)clen) {
        err_set(err, errlen, "响应体长度不符：期望 %ld，收到 %zu", clen, got);
        goto done;
    }

    mbedtls_ssl_close_notify(&ssl);
    rc = 0;

done:
    free(buf);
    mbedtls_net_free(&net);
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    mbedtls_x509_crt_free(&ca);
    mbedtls_ctr_drbg_free(&drbg);
    mbedtls_entropy_free(&entropy);
    return rc;
}

/* ── 两个便捷封装 ────────────────────────────────────────── */

struct membuf { char* p; size_t len; size_t cap; };

static int mem_write(void* ctx, const unsigned char* b, size_t n)
{
    struct membuf* m = ctx;
    if (m->len + n + 1 > m->cap) {
        size_t cap = m->cap ? m->cap : 8192;
        while (cap < m->len + n + 1)
            cap *= 2;
        char* np = realloc(m->p, cap);
        if (!np)
            return -1;
        m->p = np;
        m->cap = cap;
    }
    memcpy(m->p + m->len, b, n);
    m->len += n;
    m->p[m->len] = 0;
    return 0;
}

int bsh_http_get_mem(const char* url, char** out, size_t* outlen,
                     char* err, size_t errlen)
{
    struct membuf m = {0};
    if (bsh_http_get(url, mem_write, &m, err, errlen) != 0) {
        free(m.p);
        return -1;
    }
    if (!m.p) {
        m.p = strdup("");
        if (!m.p)
            return -1;
        m.len = 0;
    }
    *out = m.p;
    if (outlen)
        *outlen = m.len;
    return 0;
}

struct filectx { FILE* f; int bad; };

static int file_write(void* ctx, const unsigned char* b, size_t n)
{
    struct filectx* fc = ctx;
    if (fwrite(b, 1, n, fc->f) != n) {
        fc->bad = 1;
        return -1;
    }
    return 0;
}

int bsh_http_get_file(const char* url, const char* path,
                      char* err, size_t errlen)
{
    char tmp[1200];
    if (snprintf(tmp, sizeof tmp, "%s.part", path) >= (int)sizeof tmp) {
        err_set(err, errlen, "路径过长");
        return -1;
    }
    FILE* f = fopen(tmp, "wb");
    if (!f) {
        err_set(err, errlen, "打不开 %s：%s", tmp, strerror(errno));
        return -1;
    }
    struct filectx fc = { f, 0 };
    int rc = bsh_http_get(url, file_write, &fc, err, errlen);
    if (fclose(f) != 0)
        fc.bad = 1;
    if (rc != 0 || fc.bad) {
        unlink(tmp);
        if (rc == 0)
            err_set(err, errlen, "写文件失败");
        return -1;
    }
    if (rename(tmp, path) != 0) {
        err_set(err, errlen, "重命名 %s 失败：%s", path, strerror(errno));
        unlink(tmp);
        return -1;
    }
    return 0;
}
