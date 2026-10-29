// xdg_shell.cpp
#include <wayland-server-core.h>
#include "xdg-shell-server-protocol.h"

#include <algorithm>
#include <cstring>

#include "wayland_server.h"

#undef LOG_TAG
#define LOG_TAG "WaymonyXdg"
#include <hilog/log.h>

namespace {

// ── xdg_toplevel ─────────────────────────────────────────
static void tl_destroy(wl_client*, wl_resource* r) {
    // xdg_toplevel.destroy：置空 ToplevelState 中的资源指针。
    // 否则随后的 xdg_surface 销毁（xs_resource_destroy）会对已销毁的
    // xdgToplevel 再次 wl_resource_destroy → 双重释放崩溃。
    auto* tl = static_cast<ToplevelState*>(wl_resource_get_user_data(r));
    if (tl) tl->xdgToplevel = nullptr;
    wl_resource_destroy(r);
}
static void tl_set_parent(wl_client*, wl_resource*, wl_resource*) {}
static void tl_set_title(wl_client*, wl_resource* r, const char* title) {
    auto* tl = static_cast<ToplevelState*>(wl_resource_get_user_data(r));
    if (!tl) return;
    tl->title = title ? title : "";
    char json[256];
    snprintf(json, sizeof(json), "{\"title\":\"%s\"}", tl->title.c_str());
    WaylandServer::GetInstance()->FireToplevelEvent(tl->id, "title", json);
}
static void tl_set_app_id(wl_client*, wl_resource* r, const char* appId) {
    auto* tl = static_cast<ToplevelState*>(wl_resource_get_user_data(r));
    if (!tl) return;
    tl->appId = appId ? appId : "";
}
static void tl_show_window_menu(wl_client*, wl_resource*, wl_resource*, uint32_t,
                                int32_t, int32_t) {}

static void tl_move(wl_client* client, wl_resource* r, wl_resource*, uint32_t serial) {
    (void)client; (void)serial;
    auto* tl = static_cast<ToplevelState*>(wl_resource_get_user_data(r));
    if (!tl) return;
    // OS 接管拖动前释放指针按键（客户端按钮状态一致，参照 example-harmonybox）
    WaylandServer::GetInstance()->ReleasePointerButtons(tl->id);
    WaylandServer::GetInstance()->FireToplevelEvent(tl->id, "move");
}

static void tl_resize(wl_client*, wl_resource* r, wl_resource*, uint32_t serial,
                      uint32_t edges) {
    (void)serial;
    auto* tl = static_cast<ToplevelState*>(wl_resource_get_user_data(r));
    if (!tl) return;
    WaylandServer::GetInstance()->ReleasePointerButtons(tl->id);
    char json[64];
    snprintf(json, sizeof(json), "{\"edges\":%u}", edges);
    WaylandServer::GetInstance()->FireToplevelEvent(tl->id, "resize_req", json);
}

static void tl_set_max_size(wl_client*, wl_resource*, int32_t, int32_t) {}
static void tl_set_min_size(wl_client*, wl_resource*, int32_t, int32_t) {}

static void tl_set_maximized(wl_client*, wl_resource* r) {
    auto* tl = static_cast<ToplevelState*>(wl_resource_get_user_data(r));
    if (!tl) return;
    tl->maximized = true;
    WaylandServer::GetInstance()->FireToplevelEvent(tl->id, "maximize");
}

static void tl_unset_maximized(wl_client*, wl_resource* r) {
    auto* tl = static_cast<ToplevelState*>(wl_resource_get_user_data(r));
    if (!tl) return;
    tl->maximized = false;
    WaylandServer::GetInstance()->FireToplevelEvent(tl->id, "unmaximize");
}

static void tl_set_fullscreen(wl_client*, wl_resource*, wl_resource*) {}
static void tl_unset_fullscreen(wl_client*, wl_resource*) {}

static void tl_set_minimized(wl_client*, wl_resource* r) {
    auto* tl = static_cast<ToplevelState*>(wl_resource_get_user_data(r));
    if (!tl) return;
    WaylandServer::GetInstance()->FireToplevelEvent(tl->id, "minimize");
}

static const struct xdg_toplevel_interface kToplevelImpl = {
    .destroy          = tl_destroy,
    .set_parent       = tl_set_parent,
    .set_title        = tl_set_title,
    .set_app_id       = tl_set_app_id,
    .show_window_menu = tl_show_window_menu,
    .move             = tl_move,
    .resize           = tl_resize,
    .set_max_size     = tl_set_max_size,
    .set_min_size     = tl_set_min_size,
    .set_maximized    = tl_set_maximized,
    .unset_maximized  = tl_unset_maximized,
    .set_fullscreen   = tl_set_fullscreen,
    .unset_fullscreen = tl_unset_fullscreen,
    .set_minimized    = tl_set_minimized,
};

// ── xdg_surface ──────────────────────────────────────────
struct XdgSurfaceData {
    wl_resource* wlSurface = nullptr;
    wl_resource* xdgSurface = nullptr;
    std::shared_ptr<ToplevelState> toplevel;
};

static void xs_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }

