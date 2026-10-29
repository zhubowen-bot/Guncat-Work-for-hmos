// bsh_pkgindex.c — 见头文件
#include "bsh_pkgindex.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "bsh_gzip.h"
#include "bsh_http.h"

#define ARENA_INIT (1u << 20)      /* 1 MiB 起，按需翻倍 */

/* ── 小工具 ─────────────────────────────────────────────────────────────── */

static void mkdir_p(const char* path)
{
    char buf[1400];
    snprintf(buf, sizeof buf, "%s", path);
    for (char* p = buf + 1; ; p++) {
        if (*p != '/' && *p != 0)
            continue;
        char save = *p;
        *p = 0;
        if (mkdir(buf, 0755) != 0 && errno != EEXIST) { *p = save; return; }
        *p = save;
        if (save == 0)
            break;
    }
}

static char* skip_ws(char* p)
{
    while (*p == ' ' || *p == '\t')
        p++;
    return p;
}

/* 文件存在、非空、且不超龄。max_age <= 0 表示不看时间。 */
static int fresh_enough(const char* path, long max_age)
{
    struct stat st;
    if (stat(path, &st) != 0 || st.st_size <= 0)
        return 0;
    if (max_age <= 0)
        return 1;
    time_t now = time(NULL);
    return (now - st.st_mtime) < max_age;
}

/* RFC822 续行合并：'\n' 后跟空白时，把这段折行并进上一行（用一个空格连接）。
 * 就地压缩，文本变短。实测 ports.ubuntu.com 的索引里 0 处折行（最长的 Depends
 * 有 2311 字符仍是单行），但别的镜像/发行版会折，所以还是老老实实处理。 */
static size_t unfold(char* s, size_t len)
{
    size_t w = 0, r = 0;
    while (r < len) {
        if (s[r] == '\n' && r + 1 < len && (s[r + 1] == ' ' || s[r + 1] == '\t')) {
            s[w++] = ' ';
            r += 2;
            while (r < len && (s[r] == ' ' || s[r] == '\t'))
                r++;
            continue;
        }
        s[w++] = s[r++];
    }
    s[w] = 0;
    return w;
}

/* ── 条目数组 ───────────────────────────────────────────────────────────── */

static int idx_add(struct bsh_apt_index* idx, const struct bsh_apt_entry* e)
{
    if (idx->n >= idx->cap) {
        int ncap = idx->cap ? idx->cap * 2 : 1024;
        struct bsh_apt_entry* ne =
            (struct bsh_apt_entry*)realloc(idx->ents, (size_t)ncap * sizeof *ne);
        if (!ne)
            return -1;
        idx->ents = ne;
        idx->cap = ncap;
    }
    idx->ents[idx->n++] = *e;
    return 0;
}

/* ── 解析 ───────────────────────────────────────────────────────────────── */

/* 在 arena 上就地解析（顺带把行尾 '\n' 改成 '\0'，字段指针就能当 C 串用）。 */
static void parse_arena(struct bsh_apt_index* idx)
{
    char* p = idx->arena;
    char* end = idx->arena + idx->arena_len;
    struct bsh_apt_entry cur;
    int have = 0;

    memset(&cur, 0, sizeof cur);
    while (p < end) {
        char* nl = (char*)memchr(p, '\n', (size_t)(end - p));
        char* line_end = nl ? nl : end;
        if (nl)
            *nl = 0;

        if (p == line_end) {                       /* 空行 = 段落结束 */
            if (have) {
                if (cur.name && cur.filename)
                    idx_add(idx, &cur);
                memset(&cur, 0, sizeof cur);
                have = 0;
            }
        } else if (!strncmp(p, "Package:", 8)) {
            cur.name = skip_ws(p + 8);
            have = 1;
        } else if (!strncmp(p, "Version:", 8)) {
            cur.version = skip_ws(p + 8);
        } else if (!strncmp(p, "Depends:", 8)) {
            cur.depends = skip_ws(p + 8);
        } else if (!strncmp(p, "Filename:", 9)) {
            cur.filename = skip_ws(p + 9);
        } else if (!strncmp(p, "SHA256:", 7)) {
            cur.sha256 = skip_ws(p + 7);
        } else if (!strncmp(p, "Size:", 5)) {
            cur.size = strtoll(skip_ws(p + 5), NULL, 10);
        }

        p = nl ? nl + 1 : end;
    }
    if (have && cur.name && cur.filename)
        idx_add(idx, &cur);
}

