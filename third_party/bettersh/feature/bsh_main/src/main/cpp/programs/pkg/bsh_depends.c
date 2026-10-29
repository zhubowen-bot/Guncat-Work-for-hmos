// bsh_depends.c — 见头文件
#include "bsh_depends.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_DEPTH 64

/* ── 版本比较（dpkg 的规矩） ────────────────────────────────────────────── */

/* 字符序：'~' 比谁都小（所以 1.0~rc1 < 1.0），字母按 ASCII，其余 +256 */
static int vorder(int c)
{
    if (c >= '0' && c <= '9') return 0;
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) return c;
    if (c == '~') return -1;
    if (c == 0) return 0;
    return c + 256;
}

/* 上游版本段/修订段的比较：非数字段与数字段交替比 */
static int verrevcmp(const char* a, const char* b)
{
    while (*a || *b) {
        int first_diff = 0;

        while ((*a && !(*a >= '0' && *a <= '9')) ||
               (*b && !(*b >= '0' && *b <= '9'))) {
            int ac = vorder((unsigned char)*a);
            int bc = vorder((unsigned char)*b);
            if (ac != bc)
                return ac - bc;
            a++;
            b++;
        }
        while (*a == '0') a++;
        while (*b == '0') b++;
        while ((*a >= '0' && *a <= '9') && (*b >= '0' && *b <= '9')) {
            if (!first_diff)
                first_diff = *a - *b;
            a++;
            b++;
        }
        if (*a >= '0' && *a <= '9') return 1;
        if (*b >= '0' && *b <= '9') return -1;
        if (first_diff)
            return first_diff;
    }
    return 0;
}

int bsh_ver_cmp(const char* av, const char* bv)
{
    if (!av) av = "";
    if (!bv) bv = "";

    /* epoch */
    int ea = 0, eb = 0;
    const char* ca = strchr(av, ':');
    const char* cb = strchr(bv, ':');
    if (ca) { ea = atoi(av); av = ca + 1; }
    if (cb) { eb = atoi(bv); bv = cb + 1; }
    if (ea != eb)
        return ea - eb;

    /* 最后一个 '-' 之前是上游版本，之后是修订号 */
    char ua[256], ub[256], ra[256] = {0}, rb[256] = {0};
    const char* da = strrchr(av, '-');
    const char* db = strrchr(bv, '-');
    if (da) { snprintf(ua, sizeof ua, "%.*s", (int)(da - av), av); snprintf(ra, sizeof ra, "%s", da + 1); }
    else    { snprintf(ua, sizeof ua, "%s", av); }
    if (db) { snprintf(ub, sizeof ub, "%.*s", (int)(db - bv), bv); snprintf(rb, sizeof rb, "%s", db + 1); }
    else    { snprintf(ub, sizeof ub, "%s", bv); }

    int r = verrevcmp(ua, ub);
    if (r)
        return r;
    return verrevcmp(ra, rb);
}

int bsh_ver_satisfies(const char* actual, const char* op, const char* want)
{
    if (!op || !op[0])
        return 1;
    int c = bsh_ver_cmp(actual, want);
    if (!strcmp(op, ">="))  return c >= 0;
    if (!strcmp(op, "<="))  return c <= 0;
    if (!strcmp(op, "="))   return c == 0;
    if (!strcmp(op, "=="))  return c == 0;
    if (!strcmp(op, ">>"))  return c > 0;
    if (!strcmp(op, "<<"))  return c < 0;
    if (!strcmp(op, ">"))   return c > 0;
    if (!strcmp(op, "<"))   return c < 0;
    return 1;                                  /* 不认识的算子：不拦 */
}

/* ── plan ───────────────────────────────────────────────────────────────── */

static int plan_push(char*** arr, int* n, int* cap, const char* s)
{
    if (*n >= *cap) {
        int ncap = *cap ? *cap * 2 : 32;
        char** na = (char**)realloc(*arr, (size_t)ncap * sizeof *na);
        if (!na)
            return -1;
        *arr = na;
        *cap = ncap;
    }
    char* d = strdup(s);
    if (!d)
        return -1;
    (*arr)[(*n)++] = d;
    return 0;
}

