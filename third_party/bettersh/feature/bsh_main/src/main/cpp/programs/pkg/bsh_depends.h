// bsh_depends.h — Depends 语法解析 + 依赖求解
//
// Depends 的语法（我们支持的部分）：
//     a, b (>= 1.2), c | d, e:any, f:arm64 (<< 2)
// 逗号 = AND（都要装），竖线 = OR（装第一个能找到的），括号里是版本约束，
// 冒号后是架构限定（:any / :arm64，比较时直接丢掉）。
//
// 不支持的（也基本不会遇到）：Provides（虚拟包）、Conflicts/Breaks/Replaces、
// Pre-Depends（当成 Depends 处理即可）、多架构交叉（:i386 之类）。
//
// 求解结果是一份**安装顺序**（依赖排在依赖者前面），给 apt 逐个下载安装用。
#pragma once

#include <stddef.h>

#include "bsh_pkgindex.h"

struct bsh_dep_plan {
    char** names;          /* 安装顺序（依赖在前） */
    int n, cap;
    char** missing;        /* 索引里找不到、或版本都够不上的依赖名 */
    int n_miss, miss_cap;
    int n_excluded;        /* 被排除名单挡掉、因此没进 plan 的个数 */
};

/* 从 roots 里的包名出发求解。exclude 是空格/逗号分隔的"不要装"名单（我们自己提供的
 * 系统库）。成功返回 0（missing 非空也算成功 —— 调用方自己决定报不报错），
 * 只有参数错误/内存不足才返回 -1。 */
int bsh_dep_resolve(const struct bsh_apt_index* idx,
                    const char* const* roots, int n_roots,
                    const char* exclude,
                    struct bsh_dep_plan* out,
                    char* err, size_t errlen);

void bsh_dep_plan_free(struct bsh_dep_plan* p);

/* dpkg 版本比较（epoch:upstream-revision，`~` 最小、数字段按数值）。返回 <0 / 0 / >0。
 * 暴露出来是为了能在宿主上单独验证这个算法。 */
int bsh_ver_cmp(const char* a, const char* b);

/* actual 是否满足 "op want"（op 取 >= <= = >> << > <）。op 不认识时返回 1（不拦）。 */
int bsh_ver_satisfies(const char* actual, const char* op, const char* want);
