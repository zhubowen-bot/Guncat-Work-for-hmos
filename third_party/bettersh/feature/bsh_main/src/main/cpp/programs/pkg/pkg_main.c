// pkg_main.c — pkg 命令 so：BetterSH 的包管理器
//
// 形状与 bshutil 类似（命令 so、随 HAP 打、命令表 dlopen 进来跑），但**不经过主进程**：
// 下载走 mbedTLS（编在本 so 里）、解包走自己的 tar 实现，所以不需要跟宿主通信，
// 也不需要 exec 委托。装东西这件事只要"写字符串、连 TLS、解 tar"三样。
//
// 目录（都在资源根下）：
//   <root>/pkgs/source          源地址（一行；没有就用默认值）
//   <root>/pkgs/cache/          下载缓存（<file> 与 <file>.part）
//   <root>/pkgs/installed.json  已装包 → 版本 + 文件清单（remove 靠它）
//
// 安装根默认是 BSH_SYSROOT；可用环境变量 BSH_PKG_ROOT 覆盖 —— 只为了能在宿主机上
// 拿真源码编一份原生版、把"下载→校验→解包→记账"整条链跑通再上设备（设备上那个路径
// 宿主机建不出来）。命令 so 在设备上是经 procmgr 起的，环境变量继承自会话，不会被误设。
//
// 包的约定：tar 内部直接是相对安装根的路径（如 usr/bin/weston-terminal），
// 所以"安装"就是 tar -C <root> -x，不需要额外的路径映射。
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "bsh_http.h"
#include "bsh_json.h"
#include "bsh_tar.h"
#include "bsh_zstd.h"
#include "common/bsh_paths.h"

#include "mbedtls/sha256.h"

#define REL_PKGDIR  "/pkgs"
#define REL_CACHE   "/pkgs/cache"
#define REL_STATE   "/pkgs/installed.json"
#define REL_SOURCE  "/pkgs/source"
#define PKG_DEFAULT_SOURCE "https://bsh.y1yan.com/"
#define MAX_INSTALLED 64

/* ── 根目录 ─────────────────────────────────────────────── */

static const char* pkg_root(void)
{
    const char* e = getenv("BSH_PKG_ROOT");
    return (e && *e) ? e : bsh_sysroot();
}

/* 把 <root><rel> 拼进 out */
static void under_root(char* out, size_t n, const char* rel)
{
    snprintf(out, n, "%s%s", pkg_root(), rel);
}

/* ── 小工具 ─────────────────────────────────────────────── */

static void mkdir_p(const char* path)
{
    char buf[1200];
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

/* 目录能不能真用：先建出来，再**真写一个探针文件** —— 只看 access() 不够可靠
 * （有些沙箱里 access 报得比 open 宽）。探针用完删掉。 */
static int dir_usable(const char* dir)
{
    mkdir_p(dir);
    char probe[1400];
    snprintf(probe, sizeof probe, "%s/.pkg-cache-probe", dir);
    FILE* f = fopen(probe, "w");
    if (!f)
        return 0;
    fputs("ok", f);
    int ok = (fclose(f) == 0);
    unlink(probe);
    return ok;
}

/* 解析缓存目录：**只认环境变量 `BSH_PKG_CACHE`**（会话里由 shell.cpp 设成默认的
 * Download 目录，见 common/bsh_paths.h；用户 `export` 可覆盖）。
 *
 * pkg 这边不内置任何默认路径 —— 默认值是"会话环境"的事，工具只负责用；没设 or 目录
 * 不存在/没授权/写不进去，就退回资源根下的 pkgs/cache（宁可缓存不持久，也不能用不了）。
 * 返回 1 = 用了环境变量给的目录；0 = 退回资源根。 */
static int pkg_cache_dir(char* out, size_t n)
{
    const char* want = getenv("BSH_PKG_CACHE");
    if (want && *want && dir_usable(want)) {
        snprintf(out, n, "%s", want);
        return 1;
    }
    under_root(out, n, REL_CACHE);
    mkdir_p(out);
    return 0;
}

static int file_sha256(const char* path, char out[65])
{
    FILE* f = fopen(path, "rb");
    if (!f)
        return -1;
    mbedtls_sha256_context c;
    mbedtls_sha256_init(&c);
    mbedtls_sha256_starts(&c, 0);            /* 0 = SHA-256（非 SHA-224） */
    unsigned char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0)
        mbedtls_sha256_update(&c, buf, n);
    int bad = ferror(f);
    fclose(f);
    if (bad) {
        mbedtls_sha256_free(&c);
        return -1;
    }
    unsigned char d[32];
    mbedtls_sha256_finish(&c, d);
    mbedtls_sha256_free(&c);
    for (int i = 0; i < 32; i++)
        sprintf(out + i * 2, "%02x", d[i]);
    out[64] = 0;
    return 0;
}

