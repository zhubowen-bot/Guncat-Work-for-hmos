// bsh_tar.c — pkg 用的最小 tar 解包器（见 bsh_tar.h）
#include "bsh_tar.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define BLK 512
#define NAME_MAX_LEN 1024

struct ustar {
    char name[100];
    char mode[8];
    char uid[8];
    char gid[8];
    char size[12];
    char mtime[12];
    char chksum[8];
    char typeflag;
    char linkname[100];
    char magic[6];
    char version[2];
    char uname[32];
    char gname[32];
    char devmajor[8];
    char devminor[8];
    char prefix[155];
    char pad[12];
};

static void err_set(char* err, size_t errlen, const char* fmt, ...)
{
    if (!err || errlen == 0)
        return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errlen, fmt, ap);
    va_end(ap);
}

/* 八进制字段；GNU 的 base-256（首字节高位）也认一下 */
static long long parse_size(const char* f, size_t len)
{
    if ((unsigned char)f[0] & 0x80) {
        long long v = (unsigned char)f[0] & 0x7f;
        for (size_t i = 1; i < len; i++)
            v = (v << 8) | (unsigned char)f[i];
        return v;
    }
    long long v = 0;
    for (size_t i = 0; i < len; i++) {
        char c = f[i];
        if (c == ' ' || c == 0)
            break;
        if (c < '0' || c > '7')
            break;
        v = v * 8 + (c - '0');
    }
    return v;
}

static void trim_field(char* dst, size_t dstlen, const char* src, size_t srclen)
{
    size_t n = 0;
    while (n < srclen && src[n])
        n++;
    while (n > 0 && (src[n - 1] == ' ' || src[n - 1] == 0))
        n--;
    if (n >= dstlen)
        n = dstlen - 1;
    memcpy(dst, src, n);
    dst[n] = 0;
}

/* 路径安全检查：不许绝对路径、不许 .. 分量 */
static int path_safe(const char* rel)
{
    if (!rel || !*rel || rel[0] == '/')
        return 0;
    const char* p = rel;
    while (*p) {
        const char* e = strchr(p, '/');
        size_t n = e ? (size_t)(e - p) : strlen(p);
        if (n == 2 && p[0] == '.' && p[1] == '.')
            return 0;
        if (!e)
            break;
        p = e + 1;
    }
    return 1;
}

/* 建目录（逐级，含最后一级） */
static int mkdir_p(const char* root, const char* rel)
{
    char path[NAME_MAX_LEN * 2];
    if (snprintf(path, sizeof path, "%s/%s", root, rel) >= (int)sizeof path)
        return -1;
    for (char* p = path + strlen(root) + 1; ; p++) {
        if (*p != '/' && *p != 0)
            continue;
        char save = *p;
        *p = 0;
        if (mkdir(path, 0755) != 0 && errno != EEXIST)
            return -1;
        *p = save;
        if (save == 0)
            break;
    }
    return 0;
}

static int open_out(const char* root, const char* rel, FILE** out)
{
    char path[NAME_MAX_LEN * 2];
    if (snprintf(path, sizeof path, "%s/%s", root, rel) >= (int)sizeof path)
        return -1;
    /* 父目录 */
    char* slash = strrchr(path, '/');
    if (slash && slash > path) {
        *slash = 0;
        if (mkdir_p(root, path + strlen(root) + 1) != 0 && errno != EEXIST) {
            *slash = '/';
            return -1;
        }
        *slash = '/';
    }
    *out = fopen(path, "wb");
    return *out ? 0 : -1;
}

