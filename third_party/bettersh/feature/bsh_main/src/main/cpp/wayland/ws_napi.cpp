// ws_napi.cpp — Wayland 客户端窗口的 ArkTS 绑定（Wayland 线程 → ArkTS UI 线程）
#include "ws_napi.h"
#include "plugin_manager.h"
#include "wayland_server.h"

namespace wsnapi {

// ── toplevel 事件回调（wayland 线程 → ArkTS UI 线程）──
napi_threadsafe_function g_toplevelTsfn = nullptr;

struct ToplevelEvent {
    uint32_t id;
    std::string event;
    std::string json;
};

void ToplevelTsfnCallJs(napi_env env, napi_value jsCb, void*, void* data) {
    auto* ev = static_cast<ToplevelEvent*>(data);
    if (env && jsCb && ev) {
        napi_value undef, args[3];
        napi_get_undefined(env, &undef);
        napi_create_uint32(env, ev->id, &args[0]);
        napi_create_string_utf8(env, ev->event.c_str(), NAPI_AUTO_LENGTH, &args[1]);
        napi_create_string_utf8(env, ev->json.c_str(), NAPI_AUTO_LENGTH, &args[2]);
        napi_call_function(env, undef, jsCb, 3, args, nullptr);
    }
    delete ev;
}

napi_value SetToplevelCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_toplevelTsfn) {
        napi_release_threadsafe_function(g_toplevelTsfn, napi_tsfn_release);
        g_toplevelTsfn = nullptr;
    }
    napi_value resName;
    napi_create_string_utf8(env, "WaymonyToplevel", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, args[0], nullptr, resName,
                                    0, 1, nullptr, nullptr, nullptr,
                                    ToplevelTsfnCallJs, &g_toplevelTsfn);
    WaylandServer::GetInstance()->SetToplevelCallback(
        [](uint32_t id, const char* event, const char* json) {
            if (g_toplevelTsfn) {
                auto* ev = new ToplevelEvent{id, event ? event : "", json ? json : "{}"};
                napi_call_threadsafe_function(g_toplevelTsfn, ev, napi_tsfn_blocking);
            }
        });
    return nullptr;
}

napi_value CreateRenderer(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) return nullptr;
    uint32_t tl = 0, w = 0, h = 0;
    uint64_t surfaceId = 0;
    napi_get_value_uint32(env, args[0], &tl);
    // surfaceId 以 number 传入（ArkTS Number(bigint)），int64 读取
    int64_t sid = 0;
    napi_get_value_int64(env, args[1], &sid);
    surfaceId = (uint64_t)sid;
    if (surfaceId == 0) {
        // 兼容 bigint 传入
        napi_get_value_bigint_uint64(env, args[1], &surfaceId, nullptr);
    }
    napi_get_value_uint32(env, args[2], &w);
    napi_get_value_uint32(env, args[3], &h);
    bool ok = PluginManager::GetInstance()->CreateRenderer(tl, surfaceId, (int)w, (int)h);
    napi_value ret;
    napi_get_boolean(env, ok, &ret);
    return ret;
}

napi_value DestroyRenderer(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t tl = 0;
    if (argc >= 1) napi_get_value_uint32(env, args[0], &tl);
    PluginManager::GetInstance()->DestroyRenderer(tl);
    return nullptr;
}

napi_value ResizeRenderer(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t tl = 0, w = 0, h = 0;
    if (argc >= 3) {
        napi_get_value_uint32(env, args[0], &tl);
        napi_get_value_uint32(env, args[1], &w);
        napi_get_value_uint32(env, args[2], &h);
    }
    PluginManager::GetInstance()->ResizeRenderer(tl, (int)w, (int)h);
    return nullptr;
}

napi_value NotifyToplevelResize(napi_env env, napi_callback_info info) {
    // ArkTS 窗口尺寸变化 → 通知客户端重排（发 xdg configure）
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t tl = 0, w = 0, h = 0;
    if (argc >= 3) {
        napi_get_value_uint32(env, args[0], &tl);
        napi_get_value_uint32(env, args[1], &w);
        napi_get_value_uint32(env, args[2], &h);
    }
    auto* server = WaylandServer::GetInstance();
    if (auto* st = server->FindToplevel(tl)) {
        server->SendToplevelConfigure(tl, (int)w, (int)h, st->maximized);
    }
    return nullptr;
}

napi_value SendToplevelClose(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t tl = 0;
    if (argc >= 1) napi_get_value_uint32(env, args[0], &tl);
    WaylandServer::GetInstance()->SendToplevelClose(tl);
    return nullptr;
}

napi_value GetToplevelInfo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t tl = 0;
    if (argc >= 1) napi_get_value_uint32(env, args[0], &tl);
    std::string title, appId;
    int w = 0, h = 0;
    WaylandServer::GetInstance()->GetToplevelInfo(tl, title, appId, w, h);

    napi_value ret, v;
    napi_create_object(env, &ret);
    napi_create_string_utf8(env, title.c_str(), NAPI_AUTO_LENGTH, &v);
    napi_set_named_property(env, ret, "title", v);
    napi_create_string_utf8(env, appId.c_str(), NAPI_AUTO_LENGTH, &v);
    napi_set_named_property(env, ret, "appId", v);
    napi_create_int32(env, w, &v);
    napi_set_named_property(env, ret, "w", v);
    napi_create_int32(env, h, &v);
    napi_set_named_property(env, ret, "h", v);
    return ret;
}

} // namespace wsnapi
