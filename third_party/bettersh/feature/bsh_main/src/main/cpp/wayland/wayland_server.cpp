// wayland_server.cpp — Waymony compositor 核心实现
#include "wayland_server.h"

#include "../common/bsh_thread.h"

#include "xdg-shell-server-protocol.h"
#include "viewporter-server-protocol.h"

#include <algorithm>
#include <cstring>
#include <ctime>
#include <poll.h>
#include <unistd.h>
#include <sys/mman.h>

extern "C" {
#include <linux/memfd.h>
#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001
#endif
int memfd_create(const char* name, unsigned int flags);
}

extern "C" void RegisterXdgShell(wl_display* display);
// 选区/剪贴板协议（wayland/data_device.cpp）。**GTK 拿它当"seat 可用"的前置条件**：
// 没有这个全局，GDK 就永不建 GdkSeat，窗口收不到键鼠 —— 见那个文件的文件头。
extern "C" void RegisterDataDevice(wl_display* display);

#undef LOG_TAG
#define LOG_TAG "BSH_WaylandServer"
#include <hilog/log.h>

#include "crash_trace.h"
#include "plugin_manager.h"   // host 侧崩溃取证（见该文件头）

// ── 接口表 ──────────────────────────────────────────────
static const struct wl_surface_interface kSurfaceImpl = {
    .destroy             = WaylandServer::surface_destroy,
    .attach              = WaylandServer::surface_attach,
    .damage              = WaylandServer::surface_damage,
    .frame               = WaylandServer::surface_frame,
    .set_opaque_region   = WaylandServer::surface_set_opaque_region,
    .set_input_region    = WaylandServer::surface_set_input_region,
    .commit              = WaylandServer::surface_commit,
    .set_buffer_transform = WaylandServer::surface_set_buffer_transform,
    .set_buffer_scale    = WaylandServer::surface_set_buffer_scale,
    .damage_buffer       = WaylandServer::surface_damage_buffer,
    .offset              = WaylandServer::surface_offset,
};

static const struct wl_region_interface kRegionImpl = {
    .destroy  = WaylandServer::region_destroy,
    .add      = WaylandServer::region_add,
    .subtract = WaylandServer::region_subtract,
};

static const struct wl_compositor_interface kCompositorImpl = {
    .create_surface = WaylandServer::compositor_create_surface,
    .create_region  = WaylandServer::compositor_create_region,
};

static const struct wl_seat_interface kSeatImpl = {
    .get_pointer  = WaylandServer::seat_get_pointer,
    .get_keyboard = WaylandServer::seat_get_keyboard,
    .get_touch    = WaylandServer::seat_get_touch,
    .release      = WaylandServer::seat_release,
};

static const struct wl_keyboard_interface kKeyboardImpl = {
    .release = WaylandServer::keyboard_release,
};

static const struct wl_pointer_interface kPointerImpl = {
    .set_cursor = WaylandServer::pointer_set_cursor,
    .release    = WaylandServer::pointer_release,
};

static const struct wl_output_interface kOutputImpl = {
    .release = WaylandServer::output_release,
};

// ── 客户端生命周期 ──────────────────────────────────────
static void OnWlClientCreated(wl_listener*, void* data) {
    auto* client = static_cast<wl_client*>(data);
    WaylandServer::GetInstance()->GetOrCreateClientCtx(client);
}

static void OnWlClientDestroyed(wl_listener* listener, void* /*data*/) {
    ClientContext* ctx = nullptr;
    ctx = wl_container_of(listener, ctx, destroyListener);
    if (!ctx) return;
    OH_LOG_INFO(LOG_APP, "client destroyed id=%{public}s", ctx->id.c_str());
    WaylandServer::GetInstance()->CleanupClient(ctx->client);
    WaylandServer::GetInstance()->EraseClientCtx(ctx->client);
}

// ── 单例 / 生命周期 ─────────────────────────────────────
WaylandServer* WaylandServer::GetInstance() {
    static WaylandServer s;
    return &s;
}

std::shared_ptr<ClientContext> WaylandServer::GetOrCreateClientCtx(wl_client* c) {
    if (!c) return nullptr;
    std::lock_guard<std::mutex> lk(clientsMutex_);
    auto it = clients_.find(c);
    if (it != clients_.end()) return it->second;

    auto ctx = std::make_shared<ClientContext>();
    ctx->client = c;
    ctx->id = "c" + std::to_string(++clientSeq_);

    pid_t pid = -1; uid_t uid = 0; gid_t gid = 0;
    wl_client_get_credentials(c, &pid, &uid, &gid);
    ctx->pid = pid;

    ctx->destroyListener.notify = OnWlClientDestroyed;
    wl_client_add_destroy_listener(c, &ctx->destroyListener);

    clients_[c] = ctx;
    OH_LOG_INFO(LOG_APP, "client connected id=%{public}s pid=%{public}d",
                ctx->id.c_str(), (int)pid);
    return ctx;
}

std::shared_ptr<ClientContext> WaylandServer::FindClientCtx(wl_client* c) {
    if (!c) return nullptr;
    std::lock_guard<std::mutex> lk(clientsMutex_);
    auto it = clients_.find(c);
    return (it == clients_.end()) ? nullptr : it->second;
}