int bsh_tar_extract_h(const char* tar_path, const char* dest_root,
                      const struct bsh_tar_hooks* hooks, void* ctx,
                      char* err, size_t errlen)
{
    const struct bsh_tar_hooks* hk = hooks;   /* 注意别叫 h：本函数还有 struct ustar h */
    FILE* f = fopen(tar_path, "rb");
    if (!f) {
        err_set(err, errlen, "打不开 %s：%s", tar_path, strerror(errno));
        return -1;
    }

    struct ustar h;
    char longname[NAME_MAX_LEN] = {0};
    char* data = NULL;
    size_t data_cap = 0;
    int rc = -1, zero_blocks = 0;

    for (;;) {
        size_t rd = fread(&h, 1, BLK, f);
        if (rd == 0)
            break;                        /* 正常结束（有的 tar 没有两个零块） */
        if (rd != BLK) {
            err_set(err, errlen, "tar 尾部不完整");
            goto done;
        }
        /* 两个全零块 = 归档结束 */
        {
            int all_zero = 1;
            for (size_t i = 0; i < BLK; i++)
                if (((char*)&h)[i]) { all_zero = 0; break; }
            if (all_zero) {
                if (++zero_blocks >= 2)
                    break;
                continue;
            }
            zero_blocks = 0;
        }

        long long size = parse_size(h.size, sizeof h.size);

        /* GNU longname：数据块里是下一个成员的名字 */
        if (h.typeflag == 'L') {
            if (size <= 0 || size > (long long)sizeof longname) {
                err_set(err, errlen, "longname 长度不合法（%lld）", size);
                goto done;
            }
            if (fread(longname, 1, (size_t)size, f) != (size_t)size) {
                err_set(err, errlen, "读 longname 失败");
                goto done;
            }
            longname[size] = 0;
            /* 跳过填充 */
            long long pad = (BLK - (size % BLK)) % BLK;
            if (pad && fseek(f, (long)pad, SEEK_CUR) != 0) {
                err_set(err, errlen, "跳过填充失败");
                goto done;
            }
            continue;
        }

        /* 组装成员路径 */
        char rel[NAME_MAX_LEN];
        if (longname[0]) {
            snprintf(rel, sizeof rel, "%s", longname);
            longname[0] = 0;
        } else {
            char nm[200] = {0}, pf[200] = {0};
            trim_field(nm, sizeof nm, h.name, sizeof h.name);
            trim_field(pf, sizeof pf, h.prefix, sizeof h.prefix);
            if (pf[0])
                snprintf(rel, sizeof rel, "%s/%s", pf, nm);
            else
                snprintf(rel, sizeof rel, "%s", nm);
        }
        size_t rl = strlen(rel);
        while (rl > 0 && rel[rl - 1] == '/')
            rel[--rl] = 0;                /* 目录成员常带尾斜杠 */
        if (!path_safe(rel)) {
            err_set(err, errlen, "成员路径不安全，拒绝解包：%s", rel);
            goto done;
        }

        /* 调用方说"这个不要"（目标已存在之类）：把成员数据连同填充一起跳过去。
         * ⚠ size 本身一定要跳 —— 只跳 padding 的话后面每个成员的头都会读错位。 */
        if (hk && hk->skip && hk->skip(ctx, rel)) {
            long long skip = size + (BLK - (size % BLK)) % BLK;
            if (skip > 0 && fseek(f, (long)skip, SEEK_CUR) != 0) {
                err_set(err, errlen, "跳过成员 %s 失败", rel);
                goto done;
            }
            continue;
        }

        char type = h.typeflag ? h.typeflag : '0';
        if (type == '5') {                /* 目录 */
            if (mkdir_p(dest_root, rel) != 0) {
                err_set(err, errlen, "建目录失败：%s/%s", dest_root, rel);
                goto done;
            }
            if (hk && hk->on_member && hk->on_member(ctx, rel) != 0) { rc = 0; goto done; }
        } else if (type == '0') {         /* 普通文件 */
            FILE* out = NULL;
            if (open_out(dest_root, rel, &out) != 0) {
                err_set(err, errlen, "建文件失败：%s/%s", dest_root, rel);
                goto done;
            }
            if (size > 0) {
                if ((size_t)size > data_cap) {
                    char* np = realloc(data, (size_t)size);
                    if (!np) { fclose(out); err_set(err, errlen, "内存不足"); goto done; }
                    data = np;
                    data_cap = (size_t)size;
                }
                if (fread(data, 1, (size_t)size, f) != (size_t)size) {
                    fclose(out);
                    err_set(err, errlen, "读成员数据失败：%s", rel);
                    goto done;
                }
                if (fwrite(data, 1, (size_t)size, out) != (size_t)size) {
                    fclose(out);
                    err_set(err, errlen, "写文件失败：%s", rel);
                    goto done;
                }
            }
            fclose(out);
            /* 权限：解析头里的八进制 mode，带任一执行位就给 0755，其余 0644 */
            {
                char p[NAME_MAX_LEN * 2];
                long m = 0;
                for (size_t i = 0; i < sizeof h.mode && h.mode[i] >= '0' && h.mode[i] <= '7'; i++)
                    m = m * 8 + (h.mode[i] - '0');
                snprintf(p, sizeof p, "%s/%s", dest_root, rel);
                chmod(p, (m & 0111) ? 0755 : 0644);
            }
            if (hk && hk->on_member && hk->on_member(ctx, rel) != 0) { rc = 0; goto done; }
        } else if (type == '2' || type == '1') {
            /* 链接成员：*我们*不建（沙箱里 symlink(2) 会被拒），交给上层代偿 ——
             * 见 bsh_tar.h 里 bsh_tar_link_fn 的说明。lfn 为 NULL 时等同跳过，
             * 与加这个分支之前的行为完全一致。 */
            char tgt[512] = {0};
            trim_field(tgt, sizeof tgt, h.linkname, sizeof h.linkname);
            if (hk && hk->on_link && hk->on_link(ctx, rel, tgt) != 0) { rc = 0; goto done; }
        }
        /* 其它类型（设备节点、fifo…）：跳过 */

        long long pad = (BLK - (size % BLK)) % BLK;
        if (pad && fseek(f, (long)pad, SEEK_CUR) != 0) {
            err_set(err, errlen, "跳过填充失败");
            goto done;
        }
        if (ferror(f)) {
            err_set(err, errlen, "读 %s 出错", tar_path);
            goto done;
        }
    }
    rc = 0;

done:
    free(data);
    fclose(f);
    return rc;
}

