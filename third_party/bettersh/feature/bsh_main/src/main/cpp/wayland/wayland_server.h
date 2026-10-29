#pragma once
// wayland_server.h — Waymony 嵌入式 Wayland compositor 核心
//
// 每个 xdg_toplevel 映射一个 ArkUI 子窗口，wl_shm 帧 → per-toplevel 帧缓冲 →
// EGL 纹理上屏，输入经 wl_seat 注入。

#include <wayland-server-core.h>
#include <wayland-server-protocol.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

// ── toplevel（= 一个客户端窗口）状态 ─────────────────────
struct ToplevelState {
    uint32_t id = 0;
    wl_resource* surface = nullptr;      // wl_surface
    wl_resource* xdgSurface = nullptr;   // xdg_surface
    wl_resource* xdgToplevel = nullptr;  // xdg_toplevel
    std::string title;
    std::string appId;
    bool maximized = false;

    // window geometry（xdg_surface.set_window_geometry，裁掉客户端装饰/阴影）
    int32_t geomX = 0, geomY = 0, geomW = 0, geomH = 0;
    bool geomValid = false;

    // per-toplevel 帧缓冲（surface_commit 写，渲染线程读）
    std::mutex frameMutex;
    std::vector<uint8_t> pixels;  // BGRA（wl_shm ARGB 内存序）
    int w = 0, h = 0;
    std::atomic<bool> dirty{false};

    // 生命周期
    std::atomic<bool> firstCommit{true};
    // 最近一次已上报给 ArkTS 的尺寸:commit 时不带尺寸变化就不再发事件
    // (客户端每帧 commit,否则会淹没 ArkTS 回调并拖死 compositor 线程)
    int evW = 0, evH = 0;
};

// ── 客户端（= 一个鸿蒙原生应用进程）上下文 ────────────────
struct ClientContext {
    wl_client* client = nullptr;
    std::string id;   // "c1", "c2", ...
    pid_t pid = -1;

    // 输入焦点
    wl_resource* kbFocus = nullptr;
    wl_resource* ptrFocus = nullptr;

    wl_listener destroyListener{};
};

// wl_surface 的私有状态
struct SurfaceState {
    wl_resource* surface = nullptr;
    wl_resource* pendingBuffer = nullptr;
    std::vector<wl_resource*> frameCallbacks;
};

class WaylandServer {
public:
    using ToplevelCb = std::function<void(uint32_t, const char*, const char*)>;

    static WaylandServer* GetInstance();

    bool Start(const std::string& socketPath);
    void Stop();

    // ── toplevel 查询 / 帧 ──
    uint32_t NextToplevelId();
    ToplevelState* FindToplevel(uint32_t id);
    ToplevelState* FindToplevelBySurface(wl_resource* surf);
    std::shared_ptr<ToplevelState> FindToplevelShared(uint32_t id);
    bool TakeLatestFrame(uint32_t id, std::vector<uint8_t>& out, int& w, int& h);
    void GetToplevelInfo(uint32_t id, std::string& title, std::string& appId, int& w, int& h);

    // ── 事件钩子（toplevel → ArkTS）──
    void SetToplevelCallback(ToplevelCb cb) { toplevelCb_ = std::move(cb); }
    void FireToplevelEvent(uint32_t id, const char* event, const char* json = "{}");

    // ── 窗口控制（ArkTS → 客户端）──
    void SendToplevelConfigure(uint32_t id, int w, int h, bool maximized);
    void SendToplevelClose(uint32_t id);

    // ── 输入注入（ArkTS → wl_seat）──
    void DispatchKey(uint32_t toplevelId, uint32_t evdevCode, bool pressed);
    void DispatchModifiers(uint32_t toplevelId, uint32_t d, uint32_t l, uint32_t lk, uint32_t g);
    void DispatchMouseMotion(uint32_t toplevelId, double x, double y);
    void DispatchMouseButton(uint32_t toplevelId, uint32_t button, bool pressed);
    void DispatchMouseAxis(uint32_t toplevelId, double dx, double dy);
    void DispatchMouseEnter(uint32_t toplevelId, double x, double y);
    void DispatchMouseLeave(uint32_t toplevelId);
    /** xdg move/resize 前释放指针按键（避免客户端按钮状态卡住，参照 example-harmonybox） */
    void ReleasePointerButtons(uint32_t toplevelId);
    /** 设置某 client 的键盘焦点（发 wl_keyboard.enter，客户端无 enter 会忽略按键） */
    void SetKeyboardFocusForCtx(const std::shared_ptr<ClientContext>& ctx, wl_resource* surface);

    // ── 协议实现（wl_core，静态供 libwayland 分发）──
    static void compositor_bind(wl_client*, void*, uint32_t, uint32_t);
    static void compositor_create_surface(wl_client*, wl_resource*, uint32_t);
    static void compositor_create_region(wl_client*, wl_resource*, uint32_t);