static int plan_has(char** arr, int n, const char* s)
{
    for (int i = 0; i < n; i++)
        if (strcmp(arr[i], s) == 0)
            return 1;
    return 0;
}

void bsh_dep_plan_free(struct bsh_dep_plan* p)
{
    if (!p)
        return;
    for (int i = 0; i < p->n; i++)       free(p->names[i]);
    for (int i = 0; i < p->n_miss; i++)  free(p->missing[i]);
    free(p->names);
    free(p->missing);
    memset(p, 0, sizeof *p);
}

/* ── 求解 ───────────────────────────────────────────────────────────────── */

struct solver {
    const struct bsh_apt_index* idx;
    char excl[512];                  /* 归一化成 "|a|b|c|" 才好用 strstr 查 */
    struct bsh_dep_plan* out;
};

static void build_excl(struct solver* s, const char* list)
{
    size_t w = 0;
    s->excl[w++] = '|';
    for (const char* p = list; p && *p; ) {
        while (*p == ' ' || *p == ',' || *p == '\t' || *p == '\n')
            p++;
        if (!*p)
            break;
        const char* e = p;
        while (*e && *e != ' ' && *e != ',' && *e != '\t' && *e != '\n')
            e++;
        size_t n = (size_t)(e - p);
        if (w + n + 2 < sizeof s->excl) {
            memcpy(s->excl + w, p, n);
            w += n;
            s->excl[w++] = '|';
        }
        p = e;
    }
    s->excl[w] = 0;
}

static int excluded(const struct solver* s, const char* name)
{
    if (s->excl[0] == 0 || s->excl[1] == 0)
        return 0;
    char pat[300];
    snprintf(pat, sizeof pat, "|%s|", name);
    return strstr(s->excl, pat) != NULL;
}

/* 索引查找 + noble 的 t64 回退。
 *
 * 为什么需要：noble 为了 64 位 time_t 把一大批包改了名（`libgtk-3-0` →
 * `libgtk-3-0t64`、`libglib2.0-0` → `libglib2.0-0t64`…），而上游分发的 deb（VS Code
 * 官方那份就是）的 Depends 里还写着**老名字**。不回退的话这些依赖会整片落进 missing ——
 * 实测 `code` 的依赖里这样丢掉三十来个库，装出来的东西根本起不来。
 *
 * 规则很确定：精确加一个 "t64" 后缀再查一次。**不做**前缀/模糊匹配，那会误配。 */
static const struct bsh_apt_entry* find_entry(const struct bsh_apt_index* idx,
                                              const char* name)
{
    const struct bsh_apt_entry* e = bsh_apt_index_find(idx, name);
    if (e)
        return e;
    char alt[128];
    if (snprintf(alt, sizeof alt, "%st64", name) >= (int)sizeof alt)
        return NULL;
    return bsh_apt_index_find(idx, alt);
}

/* 拆一个可选分支："name[:arch] [(op ver)]" */
static int parse_alt(char* s, char* name, char* op, char* ver)
{
    op[0] = 0;
    ver[0] = 0;
    while (*s == ' ' || *s == '\t')
        s++;
    size_t n = 0;
    while (*s && *s != ' ' && *s != '\t' && *s != '(' && n < 255)
        name[n++] = *s++;
    name[n] = 0;
    char* colon = strchr(name, ':');
    if (colon)
        *colon = 0;
    if (!name[0])
        return -1;

    while (*s == ' ' || *s == '\t')
        s++;
    if (*s == '(') {
        s++;
        while (*s == ' ' || *s == '\t')
            s++;
        size_t m = 0;
        while (*s && *s != ')' && *s != ' ' && *s != '\t' && m < 3)
            op[m++] = *s++;
        op[m] = 0;
        while (*s == ' ' || *s == '\t')
            s++;
        size_t k = 0;
        while (*s && *s != ')' && *s != ' ' && *s != '\t' && k < 127)
            ver[k++] = *s++;
        ver[k] = 0;
    }
    return 0;
}

