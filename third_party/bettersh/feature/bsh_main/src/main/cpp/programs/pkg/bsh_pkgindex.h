// bsh_pkgindex.h — Ubuntu/Debian 的 Packages 索引：下载、解压、解析、查找
//
// apt 为什么绕不开它：`.deb` 的 Depends 只给**包名**，要变成「从哪下」必须查索引里的
// Filename 字段。索引在 <mirror>/dists/<suite>/<component>/binary-<arch>/Packages.gz，
// 是 RFC822 风格的多段落文本（字段行 + 空行分段）。
//
// 规模（2026-10 实测 ports.ubuntu.com noble）：
//     main      1.7 MB (.gz) → 7.0 MB 文本 →  5977 条
//     universe 19.1 MB (.gz) → 72.1 MB 文本 → 63665 条
// 所以默认只吃 main：下载与解析都是秒级。加 universe 也扛得住（解析一次约 1-2 秒，
// 内存几十 MB），由环境变量决定。
//
// 内存做法：解压后的文本**原样留在内存里**，字段指针直接指进那段文本（解析时把行尾
// 的 '\n' 就地改成 '\0'）。一份文本只花一次内存，字段不额外 strdup。
// 多组件时先把各组件文本拼进同一块 arena，再统一解析。
#pragma once

#include <stddef.h>

struct bsh_apt_entry {
    const char* name;      /* 指向 arena，'\0' 结尾 */
    const char* version;
    const char* depends;   /* 没有 Depends 字段时为 NULL */
    const char* filename;  /* 相对镜像根的路径，如 pool/main/x/xx/xx_1.0_arm64.deb */
    const char* sha256;    /* 可能为 NULL */
    long long   size;      /* .deb 字节数，0 = 索引里没写 */
};

struct bsh_apt_index {
    char* arena;                    /* 所有组件文本拼起来的一块，拥有 */
    size_t arena_len;
    size_t arena_cap;
    struct bsh_apt_entry* ents;     /* 按 name 升序、同名按 version 降序排好 */
    int n, cap;
    int n_files;                    /* 实际读进来的索引文件数（诊断用） */
    /* 本地注入的条目（apt 装本地 .deb 时用）的字符串存放处。条目数不会多，
     * 固定 8 个坑位够用；这样 free 时不用再管一批零散指针。 */
    char local_store[8][4608];
    int  n_local;
};

/* 索引源配置。攒成一个结构体是因为参数实在多。 */
struct bsh_apt_src {
    const char* mirror;      /* http://ports.ubuntu.com/ubuntu-ports（结尾带不带 / 都行） */
    const char* suite;       /* noble */
    const char* comps;       /* 空格分隔：main 或 "main universe" */
    const char* arch;        /* arm64 / amd64 */
    const char* cache_dir;   /* 缓存根，会在其下建 apt/ */
    long        max_age_sec; /* 缓存超过这么久就当过期；<=0 表示永不过期 */
};

/* 取索引并解析。cache_dir 下会建 apt/ 子目录缓存 .gz 与解压后的文本。
 * force 为真则忽略缓存重新下载。
 * 成功返回 0。失败返回负值并把原因写进 err（某组件失败但本地有旧文本时，用旧的继续，
 * 只在 err 里留提示）。 */
int bsh_apt_index_load(struct bsh_apt_index* idx, const struct bsh_apt_src* src,
                       int force, char* err, size_t errlen);

/* 按包名查找。同名多版本时给版本字符串最大的那个（字典序，够用）。找不到返回 NULL。 */
const struct bsh_apt_entry* bsh_apt_index_find(const struct bsh_apt_index* idx,
                                               const char* name);

/* 注入一个"本地提供"的包（apt install ./xxx.deb 时用）：镜像里可能根本没有这个包
 * （比如 VS Code 官方 deb），但它的 Depends 还得照常求解、它自己也要出现在计划里。
 * 注入后 filename 为空 —— 调用方见到空 filename 就知道不必下载。
 * 成功返回 0；坑位满了或太长返回 -1。 */
int bsh_apt_index_add_local(struct bsh_apt_index* idx, const char* name,
                            const char* version, const char* depends);

void bsh_apt_index_free(struct bsh_apt_index* idx);

/* 诊断用：索引里某个包名出现的次数（同名多版本/多组件重复） */
int bsh_apt_index_count_name(const struct bsh_apt_index* idx, const char* name);