void WaylandServer::EraseClientCtx(wl_client* c) {
    if (!c) return;
    std::lock_guard<std::mutex> lk(clientsMutex_);
    clients_.erase(c);
}

bool WaylandServer::Start(const std::string& socketPath) {
    if (running_) return true;

    InstallHostCrashTrace();   // host 侧崩溃取证（见 wayland/crash_trace.h）

    unlink(socketPath.c_str());

    display_ = wl_display_create();
    if (!display_) return false;

    clientCreatedListener_.notify = OnWlClientCreated;
    wl_display_add_client_created_listener(display_, &clientCreatedListener_);

    // 鸿蒙无 XDG_RUNTIME_DIR：从绝对路径拆分目录 + 文件名，setenv 给客户端继承
    std::string dir = socketPath.substr(0, socketPath.find_last_of('/'));
    std::string name = socketPath.substr(socketPath.find_last_of('/') + 1);
    if (dir.empty()) dir = "/tmp";
    socketPath_ = socketPath;
    setenv("XDG_RUNTIME_DIR", dir.c_str(), 1);
    if (wl_display_add_socket(display_, name.c_str()) != 0) {
        OH_LOG_ERROR(LOG_APP, "wl_display_add_socket(%{public}s) failed", name.c_str());
        return false;
    }
    setenv("WAYLAND_DISPLAY", name.c_str(), 1);

    // globals
    wl_global_create(display_, &wl_compositor_interface, 4, this, compositor_bind);
    wl_display_init_shm(display_);
    wl_global_create(display_, &wl_subcompositor_interface, 1, this, subcompositor_bind);
    wl_global_create(display_, &wp_viewporter_interface, 1, this, viewporter_bind);
    wl_global_create(display_, &wl_output_interface, 4, this, output_bind);
    RegisterXdgShell(display_);
    wl_global_create(display_, &wl_seat_interface, 8, this, seat_bind);
    RegisterDataDevice(display_);
    BuildKeymapFd();

    running_ = true;
    // 大栈：这条线程要处理**任意第三方客户端**发来的协议流（Electron/GTK 都走过），
    // musl 默认的 128KB 会被撑爆（见 common/bsh_thread.h 的说明）。
    loopThread_ = bsh::StartThread([this] { Loop(); });
    OH_LOG_INFO(LOG_APP, "wayland server started at %{public}s", socketPath.c_str());
    return true;
}

void WaylandServer::Stop() {
    if (!running_) return;
    running_ = false;
    if (display_) wl_display_terminate(display_);
    if (loopThread_) { pthread_join(loopThread_, nullptr); loopThread_ = 0; }
    if (display_) {
        wl_display_destroy(display_);
        display_ = nullptr;
    }
    // 清空残留状态
    {
        std::lock_guard<std::mutex> lk(toplevelsMutex_);
        toplevels_.clear();
    }
    {
        std::lock_guard<std::mutex> lk(clientsMutex_);
        clients_.clear();
    }
    if (keymapFd_ >= 0) { close(keymapFd_); keymapFd_ = -1; }
}

void WaylandServer::Loop() {
    wl_event_loop* loop = wl_display_get_event_loop(display_);
    int epfd = wl_event_loop_get_fd(loop);
    while (running_) {
        // 等事件时不持锁:dispatch 是阻塞调用,若罩在锁里,ArkTS 线程的
        // 输入注入要排队等一整轮(实测 lockWait 到 1.7s);而且解锁后循环立刻
        // 重新抢锁,唤醒中的等待者还会被反复插队(互斥量无公平性保证)。
        // poll 只看 epoll fd 是否就绪(含 libwayland 的 eventfd/timerfd),
        // 20ms 超时兜底 timer/idle 源。
        struct pollfd pfd{ epfd, POLLIN, 0 };
        poll(&pfd, 1, 20);

        // 只在真正处理事件期间持锁(libwayland 非线程安全)
        std::lock_guard<std::recursive_mutex> wlGuard(wlMutex_);
        wl_event_loop_dispatch(loop, 0);
        wl_display_flush_clients(display_);
    }
}

// ── toplevel 管理 ──────────────────────────────────────
uint32_t WaylandServer::NextToplevelId() { return ++toplevelSeq_; }

void WaylandServer::RegisterToplevel(std::shared_ptr<ToplevelState> tl) {
    std::lock_guard<std::mutex> lk(toplevelsMutex_);
    toplevels_[tl->id] = std::move(tl);
}

void WaylandServer::UnregisterToplevel(uint32_t id) {
    std::shared_ptr<ToplevelState> victim;
    {
        std::lock_guard<std::mutex> lk(toplevelsMutex_);
        auto it = toplevels_.find(id);
        if (it == toplevels_.end()) return;
        victim = std::move(it->second);
        toplevels_.erase(it);
    }
    // 置空 wl_resource 指针：client 断开时这些资源已被（或即将被）释放，
    // 后续 ArkTS 鼠标/键盘事件经 CtxForToplevel 的 !surface 检查短路，防悬垂崩溃
    if (victim) {
        victim->surface = nullptr;
        victim->xdgSurface = nullptr;
        victim->xdgToplevel = nullptr;
    }
    OH_LOG_INFO(LOG_APP, "toplevel destroyed id=%{public}u", id);
    FireToplevelEvent(id, "destroyed");
    /* 主动回收这个 toplevel 的渲染器。为什么不能只靠 ArkTS 的 onSurfaceDestroyed：
     * guest 自己断开时那条回调不一定会来 —— 实测每个跑过的 code 都在
     * PluginManager::renderers_ 里留下一个 60fps 空转的渲染线程 + EGL 上下文（STATUS §43.2）。
     * 放在锁外：DestroyRenderer 要 join 渲染线程，而渲染线程可能正持这两把锁。 */
    PluginManager::GetInstance()->DestroyRenderer(id);
}