static int ent_cmp(const void* a, const void* b)
{
    const struct bsh_apt_entry* x = (const struct bsh_apt_entry*)a;
    const struct bsh_apt_entry* y = (const struct bsh_apt_entry*)b;
    int r = strcmp(x->name, y->name);
    if (r)
        return r;
    /* 同名（多组件重复 / 多版本）时版本大的排前面 —— find 取第一个就是它。
     * 版本比较只是字符串序，够用；真要严格比版本得实现 dpkg 的版本算法。 */
    return -strcmp(x->version ? x->version : "", y->version ? y->version : "");
}

/* ── 取一个组件 ─────────────────────────────────────────────────────────── */

static int grow_arena(struct bsh_apt_index* idx, size_t need)
{
    if (idx->arena_len + need <= idx->arena_cap)
        return 0;
    size_t ncap = idx->arena_cap ? idx->arena_cap : ARENA_INIT;
    while (idx->arena_len + need > ncap)
        ncap *= 2;
    char* na = (char*)realloc(idx->arena, ncap);
    if (!na)
        return -1;
    idx->arena = na;
    idx->arena_cap = ncap;
    return 0;
}

static int append_file(struct bsh_apt_index* idx, const char* path,
                       char* err, size_t errlen)
{
    FILE* f = fopen(path, "rb");
    if (!f) {
        snprintf(err, errlen, "打不开 %.200s：%s", path, strerror(errno));
        return -1;
    }
    size_t got = 0;
    for (;;) {
        if (grow_arena(idx, 256 * 1024) != 0) {
            snprintf(err, errlen, "内存不足（索引太大？）");
            fclose(f);
            return -1;
        }
        size_t room = idx->arena_cap - idx->arena_len - 1;
        size_t r = fread(idx->arena + idx->arena_len, 1, room, f);
        idx->arena_len += r;
        got += r;
        if (r < room) {
            if (ferror(f)) {
                snprintf(err, errlen, "读 %.200s 失败", path);
                fclose(f);
                return -1;
            }
            break;
        }
    }
    fclose(f);
    if (got == 0) {
        snprintf(err, errlen, "%.200s 是空的", path);
        return -1;
    }
    idx->arena[idx->arena_len] = 0;
    return 0;
}

/* ── 对外 ───────────────────────────────────────────────────────────────── */

int bsh_apt_index_load(struct bsh_apt_index* idx, const struct bsh_apt_src* src,
                       int force, char* err, size_t errlen)
{
    memset(idx, 0, sizeof *idx);
    if (!src || !src->mirror || !src->suite || !src->comps || !src->arch || !src->cache_dir) {
        snprintf(err, errlen, "索引配置不完整");
        return -1;
    }

    char adir[1200];
    if (snprintf(adir, sizeof adir, "%s/apt", src->cache_dir) >= (int)sizeof adir) {
        snprintf(err, errlen, "缓存路径太长");
        return -1;
    }
    mkdir_p(adir);

    /* mirror 末尾的 '/' 统一去掉，拼 URL 时再加 */
    char base[512];
    snprintf(base, sizeof base, "%s", src->mirror);
    size_t bl = strlen(base);
    while (bl > 0 && base[bl - 1] == '/')
        base[--bl] = 0;

    char comps[256];
    snprintf(comps, sizeof comps, "%s", src->comps);

    int n_ok = 0;
    char warn[256] = {0};
    char* cst = NULL;
    /* 用 strtok_r 而不是 strtok：解析 Depends 时还会再切字符串，别共用一份全局状态 */
    for (char* tok = strtok_r(comps, " \t,", &cst); tok; tok = strtok_r(NULL, " \t,", &cst)) {
        char gz[1400], txt[1400], url[900];
        snprintf(gz,  sizeof gz,  "%s/%s_%s_%s_Packages.gz",  adir, src->suite, tok, src->arch);
        snprintf(txt, sizeof txt, "%s/%s_%s_%s_Packages.txt", adir, src->suite, tok, src->arch);

        int ready = 0;
        if (!force && fresh_enough(txt, src->max_age_sec)) {
            ready = 1;
        } else {
            /* 需要重下或重解 */
            if (force || !fresh_enough(gz, src->max_age_sec)) {
                snprintf(url, sizeof url, "%s/dists/%s/%s/binary-%s/Packages.gz",
                         base, src->suite, tok, src->arch);
                printf("apt: 取索引 %s\n", url);
                if (bsh_http_get_file(url, gz, err, errlen) != 0) {
                    if (fresh_enough(txt, 0)) {
                        snprintf(warn, sizeof warn, "索引下载失败，用本地旧的文本：%s", tok);
                        ready = 1;
                    } else {
                        printf("apt: %s 索引拿不到：%s\n", tok, err);
                        continue;
                    }
                }
            }
            if (!ready) {
                if (bsh_gzip_decompress_range(gz, 0, -1, txt, err, errlen) != 0) {
                    if (fresh_enough(txt, 0)) {
                        snprintf(warn, sizeof warn, "索引解压失败，用本地旧的文本：%s", tok);
                    } else {
                        printf("apt: %s 索引解压失败：%s\n", tok, err);
                        continue;
                    }
                }
                ready = 1;
            }
        }

        if (ready) {
            char aerr[256] = {0};
            if (append_file(idx, txt, aerr, sizeof aerr) != 0) {
                printf("apt: %s 索引读取失败：%s\n", tok, aerr);
                snprintf(err, errlen, "%s", aerr);
                continue;
            }
            n_ok++;
            idx->n_files++;
        }
    }

    if (n_ok == 0) {
        bsh_apt_index_free(idx);
        if (!err[0])
            snprintf(err, errlen, "没有任何可用的索引（检查 BSH_APT_MIRROR / 网络）");
        return -1;
    }

    idx->arena_len = unfold(idx->arena, idx->arena_len);
    parse_arena(idx);
    if (idx->n > 1)
        qsort(idx->ents, (size_t)idx->n, sizeof idx->ents[0], ent_cmp);

    if (warn[0])
        snprintf(err, errlen, "%s", warn);        /* 非致命，调用方自行决定是否打印 */
    return 0;
}