int bsh_tar_extract(const char* tar_path, const char* dest_root,
                    bsh_tar_list_fn fn, void* ctx,
                    char* err, size_t errlen)
{
    struct bsh_tar_hooks h;
    h.on_member = fn;
    h.on_link = NULL;
    h.skip = NULL;
    return bsh_tar_extract_h(tar_path, dest_root, &h, ctx, err, errlen);
}

/* 成员名比较：忽略 tar 里常见的前导 "./"（deb 的 control 就是 "./control"） */
static int name_eq(const char* a, const char* b)
{
    while (a[0] == '.' && a[1] == '/') a += 2;
    while (b[0] == '.' && b[1] == '/') b += 2;
    return strcmp(a, b) == 0;
}

int bsh_tar_extract_one(const char* tar_path, const char* member,
                        char** buf, size_t* len, char* err, size_t errlen)
{
    if (!tar_path || !member || !buf || !len) {
        err_set(err, errlen, "参数为空");
        return -1;
    }
    FILE* f = fopen(tar_path, "rb");
    if (!f) {
        err_set(err, errlen, "打不开 %s：%s", tar_path, strerror(errno));
        return -1;
    }
    struct ustar h;
    char longname[NAME_MAX_LEN] = {0};
    int rc = 1, zero_blocks = 0;
    for (;;) {
        size_t rd = fread(&h, 1, BLK, f);
        if (rd != BLK)
            break;
        {
            int all_zero = 1;
            for (size_t i = 0; i < BLK; i++)
                if (((char*)&h)[i]) { all_zero = 0; break; }
            if (all_zero) {
                if (++zero_blocks >= 2)
                    break;
                continue;
            }
            zero_blocks = 0;
        }
        long long size = parse_size(h.size, sizeof h.size);
        if (h.typeflag == 'L') {
            if (size > 0 && size <= (long long)sizeof longname &&
                fread(longname, 1, (size_t)size, f) == (size_t)size)
                longname[size] = 0;
            long long pad = (BLK - (size % BLK)) % BLK;
            if (pad) fseek(f, (long)pad, SEEK_CUR);
            continue;
        }
        char rel[NAME_MAX_LEN];
        if (longname[0]) {
            snprintf(rel, sizeof rel, "%s", longname);
            longname[0] = 0;
        } else {
            char nm[200] = {0}, pf[200] = {0};
            trim_field(nm, sizeof nm, h.name, sizeof h.name);
            trim_field(pf, sizeof pf, h.prefix, sizeof h.prefix);
            if (pf[0])
                snprintf(rel, sizeof rel, "%s/%s", pf, nm);
            else
                snprintf(rel, sizeof rel, "%s", nm);
        }
        size_t rl = strlen(rel);
        while (rl > 0 && rel[rl - 1] == '/')
            rel[--rl] = 0;
        char type = h.typeflag ? h.typeflag : '0';
        if (type == '0' && name_eq(rel, member)) {
            /* control 文件只有几 KB，这里的上限只是防呆 */
            if (size < 0 || size > 64LL * 1024 * 1024) {
                err_set(err, errlen, "成员 %s 大小不合法（%lld）", rel, size);
                rc = -1;
                break;
            }
            char* p = malloc((size_t)size + 1);
            if (!p) {
                err_set(err, errlen, "内存不足");
                rc = -1;
                break;
            }
            if (size > 0 && fread(p, 1, (size_t)size, f) != (size_t)size) {
                free(p);
                err_set(err, errlen, "读成员失败：%s", rel);
                rc = -1;
                break;
            }
            p[size] = 0;
            *buf = p;
            *len = (size_t)size;
            rc = 0;
            break;
        }
        /* 不匹配的成员：数据 + 填充一起跳过（漏跳 size 会让后面全部读错位） */
        {
            long long skip = size + (BLK - (size % BLK)) % BLK;
            if (skip > 0 && fseek(f, (long)skip, SEEK_CUR) != 0) {
                err_set(err, errlen, "跳过成员失败");
                rc = -1;
                break;
            }
        }
    }
    fclose(f);
    return rc;
}

