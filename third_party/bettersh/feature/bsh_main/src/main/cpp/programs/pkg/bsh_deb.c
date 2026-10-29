// bsh_deb.c — 见头文件
#include "bsh_deb.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bsh_gzip.h"
#include "bsh_tar.h"
#include "bsh_xz.h"
#include "bsh_zstd.h"

#define AR_MAGIC  "!<arch>\n"
#define AR_HDR    60          /* ar 成员头固定 60 字节 */
#define AR_MEMBERS_MAX 16     /* deb 只有 3 个成员，16 足够 */

/* ── 成员表 ─────────────────────────────────────────────────────────────── */

static int parse_members(const char* debpath, struct bsh_deb_member* out, int max,
                         char* err, size_t errlen)
{
    FILE* f = fopen(debpath, "rb");
    if (!f) {
        snprintf(err, errlen, "打不开 %s：%s", debpath, strerror(errno));
        return -1;
    }
    char magic[8];
    if (fread(magic, 1, 8, f) != 8 || memcmp(magic, AR_MAGIC, 8) != 0) {
        snprintf(err, errlen, "%s 不是 ar 归档（不是 .deb？）", debpath);
        fclose(f);
        return -1;
    }

    int n = 0;
    for (;;) {
        char hdr[AR_HDR];
        size_t rd = fread(hdr, 1, AR_HDR, f);
        if (rd == 0)
            break;                      /* 正常结束 */
        if (rd != AR_HDR) {
            snprintf(err, errlen, "ar 成员头不完整");
            fclose(f);
            return -1;
        }
        if (hdr[58] != '`' || hdr[59] != '\n') {
            snprintf(err, errlen, "ar 成员头尾标记不对（期望 \"`\\n\"）");
            fclose(f);
            return -1;
        }

        /* 名字：16 字节，空格填充；GNU ar 可能带一个 '/' 结尾 */
        char nm[17];
        memcpy(nm, hdr, 16);
        nm[16] = 0;
        int i = 15;
        while (i >= 0 && (nm[i] == ' ' || nm[i] == '\0'))
            nm[i--] = 0;
        while (i >= 0 && nm[i] == '/')
            nm[i--] = 0;

        /* 长度：10 字节十进制 ASCII（不是八进制，与 tar 不同） */
        char sz[11];
        memcpy(sz, hdr + 48, 10);
        sz[10] = 0;
        long long size = strtoll(sz, NULL, 10);
        if (size < 0) {
            snprintf(err, errlen, "ar 成员 %s 的长度不合法", nm);
            fclose(f);
            return -1;
        }

        long long off = (long long)ftell(f);
        if (off < 0) {
            snprintf(err, errlen, "ftell 失败");
            fclose(f);
            return -1;
        }
        if (out && n < max) {
            snprintf(out[n].name, sizeof out[n].name, "%s", nm);
            out[n].offset = off;
            out[n].size = size;
        }
        n++;

        /* 跳到下一个成员：数据 + 奇数长度的 1 字节填充 */
        if (fseek(f, (long)(size + (size & 1)), SEEK_CUR) != 0)
            break;
    }
    fclose(f);
    return n;
}

int bsh_deb_members(const char* debpath, struct bsh_deb_member* out, int max,
                    char* err, size_t errlen)
{
    return parse_members(debpath, out, max, err, errlen);
}

int bsh_deb_find_member(const char* debpath, const char* name,
                        struct bsh_deb_member* out, char* err, size_t errlen)
{
    struct bsh_deb_member list[AR_MEMBERS_MAX];
    int n = parse_members(debpath, list, AR_MEMBERS_MAX, err, errlen);
    if (n < 0)
        return -1;
    for (int i = 0; i < n && i < AR_MEMBERS_MAX; i++) {
        if (strcmp(list[i].name, name) == 0) {
            *out = list[i];
            return 1;
        }
    }
    return 0;
}

/* ── 成员解压 ───────────────────────────────────────────────────────────── */

enum { FMT_NONE = 0, FMT_ZST, FMT_GZ, FMT_XZ };

static int fmt_of(const char* name)
{
    size_t l = strlen(name);
    if (l > 4 && strcmp(name + l - 4, ".zst") == 0)  return FMT_ZST;
    if (l > 3 && strcmp(name + l - 3, ".gz") == 0)   return FMT_GZ;
    if (l > 3 && strcmp(name + l - 3, ".xz") == 0)   return FMT_XZ;
    return FMT_NONE;
}

