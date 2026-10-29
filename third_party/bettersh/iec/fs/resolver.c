#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "resolver.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define SUFFIX            IEC_SYMLINK_SUFFIX
#define SUFFIX_LEN        (sizeof(SUFFIX) - 1)
#define DEFAULT_MAX_LINKS 40
#define WORK_MAX          (PATH_MAX * 2)

enum kind { K_NONE = 0, K_DIR, K_FILE };

typedef struct {
    int              max_links;
    const iec_map_t *maps;
    size_t           nmaps;
    char             cwd[PATH_MAX];
    int              cwd_logical;   /* 1 means cwd came from opts and participates in mapping */
    char            *errmsg;
    size_t           errmsg_size;
} ctx_t;

/* ------------------------------------------------------------------ */
/* Utility functions                                                   */
/* ------------------------------------------------------------------ */

static int fail(const ctx_t *c, int err, const char *fmt, ...)
{
    if (c->errmsg && c->errmsg_size) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(c->errmsg, c->errmsg_size, fmt, ap);
        va_end(ap);
    }
    return -err;
}

static enum kind probe(const char *p)
{
    struct stat st;
    if (stat(p, &st) != 0)
        return K_NONE;              /* Missing or no permission; cannot distinguish */
    return S_ISDIR(st.st_mode) ? K_DIR : K_FILE;
}

static int has_suffix(const char *s, size_t len)
{
    return len >= SUFFIX_LEN &&
           memcmp(s + len - SUFFIX_LEN, SUFFIX, SUFFIX_LEN) == 0;
}

static int copy_out(const ctx_t *c, const char *s, char *out, size_t out_size)
{
    size_t n = strlen(s);
    if (n + 1 > out_size)
        return fail(c, ERANGE, "输出缓冲区太小，需要 %zu 字节", n + 1);
    memcpy(out, s, n + 1);
    return 0;
}

/* Length after trimming trailing '/'; "/" yields 0 */
static size_t trim_len(const char *s)
{
    size_t n = strlen(s);
    while (n > 0 && s[n - 1] == '/')
        n--;
    return n;
}

static int read_link(const ctx_t *c, const char *file, char *buf, size_t bufsz)
{
    int fd = open(file, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        int e = errno;
        return fail(c, e, "无法打开链接文件 %s: %s", file, strerror(e));
    }
    size_t n = 0;
    while (n < bufsz - 1) {
        ssize_t r = read(fd, buf + n, bufsz - 1 - n);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            int e = errno;
            close(fd);
            return fail(c, e, "读取链接文件 %s 失败: %s", file, strerror(e));
        }
        if (r == 0)
            break;
        n += (size_t)r;
    }
    close(fd);
    buf[n] = '\0';

    char *s = buf;
    if (n >= 3 && (unsigned char)s[0] == 0xEF &&
        (unsigned char)s[1] == 0xBB && (unsigned char)s[2] == 0xBF)
        s += 3;
    while (*s && isspace((unsigned char)*s))
        s++;
    s[strcspn(s, "\r\n")] = '\0';
    char *e = s + strlen(s);
    while (e > s && isspace((unsigned char)e[-1]))
        e--;
    *e = '\0';

    if (*s == '\0')
        return fail(c, EINVAL, "链接文件内容为空: %s", file);
    memmove(buf, s, (size_t)(e - s) + 1);
    return 0;
}

/* Normalize: merge '/', drop '.', keep '..' */
static int normalize(const ctx_t *c, const char *in, char *out, size_t outsz,
                     int *has_dotdot, int *has_sfx)
{
    size_t o = 0;
    const char *p = in;

    *has_dotdot = *has_sfx = 0;
    out[o++] = '/';
    while (*p) {
        while (*p == '/')
            p++;
        if (!*p)
            break;
        const char *s = p;
        while (*p && *p != '/')
            p++;
        size_t len = (size_t)(p - s);

        if (len == 1 && s[0] == '.')
            continue;
        if (len == 2 && s[0] == '.' && s[1] == '.')
            *has_dotdot = 1;
        else if (has_suffix(s, len))
            *has_sfx = 1;

        if (o + (o > 1) + len + 1 > outsz)
            return fail(c, ENAMETOOLONG, "路径过长: %s", in);
        if (o > 1)
            out[o++] = '/';
        memcpy(out + o, s, len);
        o += len;
    }
    out[o] = '\0';
    return 0;
}

