/* OHOS_PATCH_PATH_REMAP
 *
 * proot-style 路径前缀改写. wine/wineserver 硬编码 /tmp 的部分在
 * HAP 沙箱里走不通, 这里在 box64 wrap 层做透明替换:
 *
 *   guest:  open("/tmp/.wine-1000/server-x-y/socket", ...)
 *   host:   open("/data/storage/el2/base/cache/box64-tmp/.wine-1000/server-x-y/socket", ...)
 *
 * 单向改写: 只改 guest -> host. wine 不做反向比较所以够用.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>


/* OHOS_PATCH_LOG_GATE */
#include <stdlib.h>
#include <stdio.h>
static int ohos_remap_log_level(void) {
    static int cached = -1;
    if (cached < 0) {
        const char* v = getenv("BOX64_LOG");
        cached = (v && *v) ? atoi(v) : 0;
        if (cached < 0) cached = 0;
    }
    return cached;
}
#define OHOS_REMAP_INFO(...)  do { if (ohos_remap_log_level() >= 1) { fprintf(stderr, __VA_ARGS__); fflush(stderr); } } while (0)
#define OHOS_REMAP_DEBUG(...) do { if (ohos_remap_log_level() >= 2) { fprintf(stderr, __VA_ARGS__); fflush(stderr); } } while (0)
struct path_map {
    const char* from;       /* 不带尾部 /, 例如 "/tmp" */
    size_t      from_len;
    const char* to;         /* 不带尾部 /, 例如 "/data/storage/.../box64-tmp" */
    size_t      to_len;
};

#define BOX64_REMAP_MAX 8
static struct path_map g_maps[BOX64_REMAP_MAX];
static int             g_nmaps = 0;
static int             g_inited = 0;
static pthread_mutex_t g_init_mu = PTHREAD_MUTEX_INITIALIZER;

/* mkdir -p 简化版 (一层一层建) */
static void box64_mkpath(const char* path) {
    if (!path || !*path) return;
    char buf[PATH_MAX];
    size_t n = strlen(path);
    if (n >= sizeof(buf)) return;
    memcpy(buf, path, n + 1);
    for (char* p = buf + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(buf, 0700);   /* 失败无所谓 (可能已存在) */
            *p = '/';
        }
    }
    mkdir(buf, 0700);
}

static void box64_remap_init(void) {
    pthread_mutex_lock(&g_init_mu);
    if (g_inited) { pthread_mutex_unlock(&g_init_mu); return; }

    /* 解析 target 目录 */
    const char* override = getenv("BOX64_TMP_TARGET");
    const char* tmpdir   = getenv("TMPDIR");
    static char target[PATH_MAX];
    if (override && *override) {
        snprintf(target, sizeof(target), "%s", override);
    } else if (tmpdir && *tmpdir) {
        snprintf(target, sizeof(target), "%s/box64-tmp", tmpdir);
    } else {
        /* HAP 默认 fallback */
        snprintf(target, sizeof(target),
                 "/data/storage/el2/base/cache/box64-tmp");
    }
    /* trim 末尾 / */
    size_t tn = strlen(target);
    while (tn > 1 && target[tn - 1] == '/') target[--tn] = 0;

    box64_mkpath(target);
    if (access(target, W_OK) != 0) {
        fprintf(stderr,
            "[box64-remap] WARN: target dir '%s' not writable: %s\n",
            target, strerror(errno));
    } else {
        OHOS_REMAP_INFO("[box64-remap] /tmp -> %s\n", target);
    }

    g_maps[g_nmaps].from     = "/tmp";
    g_maps[g_nmaps].from_len = 4;
    g_maps[g_nmaps].to       = target;
    g_maps[g_nmaps].to_len   = tn;
    g_nmaps++;

    g_inited = 1;
    pthread_mutex_unlock(&g_init_mu);
}

__attribute__((constructor(120)))
static void box64_remap_ctor(void) { box64_remap_init(); }

/* 主入口: 命中改写到 buf 并返回 buf, 否则原样返回 path. */
__attribute__((visibility("default")))
void box64_remap_maybe_add_wineprefix_rule(void);

const char* box64_remap_path(const char* path, char* buf, unsigned long buflen) {
    if (!path || !*path) return path;
    if (!g_inited) box64_remap_init();
    /* OHOS_PATCH_PATH_REMAP_V2_HOOK */
    box64_remap_maybe_add_wineprefix_rule();

    for (int i = 0; i < g_nmaps; i++) {
        const struct path_map* m = &g_maps[i];
        if (strncmp(path, m->from, m->from_len) != 0) continue;
        char tail = path[m->from_len];
        /* 边界: /tmp 完全相等, 或下一字符是 / 才算命中. 避免 /tmpfoo 被误改 */
        if (tail != '\0' && tail != '/') continue;

        size_t rest_len = strlen(path + m->from_len);
        size_t need = m->to_len + rest_len + 1;
        if (need > buflen) {
            /* buf 不够大, 兜底返回原路径 (调用方 fallback) */
            return path;
        }
        memcpy(buf, m->to, m->to_len);
        memcpy(buf + m->to_len, path + m->from_len, rest_len + 1);
        return buf;
    }
    return path;
}