/* 未压缩成员：把 [off, off+size) 原样抄到 out_path */
static int copy_range(const char* src, long long off, long long size,
                      const char* out_path, char* err, size_t errlen)
{
    int rc = -1, in_fd = -1, out_fd = -1;
    char* buf = malloc(128 * 1024);

    in_fd = open(src, O_RDONLY);
    if (in_fd < 0) {
        snprintf(err, errlen, "打开源文件失败：%s", strerror(errno));
        free(buf);
        return -1;
    }
    if (off > 0 && lseek(in_fd, (off_t)off, SEEK_SET) != (off_t)off) {
        snprintf(err, errlen, "定位源文件失败：%s", strerror(errno));
        goto done;
    }
    out_fd = open(out_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) {
        snprintf(err, errlen, "创建目标文件失败：%s", strerror(errno));
        goto done;
    }
    if (!buf) {
        snprintf(err, errlen, "分配缓冲失败");
        goto done;
    }

    long long left = size;
    while (left > 0) {
        size_t want = 128 * 1024;
        if ((long long)want > left)
            want = (size_t)left;
        ssize_t got = read(in_fd, buf, want);
        if (got < 0) {
            if (errno == EINTR) continue;
            snprintf(err, errlen, "读源文件失败：%s", strerror(errno));
            goto done;
        }
        if (got == 0) {
            snprintf(err, errlen, "源文件提前结束（还差 %lld 字节）", left);
            goto done;
        }
        left -= got;
        ssize_t o = 0;
        while (o < got) {
            ssize_t wr = write(out_fd, buf + o, (size_t)(got - o));
            if (wr < 0) {
                if (errno == EINTR) continue;
                snprintf(err, errlen, "写目标文件失败：%s", strerror(errno));
                goto done;
            }
            o += wr;
        }
    }
    rc = 0;

done:
    free(buf);
    if (in_fd >= 0) close(in_fd);
    if (out_fd >= 0) close(out_fd);
    if (rc != 0 && out_path) unlink(out_path);
    return rc;
}

int bsh_deb_unpack_member(const char* debpath, const struct bsh_deb_member* m,
                          const char* out_path, char* err, size_t errlen)
{
    switch (fmt_of(m->name)) {
    case FMT_ZST:
        return bsh_zstd_decompress_range(debpath, m->offset, m->size, out_path, err, errlen);
    case FMT_GZ:
        return bsh_gzip_decompress_range(debpath, m->offset, m->size, out_path, err, errlen);
    case FMT_XZ:
        return bsh_xz_decompress_range(debpath, m->offset, m->size, out_path, err, errlen);
    default:
        return copy_range(debpath, m->offset, m->size, out_path, err, errlen);
    }
}

/* ── control ────────────────────────────────────────────────────────────── */

int bsh_deb_read_control(const char* debpath, const char* tmp_dir,
                         char** buf, size_t* len, char* err, size_t errlen)
{
    static const char* kNames[] = {
        "control.tar.zst", "control.tar.gz", "control.tar.xz", "control.tar", NULL
    };
    struct bsh_deb_member m;
    int found = 0;
    for (int i = 0; kNames[i]; i++) {
        int r = bsh_deb_find_member(debpath, kNames[i], &m, err, errlen);
        if (r < 0)
            return -1;
        if (r == 1) { found = 1; break; }
    }
    if (!found) {
        snprintf(err, errlen, "deb 里找不到 control.tar.*");
        return -1;
    }

    char tmp[1024];
    if (snprintf(tmp, sizeof tmp, "%s/.bsh-apt-control.tar", tmp_dir) >= (int)sizeof tmp) {
        snprintf(err, errlen, "临时路径太长");
        return -1;
    }
    if (bsh_deb_unpack_member(debpath, &m, tmp, err, errlen) != 0)
        return -1;

    int rc = bsh_tar_extract_one(tmp, "./control", buf, len, err, errlen);
    unlink(tmp);
    if (rc == 1) {
        snprintf(err, errlen, "control.tar 里没有 control 文件");
        return -1;
    }
    return rc;
}

int bsh_deb_field(const char* control, const char* field, char* out, size_t outlen)
{
    if (!control || !field || !out || outlen == 0)
        return 0;
    out[0] = 0;

    size_t flen = strlen(field);
    int found = 0;
    size_t used = 0;
    const char* p = control;

    while (*p) {
        const char* eol = strchr(p, '\n');
        size_t llen = eol ? (size_t)(eol - p) : strlen(p);
        if (llen == 0)
            break;                              /* 空行 = 段落结束 */

        if (p[0] == ' ' || p[0] == '\t') {      /* 续行 */
            if (found) {
                if (used && used + 1 < outlen)
                    out[used++] = ' ';
                size_t i = 0;
                while (i < llen && (p[i] == ' ' || p[i] == '\t'))
                    i++;
                for (; i < llen && used + 1 < outlen; i++)
                    out[used++] = p[i];
                out[used] = 0;
            }
        } else {
            if (found)
                break;                          /* 本字段已读完 */
            if (llen > flen && p[flen] == ':' && strncmp(p, field, flen) == 0) {
                size_t i = flen + 1;
                while (i < llen && (p[i] == ' ' || p[i] == '\t'))
                    i++;
                found = 1;
                for (; i < llen && used + 1 < outlen; i++)
                    out[used++] = p[i];
                out[used] = 0;
            }
        }
        p = eol ? eol + 1 : p + llen;
    }
    return found;
}