int bsh_tar_list(const char* tar_path, bsh_tar_list_fn fn, void* ctx,
                 char* err, size_t errlen)
{
    FILE* f = fopen(tar_path, "rb");
    if (!f) {
        err_set(err, errlen, "打不开 %s：%s", tar_path, strerror(errno));
        return -1;
    }
    struct ustar h;
    char longname[NAME_MAX_LEN] = {0};
    int rc = 0, zero_blocks = 0;
    for (;;) {
        size_t rd = fread(&h, 1, BLK, f);
        if (rd != BLK)
            break;
        {
            int all_zero = 1;
            for (size_t i = 0; i < BLK; i++)
                if (((char*)&h)[i]) { all_zero = 0; break; }
            if (all_zero) {
                if (++zero_blocks >= 2)
                    break;
                continue;
            }
            zero_blocks = 0;
        }
        long long size = parse_size(h.size, sizeof h.size);
        if (h.typeflag == 'L') {
            if (size > 0 && size <= (long long)sizeof longname &&
                fread(longname, 1, (size_t)size, f) == (size_t)size)
                longname[size] = 0;
            long long pad = (BLK - (size % BLK)) % BLK;
            if (pad) fseek(f, (long)pad, SEEK_CUR);
            continue;
        }
        char rel[NAME_MAX_LEN];
        if (longname[0]) {
            snprintf(rel, sizeof rel, "%s", longname);
            longname[0] = 0;
        } else {
            char nm[200] = {0}, pf[200] = {0};
            trim_field(nm, sizeof nm, h.name, sizeof h.name);
            trim_field(pf, sizeof pf, h.prefix, sizeof h.prefix);
            if (pf[0])
                snprintf(rel, sizeof rel, "%s/%s", pf, nm);
            else
                snprintf(rel, sizeof rel, "%s", nm);
        }
        size_t rl = strlen(rel);
        while (rl > 0 && rel[rl - 1] == '/')
            rel[--rl] = 0;
        char type = h.typeflag ? h.typeflag : '0';
        if ((type == '0' || type == '5') && rel[0] && fn && fn(ctx, rel) != 0)
            break;
        /* 数据 + 填充一起跳过（这里从来不读数据，漏跳 size 会读错位） */
        long long skip = size + (BLK - (size % BLK)) % BLK;
        if (skip > 0) fseek(f, (long)skip, SEEK_CUR);
    }
    fclose(f);
    return rc;
}
