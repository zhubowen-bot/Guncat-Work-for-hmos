// data_device.cpp — wl_data_device_manager（选区/剪贴板）
//
// ── 为什么必须补它 ──────────────────────────────────────────────────────
// 不是为了剪贴板，而是为了**让 GTK 的窗口能收到键鼠**。GDK 对 `wl_seat` 是**延迟处理**的
// （gtk/gdk/wayland/gdkdisplay-wayland.c 的 registry 处理）：
//
//     else if (strcmp (interface, "wl_seat") == 0) {
//       static const char *required_device_manager_globals[] = {
//         "wl_compositor", "wl_data_device_manager", NULL };
//       closure->base.required_globals = required_device_manager_globals;
//       postpone_on_globals_closure (display_wayland, &closure->base);
//     }
//
// 也就是说：**registry 里没有 `wl_data_device_manager` 这个全局，GDK 就永不建 GdkSeat**。
// 实测症状（补它之前）：GTK 的窗口能建出来、能渲染、主循环也跑，但是
//   * `gdk_display_get_default_seat()` 返回 NULL →
//       `Gdk-CRITICAL: gdk_seat_get_keyboard: assertion 'GDK_IS_SEAT (seat)' failed`
//     （而且 wayland 的 trace 里 `wl_seat` 全局**从未被 bind**）；
//   * 窗口收不到任何键鼠事件。Qt 没这个前置条件，所以 qtwl-demo 一直是有输入的。
//
// ── 实现范围 ────────────────────────────────────────────────────────────
// 按 weston 的语义实现**选区（copy/paste）**这一半：
//   create_data_source / get_data_device / offer / set_selection /
//   data_offer / selection / receive（把 fd 原样转给供方的 send）。
// 于是我们自己的客户端之间（GTK ↔ GTK、GTK ↔ weston-terminal）复制粘贴是通的。
//
// **拖放（DnD）不做**：`start_drag` 收到就回 `wl_data_source.cancelled` —— 协议里"这次
// 拖拽被拒"就是这么表达的，客户端据此收尾、不会卡住。V1 的合成器根本没有"跨窗口拖动手势"
// 这个输入源，与其半做不如明确不做（同 subcompositor/viewporter 那两个占位一个态度）。
//
// ⚠ 每个 request 都必须有处理函数，哪怕是空的：libwayland 分派时**直接调用**接口表里的
//   函数指针，留 NULL 就是一进这个 request 就崩。四个接口的请求顺序照
//   wayland-server-protocol.h 里的结构体定义抄（offer/source/device/manager 四张表）。
//
// 线程模型：协议分派全在合成器的 loop 线程上，所以本文件的状态不需要锁（与 xdg_shell.cpp
// 一致）。宿主侧那把 wlMutex_ 是给"ArkTS 线程注入输入"用的，那条路不碰这里。
#include <wayland-server-core.h>
#include <wayland-server-protocol.h>

#include <algorithm>
#include <string>
#include <vector>

#include "wayland_server.h"

#undef LOG_TAG
#define LOG_TAG "WaymonyDnd"
#include <hilog/log.h>