ToplevelState* WaylandServer::FindToplevel(uint32_t id) {
    std::lock_guard<std::mutex> lk(toplevelsMutex_);
    auto it = toplevels_.find(id);
    return (it == toplevels_.end()) ? nullptr : it->second.get();
}

std::shared_ptr<ToplevelState> WaylandServer::FindToplevelShared(uint32_t id) {
    std::lock_guard<std::mutex> lk(toplevelsMutex_);
    auto it = toplevels_.find(id);
    return (it == toplevels_.end()) ? nullptr : it->second;
}

ToplevelState* WaylandServer::FindToplevelBySurface(wl_resource* surf) {
    std::lock_guard<std::mutex> lk(toplevelsMutex_);
    for (auto& [id, tl] : toplevels_) {
        (void)id;
        if (tl->surface == surf) return tl.get();
    }
    return nullptr;
}

void WaylandServer::CleanupClient(wl_client* c) {
    // 收集该 client 的 toplevel，逐个走 UnregisterToplevel（发 destroyed 给 ArkTS）
    std::vector<uint32_t> ids;
    {
        std::lock_guard<std::mutex> lk(toplevelsMutex_);
        for (auto& [id, tl] : toplevels_) {
            if (wl_resource_get_client(tl->surface) == c) ids.push_back(id);
        }
    }
    for (uint32_t id : ids) UnregisterToplevel(id);
}

bool WaylandServer::TakeLatestFrame(uint32_t id, std::vector<uint8_t>& out,
                                    int& w, int& h) {
    /* 渲染线程"进了 while 就再没出去"（STATUS §40）—— 这里把两把锁的获取各打一条，
     * 一次运行就能判出卡在哪把（`FindToplevelShared` 拿 toplevelsMutex_，
     * 然后这里拿 frameMutex）。只打前 20 次。 */
    static std::atomic<int> s_lockLog{0};
    const bool logIt = s_lockLog.fetch_add(1) < 20;
    if (logIt) OH_LOG_INFO(LOG_APP, "takeFrame#%{public}d enter id=%{public}u", s_lockLog.load(), id);
    auto tl = FindToplevelShared(id);
    if (logIt) OH_LOG_INFO(LOG_APP, "takeFrame#%{public}d toplevelsMutex ok,tl=%{public}d", s_lockLog.load(), tl ? 1 : 0);
    if (!tl) return false;
    std::lock_guard<std::mutex> lk(tl->frameMutex);
    if (logIt) OH_LOG_INFO(LOG_APP, "takeFrame#%{public}d frameMutex ok", s_lockLog.load());
    bool expected = true;
    if (!tl->dirty.compare_exchange_strong(expected, false)) return false;
    out = tl->pixels;
    w = tl->w;
    h = tl->h;
    return true;
}

void WaylandServer::GetToplevelInfo(uint32_t id, std::string& title,
                                    std::string& appId, int& w, int& h) {
    auto tl = FindToplevelShared(id);
    if (!tl) { title = ""; appId = ""; w = 0; h = 0; return; }
    title = tl->title;
    appId = tl->appId;
    std::lock_guard<std::mutex> lk(tl->frameMutex);
    w = tl->w;
    h = tl->h;
}

void WaylandServer::FireToplevelEvent(uint32_t id, const char* event, const char* json) {
    if (toplevelCb_) toplevelCb_(id, event, json);
}

void WaylandServer::SetToplevelMaximized(uint32_t id, bool on) {
    if (auto* tl = FindToplevel(id)) tl->maximized = on;
}

// ── 窗口控制 ────────────────────────────────────────────
namespace {
struct ConfigureCtx {
    uint32_t id;
    int w, h;
    bool maximized;
};
}  // namespace

static void idle_send_configure(void* data) {
    auto* c = static_cast<ConfigureCtx*>(data);
    WaylandServer::GetInstance()->SendIdleConfigure(c->id, c->w, c->h, c->maximized);
    delete c;
}

void WaylandServer::SendToplevelConfigure(uint32_t id, int w, int h, bool maximized) {
    // 跨线程（ArkTS 线程 → wayland 线程）派发：wl_event_loop_add_idle 保证线程安全
    auto* c = new ConfigureCtx{id, w, h, maximized};
    wl_event_loop* loop = wl_display_get_event_loop(display_);
    wl_event_loop_add_idle(loop, idle_send_configure, c);
}