/* 源地址：<root>/pkgs/source 一行；没有就用默认 */
static void get_source(char* out, size_t outlen)
{
    char cfg[1200];
    out[0] = 0;
    under_root(cfg, sizeof cfg, REL_SOURCE);
    FILE* f = fopen(cfg, "r");
    if (f) {
        if (fgets(out, (int)outlen, f)) {
            size_t n = strlen(out);
            while (n && (out[n - 1] == '\n' || out[n - 1] == '\r' || out[n - 1] == ' '))
                out[--n] = 0;
        }
        fclose(f);
    }
    if (!out[0])
        snprintf(out, outlen, "%s", PKG_DEFAULT_SOURCE);
}

static void join_url(char* out, size_t outlen, const char* base, const char* file)
{
    size_t n = strlen(base);
    snprintf(out, outlen, "%s%s%s", base, (n && base[n - 1] == '/') ? "" : "/", file);
}

/* ── 已装清单 ───────────────────────────────────────────── */

/* 每个包最多记多少个文件。**动态数组**，因为包的大小差得很远：weston-terminal 几十个
 * 文件，而 ohos-sdk-prune 有 5 万个 —— 原来的固定 512 项会让"装得上、删不干净"
 * （remove 按这份清单删文件）。50k 条 ≈ 5 MB 内存，在设备上可以接受。 */
#define MAX_FILES_PER_PKG 200000

struct installed {
    char name[64];
    char version[32];
    char** files;            /* 动态数组：元素是 strdup 出来的相对安装根路径 */
    int nfiles;
    int cap;
};
static struct installed g_inst[MAX_INSTALLED];
static int g_ninst;

/* 追加一条；容量不够翻倍。返回 0 成功、-1（内存不足或到上限）。 */
static int inst_add_file(struct installed* e, const char* rel)
{
    if (e->nfiles >= e->cap) {
        int ncap = e->cap ? e->cap * 2 : 64;
        if (ncap > MAX_FILES_PER_PKG) ncap = MAX_FILES_PER_PKG;
        if (e->nfiles >= ncap) return -1;
        char** nf = (char**)realloc(e->files, (size_t)ncap * sizeof *nf);
        if (!nf) return -1;
        e->files = nf;
        e->cap = ncap;
    }
    char* dup = strdup(rel);
    if (!dup) return -1;
    e->files[e->nfiles++] = dup;
    return 0;
}

/* 释放一个条目的清单（不含条目本身）。释放后指针置空，重复调用安全。 */
static void inst_free(struct installed* e)
{
    for (int k = 0; k < e->nfiles; k++)
        free(e->files[k]);
    free(e->files);
    e->files = NULL;
    e->nfiles = 0;
    e->cap = 0;
}

static void installed_free_all(void)
{
    for (int i = 0; i < g_ninst; i++)
        inst_free(&g_inst[i]);
    g_ninst = 0;
}

static void installed_load(void)
{
    installed_free_all();
    char state[1200];
    under_root(state, sizeof state, REL_STATE);
    FILE* f = fopen(state, "r");
    if (!f)
        return;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz > 64 * 1024 * 1024) { fclose(f); return; }   /* 50k 文件的清单约 5MB */
    char* t = malloc((size_t)sz + 1);
    if (!t) { fclose(f); return; }
    if (fread(t, 1, (size_t)sz, f) != (size_t)sz) { free(t); fclose(f); return; }
    t[sz] = 0;
    fclose(f);

    bsh_json* root = bsh_json_parse(t);
    free(t);
    if (!root || root->type != BSH_JSON_OBJ) { bsh_json_free(root); return; }

    for (size_t i = 0; i < bsh_json_count(root) && g_ninst < MAX_INSTALLED; i++) {
        const char* nm = bsh_json_key(root, i);
        bsh_json* v = bsh_json_at(root, i);
        if (!nm || !v)
            continue;
        struct installed* e = &g_inst[g_ninst];
        memset(e, 0, sizeof *e);
        snprintf(e->name, sizeof e->name, "%s", nm);
        snprintf(e->version, sizeof e->version, "%s",
                 bsh_json_str(bsh_json_get(v, "version"), "?"));
        bsh_json* files = bsh_json_get(v, "files");
        for (size_t k = 0; k < bsh_json_count(files); k++) {
            const char* p = bsh_json_str(bsh_json_at(files, k), NULL);
            if (p && inst_add_file(e, p) != 0)
                break;                      /* 内存不足或到上限：这条清单就到这儿 */
        }
        g_ninst++;
    }
    bsh_json_free(root);
}