namespace {

/* 一个选区来源 = 供方。mime 列表在 offer() 里攒起来，转给收方时要用。 */
struct DataSource {
    wl_resource* res = nullptr;
    wl_client*   client = nullptr;
    std::vector<std::string> mimeTypes;
};

/* 给某个收方客户端造的一张"可读句柄"。
 * 收方 receive() 时我们把 fd 原样转给供方的 wl_data_source.send —— 协议就是这么定的：
 * **收方**建管道、把可写的那端交上来，我们只做转发（SCM_RIGHTS 由 libwayland 负责），
 * 收方读自己那根读端；供方写完关闭 → 收方读到 EOF。 */
struct DataOffer {
    wl_resource* res = nullptr;      // wl_data_offer（收方侧对象）
    wl_resource* device = nullptr;   // 它挂在哪个 wl_data_device 上（供方销毁时要能通知收方）
    DataSource*  source = nullptr;   // 只借用；source 先死时置 NULL
};

std::vector<DataSource*>  g_sources;
std::vector<DataOffer*>   g_offers;
std::vector<wl_resource*> g_devices;      // 每个 get_data_device 一个
DataSource* g_selection = nullptr;        // 当前选区（唯一真相）

template <typename T>
void vec_remove(std::vector<T*>& v, T* p) {
    v.erase(std::remove(v.begin(), v.end(), p), v.end());
}

/* ─────────── 前向声明 ─────────── */
void source_destroyed(wl_resource* r);
void offer_destroyed(wl_resource* r);
void device_destroyed(wl_resource* r);

/* 给 @device 造一张 offer，并把它"挂上"（data_offer + 各 mime）。
 * id 传 0 —— libwayland 会**自己分配**一个（wayland-server.c:1915 的
 * `wl_map_insert_new(&client->objects, …)`）：服务端发起创建对象就该这么传，
 * 传别的号会撞客户端自己的 id 空间。 */
wl_resource* make_offer(wl_resource* device, DataSource* src) {
    if (!device || !src) return nullptr;
    wl_resource* offer = wl_resource_create(wl_resource_get_client(device),
                                            &wl_data_offer_interface, 3, 0);
    if (!offer) return nullptr;
    auto* o = new DataOffer;
    o->res = offer;
    o->device = device;
    o->source = src;
    g_offers.push_back(o);
    wl_resource_set_implementation(offer, nullptr, o, offer_destroyed);
    wl_data_device_send_data_offer(device, offer);
    for (const std::string& m : src->mimeTypes)
        wl_data_offer_send_offer(offer, m.c_str());
    return offer;
}

/* 选区变化：给**除供方自己以外**的每个 data_device 发一份新 offer + selection。
 * 不给供方自己发是刻意的 —— 他自己知道自己的选区，收一份自己的 offer 只会让他多绕一圈。 */
void broadcast_selection(DataSource* src) {
    for (wl_resource* dev : g_devices) {
        if (!dev) continue;
        if (src && wl_resource_get_client(dev) == src->client) continue;
        wl_data_device_send_selection(dev, src ? make_offer(dev, src) : nullptr);
    }
}

/* ─────────────────────── wl_data_offer ───────────────────────
 * 请求顺序：accept receive destroy finish set_actions */
void offer_accept(wl_client*, wl_resource*, uint32_t serial, const char* mime_type) {
    // 只有 DnD 才关心 accept（"收不收这个 mime"），选区的复制粘贴不看它。
    // ⚠ 参数顺序是 (serial, mime_type) —— 与 receive 的 (mime, fd) 不一样，照
    //   wayland-server-protocol.h 的原型抄（第一版写反了，编译期就报出来了）。
    (void)serial; (void)mime_type;
}
void offer_receive(wl_client*, wl_resource* r, const char* mime, int32_t fd) {
    auto* o = static_cast<DataOffer*>(wl_resource_get_user_data(r));
    if (!o || !o->source || !o->source->res) return;
    wl_data_source_send_send(o->source->res, mime, fd);
}
void offer_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
void offer_finish(wl_client*, wl_resource*) { /* DnD 专用 */ }
void offer_set_actions(wl_client*, wl_resource*, uint32_t, uint32_t) { /* DnD 专用 */ }

const struct wl_data_offer_interface kOfferImpl = {
    offer_accept, offer_receive, offer_destroy, offer_finish, offer_set_actions,
};

void offer_destroyed(wl_resource* r) {
    auto* o = static_cast<DataOffer*>(wl_resource_get_user_data(r));
    if (!o) return;
    vec_remove(g_offers, o);
    delete o;
}

/* ─────────────────────── wl_data_source ───────────────────────
 * 请求顺序：offer destroy set_actions */
void source_offer(wl_client*, wl_resource* r, const char* mime) {
    auto* src = static_cast<DataSource*>(wl_resource_get_user_data(r));
    if (src && mime) src->mimeTypes.push_back(mime);
}
void source_destroy_req(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
void source_set_actions(wl_client*, wl_resource*, uint32_t) { /* DnD 专用 */ }

const struct wl_data_source_interface kSourceImpl = {
    source_offer, source_destroy_req, source_set_actions,
};

void source_destroyed(wl_resource* r) {
    auto* src = static_cast<DataSource*>(wl_resource_get_user_data(r));
    if (!src) return;
    const bool was_selection = (g_selection == src);
    if (was_selection) g_selection = nullptr;

    /* 引用它的 offer 全部失效：收方那边得知道"选区没了"，否则他手里那张 offer 会一直
     * 指向一个已释放的 source（receive 变成静默 no-op，粘贴表现为"没反应"）。 */
    std::vector<DataOffer*> dead;
    for (DataOffer* o : g_offers)
        if (o->source == src) dead.push_back(o);
    for (DataOffer* o : dead) {
        if (was_selection && o->device) wl_data_device_send_selection(o->device, nullptr);
        vec_remove(g_offers, o);
        if (o->res) wl_resource_set_user_data(o->res, nullptr);   // 之后再来 receive 就是 no-op
        delete o;
    }
    vec_remove(g_sources, src);
    delete src;
}

/* ─────────────────────── wl_data_device ───────────────────────
 * 请求顺序：start_drag set_selection release */
void device_start_drag(wl_client*, wl_resource*, wl_resource* source, wl_resource*,
                       wl_resource*, uint32_t) {
    if (source) wl_data_source_send_cancelled(source);
}
void device_set_selection(wl_client*, wl_resource*, wl_resource* source_res, uint32_t serial) {
    (void)serial;   // 协议里这个 serial 是给客户端做时序判断的，服务端不必校验
    DataSource* src = source_res
        ? static_cast<DataSource*>(wl_resource_get_user_data(source_res)) : nullptr;
    if (g_selection == src) return;

    /* 旧的供方要被告知"你的选区被顶掉了"（协议要求，客户端据此收尾）。 */
    if (g_selection && g_selection->res) wl_data_source_send_cancelled(g_selection->res);
    g_selection = src;
    broadcast_selection(src);
    OH_LOG_INFO(LOG_APP, "selection %{public}s（%{public}zu 个 mime）",
                src ? "set" : "cleared", src ? src->mimeTypes.size() : 0);
}
void device_release(wl_client*, wl_resource* r) { wl_resource_destroy(r); }

const struct wl_data_device_interface kDeviceImpl = {
    device_start_drag, device_set_selection, device_release,
};

void device_destroyed(wl_resource* r) {
    /* 设备没了：挂在它名下的 offer 一并释放（offer 的生命周期依附于 device）。 */
    std::vector<DataOffer*> dead;
    for (DataOffer* o : g_offers)
        if (o->device == r) dead.push_back(o);
    for (DataOffer* o : dead) {
        vec_remove(g_offers, o);
        if (o->res) wl_resource_set_user_data(o->res, nullptr);
        delete o;
    }
    vec_remove(g_devices, r);
}

/* ───────────────── wl_data_device_manager ─────────────────
 * 请求顺序：create_data_source get_data_device */
void mgr_create_data_source(wl_client* cl, wl_resource*, uint32_t id) {
    wl_resource* r = wl_resource_create(cl, &wl_data_source_interface, 3, id);
    if (!r) return;
    auto* src = new DataSource;
    src->res = r;
    src->client = cl;
    g_sources.push_back(src);
    wl_resource_set_implementation(r, &kSourceImpl, src, source_destroyed);
}

void mgr_get_data_device(wl_client* cl, wl_resource*, uint32_t id, wl_resource* seat_res) {
    (void)seat_res;   // 我们只有一个 seat，不做校验（多 seat 的合成器才需要）
    wl_resource* dev = wl_resource_create(cl, &wl_data_device_interface, 3, id);
    if (!dev) return;
    g_devices.push_back(dev);
    wl_resource_set_implementation(dev, &kDeviceImpl, nullptr, device_destroyed);

    /* 后来者也要知道**当前**选区 —— 否则"先复制、后开窗"的程序粘不上。 */
    wl_data_device_send_selection(dev, g_selection ? make_offer(dev, g_selection) : nullptr);
}

const struct wl_data_device_manager_interface kMgrImpl = {
    mgr_create_data_source, mgr_get_data_device,
};

void mgr_bind(wl_client* cl, void*, uint32_t version, uint32_t id) {
    /* GDK 是按 MIN(version, 3) 绑的（gdkdisplay-wayland.c），我们只宣告到 3 —— v3 起
     * 多了 set_actions/finish 这些 DnD 请求，我们收下但不做事（见 kSourceImpl/kOfferImpl）。 */
    const uint32_t v = version < 3 ? version : 3;
    wl_resource* r = wl_resource_create(cl, &wl_data_device_manager_interface, v, id);
    if (!r) return;
    /* destructor 必须是 nullptr：这里没有任何要清的（user_data 是 nullptr，也没存进表里）。
     *
     * ⚠ 这里原来写的是 `[](wl_resource* res) { wl_resource_destroy(res); }` —— 看着像
     * "顺手回收"，实际是**让资源自己销毁自己**：libwayland 的
     *     wl_resource_destroy → destroy_resource → if (resource->destroy) resource->destroy(resource)
     * 不会清 `resource->destroy`，于是同一个 lambda 被无限递归调用，直到把线程栈耗光
     * （崩溃现场正是"fault 落在栈保护页下方"，faultlogger 会误报成 stack-buffer-overflow）。
     * 实测：Chromium/Electron 作为 wayland 客户端连上来、再断开时必崩，把整个 app 带成
     * CppCrash；而且**加多大栈都没用**（128KB 与 8MB 崩得一模一样）。
     * 取证见 build/vscode/STATUS.md（host 侧 pc/lr/fpwalk 指向本行）。 */
    wl_resource_set_implementation(r, &kMgrImpl, nullptr, nullptr);
    OH_LOG_INFO(LOG_APP, "wl_data_device_manager 已绑定（v%{public}u）", v);
}

}  // namespace

extern "C" void RegisterDataDevice(wl_display* display) {
    wl_global_create(display, &wl_data_device_manager_interface, 3, nullptr, mgr_bind);
}