static void xs_get_toplevel(wl_client* client, wl_resource* xsRes, uint32_t id) {
    auto* d = static_cast<XdgSurfaceData*>(wl_resource_get_user_data(xsRes));
    if (!d) return;

    auto* self = WaylandServer::GetInstance();
    auto tl = std::make_shared<ToplevelState>();
    tl->id = self->NextToplevelId();
    tl->surface = d->wlSurface;
    tl->xdgSurface = xsRes;

    wl_resource* tlRes = wl_resource_create(client, &xdg_toplevel_interface,
                                            wl_resource_get_version(xsRes), id);
    tl->xdgToplevel = tlRes;
    // xdg_toplevel 的 user_data 存 ToplevelState（weak 语义：surface 销毁时 toplevel 回收，
    // 但 client 可能先 destroy toplevel 对象——用裸指针，回调里判空即可）
    wl_resource_set_implementation(tlRes, &kToplevelImpl, tl.get(), nullptr);
    d->toplevel = tl;  // 持有 shared_ptr，保证 ToplevelState 存活到 xdg_surface 销毁

    // 立即回 configure：建议尺寸 0×0（客户端自决）+ activated
    wl_array states;
    wl_array_init(&states);
    uint32_t* st = static_cast<uint32_t*>(wl_array_add(&states, sizeof(uint32_t)));
    *st = XDG_TOPLEVEL_STATE_ACTIVATED;
    xdg_toplevel_send_configure(tlRes, 0, 0, &states);
    wl_array_release(&states);

    wl_display* dpy = wl_client_get_display(client);
    uint32_t serial = wl_display_next_serial(dpy);
    xdg_surface_send_configure(xsRes, serial);

    self->RegisterToplevel(tl);
    OH_LOG_INFO(LOG_APP, "get_toplevel id=%{public}u", tl->id);
}

static void xs_get_popup(wl_client* client, wl_resource* xsRes, uint32_t id,
                         wl_resource*, wl_resource*) {
    // V1：popup 未实现，仅创建空对象避免客户端崩溃
    static const struct xdg_popup_interface kPopupImpl = {
        .destroy = [](wl_client*, wl_resource* r) { wl_resource_destroy(r); },
        .grab    = [](wl_client*, wl_resource*, wl_resource*, uint32_t) {},
    };
    wl_resource* pop = wl_resource_create(client, &xdg_popup_interface,
                                          wl_resource_get_version(xsRes), id);
    if (pop) wl_resource_set_implementation(pop, &kPopupImpl, nullptr, nullptr);
}

static void xs_set_window_geometry(wl_client*, wl_resource* xsRes,
                                   int32_t x, int32_t y, int32_t w, int32_t h) {
    auto* d = static_cast<XdgSurfaceData*>(wl_resource_get_user_data(xsRes));
    if (d && d->toplevel) {
        d->toplevel->geomX = x;
        d->toplevel->geomY = y;
        d->toplevel->geomW = w;
        d->toplevel->geomH = h;
        d->toplevel->geomValid = (w > 0 && h > 0);
        OH_LOG_INFO(LOG_APP, "set_window_geometry tl=%{public}u x=%{public}d y=%{public}d w=%{public}d h=%{public}d",
                    d->toplevel->id, x, y, w, h);
    }
}