static struct installed* installed_find(const char* name)
{
    for (int i = 0; i < g_ninst; i++)
        if (strcmp(g_inst[i].name, name) == 0)
            return &g_inst[i];
    return NULL;
}

static int installed_save(void)
{
    char dir[1200], state[1200], tmp[1300];
    under_root(dir, sizeof dir, REL_PKGDIR);
    under_root(state, sizeof state, REL_STATE);
    snprintf(tmp, sizeof tmp, "%s.tmp", state);
    mkdir_p(dir);
    FILE* f = fopen(tmp, "w");
    if (!f) {
        printf("pkg: 写不了 %s：%s\n", tmp, strerror(errno));
        return -1;
    }
    fprintf(f, "{\n");
    for (int i = 0; i < g_ninst; i++) {
        fprintf(f, "  \"%s\": {\"version\": \"%s\", \"files\": [",
                g_inst[i].name, g_inst[i].version);
        for (int k = 0; k < g_inst[i].nfiles; k++)
            fprintf(f, "%s\"%s\"", k ? ", " : "", g_inst[i].files[k]);
        fprintf(f, "]}%s\n", (i + 1 < g_ninst) ? "," : "");
    }
    fprintf(f, "}\n");
    if (fclose(f) != 0) {
        printf("pkg: 写 %s 失败\n", tmp);
        return -1;
    }
    return rename(tmp, state) == 0 ? 0 : -1;
}

/* ── 远端清单 ───────────────────────────────────────────── */

static bsh_json* fetch_index(char* err, size_t errlen)
{
    char src[512], url[700];
    get_source(src, sizeof src);
    join_url(url, sizeof url, src, "index.json");
    printf("pkg: 取清单 %s\n", url);
    char* body = NULL;
    size_t len = 0;
    if (bsh_http_get_mem(url, &body, &len, err, errlen) != 0)
        return NULL;
    bsh_json* doc = bsh_json_parse(body);
    free(body);
    if (!doc) {
        snprintf(err, errlen, "清单不是合法 JSON");
        return NULL;
    }
    if (!bsh_json_get(doc, "packages")) {
        bsh_json_free(doc);
        snprintf(err, errlen, "清单里没有 packages 字段");
        return NULL;
    }
    return doc;
}

struct pkg_ref {
    const char* name;
    bsh_json* meta;
};

static int resolve_deps(bsh_json* doc, const char* name, struct pkg_ref* out,
                        int max, int* n, char* err, size_t errlen)
{
    bsh_json* meta = bsh_json_get(bsh_json_get(doc, "packages"), name);
    if (!meta) {
        snprintf(err, errlen, "源里没有包 %s", name);
        return -1;
    }
    for (int i = 0; i < *n; i++)
        if (strcmp(out[i].name, name) == 0)
            return 0;                        /* 已加入（顺带断开依赖环） */
    if (*n >= max) {
        snprintf(err, errlen, "依赖太多（> %d）", max);
        return -1;
    }
    bsh_json* deps = bsh_json_get(meta, "depends");
    for (size_t i = 0; i < bsh_json_count(deps); i++) {
        const char* d = bsh_json_str(bsh_json_at(deps, i), NULL);
        if (d && resolve_deps(doc, d, out, max, n, err, errlen) != 0)
            return -1;
    }
    out[*n].name = name;
    out[*n].meta = meta;
    (*n)++;
    return 0;
}

/* ── 子命令 ─────────────────────────────────────────────── */

