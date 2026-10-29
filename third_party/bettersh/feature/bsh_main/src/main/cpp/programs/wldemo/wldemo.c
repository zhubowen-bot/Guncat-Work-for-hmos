// programs/wldemo/wldemo.c — Wayland 演示客户端(so 化,命令表 wldemo)
//
// 连接本应用内嵌 compositor,创建 xdg_toplevel 窗口,用 wl_shm
// 持续渲染动态画面(移动色带 + 反弹方块),窗口关闭/SIGTERM 前不主动退出。
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/syscall.h>

#include "wayland-client.h"
#include "protocol/wayland-client-protocol.h"
#include "protocol/xdg-shell-client-protocol.h"

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001
#endif

#define DEF_W 480
#define DEF_H 320
#define FPS 30

struct Ctx {
    struct wl_display* dpy;
    struct wl_registry* reg;
    struct wl_compositor* comp;
    struct wl_shm* shm;
    struct xdg_wm_base* wm;
    struct wl_surface* surf;
    struct xdg_surface* xsurf;
    struct xdg_toplevel* top;
    struct wl_buffer* buf[2];
    uint8_t* px[2];
    size_t px_len;
    int cur;                 /* 当前用于绘制的缓冲下标 */
    int w, h;
    int configured;
    int running;
};

static struct Ctx g;

static int shm_fd_create(size_t size) {
#ifdef SYS_memfd_create
    int fd = (int)syscall(SYS_memfd_create, "wldemo", MFD_CLOEXEC);
#else
    int fd = -1;
#endif
    if (fd < 0) {
        char path[] = "/tmp/wldemo-XXXXXX";
        fd = mkstemp(path);
        if (fd >= 0) unlink(path);
    }
    if (fd < 0) return -1;
    if (ftruncate(fd, (off_t)size) != 0) { close(fd); return -1; }
    return fd;
}

/* 动态画面:横向移动的色带 + 反弹方块(无外部图片依赖) */
static void render_frame(uint32_t t_ms) {
    int w = g.w, h = g.h;
    uint8_t* base = g.px[g.cur];
    if (!base || w <= 0 || h <= 0) return;
    double phase = (t_ms % 6000) / 6000.0;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            double fx = (double)x / w, fy = (double)y / h;
            double v = fx * 0.6 + fy * 0.4 + phase;
            v = v - floor(v);
            uint8_t r = (uint8_t)(v * 255);
            uint8_t gg = (uint8_t)((1.0 - v) * 200);
            uint8_t b = (uint8_t)(128 + 100 * sin((fx + fy + phase) * 6.283));
            uint8_t* p = base + ((size_t)y * w + x) * 4;
            p[0] = b; p[1] = gg; p[2] = r; p[3] = 255;   /* XRGB8888 小端 */
        }
    }
    /* 反弹方块(位置随时间来回) */
    int side = h / 6;
    double sw = (double)(w - side);
    double sh = (double)(h - side);
    int bx = (int)(sw * (0.5 + 0.5 * sin(t_ms / 1500.0)));
    int by = (int)(sh * (0.5 + 0.5 * cos(t_ms / 1100.0)));
    for (int y = by; y < by + side && y < h; y++) {
        for (int x = bx; x < bx + side && x < w; x++) {
            uint8_t* p = base + ((size_t)y * w + x) * 4;
            int edge = (x - bx < 4) || (bx + side - x <= 4) ||
                       (y - by < 4) || (by + side - y <= 4);
            p[0] = edge ? 60 : 250; p[1] = edge ? 60 : 250;
            p[2] = edge ? 60 : 120; p[3] = 255;
        }
    }
    /* 四周边框,便于观察窗口范围 */
    for (int x = 0; x < w; x++) {
        for (int k = 0; k < 2; k++) {
            uint8_t* a = base + ((size_t)k * w + x) * 4;
            uint8_t* b2 = base + ((size_t)(h - 1 - k) * w + x) * 4;
            a[0] = a[1] = a[2] = 255; b2[0] = b2[1] = b2[2] = 255;
        }
    }
}

