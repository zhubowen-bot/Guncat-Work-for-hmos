// apt_main.c — `apt` 命令 so：从镜像解析依赖树、下载 .deb、装进 sysroot
//
// 与 pkg 的关系：同一个 so（libpkg.so）的第三个入口，共用 mbedTLS / bsh_http /
// bsh_tar / bsh_zstd / bsh_json（见 programs/pkg/CMakeLists.txt）。apt 另加了
// zlib（读 Packages.gz）、bsh_deb（ar 解析）、bsh_pkgindex（包索引）、bsh_depends
// （依赖求解）。记账文件与 pkg **分开**（pkgs/apt-installed.json），两套语义不混。
//
// 用法（用户给的例子）：
//     apt install ./code_1.141.0-1234_arm64.deb
// 会读该 deb 的 control 拿到 Depends，递归查索引得到依赖闭包，把依赖下载到缓存目录
// 再逐个解包安装。镜像地址由环境变量指定：
//
//     BSH_APT_MIRROR      镜像根，默认 http://ports.ubuntu.com/ubuntu-ports
//     BSH_APT_SUITE       代号，默认 noble
//     BSH_APT_COMPONENTS  空格分隔，默认 main（可 main universe）
//     BSH_APT_ARCH        架构，默认按编译目标推（arm64 / amd64）
//     BSH_APT_CACHE       缓存根，默认沿用 BSH_PKG_CACHE
//     BSH_APT_EXCLUDE_EXTRA / BSH_APT_EXCLUDE_NONE   排除名单的增/清
//     BSH_PKG_ROOT        安装根覆盖（沿用 pkg 的，宿主机测试用）
//
// 三条从实战里来的纪律：
//   1. **系统库不装**。vscode 依赖 libc6/libgcc-s1/libstdc++6，而它们由我们自编的
//      glibc 提供（bundle libs）。从 deb 装一份不配套的进来，会让 ld.so 与 libc 的
//      TLS/内部 ABI 对不上（实测 glib-compile-schemas 在 ____strtod_l_internal 里崩）。
//      所以有一份默认排除名单。
//   2. **软链要代偿**。沙箱里 symlink(2) 被拒，deb 里的软链解了等于没解。库软链
//      （含 ".so"）复制成真文件，命令软链（bin 下）生成 sh 包装脚本。
//   3. **目标已存在就不覆盖**（除非 --overwrite）。这条正是"usr/bin 下不存在就创建、
//      已经存在就不新建"的落地。
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "bsh_deb.h"
#include "bsh_depends.h"
#include "bsh_http.h"
#include "bsh_json.h"
#include "bsh_pkgindex.h"
#include "bsh_tar.h"
#include "common/bsh_paths.h"

/* ── 常量 ───────────────────────────────────────────────────────────────── */

#define REL_PKGDIR   "/pkgs"
#define REL_APTSTATE "/pkgs/apt-installed.json"
#define REL_APTSRC   "/pkgs/apt-source"

/* 默认镜像见 common/bsh_paths.h 的 BSH_APT_MIRROR_DEFAULT（.bshrc 也用它导出一份） */
#define APT_DEFAULT_MIRROR BSH_APT_MIRROR_DEFAULT
#define APT_DEFAULT_SUITE  "noble"
#define APT_DEFAULT_COMPS  "main"
/* 由 BetterSH 自己提供、绝不能从 deb 装的包。libc6 系是根因（见文件头纪律 1），
 * libstdc++/libgcc 同理跟着我们那份 glibc 走。 */
#define APT_DEFAULT_EXCLUDE "libc6 libc6-dev libgcc-s1 libstdc++6 libcrypt1 gcc-14-base"

/* 用户自己下好 deb 的公共目录（装机/卸载都不会清它）。下载前先来这里找同名文件 ——
 * 设备直连官方镜像实测只有几 KB/s，能复用就绝不再下一次。与 vscode-download.sh 同款做法。 */
#define APT_DEFAULT_PUB "/storage/Users/currentUser/Download/com.yiyan.bettersh"

/* 记账能放多少个包。vscode 那套依赖实测 225 个（含传递依赖），64 会从第 65 个开始
 * 全部"已装包太多"拒掉 —— 实测就这么漏装过一半。 */
#define APT_MAX_PKGS  512
#define APT_MAX_FILES 200000
#define INDEX_MAX_AGE (7 * 24 * 3600)      /* 索引缓存 7 天 */

/* ── 配置 ───────────────────────────────────────────────────────────────── */

struct apt_cfg {
    char root[1024];        /* 安装根 */
    char mirror[512];
    char suite[64];
    char comps[128];
    char arch[16];
    char cache[1200];       /* 缓存根，apt 的东西都在它下面 */
    char exclude[512];
    char flatten[1024];     /* 非空则把库平铺一份到这里 */
    char write_list[1024];  /* 非空则把解出来的包清单（一行一个）写到这里 */
    int  flatten_move;
    int  overwrite;
    int  dry_run;
    int  force;
};

static const char* default_arch(void)
{
    const char* e = getenv("BSH_APT_ARCH");
    if (e && *e)
        return e;
#if defined(__aarch64__)
    return "arm64";
#elif defined(__x86_64__)
    return "amd64";
#else
    return "arm64";
#endif
}

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

static int path_exists(const char* p)
{
    struct stat st;
    return lstat(p, &st) == 0;
}

/* 目录能不能真用：建出来 + 写一个探针文件（只看 access 不够可靠） */
static int dir_usable(const char* dir)
{
    mkdir_p(dir);
    char probe[1500];
    if (snprintf(probe, sizeof probe, "%s/.apt-probe", dir) >= (int)sizeof probe)
        return 0;
    FILE* f = fopen(probe, "w");
    if (!f)
        return 0;
    fputs("ok", f);
    int ok = (fclose(f) == 0);
    unlink(probe);
    return ok;
}

/* <root><rel> */
static void under_root(const struct apt_cfg* c, char* out, size_t n, const char* rel)
{
    snprintf(out, n, "%s%s", c->root, rel);
}