    static void surface_destroy(wl_client*, wl_resource*);
    static void surface_attach(wl_client*, wl_resource*, wl_resource*, int32_t, int32_t);
    static void surface_damage(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t);
    static void surface_frame(wl_client*, wl_resource*, uint32_t);
    static void surface_commit(wl_client*, wl_resource*);
    static void surface_set_opaque_region(wl_client*, wl_resource*, wl_resource*) {}
    static void surface_set_input_region(wl_client*, wl_resource*, wl_resource*) {}
    static void surface_set_buffer_transform(wl_client*, wl_resource*, int32_t) {}
    static void surface_set_buffer_scale(wl_client*, wl_resource*, int32_t) {}
    static void surface_damage_buffer(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {}
    static void surface_offset(wl_client*, wl_resource*, int32_t, int32_t) {}

    static void region_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
    static void region_add(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {}
    static void region_subtract(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {}

    // wl_seat / wl_keyboard / wl_pointer / wl_touch
    static void seat_bind(wl_client*, void*, uint32_t, uint32_t);
    static void seat_get_pointer(wl_client*, wl_resource*, uint32_t);
    static void seat_get_keyboard(wl_client*, wl_resource*, uint32_t);
    static void seat_get_touch(wl_client*, wl_resource*, uint32_t);
    static void seat_release(wl_client*, wl_resource*);
    static void keyboard_release(wl_client*, wl_resource*);
    static void pointer_release(wl_client*, wl_resource*);
    static void pointer_set_cursor(wl_client*, wl_resource*, uint32_t, wl_resource*, int32_t, int32_t);

    // wl_output
    static void output_bind(wl_client*, void*, uint32_t, uint32_t);
    static void output_release(wl_client*, wl_resource*);

    // wl_subcompositor / wp_viewporter 占位（V1 不实现，仅提供 binding 防客户端失败）
    static void subcompositor_bind(wl_client*, void*, uint32_t, uint32_t);
    static void subcompositor_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
    static void subcompositor_get_subsurface(wl_client*, wl_resource*, uint32_t,
                                             wl_resource*, wl_resource*);
    static void viewporter_bind(wl_client*, void*, uint32_t, uint32_t);
    static void viewporter_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
    static void viewporter_get_viewport(wl_client*, wl_resource*, uint32_t, wl_resource*);

    // 供 xdg_shell.cpp 使用
    std::shared_ptr<ClientContext> GetOrCreateClientCtx(wl_client* c);
    std::shared_ptr<ClientContext> FindClientCtx(wl_client* c);
    void EraseClientCtx(wl_client* c);
    void RegisterToplevel(std::shared_ptr<ToplevelState> tl);
    void UnregisterToplevel(uint32_t id);
    wl_display* GetDisplay() const { return display_; }
    const std::string& GetSocketPath() const { return socketPath_; }

    // xdg_shell 内部：get_toplevel 时登记、surface 销毁清理
    void SetToplevelMaximized(uint32_t id, bool on);
    uint32_t NextSerial() { return wl_display_next_serial(display_); }

    // idle 派发 configure（供 SendToplevelConfigure 的 idle 回调使用）
    void SendIdleConfigure(uint32_t id, int w, int h, bool maximized);
    // 客户端断开清理：回收该 client 的全部 toplevel
    void CleanupClient(wl_client* c);

private:
    WaylandServer() = default;
    void Loop();

    wl_display* display_ = nullptr;
    std::string socketPath_;
    pthread_t loopThread_ = 0;
    std::atomic<bool> running_{false};

    ToplevelCb toplevelCb_;

    // 客户端表
    std::mutex clientsMutex_;
    // 串行化对 wl_display/wl_resource 的访问:输入注入来自 ArkTS 线程,
    // compositor 事件循环在服务线程;libwayland 非线程安全(递归锁因
    // commit 回调内也会走这里)。
    std::recursive_mutex wlMutex_;
    std::unordered_map<wl_client*, std::shared_ptr<ClientContext>> clients_;
    std::atomic<int> clientSeq_{0};

    // toplevel 表
    std::mutex toplevelsMutex_;
    std::unordered_map<uint32_t, std::shared_ptr<ToplevelState>> toplevels_;
    std::atomic<uint32_t> toplevelSeq_{0};

    // seat
    struct SeatState {
        wl_resource* seatRes = nullptr;
        std::vector<wl_resource*> keyboards;
        std::vector<wl_resource*> pointers;
    } seat_;
    int keymapFd_ = -1;
    size_t keymapSize_ = 0;
    bool BuildKeymapFd();

    wl_listener clientCreatedListener_{};
};