static void xs_ack_configure(wl_client*, wl_resource* r, uint32_t serial) {
    /* guest 认下 configure 才会按新尺寸画。这里打出来是为了把
     * "我们发了多大 / 它认没认" 对齐（见 wayland_server.cpp 的 configure 日志）。 */
    auto* d = static_cast<XdgSurfaceData*>(wl_resource_get_user_data(r));
    OH_LOG_INFO(LOG_APP, "ack_configure tl=%{public}u serial=%{public}u",
                (d && d->toplevel) ? d->toplevel->id : 0u, serial);
}

static const struct xdg_surface_interface kSurfaceImpl = {
    .destroy             = xs_destroy,
    .get_toplevel        = xs_get_toplevel,
    .get_popup           = xs_get_popup,
    .set_window_geometry = xs_set_window_geometry,
    .ack_configure       = xs_ack_configure,
};

static void xs_resource_destroy(wl_resource* r) {
    auto* d = static_cast<XdgSurfaceData*>(wl_resource_get_user_data(r));
    if (d && d->toplevel) {
        // 先销毁关联的 xdg_toplevel 资源（保证「xdg_toplevel 存活 ⇒ ToplevelState 存活」，
        // 防止 tl_* 回调拿到悬垂 user_data），再回收 toplevel 状态
        if (d->toplevel->xdgToplevel) {
            wl_resource_destroy(d->toplevel->xdgToplevel);
            d->toplevel->xdgToplevel = nullptr;
        }
        WaylandServer::GetInstance()->UnregisterToplevel(d->toplevel->id);
    }
    delete d;
}

// ── xdg_wm_base ──────────────────────────────────────────
static void wm_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }

static void wm_create_positioner(wl_client* c, wl_resource*, uint32_t id) {
    static const struct xdg_positioner_interface kPosImpl = {
        .destroy               = [](wl_client*, wl_resource* r) { wl_resource_destroy(r); },
        .set_size              = [](wl_client*, wl_resource*, int32_t, int32_t) {},
        .set_anchor_rect       = [](wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {},
        .set_anchor            = [](wl_client*, wl_resource*, uint32_t) {},
        .set_gravity           = [](wl_client*, wl_resource*, uint32_t) {},
        .set_constraint_adjustment = [](wl_client*, wl_resource*, uint32_t) {},
        .set_offset            = [](wl_client*, wl_resource*, int32_t, int32_t) {},
        .set_reactive          = [](wl_client*, wl_resource*) {},
        .set_parent_size       = [](wl_client*, wl_resource*, int32_t, int32_t) {},
        .set_parent_configure  = [](wl_client*, wl_resource*, uint32_t) {},
    };
    wl_resource* p = wl_resource_create(c, &xdg_positioner_interface, 3, id);
    if (p) wl_resource_set_implementation(p, &kPosImpl, nullptr, nullptr);
}

static void wm_get_xdg_surface(wl_client* client, wl_resource* wmRes,
                               uint32_t id, wl_resource* surfaceRes) {
    wl_resource* xs = wl_resource_create(client, &xdg_surface_interface,
                                         wl_resource_get_version(wmRes), id);
    auto* d = new XdgSurfaceData();
    d->wlSurface = surfaceRes;
    d->xdgSurface = xs;
    wl_resource_set_implementation(xs, &kSurfaceImpl, d, xs_resource_destroy);
}

static void wm_pong(wl_client*, wl_resource*, uint32_t) {}

static const struct xdg_wm_base_interface kWmBaseImpl = {
    .destroy           = wm_destroy,
    .create_positioner = wm_create_positioner,
    .get_xdg_surface   = wm_get_xdg_surface,
    .pong              = wm_pong,
};

static void wm_base_bind(wl_client* client, void*, uint32_t version, uint32_t id) {
    wl_resource* r = wl_resource_create(client, &xdg_wm_base_interface,
                                        std::min(version, 6u), id);
    wl_resource_set_implementation(r, &kWmBaseImpl, nullptr, nullptr);
    OH_LOG_INFO(LOG_APP, "xdg_wm_base bound v=%{public}u", std::min(version, 6u));
}

}  // namespace

extern "C" void RegisterXdgShell(wl_display* display) {
    wl_global_create(display, &xdg_wm_base_interface, 6, nullptr, wm_base_bind);
    OH_LOG_INFO(LOG_APP, "xdg_wm_base global created");
}