static void cfg_init(struct apt_cfg* c)
{
    memset(c, 0, sizeof *c);

    const char* root = getenv("BSH_PKG_ROOT");
    if (!root || !*root)
        root = bsh_sysroot();
    snprintf(c->root, sizeof c->root, "%s", root);

    const char* v;
    v = getenv("BSH_APT_MIRROR");
    snprintf(c->mirror, sizeof c->mirror, "%s", (v && *v) ? v : APT_DEFAULT_MIRROR);
    v = getenv("BSH_APT_SUITE");
    snprintf(c->suite, sizeof c->suite, "%s", (v && *v) ? v : APT_DEFAULT_SUITE);
    v = getenv("BSH_APT_COMPONENTS");
    snprintf(c->comps, sizeof c->comps, "%s", (v && *v) ? v : APT_DEFAULT_COMPS);
    snprintf(c->arch, sizeof c->arch, "%s", default_arch());

    /* 缓存根：BSH_APT_CACHE → BSH_PKG_CACHE → <root>/pkgs/cache。三级都要能真写。
     * 与 pkg 同一个思路：环境变量给的目录不可用就退回资源根，宁可缓存不持久。 */
    const char* cand = getenv("BSH_APT_CACHE");
    if (!cand || !*cand)
        cand = getenv("BSH_PKG_CACHE");
    if (cand && *cand && dir_usable(cand)) {
        snprintf(c->cache, sizeof c->cache, "%s", cand);
    } else {
        char fallback[1200];
        under_root(c, fallback, sizeof fallback, "/pkgs/cache");
        mkdir_p(fallback);
        snprintf(c->cache, sizeof c->cache, "%s", fallback);
    }

    /* 排除名单 */
    const char* none = getenv("BSH_APT_EXCLUDE_NONE");
    if (none && *none && strcmp(none, "0") != 0) {
        c->exclude[0] = 0;
    } else {
        snprintf(c->exclude, sizeof c->exclude, "%s", APT_DEFAULT_EXCLUDE);
        const char* extra = getenv("BSH_APT_EXCLUDE_EXTRA");
        if (extra && *extra) {
            size_t l = strlen(c->exclude);
            snprintf(c->exclude + l, sizeof c->exclude - l, " %s", extra);
        }
    }
}

/* 源地址：<root>/pkgs/apt-source 一行；没有就用环境变量/默认 */
static void cfg_source(struct apt_cfg* c)
{
    char cfg[1300];
    under_root(c, cfg, sizeof cfg, REL_APTSRC);
    FILE* f = fopen(cfg, "r");
    if (!f)
        return;
    char line[512] = {0};
    if (fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r' || line[n - 1] == ' '))
            line[--n] = 0;
        if (line[0]) {
            /* 只覆盖 mirror；suite/components 若要改就直接给环境变量 */
            snprintf(c->mirror, sizeof c->mirror, "%s", line);
        }
    }
    fclose(f);
}

static void cfg_index_src(const struct apt_cfg* c, struct bsh_apt_src* s)
{
    s->mirror = c->mirror;
    s->suite = c->suite;
    s->comps = c->comps;
    s->arch = c->arch;
    s->cache_dir = c->cache;
    s->max_age_sec = INDEX_MAX_AGE;
}

/* ── 安装记账（与 pkg 的 installed.json 分开，语义不同） ─────────────────── */

struct apt_inst {
    char name[96];
    char version[48];
    char** files;
    int nfiles, cap;
};
static struct apt_inst g_inst[APT_MAX_PKGS];
static int g_ninst;

static int inst_add_file(struct apt_inst* e, const char* rel)
{
    if (e->nfiles >= e->cap) {
        int ncap = e->cap ? e->cap * 2 : 64;
        if (ncap > APT_MAX_FILES) ncap = APT_MAX_FILES;
        if (e->nfiles >= ncap) return -1;
        char** nf = (char**)realloc(e->files, (size_t)ncap * sizeof *nf);
        if (!nf) return -1;
        e->files = nf;
        e->cap = ncap;
    }
    char* d = strdup(rel);
    if (!d) return -1;
    e->files[e->nfiles++] = d;
    return 0;
}

static void inst_free(struct apt_inst* e)
{
    for (int i = 0; i < e->nfiles; i++) free(e->files[i]);
    free(e->files);
    e->files = NULL;
    e->nfiles = e->cap = 0;
}

static struct apt_inst* inst_find(const char* name)
{
    for (int i = 0; i < g_ninst; i++)
        if (strcmp(g_inst[i].name, name) == 0)
            return &g_inst[i];
    return NULL;
}

/* 记账文件是我们自己写的极简 JSON，格式与 pkg 的一致：
 *   { "包名": {"version": "…", "files": ["路径", …]}, … }
 * 用 bsh_json 解析（它已经编在同一个 so 里，比自己手搓扫描可靠）。 */
static void inst_load(const struct apt_cfg* c)
{
    for (int i = 0; i < g_ninst; i++) inst_free(&g_inst[i]);
    g_ninst = 0;

    char state[1300];
    under_root(c, state, sizeof state, REL_APTSTATE);
    FILE* f = fopen(state, "r");
    if (!f)
        return;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz > 64 * 1024 * 1024) { fclose(f); return; }
    char* t = (char*)malloc((size_t)sz + 1);
    if (!t) { fclose(f); return; }
    if (fread(t, 1, (size_t)sz, f) != (size_t)sz) { free(t); fclose(f); return; }
    t[sz] = 0;
    fclose(f);

    bsh_json* root = bsh_json_parse(t);
    free(t);
    if (!root || root->type != BSH_JSON_OBJ) { bsh_json_free(root); return; }

    for (size_t i = 0; i < bsh_json_count(root) && g_ninst < APT_MAX_PKGS; i++) {
        const char* nm = bsh_json_key(root, i);
        bsh_json* v = bsh_json_at(root, i);
        if (!nm || !v)
            continue;
        struct apt_inst* e = &g_inst[g_ninst];
        memset(e, 0, sizeof *e);
        snprintf(e->name, sizeof e->name, "%s", nm);
        snprintf(e->version, sizeof e->version, "%s",
                 bsh_json_str(bsh_json_get(v, "version"), "?"));
        bsh_json* files = bsh_json_get(v, "files");
        for (size_t k = 0; k < bsh_json_count(files); k++) {
            const char* p = bsh_json_str(bsh_json_at(files, k), NULL);
            if (p && inst_add_file(e, p) != 0)
                break;
        }
        g_ninst++;
    }
    bsh_json_free(root);
}

static int inst_save(const struct apt_cfg* c)
{
    char dir[1200], state[1300], tmp[1400];
    under_root(c, dir, sizeof dir, REL_PKGDIR);
    under_root(c, state, sizeof state, REL_APTSTATE);
    snprintf(tmp, sizeof tmp, "%s.tmp", state);
    mkdir_p(dir);
    FILE* f = fopen(tmp, "w");
    if (!f) {
        printf("apt: 写不了 %s：%s\n", tmp, strerror(errno));
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
        printf("apt: 写 %s 失败\n", tmp);
        return -1;
    }
    return rename(tmp, state) == 0 ? 0 : -1;
}

/* ── 小 IO ──────────────────────────────────────────────────────────────── */