static int solve_one(struct solver* s, const char* name, int depth);

/* 一个 AND 组（可能含多个 OR 分支）：挑第一个能用的 */
static int solve_group(struct solver* s, char* group, int depth)
{
    char pick[256] = {0};
    char first[256] = {0};
    char save[8192];
    snprintf(save, sizeof save, "%s", group);

    char* st = NULL;
    for (char* alt = strtok_r(save, "|", &st); alt; alt = strtok_r(NULL, "|", &st)) {
        char name[256], op[4], ver[128];
        if (parse_alt(alt, name, op, ver) != 0)
            continue;
        if (!first[0])
            snprintf(first, sizeof first, "%s", name);

        if (excluded(s, name)) {                 /* 系统自己提供 → 视为满足 */
            snprintf(pick, sizeof pick, "%s", name);
            break;
        }
        const struct bsh_apt_entry* e = find_entry(s->idx, name);
        if (!e)
            continue;
        if (op[0] && !bsh_ver_satisfies(e->version, op, ver))
            continue;
        /* 记**索引里的实际名字**：回退命中时它就是 xxx-t64 那个，后面下载要按它查 */
        snprintf(pick, sizeof pick, "%s", e->name);
        break;
    }

    if (!pick[0]) {
        if (first[0])
            plan_push(&s->out->missing, &s->out->n_miss, &s->out->miss_cap, first);
        return 0;
    }
    if (excluded(s, pick)) {
        s->out->n_excluded++;
        return 0;
    }
    return solve_one(s, pick, depth + 1);
}

static int solve_one(struct solver* s, const char* name, int depth)
{
    if (depth > MAX_DEPTH)
        return 0;                                /* 依赖链过深：放过，别把栈玩炸 */
    if (excluded(s, name)) {
        s->out->n_excluded++;
        return 0;
    }

    const struct bsh_apt_entry* e = find_entry(s->idx, name);
    if (!e) {
        if (!plan_has(s->out->missing, s->out->n_miss, name))
            plan_push(&s->out->missing, &s->out->n_miss, &s->out->miss_cap, name);
        return 0;
    }
    if (excluded(s, e->name)) {
        s->out->n_excluded++;
        return 0;
    }
    /* 去重按**索引里的实际名字**（回退之后可能已经是 xxx-t64，别名不能当两个包） */
    if (plan_has(s->out->names, s->out->n, e->name))
        return 0;                                /* 已处理（顺带断开依赖环） */

    if (e->depends && e->depends[0]) {
        char buf[8192];
        snprintf(buf, sizeof buf, "%s", e->depends);
        char* st = NULL;
        for (char* g = strtok_r(buf, ",", &st); g; g = strtok_r(NULL, ",", &st))
            if (solve_group(s, g, depth) != 0)
                return -1;
    }
    /* 后序加入：依赖都排在自己前面 */
    return plan_push(&s->out->names, &s->out->n, &s->out->cap, e->name);
}

int bsh_dep_resolve(const struct bsh_apt_index* idx,
                    const char* const* roots, int n_roots,
                    const char* exclude,
                    struct bsh_dep_plan* out,
                    char* err, size_t errlen)
{
    if (!idx || !roots || n_roots <= 0 || !out) {
        snprintf(err, errlen, "参数不合法");
        return -1;
    }
    memset(out, 0, sizeof *out);

    struct solver s;
    memset(&s, 0, sizeof s);
    s.idx = idx;
    s.out = out;
    build_excl(&s, exclude ? exclude : "");

    for (int i = 0; i < n_roots; i++) {
        if (solve_one(&s, roots[i], 0) != 0) {
            snprintf(err, errlen, "内存不足（依赖太多？）");
            return -1;
        }
    }
    return 0;
}