static int cmd_list(void)
{
    char err[256];
    bsh_json* doc = fetch_index(err, sizeof err);
    if (!doc) {
        printf("pkg: %s\n", err);
        return 1;
    }
    installed_load();
    bsh_json* pkgs = bsh_json_get(doc, "packages");
    printf("%-18s %-10s %10s  %s\n", "包", "版本", "大小", "状态");
    for (size_t i = 0; i < bsh_json_count(pkgs); i++) {
        const char* nm = bsh_json_key(pkgs, i);
        bsh_json* m = bsh_json_at(pkgs, i);
        struct installed* ins = installed_find(nm);
        char state[64];
        if (ins)
            snprintf(state, sizeof state, "已装 %s", ins->version);
        else
            snprintf(state, sizeof state, "-");
        printf("%-18s %-10s %9ldK  %s\n", nm,
               bsh_json_str(bsh_json_get(m, "version"), "?"),
               bsh_json_int(bsh_json_get(m, "size"), 0) / 1024, state);
    }
    bsh_json_free(doc);
    return 0;
}

static int cmd_info(const char* name)
{
    char err[256];
    bsh_json* doc = fetch_index(err, sizeof err);
    if (!doc) {
        printf("pkg: %s\n", err);
        return 1;
    }
    bsh_json* m = bsh_json_get(bsh_json_get(doc, "packages"), name);
    if (!m) {
        printf("pkg: 源里没有包 %s\n", name);
        bsh_json_free(doc);
        return 1;
    }
    printf("name    : %s\n", name);
    printf("version : %s\n", bsh_json_str(bsh_json_get(m, "version"), "?"));
    printf("file    : %s\n", bsh_json_str(bsh_json_get(m, "file"), "?"));
    printf("size    : %ld\n", bsh_json_int(bsh_json_get(m, "size"), 0));
    printf("sha256  : %s\n", bsh_json_str(bsh_json_get(m, "sha256"), "?"));
    printf("dest    : %s\n", bsh_json_str(bsh_json_get(m, "dest"), "/"));
    printf("desc    : %s\n", bsh_json_str(bsh_json_get(m, "desc"), ""));
    printf("depends :");
    bsh_json* deps = bsh_json_get(m, "depends");
    for (size_t i = 0; i < bsh_json_count(deps); i++)
        printf(" %s", bsh_json_str(bsh_json_at(deps, i), "?"));
    printf("\n");
    bsh_json_free(doc);
    return 0;
}

/* tar 成员回调：记进文件清单 */
static int on_member(void* ctx, const char* rel)
{
    struct installed* e = ctx;
    /* 记不下就**中断解包**：装到一半却记不全清单，会造成"删不干净"的残留，
     * 不如当场失败（bsh_tar 见到非 0 就停）。 */
    return inst_add_file(e, rel) == 0 ? 0 : 1;
}