void WaylandServer::SendIdleConfigure(uint32_t id, int w, int h, bool maximized) {
    auto tl = FindToplevelShared(id);
    if (!tl || !tl->xdgToplevel || !tl->xdgSurface) return;

    wl_array states;
    wl_array_init(&states);
    uint32_t* st = static_cast<uint32_t*>(wl_array_add(&states, sizeof(uint32_t)));
    *st = XDG_TOPLEVEL_STATE_ACTIVATED;
    if (maximized) {
        st = static_cast<uint32_t*>(wl_array_add(&states, sizeof(uint32_t)));
        *st = XDG_TOPLEVEL_STATE_MAXIMIZED;
    }
    xdg_toplevel_send_configure(tl->xdgToplevel, w, h, &states);
    wl_array_release(&states);
    /* 发下去的就是 guest 会照着画的尺寸。ArkTS 侧 surface 是**物理**像素，
     * 而 xdg_toplevel 的 configure 尺寸按协议是**逻辑**像素 —— 这两个口径必须一致，
     * 不然 guest 会以为自己该画物理那么大（症状：内容整体放大一圈/布局错乱）。
     * 打出来才判得了，见 build/vscode/STATUS.md §30.1。 */
    OH_LOG_INFO(LOG_APP, "configure tl=%{public}u %{public}dx%{public}d max=%{public}d",
                id, w, h, maximized ? 1 : 0);

    uint32_t serial = NextSerial();
    xdg_surface_send_configure(tl->xdgSurface, serial);
    wl_display_flush_clients(display_);
}

void WaylandServer::SendToplevelClose(uint32_t id) {
    auto tl = FindToplevelShared(id);
    if (tl && tl->xdgToplevel) xdg_toplevel_send_close(tl->xdgToplevel);
}

// ── compositor / surface ────────────────────────────────
void WaylandServer::compositor_bind(wl_client* client, void*, uint32_t version, uint32_t id) {
    wl_resource* res = wl_resource_create(client, &wl_compositor_interface, version, id);
    wl_resource_set_implementation(res, &kCompositorImpl, nullptr, nullptr);
}

void WaylandServer::compositor_create_surface(wl_client* client, wl_resource* compositorRes,
                                              uint32_t id) {
    auto* state = new SurfaceState();
    wl_resource* surfRes = wl_resource_create(client, &wl_surface_interface,
                                              wl_resource_get_version(compositorRes), id);
    state->surface = surfRes;
    wl_resource_set_implementation(surfRes, &kSurfaceImpl, state, [](wl_resource* r) {
        auto* self = WaylandServer::GetInstance();
        // surface 销毁：若它是某个 toplevel 的 surface，先置空其指针
        // （后续 ArkTS 鼠标/键盘事件经 CtxForToplevel 的 !surface 检查短路，
        //   避免访问已释放的 wl_resource 悬垂崩溃），再销毁 xdg_surface/xdg_toplevel
        // 资源（触发 xdg_shell 的清理回调 → UnregisterToplevel），保证资源与状态一致
        if (auto* tl = self->FindToplevelBySurface(r)) {
            tl->surface = nullptr;
            if (tl->xdgSurface) {
                wl_resource_destroy(tl->xdgSurface);
            } else {
                self->UnregisterToplevel(tl->id);
            }
        }
        delete static_cast<SurfaceState*>(wl_resource_get_user_data(r));
    });
}

void WaylandServer::compositor_create_region(wl_client* client, wl_resource* compositorRes,
                                             uint32_t id) {
    wl_resource* res = wl_resource_create(client, &wl_region_interface,
                                          wl_resource_get_version(compositorRes), id);
    wl_resource_set_implementation(res, &kRegionImpl, nullptr, nullptr);
}

void WaylandServer::surface_destroy(wl_client*, wl_resource* surfRes) {
    wl_resource_destroy(surfRes);
}

void WaylandServer::surface_attach(wl_client*, wl_resource* surfRes, wl_resource* buffer,
                                   int32_t, int32_t) {
    auto* s = static_cast<SurfaceState*>(wl_resource_get_user_data(surfRes));
    if (s) s->pendingBuffer = buffer;
}