/* 给 bind/connect 用的 sockaddr_un 改写.
 * 命中时把改写后的地址写到 *out_sa, 长度写到 *out_len, 返回 1.
 * 不命中或非 AF_UNIX 返回 0, 调用方使用原 sa.
 */
__attribute__((visibility("default")))
int box64_remap_sockaddr_un(const void* sa, unsigned int salen,
                            void* out_sa, unsigned int* out_len) {
    if (!sa || salen < sizeof(sa_family_t)) return 0;
    const struct sockaddr* p = (const struct sockaddr*)sa;
    if (p->sa_family != AF_UNIX) return 0;

    const struct sockaddr_un* sun_in = (const struct sockaddr_un*)sa;
    /* abstract socket (sun_path[0] == '\0') 不动 */
    if (salen < offsetof(struct sockaddr_un, sun_path) + 1) return 0;
    if (sun_in->sun_path[0] == '\0') return 0;

    /* sun_path 是定长数组, 不一定 NUL 终止. 算实际长度. */
    size_t maxp = sizeof(sun_in->sun_path);
    size_t plen = strnlen(sun_in->sun_path, maxp);
    char tmp[sizeof(sun_in->sun_path) + 1];
    if (plen >= sizeof(tmp)) return 0;
    memcpy(tmp, sun_in->sun_path, plen);
    tmp[plen] = '\0';

    char buf[PATH_MAX];
    const char* mapped = box64_remap_path(tmp, buf, sizeof(buf));
    if (mapped == tmp) return 0;   /* 没改写 */

    size_t mlen = strlen(mapped);
    if (mlen >= sizeof(sun_in->sun_path)) {
        fprintf(stderr,
            "[box64-remap] WARN: remapped sun_path too long (%zu >= %zu): %s\n",
            mlen, sizeof(sun_in->sun_path), mapped);
        return 0;
    }

    struct sockaddr_un* sun_out = (struct sockaddr_un*)out_sa;
    memset(sun_out, 0, sizeof(*sun_out));
    sun_out->sun_family = AF_UNIX;
    memcpy(sun_out->sun_path, mapped, mlen + 1);
    *out_len = (unsigned int)(offsetof(struct sockaddr_un, sun_path) + mlen + 1);
    return 1;
}

/* OHOS_PATCH_PATH_REMAP_V2
 * lazy 加 ${WINEPREFIX}/dosdevices/c: -> ${WINEPREFIX}/drive_c.
 * WINEPREFIX 在 box64_run 启动期通过 environ 传入, ctor 跑得太早拿不到.
 * 这里在每次 box64_remap_path 入口检查, 一旦 getenv 命中就建规则.
 */
static int g_wineprefix_done = 0;
static char g_wp_from[PATH_MAX];
static char g_wp_to  [PATH_MAX];

void box64_remap_maybe_add_wineprefix_rule(void) {
    if (__atomic_load_n(&g_wineprefix_done, __ATOMIC_ACQUIRE)) return;

    pthread_mutex_lock(&g_init_mu);
    if (g_wineprefix_done) { pthread_mutex_unlock(&g_init_mu); return; }

    const char* wp = getenv("WINEPREFIX");
    if (!wp || !*wp) {
        /* 环境变量还没就位, 这次不算"已尝试", 下次再 try */
        pthread_mutex_unlock(&g_init_mu);
        return;
    }

    /* trim trailing / */
    size_t wpl = strlen(wp);
    while (wpl > 1 && wp[wpl - 1] == '/') wpl--;

    int n = snprintf(g_wp_from, sizeof(g_wp_from),
                     "%.*s/dosdevices/c:", (int)wpl, wp);
    int m = snprintf(g_wp_to,   sizeof(g_wp_to),
                     "%.*s/drive_c",       (int)wpl, wp);

    if (n > 0 && (size_t)n < sizeof(g_wp_from) &&
        m > 0 && (size_t)m < sizeof(g_wp_to)   &&
        g_nmaps < BOX64_REMAP_MAX) {
        g_maps[g_nmaps].from     = g_wp_from;
        g_maps[g_nmaps].from_len = (size_t)n;
        g_maps[g_nmaps].to       = g_wp_to;
        g_maps[g_nmaps].to_len   = (size_t)m;
        g_nmaps++;
        OHOS_REMAP_INFO("[box64-remap] %s -> %s\n", g_wp_from, g_wp_to);
    }

    __atomic_store_n(&g_wineprefix_done, 1, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&g_init_mu);
}