static int install_one(bsh_json* doc, const char* name, int force)
{
    char err[512], src[512], url[900], cache[1400];
    struct installed* old = installed_find(name);
    if (old && !force) {
        printf("pkg: %s %s 已装（--force 可重装）\n", name, old->version);
        return 0;
    }

    bsh_json* m = bsh_json_get(bsh_json_get(doc, "packages"), name);
    const char* file = bsh_json_str(bsh_json_get(m, "file"), NULL);
    const char* want_sha = bsh_json_str(bsh_json_get(m, "sha256"), NULL);
    const char* ver = bsh_json_str(bsh_json_get(m, "version"), "?");
    if (!file || !want_sha) {
        printf("pkg: 清单里 %s 缺 file/sha256\n", name);
        return 1;
    }

    mkdir_p(pkg_root());
    /* 缓存目录：环境变量 BSH_PKG_CACHE 给的（会话里默认是用户 Download 下那个，由
     * shell.cpp 导出）→ 没设或用不了就退回资源根下的 pkgs/cache。把结果打出来，
     * 用户一眼能看出缓存到底落在哪儿。 */
    char cdir[1400];
    int cache_persist = pkg_cache_dir(cdir, sizeof cdir);
    printf("pkg: 缓存目录 %s%s\n", cdir,
           cache_persist ? "" : "（BSH_PKG_CACHE 没设或用不了，已退回资源根）");
    get_source(src, sizeof src);
    join_url(url, sizeof url, src, file);
    snprintf(cache, sizeof cache, "%s/%s", cdir, file);

    /* 缓存里已有同 sha256 的包就用它，不再下载：SDK 这种包 250MB，设备上下一趟要
     * 十几分钟，`--force` 重装（或上次解包失败后重试）没必要再下一遍。
     * 校验不通过才去下载，下载完再校验一次（下面那段）。 */
    char got[65];
    int cached_ok = 0;
    if (file_sha256(cache, got) == 0 && strcasecmp(got, want_sha) == 0) {
        printf("pkg: 用缓存 %s（sha256 对得上）\n", cache);
        cached_ok = 1;
    }
    if (!cached_ok) {
        printf("pkg: 下载 %s\n", url);
        if (bsh_http_get_file(url, cache, err, sizeof err) != 0) {
            printf("pkg: 下载失败：%s\n", err);
            return 1;
        }
    }
    if (file_sha256(cache, got) != 0) {
        printf("pkg: 算 sha256 失败\n");
        return 1;
    }
    if (strcasecmp(got, want_sha) != 0) {
        printf("pkg: sha256 不匹配\n  期望 %s\n  实际 %s\n", want_sha, got);
        unlink(cache);
        return 1;
    }

    /* 解包：先记进临时条目，成功了再并入清单。
     * 包可能是 `*.tar.zst`（现在默认就是这个）：bsh_tar 只认未压缩 tar，所以先解成
     * <cache>.tar 再解包，用完删掉临时 tar。磁盘峰值 = 压缩包 + 解出来的 tar
     * （SDK 那个包 1.8 GiB，设备上 90+ GiB 可用，够）。 */
    const char* tar_path = cache;
    int had_temp_tar = 0;
    char temp_tar[1400];
    size_t flen = strlen(file);
    if (flen > 4 && strcmp(file + flen - 4, ".zst") == 0) {
        snprintf(temp_tar, sizeof temp_tar, "%s.tar", cache);
        printf("pkg: 解 zstd → %s\n", temp_tar);
        if (bsh_zstd_decompress_file(cache, temp_tar, err, sizeof err) != 0) {
            printf("pkg: zstd 解压失败：%s\n", err);
            return 1;
        }
        tar_path = temp_tar;
        had_temp_tar = 1;
    }

    struct installed newe;
    memset(&newe, 0, sizeof newe);
    snprintf(newe.name, sizeof newe.name, "%s", name);
    snprintf(newe.version, sizeof newe.version, "%s", ver);
    printf("pkg: 解包到 %s\n", pkg_root());
    if (bsh_tar_extract(tar_path, pkg_root(), on_member, &newe, err, sizeof err) != 0) {
        printf("pkg: 解包失败：%s\n", err);
        if (had_temp_tar) unlink(temp_tar);
        inst_free(&newe);
        return 1;
    }
    if (had_temp_tar) unlink(temp_tar);

    /* 清单的**所有权转移**：newe 的数组直接交给落点，然后把 newe 置空
     * （否则后面任何一条 return 路径上的 inst_free(&newe) 会二次释放）。 */
    if (old) {                                /* 覆盖安装：丢掉旧清单，接管新的 */
        inst_free(old);
        old->files = newe.files;
        old->nfiles = newe.nfiles;
        old->cap = newe.cap;
        newe.files = NULL; newe.nfiles = 0; newe.cap = 0;
        snprintf(old->version, sizeof old->version, "%s", ver);
    } else if (g_ninst < MAX_INSTALLED) {
        g_inst[g_ninst] = newe;
        newe.files = NULL; newe.nfiles = 0; newe.cap = 0;
        g_ninst++;
    } else {
        printf("pkg: 已装包太多（> %d）\n", MAX_INSTALLED);
        inst_free(&newe);
        return 1;
    }
    if (installed_save() != 0)
        return 1;
    /* 报数要从**落点**取：上面已经把自己的清单指针交给落点了（newe.nfiles 归零），
     * 从 newe 取会永远打印 0 —— 实测就这么错过一次。 */
    int nrec = old ? old->nfiles : (g_ninst > 0 ? g_inst[g_ninst - 1].nfiles : 0);
    printf("pkg: %s %s 安装完成（%d 个文件）\n", name, ver, nrec);
    return 0;
}

static int cmd_install(int argc, char** argv)
{
    int force = 0, nn = 0;
    char* names[32];
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--force") == 0 || strcmp(argv[i], "-f") == 0) {
            force = 1;
            continue;
        }
        if (nn < 32)
            names[nn++] = argv[i];
    }
    if (nn == 0) {
        printf("用法：pkg install [--force] <包名>…\n");
        return 2;
    }

    char err[512];
    bsh_json* doc = fetch_index(err, sizeof err);
    if (!doc) {
        printf("pkg: %s\n", err);
        return 1;
    }
    installed_load();

    struct pkg_ref refs[64];
    int n = 0;
    for (int i = 0; i < nn; i++) {
        if (resolve_deps(doc, names[i], refs, 64, &n, err, sizeof err) != 0) {
            printf("pkg: %s\n", err);
            bsh_json_free(doc);
            return 1;
        }
    }
    int rc = 0;
    for (int i = 0; i < n; i++) {
        if (install_one(doc, refs[i].name, force) != 0)
            rc = 1;
    }
    bsh_json_free(doc);
    return rc;
}