void WaylandServer::surface_damage(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {}

void WaylandServer::surface_frame(wl_client* client, wl_resource* surfRes, uint32_t cbId) {
    auto* s = static_cast<SurfaceState*>(wl_resource_get_user_data(surfRes));
    wl_resource* cbRes = wl_resource_create(client, &wl_callback_interface, 1, cbId);
    if (s) s->frameCallbacks.push_back(cbRes);
}

void WaylandServer::surface_commit(wl_client* client, wl_resource* surfRes) {
    auto* s = static_cast<SurfaceState*>(wl_resource_get_user_data(surfRes));
    auto* self = GetInstance();
    if (!s) return;

    /* 前 300 次 commit 各打一条：用来判定"窗口是不是活的"（只打首帧的话，
     * 看不出客户端还在不在画；打全量又会刷爆 hilog，所以封顶）。 */
    {
        static std::atomic<uint32_t> s_n{0};
        uint32_t n = s_n.fetch_add(1);
        if (n < 300)
            OH_LOG_INFO(LOG_APP, "commit #%{public}u buf=%{public}d cb=%{public}zu",
                        n, s->pendingBuffer ? 1 : 0, s->frameCallbacks.size());
    }

    uint32_t now = (uint32_t)(time(nullptr) * 1000);
    auto finishCallbacks = [&]() {
        for (auto* cb : s->frameCallbacks) {
            wl_callback_send_done(cb, now);
            wl_resource_destroy(cb);
        }
        s->frameCallbacks.clear();
    };

    // NULL buffer commit（unmap）：仅回 frame callback
    if (!s->pendingBuffer) {
        finishCallbacks();
        return;
    }

    // 只有 toplevel surface 参与渲染；cursor/popup 等其它 surface 直接释放
    auto* tl = self->FindToplevelBySurface(surfRes);
    if (!tl) {
        wl_buffer_send_release(s->pendingBuffer);
        s->pendingBuffer = nullptr;
        finishCallbacks();
        return;
    }

    wl_shm_buffer* shm = wl_shm_buffer_get(s->pendingBuffer);
    if (!shm) {
        OH_LOG_WARN(LOG_APP, "commit non-SHM buffer tl=%{public}u", tl->id);
        wl_buffer_send_release(s->pendingBuffer);
        s->pendingBuffer = nullptr;
        finishCallbacks();
        return;
    }

    const int32_t bufW = wl_shm_buffer_get_width(shm);
    const int32_t bufH = wl_shm_buffer_get_height(shm);
    const int32_t stride = wl_shm_buffer_get_stride(shm);

    // window_geometry 裁剪（裁掉 weston 窗口阴影/标题栏，显示纯内容区）
    int32_t srcX = 0, srcY = 0, outW = bufW, outH = bufH;
    if (tl->geomValid) {
        srcX = std::max(0, tl->geomX);
        srcY = std::max(0, tl->geomY);
        outW = std::min(tl->geomW, bufW - srcX);
        outH = std::min(tl->geomH, bufH - srcY);
        if (outW <= 0 || outH <= 0) {
            srcX = 0; srcY = 0; outW = bufW; outH = bufH;
        }
    }

    wl_shm_buffer_begin_access(shm);
    const uint8_t* data = static_cast<const uint8_t*>(wl_shm_buffer_get_data(shm));
    {
        std::lock_guard<std::mutex> lk(tl->frameMutex);
        const int dstStride = outW * 4;
        tl->pixels.resize((size_t)dstStride * outH);
        if (srcX == 0 && srcY == 0 && outW == bufW && outH == bufH && stride == bufW * 4) {
            std::memcpy(tl->pixels.data(), data, (size_t)stride * outH);
        } else {
            for (int row = 0; row < outH; ++row) {
                const uint8_t* srcRow = data + (size_t)(srcY + row) * stride + (size_t)srcX * 4;
                std::memcpy(tl->pixels.data() + (size_t)row * dstStride, srcRow, dstStride);
            }
        }
        /* 窗口出来是**黑**的（截图见 build/vscode/STATUS.md §36）—— 这条日志用来区分
         * "guest 交来的帧本身就是黑" 与 "我们收下了但没传/没画"。前 16KB 里数非零像素、
         * 再看头 4 字节（BGRA）。只打前 12 次，避免刷屏。 */
        {
            static std::atomic<int> s_frameLog{0};
            if (s_frameLog.fetch_add(1) < 12) {
                const size_t n = tl->pixels.size();
                size_t nz = 0;
                for (size_t i = 0; i + 3 < n && i < 65536; i += 4)
                    if (tl->pixels[i] || tl->pixels[i + 1] || tl->pixels[i + 2]) nz++;
                OH_LOG_INFO(LOG_APP,
                    "frame tl=%{public}u buf=%{public}dx%{public}d out=%{public}dx%{public}d "
                    "stride=%{public}d bytes=%{public}zu 前16KB非零=%{public}zu "
                    "b0..3=%{public}02x%{public}02x%{public}02x%{public}02x",
                    tl->id, bufW, bufH, outW, outH, stride, n, nz,
                    n ? tl->pixels[0] : 0, n > 1 ? tl->pixels[1] : 0,
                    n > 2 ? tl->pixels[2] : 0, n > 3 ? tl->pixels[3] : 0);
            }
        }
        tl->w = outW;
        tl->h = outH;
        tl->dirty.store(true);
    }
    wl_shm_buffer_end_access(shm);

    wl_buffer_send_release(s->pendingBuffer);
    s->pendingBuffer = nullptr;
    finishCallbacks();

    // 首帧 → created(ArkTS 建窗);仅在尺寸变化时上报 resize
    // (客户端每帧 commit,尺寸不变就不该再驱动 ArkTS,否则回调被淹没、
    //  compositor 线程被阻塞式 tsfn 拖死,最终客户端 broken pipe)
    bool first = tl->firstCommit.exchange(false);
    if (first) {
        OH_LOG_INFO(LOG_APP, "toplevel first commit id=%{public}u %{public}dx%{public}d",
                    tl->id, outW, outH);
        tl->evW = outW;
        tl->evH = outH;
        // 键盘焦点：客户端需收到 wl_keyboard.enter 才会处理按键（此前 kbFocus 从未设置）
        if (auto ctx = self->FindClientCtx(client)) {
            self->SetKeyboardFocusForCtx(ctx, surfRes);
        }
        char json[160];
        snprintf(json, sizeof(json), "{\"title\":\"%s\",\"appId\":\"%s\",\"w\":%d,\"h\":%d}",
                 tl->title.c_str(), tl->appId.c_str(), outW, outH);
        self->FireToplevelEvent(tl->id, "created", json);
    } else if (outW != tl->evW || outH != tl->evH) {
        tl->evW = outW;
        tl->evH = outH;
        char json[64];
        snprintf(json, sizeof(json), "{\"w\":%d,\"h\":%d}", outW, outH);
        self->FireToplevelEvent(tl->id, "resize", json);
    }
}

// ── seat / 输入注入 ─────────────────────────────────────
bool WaylandServer::BuildKeymapFd() {
    static const char kKeymap[] =
        "xkb_keymap {\n"
        "  xkb_keycodes  { include \"evdev+aliases(qwerty)\" };\n"
        "  xkb_types     { include \"complete\" };\n"
        "  xkb_compat    { include \"complete\" };\n"
        "  xkb_symbols   { include \"pc+us+inet(evdev)\" };\n"
        "};\n";
    keymapSize_ = sizeof(kKeymap);
    int fd = memfd_create("waymony-xkb", MFD_CLOEXEC);
    if (fd < 0) return false;
    if (ftruncate(fd, (off_t)keymapSize_) < 0) { close(fd); return false; }
    void* p = mmap(nullptr, keymapSize_, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) { close(fd); return false; }
    memcpy(p, kKeymap, keymapSize_);
    munmap(p, keymapSize_);
    keymapFd_ = fd;
    return true;
}

void WaylandServer::seat_bind(wl_client* c, void*, uint32_t v, uint32_t id) {
    auto* self = GetInstance();
    wl_resource* res = wl_resource_create(c, &wl_seat_interface, v, id);
    wl_resource_set_implementation(res, &kSeatImpl, self, nullptr);
    self->seat_.seatRes = res;
    wl_seat_send_capabilities(res, WL_SEAT_CAPABILITY_KEYBOARD | WL_SEAT_CAPABILITY_POINTER);
    if (v >= 2) wl_seat_send_name(res, "default");
}

void WaylandServer::seat_get_keyboard(wl_client* c, wl_resource* sr, uint32_t id) {
    auto* self = GetInstance();
    wl_resource* kb = wl_resource_create(c, &wl_keyboard_interface,
                                         wl_resource_get_version(sr), id);
    wl_resource_set_implementation(kb, &kKeyboardImpl, self, [](wl_resource* r) {
        auto& v = WaylandServer::GetInstance()->seat_.keyboards;
        v.erase(std::remove(v.begin(), v.end(), r), v.end());
    });
    self->seat_.keyboards.push_back(kb);

    if (self->keymapFd_ >= 0) {
        wl_keyboard_send_keymap(kb, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
                                self->keymapFd_, (uint32_t)self->keymapSize_);
    }
    if (wl_resource_get_version(kb) >= 4) {
        wl_keyboard_send_repeat_info(kb, 25, 400);
    }
    auto ctx = self->FindClientCtx(c);
    if (ctx && ctx->kbFocus) {
        wl_array keys;
        wl_array_init(&keys);
        wl_keyboard_send_enter(kb, self->NextSerial(), ctx->kbFocus, &keys);
        wl_array_release(&keys);
    }
}

void WaylandServer::seat_get_pointer(wl_client* c, wl_resource* sr, uint32_t id) {
    auto* self = GetInstance();
    wl_resource* p = wl_resource_create(c, &wl_pointer_interface,
                                        wl_resource_get_version(sr), id);
    wl_resource_set_implementation(p, &kPointerImpl, self, [](wl_resource* r) {
        auto& v = WaylandServer::GetInstance()->seat_.pointers;
        v.erase(std::remove(v.begin(), v.end(), r), v.end());
    });
    self->seat_.pointers.push_back(p);
}

void WaylandServer::seat_get_touch(wl_client* c, wl_resource* sr, uint32_t id) {
    // V1：touch 仅提供对象，事件不注入
    static const struct wl_touch_interface kTouchImpl = {
        .release = [](wl_client*, wl_resource* r) { wl_resource_destroy(r); }
    };
    wl_resource* t = wl_resource_create(c, &wl_touch_interface, 1, id);
    wl_resource_set_implementation(t, &kTouchImpl, nullptr, nullptr);
}

void WaylandServer::seat_release(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
void WaylandServer::keyboard_release(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
void WaylandServer::pointer_release(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
void WaylandServer::pointer_set_cursor(wl_client*, wl_resource*, uint32_t,
                                       wl_resource*, int32_t, int32_t) {
    // V1 不实现自定义光标
}

// 焦点（按 toplevel 的归属 client 设置）
static std::shared_ptr<ClientContext> CtxForToplevel(uint32_t toplevelId) {
    auto tl = WaylandServer::GetInstance()->FindToplevelShared(toplevelId);
    if (!tl || !tl->surface) return nullptr;
    return WaylandServer::GetInstance()->FindClientCtx(wl_resource_get_client(tl->surface));
}

void WaylandServer::DispatchKey(uint32_t toplevelId, uint32_t code, bool pressed) {
    std::lock_guard<std::recursive_mutex> wlGuard(wlMutex_);
    auto ctx = CtxForToplevel(toplevelId);
    if (!ctx) return;
    uint32_t serial = NextSerial();
    uint32_t t = (uint32_t)(time(nullptr) * 1000);
    for (auto* k : seat_.keyboards) {
        if (wl_resource_get_client(k) != ctx->client) continue;
        wl_keyboard_send_key(k, serial, t, code,
                             pressed ? WL_KEYBOARD_KEY_STATE_PRESSED
                                     : WL_KEYBOARD_KEY_STATE_RELEASED);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchModifiers(uint32_t toplevelId, uint32_t d, uint32_t l,
                                      uint32_t lk, uint32_t g) {
    std::lock_guard<std::recursive_mutex> wlGuard(wlMutex_);
    auto ctx = CtxForToplevel(toplevelId);
    if (!ctx) return;
    uint32_t serial = NextSerial();
    for (auto* k : seat_.keyboards) {
        if (wl_resource_get_client(k) != ctx->client) continue;
        wl_keyboard_send_modifiers(k, serial, d, l, lk, g);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchMouseMotion(uint32_t toplevelId, double x, double y) {
    std::lock_guard<std::recursive_mutex> wlGuard(wlMutex_);
    auto ctx = CtxForToplevel(toplevelId);
    if (!ctx || !ctx->ptrFocus) return;
    // geometry 补偿（参照 example-harmonybox DispatchMouseMotion）：
    // ArkTS 按裁剪后的内容尺寸（tl->w/h）比例映射 → 内容坐标；加回 geometry 偏移
    // 得到 buffer 全尺寸坐标，weston 的 frame/内容命中判定才正确。
    auto tl = FindToplevelShared(toplevelId);
    if (tl && tl->surface && tl->geomValid) {
        x += tl->geomX;
        y += tl->geomY;
    }
    uint32_t t = (uint32_t)(time(nullptr) * 1000);
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != ctx->client) continue;
        wl_pointer_send_motion(p, t, wl_fixed_from_double(x), wl_fixed_from_double(y));
        if (wl_resource_get_version(p) >= 5) wl_pointer_send_frame(p);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchMouseButton(uint32_t toplevelId, uint32_t button, bool pressed) {
    std::lock_guard<std::recursive_mutex> wlGuard(wlMutex_);
    auto ctx = CtxForToplevel(toplevelId);
    if (!ctx || !ctx->ptrFocus) return;
    uint32_t serial = NextSerial();
    uint32_t t = (uint32_t)(time(nullptr) * 1000);
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != ctx->client) continue;
        wl_pointer_send_button(p, serial, t, button,
                               pressed ? WL_POINTER_BUTTON_STATE_PRESSED
                                       : WL_POINTER_BUTTON_STATE_RELEASED);
        if (wl_resource_get_version(p) >= 5) wl_pointer_send_frame(p);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchMouseAxis(uint32_t toplevelId, double dx, double dy) {
    std::lock_guard<std::recursive_mutex> wlGuard(wlMutex_);
    auto ctx = CtxForToplevel(toplevelId);
    if (!ctx || !ctx->ptrFocus) return;
    uint32_t t = (uint32_t)(time(nullptr) * 1000);
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != ctx->client) continue;
        if (dx != 0) {
            wl_pointer_send_axis(p, t, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
                                 wl_fixed_from_double(dx));
        }
        if (dy != 0) {
            wl_pointer_send_axis(p, t, WL_POINTER_AXIS_VERTICAL_SCROLL,
                                 wl_fixed_from_double(dy));
        }
        if (wl_resource_get_version(p) >= 5) wl_pointer_send_frame(p);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchMouseEnter(uint32_t toplevelId, double x, double y) {
    std::lock_guard<std::recursive_mutex> wlGuard(wlMutex_);
    auto ctx = CtxForToplevel(toplevelId);
    auto tl = FindToplevelShared(toplevelId);
    if (!ctx || !tl || !tl->surface) return;
    // geometry 补偿（与 DispatchMouseMotion 一致）
    if (tl->geomValid) {
        x += tl->geomX;
        y += tl->geomY;
    }
    ctx->ptrFocus = tl->surface;
    uint32_t serial = NextSerial();
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != ctx->client) continue;
        wl_pointer_send_enter(p, serial, tl->surface,
                              wl_fixed_from_double(x), wl_fixed_from_double(y));
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchMouseLeave(uint32_t toplevelId) {
    std::lock_guard<std::recursive_mutex> wlGuard(wlMutex_);
    auto ctx = CtxForToplevel(toplevelId);
    auto tl = FindToplevelShared(toplevelId);
    if (!ctx || !tl || !tl->surface) return;
    uint32_t serial = NextSerial();
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != ctx->client) continue;
        wl_pointer_send_leave(p, serial, tl->surface);
    }
    if (ctx->ptrFocus == tl->surface) ctx->ptrFocus = nullptr;
    wl_display_flush_clients(display_);
}

void WaylandServer::ReleasePointerButtons(uint32_t toplevelId) {
    std::lock_guard<std::recursive_mutex> wlGuard(wlMutex_);
    // xdg move/resize 触发时，OS 接管拖拽手势，客户端可能收不到按键释放；
    // 这里补发 LEFT/RIGHT/MIDDLE 的 release，保证客户端按钮状态一致。
    auto ctx = CtxForToplevel(toplevelId);
    if (!ctx) return;
    uint32_t serial = NextSerial();
    uint32_t t = (uint32_t)(time(nullptr) * 1000);
    static const uint32_t kButtons[] = {0x110, 0x111, 0x112};  // BTN_LEFT/RIGHT/MIDDLE
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != ctx->client) continue;
        for (uint32_t btn : kButtons) {
            wl_pointer_send_button(p, serial, t, btn,
                                   WL_POINTER_BUTTON_STATE_RELEASED);
        }
        if (wl_resource_get_version(p) >= 5) wl_pointer_send_frame(p);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::SetKeyboardFocusForCtx(const std::shared_ptr<ClientContext>& ctx,
                                           wl_resource* surface) {
    std::lock_guard<std::recursive_mutex> wlGuard(wlMutex_);
    // 客户端只有在收到 wl_keyboard.enter 后才会处理按键（weston/GTK 均如此）。
    // 参照 example-harmonybox SetKeyboardFocusForCtx：只对本 client 的 keyboard 资源
    // 发 leave（旧 surface）+ enter（新 surface），kbFocus 存 per-client。
    if (!ctx) return;
    if (ctx->kbFocus == surface) return;
    uint32_t serial = NextSerial();
    if (ctx->kbFocus) {
        for (auto* k : seat_.keyboards) {
            if (wl_resource_get_client(k) != ctx->client) continue;
            wl_keyboard_send_leave(k, serial, ctx->kbFocus);
        }
    }
    ctx->kbFocus = surface;
    wl_array keys;
    wl_array_init(&keys);
    for (auto* k : seat_.keyboards) {
        if (wl_resource_get_client(k) != ctx->client) continue;
        wl_keyboard_send_enter(k, serial, surface, &keys);
    }
    wl_array_release(&keys);
    wl_display_flush_clients(display_);
}

// ── output（虚拟显示器）─────────────────────────────────
void WaylandServer::output_bind(wl_client* client, void*, uint32_t version, uint32_t id) {
    uint32_t use_ver = std::min(version, 4u);
    wl_resource* res = wl_resource_create(client, &wl_output_interface, use_ver, id);
    wl_resource_set_implementation(res, &kOutputImpl, nullptr, nullptr);

    wl_output_send_geometry(res, 0, 0, 340, 190, WL_OUTPUT_SUBPIXEL_UNKNOWN,
                            "Waymony", "Virtual", WL_OUTPUT_TRANSFORM_NORMAL);
    wl_output_send_mode(res, WL_OUTPUT_MODE_CURRENT | WL_OUTPUT_MODE_PREFERRED,
                        1920, 1080, 60000);
    if (use_ver >= 2) {
        wl_output_send_scale(res, 1);
        wl_output_send_done(res);
    }
}

void WaylandServer::output_release(wl_client*, wl_resource* r) { wl_resource_destroy(r); }

// ── subcompositor / viewporter 占位 ─────────────────────
void WaylandServer::subcompositor_bind(wl_client* client, void*, uint32_t, uint32_t id) {
    static const struct wl_subcompositor_interface kImpl = {
        .destroy        = WaylandServer::subcompositor_destroy,
        .get_subsurface = WaylandServer::subcompositor_get_subsurface,
    };
    wl_resource* res = wl_resource_create(client, &wl_subcompositor_interface, 1, id);
    wl_resource_set_implementation(res, &kImpl, nullptr, nullptr);
}

void WaylandServer::subcompositor_get_subsurface(wl_client* client, wl_resource* res,
                                                 uint32_t id, wl_resource*, wl_resource*) {
    static const struct wl_subsurface_interface kSubImpl = {
        .destroy      = [](wl_client*, wl_resource* r) { wl_resource_destroy(r); },
        .set_position = [](wl_client*, wl_resource*, int32_t, int32_t) {},
        .place_above  = [](wl_client*, wl_resource*, wl_resource*) {},
        .place_below  = [](wl_client*, wl_resource*, wl_resource*) {},
        .set_sync     = [](wl_client*, wl_resource*) {},
        .set_desync   = [](wl_client*, wl_resource*) {},
    };
    wl_resource* sub = wl_resource_create(client, &wl_subsurface_interface,
                                          wl_resource_get_version(res), id);
    if (sub) wl_resource_set_implementation(sub, &kSubImpl, nullptr, nullptr);
}

void WaylandServer::viewporter_bind(wl_client* client, void*, uint32_t, uint32_t id) {
    static const struct wp_viewporter_interface kImpl = {
        .destroy      = WaylandServer::viewporter_destroy,
        .get_viewport = WaylandServer::viewporter_get_viewport,
    };
    wl_resource* res = wl_resource_create(client, &wp_viewporter_interface, 1, id);
    wl_resource_set_implementation(res, &kImpl, nullptr, nullptr);
}

void WaylandServer::viewporter_get_viewport(wl_client* client, wl_resource* res,
                                            uint32_t id, wl_resource*) {
    static const struct wp_viewport_interface kViewportImpl = {
        .destroy        = [](wl_client*, wl_resource* r) { wl_resource_destroy(r); },
        .set_source     = [](wl_client*, wl_resource*, wl_fixed_t, wl_fixed_t,
                             wl_fixed_t, wl_fixed_t) {},
        .set_destination = [](wl_client*, wl_resource*, int32_t, int32_t) {},
    };
    wl_resource* vp = wl_resource_create(client, &wp_viewport_interface,
                                         wl_resource_get_version(res), id);
    if (vp) wl_resource_set_implementation(vp, &kViewportImpl, nullptr, nullptr);
}