static int copy_file(const char* src, const char* dst)
{
    FILE* in = fopen(src, "rb");
    if (!in)
        return -1;
    FILE* out = fopen(dst, "wb");
    if (!out) { fclose(in); return -1; }
    char buf[128 * 1024];
    size_t n;
    int rc = 0;
    while ((n = fread(buf, 1, sizeof buf, in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) { rc = -1; break; }
    }
    if (ferror(in)) rc = -1;
    fclose(in);
    if (fclose(out) != 0) rc = -1;
    if (rc != 0) unlink(dst);
    return rc;
}

/* 把 <root>/<rel> 的父目录建出来（就地改 buf 的副本） */
static void mkdir_parent(const char* root, const char* rel)
{
    char p[1500];
    if (snprintf(p, sizeof p, "%s/%s", root, rel) >= (int)sizeof p)
        return;
    char* slash = strrchr(p, '/');
    if (slash && slash > p) {
        *slash = 0;
        mkdir_p(p);
    }
}

/* ── 软链代偿 ───────────────────────────────────────────────────────────── */

struct link_fixup {
    char rel[400];
    char target[400];
    char owner[96];           /* 这个链接属于哪个包 —— 代偿出来的文件要记进它的清单，
                               * 否则 apt remove 会漏删（实测漏过一次）。
                               * 存**包名**而不是指针：安装时用的是栈上的临时条目，
                               * 它随后被拷进 g_inst，指针当场就失效了。 */
    int  done;
};
struct link_list {
    struct link_fixup* v;
    int n, cap;
};

static int link_push(struct link_list* ll, const char* rel, const char* target,
                     const char* owner)
{
    if (ll->n >= ll->cap) {
        int ncap = ll->cap ? ll->cap * 2 : 256;
        struct link_fixup* nv =
            (struct link_fixup*)realloc(ll->v, (size_t)ncap * sizeof *nv);
        if (!nv)
            return -1;
        ll->v = nv;
        ll->cap = ncap;
    }
    struct link_fixup* f = &ll->v[ll->n++];
    snprintf(f->rel, sizeof f->rel, "%s", rel);
    snprintf(f->target, sizeof f->target, "%s", target);
    snprintf(f->owner, sizeof f->owner, "%s", owner ? owner : "");
    f->done = 0;
    return 0;
}

/* 把链接解析成"相对 root 的路径"。越界（.. 冒到根外）返回 -1。 */
static int resolve_link(const char* rel, const char* target, char* out, size_t outlen)
{
    char buf[800];
    if (target[0] == '/') {
        snprintf(buf, sizeof buf, "%s", target + 1);      /* tar 里的绝对链接按 root 看待 */
    } else {
        char dir[600];
        snprintf(dir, sizeof dir, "%s", rel);
        char* slash = strrchr(dir, '/');
        if (slash) *slash = 0; else dir[0] = 0;
        if (dir[0]) snprintf(buf, sizeof buf, "%s/%s", dir, target);
        else        snprintf(buf, sizeof buf, "%s", target);
    }

    /* 规范化：拆分量、吃掉 "."、处理 ".." */
    char parts[48][128];
    int np = 0;
    char* p = buf;
    while (*p) {
        while (*p == '/') p++;
        if (!*p) break;
        char* e = p;
        while (*e && *e != '/') e++;
        size_t n = (size_t)(e - p);
        if (n == 1 && p[0] == '.') { p = e; continue; }
        if (n == 2 && p[0] == '.' && p[1] == '.') {
            if (np == 0) return -1;
            np--;
            p = e;
            continue;
        }
        if (np >= 48) return -1;
        if (n >= sizeof parts[0]) n = sizeof parts[0] - 1;
        memcpy(parts[np], p, n);
        parts[np][n] = 0;
        np++;
        p = e;
    }
    char o[800];
    size_t w = 0;
    o[0] = 0;
    for (int i = 0; i < np; i++) {
        size_t l = strlen(parts[i]);
        if (w + l + 2 >= sizeof o) return -1;
        if (w) o[w++] = '/';
        memcpy(o + w, parts[i], l);
        w += l;
        o[w] = 0;
    }
    if (!o[0]) return -1;
    snprintf(out, outlen, "%s", o);
    return 0;
}

/* 库名（.so / .so.1 / .so.1.2）：这种软链必须落成真文件 —— dlopen 打不开 shell 脚本 */
static int is_lib_name(const char* rel)
{
    const char* base = strrchr(rel, '/');
    base = base ? base + 1 : rel;
    return strstr(base, ".so") != NULL;
}

/* 命令软链：生成一个 sh 包装脚本（比复制 200MB 的 code 本体省太多）。
 *
 * ⚠ 必须用 `exec -a` 保住 **argv[0]** —— deb 里的软链是"内核级的改名 exec"：
 * `usr/bin/git-upload-pack -> git` 执行起来 argv[0] 就是 "git-upload-pack"，而 git
 * 正是靠这个 basename 分发到 upload-pack 子命令（dashed built-in 机制）。普通 wrapper
 * 会把 argv[0] 变成真正的二进制名，于是 git 把**路径**当成了子命令：
 *     git: '/data/…/gtest/.git' is not a git command
 * 实测就是这么栽的（本地 clone 直接失败）。同类程序还有 busybox/toybox/dropbear ——
 * 凡是"按 argv[0] 分发"的都会中招。
 *
 * 取 basename 用的是 shell 参数展开（对 0 号参数做"删到最后一个斜杠"的模式删除，
 * 不 fork）；`exec -a` 是 ksh 系扩展，而我们的 guest sh 正是 mksh
 * （$SYSROOT/bin/sh → libmksh.so），两者都可用。
 *
 * ⚠ 写这类注释时别把那个参数展开原样敲进来 —— 它含有"星号紧挨斜杠"的序列，会**提前
 * 结束 C 注释**（实测：编译报 "extraneous closing brace"，后面整段中文变成代码）。 */
static int write_wrapper(const char* out, const char* root, const char* tgt_rel)
{
    FILE* f = fopen(out, "w");
    if (!f)
        return -1;
    fprintf(f,
            "#!/bin/sh\n"
            "# 由 BetterSH 的 apt 生成：代替 .deb 里的符号链接（沙箱禁 symlink）\n"
            "R=\"${BSH_SYSROOT:-%s}\"\n"
            "exec -a \"${0##*/}\" \"$R/%s\" \"$@\"\n",
            root, tgt_rel);
    if (fclose(f) != 0) { unlink(out); return -1; }
    chmod(out, 0755);
    return 0;
}

static int apply_links(struct apt_cfg* c, struct link_list* ll)
{
    if (ll->n == 0)
        return 0;
    int made = 0;
    /* 链式软链（a→b→c）第一轮里源的源还没到位，多跑几轮自然收敛 */
    for (int round = 0; round < 4; round++) {
        int progressed = 0;
        for (int i = 0; i < ll->n; i++) {
            struct link_fixup* f = &ll->v[i];
            if (f->done)
                continue;

            char tgt_rel[800];
            if (resolve_link(f->rel, f->target, tgt_rel, sizeof tgt_rel) != 0) {
                f->done = 1;
                continue;
            }
            char src[1500];
            snprintf(src, sizeof src, "%s/%s", c->root, tgt_rel);
            struct stat st;
            if (stat(src, &st) != 0)
                continue;                       /* 源还没到，下轮再说 */

            char out[1500];
            snprintf(out, sizeof out, "%s/%s", c->root, f->rel);
            /* 已经存在就不新建（用户明确要 --overwrite 时才重写）。
             * 注意这一条也会挡住"wrapper 生成逻辑改了、想让它重写一遍"的场景 ——
             * 那种情况得 `--overwrite`（或者先删掉旧的），否则会一直用着老版本
             * （实测：改了 exec -a 之后重装，代偿数仍是 0，链上去的还是旧 wrapper）。 */
            if (path_exists(out) && !c->overwrite) {
                f->done = 1;
                continue;
            }
            mkdir_parent(c->root, f->rel);

            int rc;
            if (S_ISDIR(st.st_mode))
                rc = mkdir(out, 0755);
            else if (is_lib_name(f->rel))
                rc = copy_file(src, out);
            else
                rc = write_wrapper(out, c->root, tgt_rel);

            if (rc == 0) {
                f->done = 1;
                made++;
                progressed = 1;
                /* 记进所属包的清单，apt remove 才能一起删掉（只有真做了才记：
                 * "目标已存在所以没动"的那些不属于我们，删的时候不该碰） */
                struct apt_inst* own = inst_find(f->owner);
                if (own)
                    inst_add_file(own, f->rel);
            }
        }
        if (!progressed)
            break;
    }
    int left = 0, shown = 0;
    for (int i = 0; i < ll->n; i++) {
        if (ll->v[i].done)
            continue;
        left++;
        /* 只报前几个，够看出是"哪一类"问题（大多是被排除掉的那几个包提供的库） */
        if (shown < 5) {
            char tgt[800];
            int bad = resolve_link(ll->v[i].rel, ll->v[i].target, tgt, sizeof tgt) != 0;
            printf("apt:   没做成：%s -> %s（%s）\n", ll->v[i].rel, ll->v[i].target,
                   bad ? "链接目标越界" : "源还没到位");
            shown++;
        }
    }
    printf("apt: 代偿链接 %d 个", made);
    if (left)
        printf("，另有 %d 个没做成（多为被排除包提供的库）", left);
    printf("\n");
    return 0;
}

/* ── 安装一个 deb ───────────────────────────────────────────────────────── */

struct extract_ctx {
    struct apt_cfg* cfg;
    struct apt_inst* rec;
    struct link_list* links;
    int n_skip;
};

/* tar 成员名一律带 "./" 前缀（deb 就是这么打的）。记账里存规范化后的相对路径，
 * 免得每个用它的地方（flatten / remove）都要自己剥一遍。 */
static const char* strip_dotslash(const char* rel)
{
    while (rel[0] == '.' && rel[1] == '/')
        rel += 2;
    return rel;
}

static int on_member(void* ctx, const char* rel)
{
    struct extract_ctx* x = (struct extract_ctx*)ctx;
    return inst_add_file(x->rec, strip_dotslash(rel)) == 0 ? 0 : 1;
}

static int on_link(void* ctx, const char* rel, const char* target)
{
    struct extract_ctx* x = (struct extract_ctx*)ctx;
    return link_push(x->links, strip_dotslash(rel), target, x->rec->name) == 0 ? 0 : 1;
}

/* 目标已存在 → 跳过解包（"已经存在就不新建"） */
static int on_skip(void* ctx, const char* rel)
{
    struct extract_ctx* x = (struct extract_ctx*)ctx;
    char full[1500];
    if (snprintf(full, sizeof full, "%s/%s", x->cfg->root, rel) >= (int)sizeof full)
        return 0;
    if (path_exists(full)) {
        x->n_skip++;
        return 1;
    }
    return 0;
}

static int apt_install_one(struct extract_ctx* x, const char* debpath)
{
    struct apt_cfg* c = x->cfg;
    char err[512];

    static const char* kData[] = { "data.tar.zst", "data.tar.gz", "data.tar.xz", "data.tar", NULL };
    struct bsh_deb_member m;
    int found = 0;
    for (int i = 0; kData[i]; i++) {
        int r = bsh_deb_find_member(debpath, kData[i], &m, err, sizeof err);
        if (r < 0) {
            printf("apt: %s\n", err);
            return -1;
        }
        if (r == 1) { found = 1; break; }
    }
    if (!found) {
        printf("apt: %s 里没有 data.tar.*\n", debpath);
        return -1;
    }

    /* data.tar 先解成裸 tar 再交给 bsh_tar —— 与 pkg 的做法一致 */
    char tmpdir[1300], tmp[1400];
    snprintf(tmpdir, sizeof tmpdir, "%s/apt/tmp", c->cache);
    mkdir_p(tmpdir);
    snprintf(tmp, sizeof tmp, "%s/%s.tar", tmpdir, x->rec->name);
    if (bsh_deb_unpack_member(debpath, &m, tmp, err, sizeof err) != 0) {
        printf("apt: 解 %s 失败：%s\n", m.name, err);
        return -1;
    }

    struct bsh_tar_hooks hooks;
    hooks.on_member = on_member;
    hooks.on_link = on_link;
    hooks.skip = c->overwrite ? NULL : on_skip;

    if (bsh_tar_extract_h(tmp, c->root, &hooks, x, err, sizeof err) != 0) {
        printf("apt: 解包失败：%s\n", err);
        unlink(tmp);
        return -1;
    }
    unlink(tmp);
    return 0;
}

/* ── flatten ────────────────────────────────────────────────────────────── */

static int apply_flatten(struct apt_cfg* c)
{
    if (!c->flatten[0])
        return 0;
    mkdir_p(c->flatten);
    int n = 0;
    for (int i = 0; i < g_ninst; i++) {
        for (int k = 0; k < g_inst[i].nfiles; k++) {
            /* 记账里已经是规范化路径，这里再剥一次纯粹为了兼容上一版写下的旧记账 */
            const char* rel = strip_dotslash(g_inst[i].files[k]);
            if (strncmp(rel, "usr/lib/", 8) != 0)
                continue;
            const char* base = strrchr(rel, '/');
            base = base ? base + 1 : rel;
            if (!strstr(base, ".so"))
                continue;
            char src[1500], dst[1500];
            snprintf(src, sizeof src, "%s/%s", c->root, rel);
            snprintf(dst, sizeof dst, "%s/%s", c->flatten, base);
            if (strcmp(src, dst) == 0)
                continue;
            struct stat st;
            if (stat(src, &st) != 0 || !S_ISREG(st.st_mode))
                continue;
            if (path_exists(dst))
                continue;
            if (copy_file(src, dst) == 0) {
                n++;
                if (c->flatten_move)
                    unlink(src);
            }
        }
    }
    printf("apt: 平铺 %d 个库到 %s\n", n, c->flatten);
    return 0;
}

/* ── 下载 ───────────────────────────────────────────────────────────────── */

/* 缓存里已有（存在即算，索引给了 sha256 的话可以再校验）就跳过 */
static int fetch_deb(struct apt_cfg* c, const struct bsh_apt_entry* e,
                     char* debpath_out, size_t outlen)
{
    char adir[1300];
    snprintf(adir, sizeof adir, "%s/apt/debs", c->cache);
    mkdir_p(adir);

    const char* base = strrchr(e->filename, '/');
    base = base ? base + 1 : e->filename;
    snprintf(debpath_out, outlen, "%s/%s", adir, base);

    struct stat st;
    if (stat(debpath_out, &st) == 0 && st.st_size > 0) {
        if (e->size <= 0 || st.st_size == e->size)
            return 0;                                   /* 缓存命中 */
    }

    /* 用户自己下好的（公共目录）优先于联网下载 —— 设备直连镜像只有几 KB/s，
     * 46MB 要下到天荒地老。size 对得上才用，免得拿半截文件。 */
    const char* pub = getenv("BSH_APT_PUB");
    if (!pub || !*pub)
        pub = APT_DEFAULT_PUB;
    if (pub && *pub) {
        char src[1500];
        if (snprintf(src, sizeof src, "%s/%s", pub, base) < (int)sizeof src) {
            struct stat ps;
            if (stat(src, &ps) == 0 && ps.st_size > 0 &&
                (e->size <= 0 || ps.st_size == e->size)) {
                if (copy_file(src, debpath_out) == 0) {
                    printf("apt: 从公共目录取 %s\n", base);
                    return 0;
                }
            }
        }
    }

    char url[900];
    size_t ml = strlen(c->mirror);
    snprintf(url, sizeof url, "%s%s%s", c->mirror,
             (ml && c->mirror[ml - 1] == '/') ? "" : "/", e->filename);

    printf("apt: 下载 %s\n", base);
    char err[512];
    if (bsh_http_get_file(url, debpath_out, err, sizeof err) != 0) {
        printf("apt: 下载失败 %s：%s\n", url, err);
        return -1;
    }
    if (stat(debpath_out, &st) != 0 || st.st_size <= 0) {
        printf("apt: %s 落地是空的\n", base);
        return -1;
    }
    if (e->size > 0 && st.st_size != e->size)
        printf("apt: 警告 %s 大小与索引不符（索引 %lld，实际 %lld）\n",
               base, e->size, (long long)st.st_size);
    return 0;
}

/* ── install ────────────────────────────────────────────────────────────── */

struct target {
    char spec[1024];      /* 用户给的原样（路径或包名） */
    char name[96];        /* 包名（本地 deb 会先从 control 读出来） */
    char version[48];
    char debpath[1024];   /* 本地 deb 的路径；空 = 需要从索引下载 */
    char depends[4096];   /* 本地 deb 的 Depends（供求解时当作根包的依赖） */
};

/* 本地 .deb：读 control 拿包名与依赖 */
static int inspect_deb(const struct apt_cfg* c, struct target* t, char* err, size_t errlen)
{
    char* ctrl = NULL;
    size_t clen = 0;
    char tmpdir[1300];
    snprintf(tmpdir, sizeof tmpdir, "%s/apt/tmp", c->cache);
    mkdir_p(tmpdir);

    if (bsh_deb_read_control(t->spec, tmpdir, &ctrl, &clen, err, errlen) != 0)
        return -1;
    (void)clen;

    if (!bsh_deb_field(ctrl, "Package", t->name, sizeof t->name) || !t->name[0]) {
        snprintf(err, errlen, "%s 的 control 里没有 Package 字段", t->spec);
        free(ctrl);
        return -1;
    }
    if (!bsh_deb_field(ctrl, "Version", t->version, sizeof t->version))
        snprintf(t->version, sizeof t->version, "?");
    if (!bsh_deb_field(ctrl, "Depends", t->depends, sizeof t->depends))
        t->depends[0] = 0;
    snprintf(t->debpath, sizeof t->debpath, "%s", t->spec);
    free(ctrl);
    return 0;
}

static int is_url(const char* s)
{
    return strncmp(s, "http://", 7) == 0 || strncmp(s, "https://", 8) == 0;
}

static int looks_like_path(const char* s)
{
    if (strchr(s, '/'))
        return 1;
    size_t l = strlen(s);
    return l > 4 && strcmp(s + l - 4, ".deb") == 0;
}

static int cmd_install(int argc, char** argv)
{
    struct apt_cfg cfg;
    cfg_init(&cfg);
    cfg_source(&cfg);

    /* 128 × 6KB ≈ 800KB：放 BSS（static），别压在栈上 */
    static struct target tg[256];
    int nt = 0;
    for (int i = 0; i < argc; i++) {
        const char* a = argv[i];
        if (strcmp(a, "--dry-run") == 0 || strcmp(a, "-n") == 0) { cfg.dry_run = 1; continue; }
        if (strcmp(a, "--force") == 0 || strcmp(a, "-f") == 0)   { cfg.force = 1; continue; }
        if (strcmp(a, "--overwrite") == 0)                      { cfg.overwrite = 1; continue; }
        if (strcmp(a, "--flatten") == 0 && i + 1 < argc) {
            snprintf(cfg.flatten, sizeof cfg.flatten, "%s", argv[++i]);
            continue;
        }
        if (strcmp(a, "--flatten-move") == 0 && i + 1 < argc) {
            snprintf(cfg.flatten, sizeof cfg.flatten, "%s", argv[++i]);
            cfg.flatten_move = 1;
            continue;
        }
        if (strcmp(a, "--write-list") == 0 && i + 1 < argc) {
            snprintf(cfg.write_list, sizeof cfg.write_list, "%s", argv[++i]);
            continue;
        }
        if (a[0] == '-' && a[1]) {
            printf("apt: 不认识的选项 %s\n", a);
            return 2;
        }
        if (nt >= 256) {
            printf("apt: 一次装不了这么多（> 256）\n");
            return 2;
        }
        memset(&tg[nt], 0, sizeof tg[nt]);
        snprintf(tg[nt].spec, sizeof tg[nt].spec, "%s", a);
        nt++;
    }
    if (nt == 0) {
        printf("用法：apt install [--dry-run] [--force] [--overwrite] "
               "[--flatten DIR] [--write-list FILE] <deb路径|URL|包名>…\n");
        return 2;
    }

    char err[512] = {0};

    /* ① 本地 .deb 先看 control（拿包名与 Depends）。
     * 读不动 control 也**不中断** —— 用文件名推包名兜底（deb 的命名是
     * <name>_<version>_<arch>.deb），依赖关系照样能从索引里查。
     * 这样单个坏包（比如 control.tar 是 xz 的）不会拖垮整条安装。 */
    int need_index = 0, n_bad = 0;
    for (int i = 0; i < nt; i++) {
        /* 传进来的是 URL（比如 VS Code 官方的
         * https://update.code.visualstudio.com/latest/linux-deb-arm64/stable）：
         * 先下到缓存，之后就跟本地 .deb 一视同仁。 */
        if (is_url(tg[i].spec)) {
            const char* b = strrchr(tg[i].spec, '/');
            char safe[200];
            snprintf(safe, sizeof safe, "%s", (b && b[1]) ? b + 1 : "download.deb");
            for (char* q = safe; *q; q++)
                if (*q == '?' || *q == '&' || *q == '#' || *q == ':')
                    *q = 0;
            if (!safe[0])
                snprintf(safe, sizeof safe, "download.deb");
            if (!strchr(safe, '.'))
                strncat(safe, ".deb", sizeof safe - strlen(safe) - 1);

            char ddir[1300], dl[1400];
            snprintf(ddir, sizeof ddir, "%s/apt/debs", cfg.cache);
            mkdir_p(ddir);
            snprintf(dl, sizeof dl, "%s/%s", ddir, safe);

            struct stat st;
            if (stat(dl, &st) == 0 && st.st_size > 0) {
                printf("apt: 用已下载的 %s\n", dl);
            } else {
                printf("apt: 下载 %s\n", tg[i].spec);
                if (bsh_http_get_file(tg[i].spec, dl, err, sizeof err) != 0) {
                    printf("apt: 下载失败：%s\n", err);
                    n_bad++;
                    continue;
                }
            }
            snprintf(tg[i].spec, sizeof tg[i].spec, "%s", dl);
        }

        if (!looks_like_path(tg[i].spec)) {
            snprintf(tg[i].name, sizeof tg[i].name, "%s", tg[i].spec);
            need_index = 1;
            continue;
        }
        if (inspect_deb(&cfg, &tg[i], err, sizeof err) == 0) {
            printf("apt: %s 是 %s %s\n", tg[i].spec, tg[i].name, tg[i].version);
            need_index = 1;
            continue;
        }
        /* 兜底：从文件名抠出包名 */
        const char* base = strrchr(tg[i].spec, '/');
        base = base ? base + 1 : tg[i].spec;
        char tmp[256];
        snprintf(tmp, sizeof tmp, "%s", base);
        char* us = strchr(tmp, '_');
        if (us && us > tmp) {
            *us = 0;
            snprintf(tg[i].name, sizeof tg[i].name, "%s", tmp);
            snprintf(tg[i].debpath, sizeof tg[i].debpath, "%s", tg[i].spec);
            printf("apt: %s（%s）—— 用文件名当包名 %s，依赖从索引查\n",
                   err, base, tg[i].name);
            need_index = 1;
        } else {
            printf("apt: 跳过 %s：%s\n", tg[i].spec, err);
            n_bad++;
        }
    }
    if (nt > 0 && n_bad == nt) {
        printf("apt: 没有可用的目标\n");
        return 1;
    }

    /* ② 索引 + 依赖求解 */
    struct bsh_apt_index idx;
    struct bsh_dep_plan plan;
    memset(&plan, 0, sizeof plan);
    int have_index = 0;

    if (need_index && strncmp(cfg.mirror, "https://", 8) != 0) {
        printf("apt: 镜像 %s 不是 https —— 本内置客户端只做 TLS 连接，"
               "请改用 https 镜像（如 https://ports.ubuntu.com/ubuntu-ports）\n",
               cfg.mirror);
        return 1;
    }

    if (need_index) {
        struct bsh_apt_src src;
        cfg_index_src(&cfg, &src);
        printf("apt: 镜像 %s（%s / %s / %s）\n",
               cfg.mirror, cfg.suite, cfg.comps, cfg.arch);
        char ierr[256] = {0};
        if (bsh_apt_index_load(&idx, &src, cfg.force, ierr, sizeof ierr) != 0) {
            printf("apt: 索引不可用：%s\n", ierr[0] ? ierr : err);
            return 1;
        }
        have_index = 1;
        printf("apt: 索引 %d 个包（%d 个文件）\n", idx.n, idx.n_files);
        if (ierr[0])
            printf("apt: 提示：%s\n", ierr);

        /* 本地 .deb 注入索引：镜像里很可能根本没有它（VS Code 官方 deb 就是），
         * 但它的 Depends 要照常求解，它自己也要出现在计划里。注入后 filename 为空。 */
        for (int i = 0; i < nt; i++) {
            if (!tg[i].name[0])
                continue;
            if (bsh_apt_index_add_local(&idx, tg[i].name, tg[i].version, tg[i].depends) != 0)
                printf("apt: 警告 本地包 %s 注入索引失败（槽位满？）\n", tg[i].name);
        }
    }

    /* 根：本地 deb 用自己的名字 + 自己的 Depends；包名直接当根 */
    const char* roots[256];
    int nr = 0;
    for (int i = 0; i < nt && nr < 256; i++)
        roots[nr++] = tg[i].name;

    if (bsh_dep_resolve(&idx, roots, nr, cfg.exclude, &plan, err, sizeof err) != 0) {
        printf("apt: %s\n", err);
        bsh_apt_index_free(&idx);
        return 1;
    }

    printf("apt: 计划安装 %d 个包", plan.n);
    if (plan.n_excluded)
        printf("（%d 个依赖由系统自带，已跳过）", plan.n_excluded);
    printf("\n");

    long long total = 0;
    for (int i = 0; i < plan.n; i++) {
        const struct bsh_apt_entry* e = bsh_apt_index_find(&idx, plan.names[i]);
        if (!e) {
            printf("  %-40s ?\n", plan.names[i]);
            continue;
        }
        total += e->size;
        printf("  %-40s %-20s %8lldK\n", e->name,
               e->version ? e->version : "?", e->size / 1024);
    }
    for (int i = 0; i < plan.n_miss; i++)
        printf("  %-40s 索引里找不到（跳过）\n", plan.missing[i]);
    printf("apt: 合计约 %lld MB\n", total / (1024 * 1024));

    /* 把解出来的清单落盘（一行一个包名，已按安装顺序）。
     * 用途：这次依赖树是 apt 自己算的，写出来客户端就能拿去复用 —— 换个设备、或者
     * 用户想自己去镜像下 deb 时，照这份清单来即可，不必再让宿主预先算一份打进 HAP。 */
    if (cfg.write_list[0]) {
        FILE* wf = fopen(cfg.write_list, "w");
        if (!wf) {
            printf("apt: 写不了清单 %s：%s\n", cfg.write_list, strerror(errno));
        } else {
            for (int i = 0; i < plan.n; i++)
                fprintf(wf, "%s\n", plan.names[i]);
            if (fclose(wf) == 0)
                printf("apt: 清单已写入 %s（%d 个包）\n", cfg.write_list, plan.n);
            else
                printf("apt: 清单写失败 %s\n", cfg.write_list);
        }
    }

    if (cfg.dry_run) {
        printf("apt: --dry-run，未做任何改动\n");
        bsh_dep_plan_free(&plan);
        if (have_index) bsh_apt_index_free(&idx);
        return 0;
    }

    /* ③ 逐个下载 + 安装 */
    inst_load(&cfg);
    struct link_list links;
    memset(&links, 0, sizeof links);
    int rc = 0, n_new = 0;

    for (int i = 0; i < plan.n; i++) {
        const struct bsh_apt_entry* e = bsh_apt_index_find(&idx, plan.names[i]);
        if (!e)
            continue;

        /* 本地 deb 优先用用户给的那份（版本可能比镜像新） */
        const char* debpath = NULL;
        for (int k = 0; k < nt; k++)
            if (strcmp(tg[k].name, plan.names[i]) == 0 && tg[k].debpath[0])
                debpath = tg[k].debpath;

        char fetched[1200] = {0};
        if (!debpath) {
            if (!e->filename || !e->filename[0]) {
                /* 本地注入的条目（没有对应的下载地址）却没给本地 deb：跳过 */
                printf("apt: %s 既不在镜像里也没有本地 deb，跳过\n", e->name);
                rc = 1;
                continue;
            }
            if (fetch_deb(&cfg, e, fetched, sizeof fetched) != 0) {
                rc = 1;
                continue;
            }
            debpath = fetched;
        }

        struct apt_inst* old = inst_find(plan.names[i]);
        if (old && !cfg.force) {
            printf("apt: %s %s 已装（--force 可重装）\n", old->name, old->version);
            continue;
        }

        struct apt_inst newe;
        memset(&newe, 0, sizeof newe);
        snprintf(newe.name, sizeof newe.name, "%s", e->name);
        snprintf(newe.version, sizeof newe.version, "%s", e->version ? e->version : "?");

        struct extract_ctx x;
        memset(&x, 0, sizeof x);
        x.cfg = &cfg;
        x.rec = &newe;
        x.links = &links;

        printf("apt: 安装 %s %s\n", newe.name, newe.version);
        if (apt_install_one(&x, debpath) != 0) {
            inst_free(&newe);
            rc = 1;
            continue;
        }

        if (old) {                              /* 覆盖安装：接管旧槽位 */
            inst_free(old);
            old->files = newe.files;
            old->nfiles = newe.nfiles;
            old->cap = newe.cap;
            newe.files = NULL; newe.nfiles = 0; newe.cap = 0;
            snprintf(old->version, sizeof old->version, "%s", newe.version);
        } else if (g_ninst < APT_MAX_PKGS) {
            g_inst[g_ninst] = newe;
            newe.files = NULL; newe.nfiles = 0; newe.cap = 0;
            g_ninst++;
        } else {
            printf("apt: 已装包太多（> %d）\n", APT_MAX_PKGS);
            inst_free(&newe);
            rc = 1;
            continue;
        }
        n_new++;
        int nrec = old ? old->nfiles : (g_ninst > 0 ? g_inst[g_ninst - 1].nfiles : 0);
        printf("apt:   解出 %d 个文件", nrec);
        if (x.n_skip)
            printf("，跳过 %d 个已存在的", x.n_skip);
        printf("\n");
    }

    /* ④ 软链代偿 + 平铺 + 记账 */
    apply_links(&cfg, &links);
    apply_flatten(&cfg);
    if (inst_save(&cfg) != 0)
        rc = 1;

    printf("apt: 完成（新装 %d 个包）\n", n_new);
    if (plan.n_miss) {
        /* 把名字打出来 —— 只报个数的话，遇到"deb 漏写依赖"（如 zcode 少了 libgbm1）
         * 就得来回试，白白多烧一轮装机。 */
        printf("apt: 有 %d 个依赖在索引里没找到，相关功能可能不完整：", plan.n_miss);
        for (int i = 0; i < plan.n_miss; i++)
            printf(" %s", plan.missing[i]);
        printf("\n");
    }

    free(links.v);
    bsh_dep_plan_free(&plan);
    if (have_index) bsh_apt_index_free(&idx);
    for (int i = 0; i < g_ninst; i++) inst_free(&g_inst[i]);
    g_ninst = 0;
    return rc;
}

/* ── remove ─────────────────────────────────────────────────────────────── */

static int cmd_remove(int argc, char** argv)
{
    if (argc < 1) {
        printf("用法：apt remove <包名>…\n");
        return 2;
    }
    struct apt_cfg cfg;
    cfg_init(&cfg);
    inst_load(&cfg);

    int rc = 0;
    for (int a = 0; a < argc; a++) {
        struct apt_inst* e = inst_find(argv[a]);
        if (!e) {
            printf("apt: %s 没装\n", argv[a]);
            rc = 1;
            continue;
        }
        char full[1500];
        int n = 0;
        for (int i = e->nfiles - 1; i >= 0; i--) {      /* 倒序：先文件后目录 */
            snprintf(full, sizeof full, "%s/%s", cfg.root, e->files[i]);
            struct stat st;
            if (stat(full, &st) != 0)
                continue;
            if (S_ISDIR(st.st_mode)) {
                if (rmdir(full) == 0) n++;
            } else if (unlink(full) == 0) {
                n++;
            }
        }
        inst_free(e);
        int idx = (int)(e - g_inst);
        for (int i = idx; i + 1 < g_ninst; i++)
            g_inst[i] = g_inst[i + 1];
        g_ninst--;
        memset(&g_inst[g_ninst], 0, sizeof g_inst[g_ninst]);
        printf("apt: %s 已卸载（删除 %d 项）\n", argv[a], n);
    }
    if (inst_save(&cfg) != 0)
        rc = 1;
    for (int i = 0; i < g_ninst; i++) inst_free(&g_inst[i]);
    g_ninst = 0;
    return rc;
}

/* ── update / search / info / source ────────────────────────────────────── */

static int cmd_update(void)
{
    struct apt_cfg cfg;
    cfg_init(&cfg);
    cfg_source(&cfg);
    struct bsh_apt_src src;
    cfg_index_src(&cfg, &src);

    printf("apt: 镜像 %s（%s / %s / %s）\n", cfg.mirror, cfg.suite, cfg.comps, cfg.arch);
    struct bsh_apt_index idx;
    char err[256] = {0};
    if (bsh_apt_index_load(&idx, &src, 1, err, sizeof err) != 0) {
        printf("apt: %s\n", err[0] ? err : "索引更新失败");
        return 1;
    }
    printf("apt: 索引已更新：%d 个包\n", idx.n);
    bsh_apt_index_free(&idx);
    return 0;
}

static int cmd_search(const char* kw)
{
    struct apt_cfg cfg;
    cfg_init(&cfg);
    cfg_source(&cfg);
    struct bsh_apt_src src;
    cfg_index_src(&cfg, &src);
    struct bsh_apt_index idx;
    char err[256] = {0};
    if (bsh_apt_index_load(&idx, &src, 0, err, sizeof err) != 0) {
        printf("apt: %s\n", err[0] ? err : "索引不可用");
        return 1;
    }
    int n = 0;
    for (int i = 0; i < idx.n; i++) {
        if (strstr(idx.ents[i].name, kw)) {
            printf("%-40s %-20s %8lldK\n", idx.ents[i].name,
                   idx.ents[i].version ? idx.ents[i].version : "?",
                   idx.ents[i].size / 1024);
            if (++n >= 200) {
                printf("…（只列前 200 个）\n");
                break;
            }
        }
    }
    printf("apt: 匹配 %d 个\n", n);
    bsh_apt_index_free(&idx);
    return 0;
}

static int cmd_info(int argc, char** argv)
{
    if (argc < 1) {
        printf("用法：apt info <deb路径|包名>\n");
        return 2;
    }
    struct apt_cfg cfg;
    cfg_init(&cfg);
    cfg_source(&cfg);

    if (looks_like_path(argv[0])) {
        /* 直接读一次 control，所有字段都从它取（不必先走 inspect_deb 再读一遍） */
        char tmpdir[1300];
        snprintf(tmpdir, sizeof tmpdir, "%s/apt/tmp", cfg.cache);
        mkdir_p(tmpdir);
        char err[512] = {0};
        char* ctrl = NULL;
        size_t clen = 0;
        if (bsh_deb_read_control(argv[0], tmpdir, &ctrl, &clen, &err[0], sizeof err) != 0) {
            printf("apt: %s\n", err);
            return 1;
        }
        (void)clen;
        char v[1024];
        printf("本地 deb : %s\n", argv[0]);
        if (bsh_deb_field(ctrl, "Package", v, sizeof v))        printf("name     : %s\n", v);
        if (bsh_deb_field(ctrl, "Version", v, sizeof v))        printf("version  : %s\n", v);
        if (bsh_deb_field(ctrl, "Architecture", v, sizeof v))   printf("arch     : %s\n", v);
        if (bsh_deb_field(ctrl, "Installed-Size", v, sizeof v)) printf("装后大小 : %s KB\n", v);
        if (bsh_deb_field(ctrl, "Maintainer", v, sizeof v))     printf("维护者   : %s\n", v);
        if (bsh_deb_field(ctrl, "Depends", v, sizeof v))        printf("depends  : %s\n", v);
        else                                                    printf("depends  : (无)\n");
        if (bsh_deb_field(ctrl, "Description", v, sizeof v))    printf("说明     : %s\n", v);
        free(ctrl);
        return 0;
    }

    struct bsh_apt_src src;
    cfg_index_src(&cfg, &src);
    struct bsh_apt_index idx;
    char err[256] = {0};
    if (bsh_apt_index_load(&idx, &src, 0, err, sizeof err) != 0) {
        printf("apt: %s\n", err[0] ? err : "索引不可用");
        return 1;
    }
    const struct bsh_apt_entry* e = bsh_apt_index_find(&idx, argv[0]);
    if (!e) {
        printf("apt: 索引里没有 %s\n", argv[0]);
        bsh_apt_index_free(&idx);
        return 1;
    }
    printf("name     : %s\n", e->name);
    printf("version  : %s\n", e->version ? e->version : "?");
    printf("size     : %lld\n", e->size);
    printf("file     : %s\n", e->filename);
    printf("sha256   : %s\n", e->sha256 ? e->sha256 : "?");
    printf("depends  : %s\n", e->depends ? e->depends : "(无)");
    int dup = bsh_apt_index_count_name(&idx, e->name);
    if (dup > 1)
        printf("注意     : 索引里有 %d 个同名条目（多版本/多组件）\n", dup);
    bsh_apt_index_free(&idx);
    return 0;
}

static int cmd_source(int argc, char** argv)
{
    struct apt_cfg cfg;
    cfg_init(&cfg);
    char dir[1200], file[1300];
    under_root(&cfg, dir, sizeof dir, REL_PKGDIR);
    under_root(&cfg, file, sizeof file, REL_APTSRC);

    cfg_source(&cfg);
    if (argc == 0) {
        printf("镜像：%s\n", cfg.mirror);
        printf("代号：%s   组件：%s   架构：%s\n", cfg.suite, cfg.comps, cfg.arch);
        printf("（改镜像：apt source <url>，写进 %s）\n", file);
        printf("（改代号/组件/架构：环境变量 BSH_APT_SUITE / BSH_APT_COMPONENTS / BSH_APT_ARCH）\n");
        return 0;
    }
    mkdir_p(dir);
    FILE* f = fopen(file, "w");
    if (!f) {
        printf("apt: 写不了 %s：%s\n", file, strerror(errno));
        return 1;
    }
    fprintf(f, "%s\n", argv[0]);
    fclose(f);
    printf("镜像已改为：%s\n", argv[0]);
    return 0;
}

/* ── 入口 ───────────────────────────────────────────────────────────────── */

static int usage(void)
{
    struct apt_cfg cfg;
    cfg_init(&cfg);
    cfg_source(&cfg);
    printf(
        "apt — 从 Ubuntu/Debian 镜像装 .deb（自动解析依赖树）\n"
        "  apt install [--dry-run] [--force] [--overwrite] [--flatten DIR]\n"
        "              [--write-list FILE] <deb路径|URL|包名>…\n"
        "  apt remove <包名>…              按安装记录删文件\n"
        "  apt update                      强制重下包索引\n"
        "  apt search <关键字>             在索引里搜包名\n"
        "  apt info <deb路径|包名>         看详情与依赖\n"
        "  apt source [url]                查看/设置镜像\n"
        "\n"
        "安装根：%s\n"
        "缓存  ：%s\n"
        "镜像  ：%s（%s / %s / %s）\n"
        "排除  ：%s\n",
        cfg.root, cfg.cache, cfg.mirror, cfg.suite, cfg.comps, cfg.arch,
        cfg.exclude[0] ? cfg.exclude : "(空)");
    return 0;
}

int apt_main(int argc, char** argv)
{
    /* 逐行刷：装包过程很长，被信号打断时也别把已有输出整段丢掉（pkg 同款处理） */
    setvbuf(stdout, NULL, _IOLBF, 0);

    if (argc < 2)
        return usage();
    const char* sub = argv[1];
    if (strcmp(sub, "install") == 0) return cmd_install(argc - 2, argv + 2);
    if (strcmp(sub, "remove") == 0)  return cmd_remove(argc - 2, argv + 2);
    if (strcmp(sub, "update") == 0)  return cmd_update();
    if (strcmp(sub, "search") == 0) {
        if (argc < 3) { printf("用法：apt search <关键字>\n"); return 2; }
        return cmd_search(argv[2]);
    }
    if (strcmp(sub, "info") == 0)    return cmd_info(argc - 2, argv + 2);
    if (strcmp(sub, "source") == 0)  return cmd_source(argc - 2, argv + 2);
    return usage();
}