static void create_buffer(void) {
    for (int i = 0; i < 2; i++) {
        if (g.px[i]) { munmap(g.px[i], g.px_len); g.px[i] = NULL; }
        if (g.buf[i]) { wl_buffer_destroy(g.buf[i]); g.buf[i] = NULL; }
    }
    int w = g.w, h = g.h;
    size_t stride = (size_t)w * 4;
    g.px_len = stride * (size_t)h;
    for (int i = 0; i < 2; i++) {
        int fd = shm_fd_create(g.px_len);
        if (fd < 0) { fprintf(stderr, "wldemo: shm fd failed\n"); return; }
        struct wl_shm_pool* pool = wl_shm_create_pool(g.shm, fd, (int)g.px_len);
        g.buf[i] = wl_shm_pool_create_buffer(pool, 0, w, h, (int)stride,
                                             WL_SHM_FORMAT_XRGB8888);
        wl_shm_pool_destroy(pool);
        g.px[i] = mmap(NULL, g.px_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (g.px[i] == MAP_FAILED) { g.px[i] = NULL; return; }
    }
    g.cur = 0;
}

static const struct wl_callback_listener kFrameListener;   /* 定义在下方 */

static void frame_done(void* data, struct wl_callback* cb, uint32_t) {
    wl_callback_destroy(cb);
    struct Ctx* c = data;
    if (!c->running || !c->px[0]) return;
    c->cur ^= 1;                       /* 交替缓冲,避免复用服务端正在读的那张 */
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint32_t t_ms = (uint32_t)((ts.tv_sec * 1000) + ts.tv_nsec / 1000000);
    render_frame(t_ms);
    static int frames = 0;
    if (++frames <= 10) {
        fprintf(stderr, "wldemo: frame %d (%dx%d)\n", frames, c->w, c->h);
        fflush(stderr);
    }
    wl_surface_attach(c->surf, c->buf[c->cur], 0, 0);
    wl_surface_damage(c->surf, 0, 0, c->w, c->h);
    struct wl_callback* ncb = wl_surface_frame(c->surf);
    wl_callback_add_listener(ncb, &kFrameListener, c);
    wl_surface_commit(c->surf);
}

static const struct wl_callback_listener kFrameListener = { frame_done };

static void xsurf_configure(void* data, struct xdg_surface* xs, uint32_t serial) {
    struct Ctx* c = data;
    xdg_surface_ack_configure(xs, serial);
    if (!c->configured) {
        c->configured = 1;
        create_buffer();
        if (!c->px[0]) return;
        struct wl_callback* cb = wl_surface_frame(c->surf);
        wl_callback_add_listener(cb, &kFrameListener, c);
        wl_surface_commit(c->surf);   /* 首帧由 frame callback 触发 */
    }
}
static const struct xdg_surface_listener kXSurfListener = { xsurf_configure };

static void top_configure(void* data, struct xdg_toplevel*, int32_t w, int32_t h,
                          struct wl_array*) {
    struct Ctx* c = data;
    if (w > 0 && h > 0 && (w != c->w || h != c->h)) {
        c->w = w; c->h = h;
        if (c->configured) create_buffer();
    }
}
static void top_close(void* data, struct xdg_toplevel*) {
    struct Ctx* c = data;
    c->running = 0;
}
static void top_configure_bounds(void*, struct xdg_toplevel*, int32_t, int32_t) {}
static void top_wm_capabilities(void*, struct xdg_toplevel*, struct wl_array*) {}

static const struct xdg_toplevel_listener kTopListener = {
    top_configure, top_close, top_configure_bounds, top_wm_capabilities,
};

static void wm_ping(void*, struct xdg_wm_base* wm, uint32_t serial) {
    xdg_wm_base_pong(wm, serial);
}
static const struct xdg_wm_base_listener kWmListener = { wm_ping };

static void reg_global(void*, struct wl_registry* reg, uint32_t name,
                       const char* iface, uint32_t ver) {
    if (strcmp(iface, wl_compositor_interface.name) == 0) {
        g.comp = wl_registry_bind(reg, name, &wl_compositor_interface,
                                  ver < 4 ? ver : 4);
    } else if (strcmp(iface, wl_shm_interface.name) == 0) {
        g.shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    } else if (strcmp(iface, xdg_wm_base_interface.name) == 0) {
        g.wm = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(g.wm, &kWmListener, &g);
    }
}
static void reg_remove(void*, struct wl_registry*, uint32_t) {}
static const struct wl_registry_listener kRegListener = { reg_global, reg_remove };

static void on_signal(int sig) { (void)sig; g.running = 0; }

static void on_fatal(int sig) {
    fprintf(stderr, "wldemo: FATAL signal %d\n", sig);
    fflush(stderr);
    signal(sig, SIG_DFL);
    raise(sig);
}

int main(int argc, char** argv) {
    (void)argc; (void)argv;
    memset(&g, 0, sizeof g);
    g.w = DEF_W; g.h = DEF_H; g.running = 1;

    /* 连接路径:仅按 WAYLAND_DISPLAY/XDG_RUNTIME_DIR(会话启动时设置) */
    g.dpy = wl_display_connect(NULL);
    if (!g.dpy) {
        fprintf(stderr, "wldemo: connect failed (WAYLAND_DISPLAY=%s)\n",
                getenv("WAYLAND_DISPLAY") ? getenv("WAYLAND_DISPLAY") : "(unset)");
        return 1;
    }

    g.reg = wl_display_get_registry(g.dpy);
    wl_registry_add_listener(g.reg, &kRegListener, &g);
    wl_display_roundtrip(g.dpy);
    if (!g.comp || !g.shm || !g.wm) {
        fprintf(stderr, "wldemo: missing globals comp=%p shm=%p wm=%p\n",
                (void*)g.comp, (void*)g.shm, (void*)g.wm);
        return 1;
    }

    g.surf = wl_compositor_create_surface(g.comp);
    g.xsurf = xdg_wm_base_get_xdg_surface(g.wm, g.surf);
    xdg_surface_add_listener(g.xsurf, &kXSurfListener, &g);
    g.top = xdg_surface_get_toplevel(g.xsurf);
    xdg_toplevel_add_listener(g.top, &kTopListener, &g);
    xdg_toplevel_set_title(g.top, "wldemo");
    wl_surface_commit(g.surf);
    wl_display_roundtrip(g.dpy);

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGPIPE, SIG_IGN);   /* 服务端先断开时不要被 SIGPIPE 杀掉 */
    signal(SIGSEGV, on_fatal);
    signal(SIGBUS, on_fatal);
    signal(SIGABRT, on_fatal);
    signal(SIGILL, on_fatal);

    fprintf(stderr, "wldemo: window up %dx%d, rendering at %d fps\n", g.w, g.h, FPS);
    fflush(stderr);
    while (g.running) {
        if (wl_display_dispatch(g.dpy) < 0) {
            int e = wl_display_get_error(g.dpy);
            fprintf(stderr, "wldemo: dispatch failed: %s (%d)\n", strerror(e), e);
            break;
        }
    }

    for (int i = 0; i < 2; i++) {
        if (g.px[i]) munmap(g.px[i], g.px_len);
        if (g.buf[i]) wl_buffer_destroy(g.buf[i]);
    }
    if (g.top) xdg_toplevel_destroy(g.top);
    if (g.xsurf) xdg_surface_destroy(g.xsurf);
    if (g.surf) wl_surface_destroy(g.surf);
    if (g.wm) xdg_wm_base_destroy(g.wm);
    if (g.shm) wl_shm_destroy(g.shm);
    if (g.comp) wl_compositor_destroy(g.comp);
    wl_registry_destroy(g.reg);
    wl_display_disconnect(g.dpy);
    fprintf(stderr, "wldemo: bye\n");
    return 0;
}