const struct bsh_apt_entry* bsh_apt_index_find(const struct bsh_apt_index* idx,
                                               const char* name)
{
    if (!idx || !name || idx->n <= 0)
        return NULL;
    int lo = 0, hi = idx->n - 1, hit = -1;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        int r = strcmp(idx->ents[mid].name, name);
        if (r == 0) { hit = mid; hi = mid - 1; }
        else if (r < 0) lo = mid + 1;
        else hi = mid - 1;
    }
    return hit < 0 ? NULL : &idx->ents[hit];
}

int bsh_apt_index_count_name(const struct bsh_apt_index* idx, const char* name)
{
    if (!idx || !name)
        return 0;
    const struct bsh_apt_entry* e = bsh_apt_index_find(idx, name);
    if (!e)
        return 0;
    int i = (int)(e - idx->ents), c = 0;
    for (; i < idx->n && strcmp(idx->ents[i].name, name) == 0; i++)
        c++;
    return c;
}

int bsh_apt_index_add_local(struct bsh_apt_index* idx, const char* name,
                            const char* version, const char* depends)
{
    if (!idx || !name || !name[0] || idx->n_local >= (int)(sizeof idx->local_store / sizeof idx->local_store[0]))
        return -1;
    if (bsh_apt_index_find(idx, name))
        return 0;                          /* 索引里已经有了，别插重复的 */

    const char* ver = (version && version[0]) ? version : "?";
    const char* dep = depends ? depends : "";
    size_t cap = sizeof idx->local_store[0];
    size_t l1 = strlen(name) + 1;
    size_t l2 = strlen(ver) + 1;
    size_t l3 = strlen(dep) + 1;
    if (l1 + l2 + l3 > cap)
        return -1;

    char* slot = idx->local_store[idx->n_local++];
    memcpy(slot, name, l1);
    char* nm = slot;
    memcpy(slot + l1, ver, l2);
    char* vr = slot + l1;
    memcpy(slot + l1 + l2, dep, l3);
    char* dp = slot + l1 + l2;

    struct bsh_apt_entry e;
    memset(&e, 0, sizeof e);
    e.name = nm;
    e.version = vr;
    e.depends = dp[0] ? dp : NULL;
    e.filename = "";                       /* 空 = 本地有，别去下载 */
    e.size = 0;

    if (idx->n >= idx->cap) {
        int ncap = idx->cap ? idx->cap * 2 : 1024;
        struct bsh_apt_entry* ne =
            (struct bsh_apt_entry*)realloc(idx->ents, (size_t)ncap * sizeof *ne);
        if (!ne)
            return -1;
        idx->ents = ne;
        idx->cap = ncap;
    }
    idx->ents[idx->n++] = e;
    qsort(idx->ents, (size_t)idx->n, sizeof idx->ents[0], ent_cmp);
    return 0;
}

void bsh_apt_index_free(struct bsh_apt_index* idx)
{
    if (!idx)
        return;
    free(idx->arena);
    free(idx->ents);
    memset(idx, 0, sizeof *idx);
}