static int cmd_remove(const char* name)
{
    installed_load();
    struct installed* e = installed_find(name);
    if (!e) {
        printf("pkg: %s 没装\n", name);
        return 1;
    }
    char full[1400];
    int removed = 0;
    /* 倒序删（先文件后目录）；目录用 rmdir，非空就留着（无害） */
    for (int i = e->nfiles - 1; i >= 0; i--) {
        snprintf(full, sizeof full, "%s/%s", pkg_root(), e->files[i]);
        struct stat st;
        if (stat(full, &st) != 0)
            continue;
        if (S_ISDIR(st.st_mode)) {
            if (rmdir(full) == 0)
                removed++;
        } else if (unlink(full) == 0) {
            removed++;
        }
    }
    inst_free(e);
    int idx = (int)(e - g_inst);
    for (int i = idx; i + 1 < g_ninst; i++)
        g_inst[i] = g_inst[i + 1];           /* 浅拷贝：指针跟着搬到前一个槽 */
    g_ninst--;
    /* 搬完后最后那个槽里留着同一份指针的副本，得**丢掉**（清空）而不是释放 —— 
     * 否则下次 free_all 会二次释放同一块内存。 */
    memset(&g_inst[g_ninst], 0, sizeof g_inst[g_ninst]);
    if (installed_save() != 0)
        return 1;
    printf("pkg: %s 已卸载（删除 %d 项）\n", name, removed);
    return 0;
}

static int cmd_source(int argc, char** argv)
{
    char dir[1200], cfg[1300];
    under_root(dir, sizeof dir, REL_PKGDIR);
    under_root(cfg, sizeof cfg, REL_SOURCE);
    if (argc == 0) {
        char src[512];
        get_source(src, sizeof src);
        printf("源：%s\n", src);
        printf("（改：pkg source <url>，写进 %s）\n", cfg);
        return 0;
    }
    mkdir_p(dir);
    FILE* f = fopen(cfg, "w");
    if (!f) {
        printf("pkg: 写不了 %s：%s\n", cfg, strerror(errno));
        return 1;
    }
    fprintf(f, "%s\n", argv[0]);
    fclose(f);
    printf("源已改为：%s\n", argv[0]);
    return 0;
}

static int usage(void)
{
    char dir[1200], cdir[1400];
    under_root(dir, sizeof dir, REL_PKGDIR);
    (void)pkg_cache_dir(cdir, sizeof cdir);
    printf(
        "pkg — BetterSH 包管理器\n"
        "  pkg list                       列出源上的包与本地状态\n"
        "  pkg info <包名>                看一个包的详情\n"
        "  pkg install [--force] <包名>…  下载+校验+解包（自动带依赖）\n"
        "  pkg remove <包名>              按安装记录删除文件\n"
        "  pkg source [url]               查看/设置包源\n"
        "\n"
        "安装根：%s（installed.json source 也在这儿）\n"
        "缓存  ：%s（改：export BSH_PKG_CACHE=<目录>）\n", dir, cdir);
    return 0;
}

int pkg_main(int argc, char** argv)
{
    /* 输出按行刷。默认 stdio 在重定向到文件时是全缓冲的，一旦进程被信号打死，
     * 已经打印的内容会整段丢掉（实测踩过：日志停在“取清单”，后面的下载/解包全没了，
     * 根本看不出死在哪一步）。pkg 是给终端用的工具，逐行刷更合适。 */
    setvbuf(stdout, NULL, _IOLBF, 0);

    if (argc < 2)
        return usage();
    const char* sub = argv[1];
    if (strcmp(sub, "list") == 0)                 return cmd_list();
    if (strcmp(sub, "info") == 0) {
        if (argc < 3) { printf("用法：pkg info <包名>\n"); return 2; }
        return cmd_info(argv[2]);
    }
    if (strcmp(sub, "install") == 0)              return cmd_install(argc - 2, argv + 2);
    if (strcmp(sub, "remove") == 0) {
        if (argc < 3) { printf("用法：pkg remove <包名>\n"); return 2; }
        return cmd_remove(argv[2]);
    }
    if (strcmp(sub, "source") == 0)               return cmd_source(argc - 2, argv + 2);
    return usage();
}