/* ------------------------------------------------------------------ */
/* Directory mapping: longest prefix, whole-component match, applied once */
/* in must be a normalized absolute path                               */
/* ------------------------------------------------------------------ */

static int apply_map(const ctx_t *c, const char *in, char *out, size_t outsz)
{
    const iec_map_t *best = NULL;
    size_t best_len = 0;

    for (size_t i = 0; i < c->nmaps; i++) {
        const char *f = c->maps[i].from;
        size_t fl = trim_len(f);          /* "/" has length 0 and matches any path */
        if (strncmp(in, f, fl) == 0 && (in[fl] == '\0' || in[fl] == '/') &&
            (!best || fl > best_len)) {
            best = &c->maps[i];
            best_len = fl;
        }
    }

    int n;
    if (!best) {
        n = snprintf(out, outsz, "%s", in);
    } else {
        size_t tl = trim_len(best->to);
        n = snprintf(out, outsz, "%.*s%s", (int)tl, best->to, in + best_len);
    }
    if (n < 0 || (size_t)n >= outsz)
        return fail(c, ENAMETOOLONG, "映射后路径过长: %s", in);
    if (out[0] == '\0') {                 /* e.g. "/x" maps to "/" */
        out[0] = '/';
        out[1] = '\0';
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Core resolution                                                     */
/* do_map: whether to map the entry path abs                           */
/* Absolute targets of pseudo-links are always mapped                  */
/* ------------------------------------------------------------------ */

static int resolve_abs(const ctx_t *c, const char *abs, int do_map,
                       char *out, size_t out_size)
{
    char rest[WORK_MAX];
    char tmp[WORK_MAX];
    char m[WORK_MAX];
    char res[PATH_MAX];
    char target[PATH_MAX];
    char first_opaque[PATH_MAX];
    int  dotdot, sfx, rc, n, links = 0;

    first_opaque[0] = '\0';

    rc = normalize(c, abs, tmp, sizeof tmp, &dotdot, &sfx);
    if (rc)
        return rc;
    if (do_map) {
        rc = apply_map(c, tmp, m, sizeof m);
        if (rc)
            return rc;
    } else {
        memcpy(m, tmp, strlen(tmp) + 1);
    }
    rc = normalize(c, m, rest, sizeof rest, &dotdot, &sfx);
    if (rc)
        return rc;

    /* Fast path */
    if (!dotdot && !sfx && strlen(rest) < PATH_MAX && probe(rest) != K_NONE)
        return copy_out(c, rest, out, out_size);

    size_t rlen = 1;
    res[0] = '/';
    res[1] = '\0';

    const char *p = rest;
    for (;;) {
        while (*p == '/')
            p++;
        if (!*p)
            break;
        const char *s = p;
        while (*p && *p != '/')
            p++;
        size_t len = (size_t)(p - s);

        if (len == 1 && s[0] == '.')
            continue;
        if (len == 2 && s[0] == '.' && s[1] == '.') {
            while (rlen > 1 && res[rlen - 1] != '/')
                rlen--;
            if (rlen > 1)
                rlen--;
            res[rlen] = '\0';
            continue;
        }

        size_t save = rlen;
        if (rlen + 1 + len + SUFFIX_LEN + 1 > sizeof res)
            return fail(c, ENAMETOOLONG, "路径过长: %s", abs);
        if (rlen > 1)
            res[rlen++] = '/';
        memcpy(res + rlen, s, len);
        rlen += len;
        res[rlen] = '\0';

        const char *q = p;
        while (*q == '/')
            q++;
        int more = (*q != '\0');

        enum kind k = probe(res);
        if (k == K_FILE && has_suffix(s, len)) {
            /* Case 1: the link file was given explicitly */
        } else if (k != K_NONE) {
            /* Case 2: real component */
            if (k == K_FILE && more)
                return fail(c, ENOTDIR, "不是目录: %s", res);
            continue;
        } else {
            memcpy(res + rlen, SUFFIX, SUFFIX_LEN + 1);
            if (probe(res) != K_FILE) {
                /* Case 4: opaque directory */
                res[rlen] = '\0';
                if (!first_opaque[0])
                    memcpy(first_opaque, res, rlen + 1);
                continue;
            }
            /* Case 3: pseudo-link */
        }

        if (++links > c->max_links)
            return fail(c, ELOOP, "链接层数过多（可能存在循环）: %s", abs);
        rc = read_link(c, res, target, sizeof target);
        if (rc)
            return rc;

        rlen = save;
        res[rlen] = '\0';

        if (target[0] == '/') {
            /* Absolute target: belongs to the logical path space; map first, then resolve from the root */
            rlen = 1;
            res[1] = '\0';
            rc = normalize(c, target, m, sizeof m, &dotdot, &sfx);
            if (rc)
                return rc;
            rc = apply_map(c, m, tmp, sizeof tmp);
            if (rc)
                return rc;
            n = snprintf(m, sizeof m, "%s/%s", tmp, p);
        } else {
            /* Relative target: relative to the physical directory containing the link; not mapped */
            n = snprintf(m, sizeof m, "%s/%s", target, p);
        }
        if (n < 0 || (size_t)n >= sizeof m)
            return fail(c, ENAMETOOLONG, "展开链接后路径过长: %s", abs);
        memcpy(rest, m, (size_t)n + 1);
        p = rest;
    }

    if (probe(res) == K_NONE) {
        if (first_opaque[0])
            return fail(c, ENOENT,
                        "路径不存在: %s -> %s（%s 被假定为不可直接访问的目录）",
                        abs, res, first_opaque);
        return fail(c, ENOENT, "路径不存在: %s -> %s", abs, res);
    }
    return copy_out(c, res, out, out_size);
}

/* ------------------------------------------------------------------ */
/* Context and command lookup                                          */
/* ------------------------------------------------------------------ */

static int init_ctx(ctx_t *c, const iec_opts_t *opts)
{
    memset(c, 0, sizeof *c);
    c->max_links = (opts && opts->max_links > 0) ? opts->max_links
                                                  : DEFAULT_MAX_LINKS;
    if (opts) {
        c->errmsg      = opts->errmsg;
        c->errmsg_size = opts->errmsg_size;
        c->maps        = opts->maps;
        c->nmaps       = opts->nmaps;
    }
    if (c->errmsg && c->errmsg_size)
        c->errmsg[0] = '\0';

    if (c->nmaps && !c->maps)
        return fail(c, EINVAL, "maps 为 NULL 但 nmaps=%zu", c->nmaps);
    for (size_t i = 0; i < c->nmaps; i++) {
        const iec_map_t *mp = &c->maps[i];
        if (!mp->from || !mp->to || mp->from[0] != '/' || mp->to[0] != '/')
            return fail(c, EINVAL, "第 %zu 条映射非法（必须是绝对路径）", i);
    }

    if (opts && opts->cwd) {
        if (opts->cwd[0] != '/')
            return fail(c, EINVAL, "cwd 必须是绝对路径: %s", opts->cwd);
        if (strlen(opts->cwd) >= sizeof c->cwd)
            return fail(c, ENAMETOOLONG, "cwd 过长");
        strcpy(c->cwd, opts->cwd);
        c->cwd_logical = 1;
    } else if (!getcwd(c->cwd, sizeof c->cwd)) {
        int e = errno;
        return fail(c, e, "getcwd 失败: %s", strerror(e));
    }
    return 0;
}

static int resolve_in(const ctx_t *c, const char *path,
                      char *out, size_t out_size)
{
    if (path[0] == '/')
        return resolve_abs(c, path, 1, out, out_size);

    char full[WORK_MAX];
    int n = snprintf(full, sizeof full, "%s/%s", c->cwd, path);
    if (n < 0 || (size_t)n >= sizeof full)
        return fail(c, ENAMETOOLONG, "路径过长: %s", path);
    /* Logical cwd is mapped; a physical cwd from getcwd() is not */
    return resolve_abs(c, full, c->cwd_logical, out, out_size);
}

static int try_dir(const ctx_t *c, const char *dir, size_t dlen,
                   const char *cmd, char *out, size_t out_size)
{
    char cand[WORK_MAX];
    int n = snprintf(cand, sizeof cand, "%.*s/%s", (int)dlen, dir, cmd);
    if (n < 0 || (size_t)n >= sizeof cand)
        return -ENAMETOOLONG;

    int rc = resolve_in(c, cand, out, out_size);
    if (rc)
        return rc;
    if (probe(out) != K_FILE)
        return -ENOENT;
    if (faccessat(AT_FDCWD, out, X_OK, AT_EACCESS) != 0)
        return -EACCES;
    return 0;
}

static int seg_eq(const char *a, size_t al, const char *b, size_t bl)
{
    return al == bl && memcmp(a, b, al) == 0;
}

static int seen_before(const char *env, const char *seg, size_t len,
                       const char *cwd)
{
    if (len == 0 || seg_eq(seg, len, cwd, strlen(cwd)))
        return 1;
    for (const char *s = env; s < seg; ) {
        const char *e = strchrnul(s, ':');
        if (seg_eq(s, (size_t)(e - s), seg, len))
            return 1;
        s = e + 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

int iec_resolve_path(const char *path, const iec_opts_t *opts,
                     char *out, size_t out_size)
{
    ctx_t c;
    int rc = init_ctx(&c, opts);
    if (rc)
        return rc;
    if (!path || !*path || !out || out_size == 0)
        return fail(&c, EINVAL, "参数非法");
    return resolve_in(&c, path, out, out_size);
}

int iec_resolve(const char *input, const iec_opts_t *opts,
                char *out, size_t out_size)
{
    ctx_t c;
    char cand[PATH_MAX];
    int rc = init_ctx(&c, opts);
    if (rc)
        return rc;
    if (!input || !*input || !out || out_size == 0)
        return fail(&c, EINVAL, "参数非法");

    if (strchr(input, '/'))
        return resolve_in(&c, input, out, out_size);

    /* Command: look in the current directory first, then search PATH */
    if (try_dir(&c, c.cwd, strlen(c.cwd), input, cand, sizeof cand) == 0)
        return copy_out(&c, cand, out, out_size);

    const char *env = (opts && opts->path_env) ? opts->path_env
                                               : getenv("PATH");
    if (!env)
        env = "";
    for (const char *seg = env; ; ) {
        const char *end = strchrnul(seg, ':');
        size_t len = (size_t)(end - seg);
        if (!seen_before(env, seg, len, c.cwd) &&
            try_dir(&c, seg, len, input, cand, sizeof cand) == 0)
            return copy_out(&c, cand, out, out_size);
        if (!*end)
            break;
        seg = end + 1;
    }
    return fail(&c, ENOENT, "command not found: %s", input);
}

/* ------------------------------------------------------------------ */
/* Mapping-table text parsing                                          */
/* ------------------------------------------------------------------ */

static char *trim(char *s)
{
    while (*s && isspace((unsigned char)*s))
        s++;
    char *e = s + strlen(s);
    while (e > s && isspace((unsigned char)e[-1]))
        e--;
    *e = '\0';
    return s;
}

int iec_parse_maps(char *buf, iec_map_t *maps, size_t cap)
{
    size_t n = 0;
    char *save = NULL;

    if (!buf || (cap && !maps))
        return -EINVAL;
    for (char *tok = strtok_r(buf, ";\n", &save); tok;
         tok = strtok_r(NULL, ";\n", &save)) {
        tok = trim(tok);
        if (*tok == '\0' || *tok == '#')
            continue;
        char *arrow = strstr(tok, "->");
        if (!arrow)
            return -EINVAL;
        *arrow = '\0';
        char *from = trim(tok);
        char *to   = trim(arrow + 2);
        if (from[0] != '/' || to[0] != '/')
            return -EINVAL;
        if (n >= cap)
            return -ENOSPC;
        maps[n].from = from;
        maps[n].to   = to;
        n++;
    }
    return (int)n;
}
