// input_napi.cpp — 键鼠输入注入 NAPI
#include "input_napi.h"
#include "wayland_server.h"

#undef LOG_TAG
#define LOG_TAG "BSH_Input"
#include <hilog/log.h>

namespace {

uint32_t GetUint32(napi_env env, napi_value v) {
    uint32_t r = 0;
    napi_get_value_uint32(env, v, &r);
    return r;
}

double GetDouble(napi_env env, napi_value v) {
    double r = 0;
    napi_get_value_double(env, v, &r);
    return r;
}

bool GetBool(napi_env env, napi_value v) {
    bool r = false;
    napi_get_value_bool(env, v, &r);
    return r;
}

}  // namespace

namespace iwnapi {

napi_value SendKey(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) return nullptr;
    uint32_t tl = GetUint32(env, args[0]);
    uint32_t code = GetUint32(env, args[1]);
    bool pressed = GetBool(env, args[2]);
    WaylandServer::GetInstance()->DispatchKey(tl, code, pressed);
    return nullptr;
}

napi_value SendModifiers(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5) return nullptr;
    uint32_t tl = GetUint32(env, args[0]);
    WaylandServer::GetInstance()->DispatchModifiers(
        tl, GetUint32(env, args[1]), GetUint32(env, args[2]),
        GetUint32(env, args[3]), GetUint32(env, args[4]));
    return nullptr;
}

napi_value SendMouseMove(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) return nullptr;
    WaylandServer::GetInstance()->DispatchMouseMotion(
        GetUint32(env, args[0]), GetDouble(env, args[1]), GetDouble(env, args[2]));
    return nullptr;
}

napi_value SendMouseButton(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) return nullptr;
    /* 这条以前完全没有日志，于是"输入到底有没有送进 guest"是盲区。
     * 打在最外层入口（ArkTS → 合成器），配合 guest 那边是否响应就能判定。 */
    uint32_t tid = GetUint32(env, args[0]);
    uint32_t btn = GetUint32(env, args[1]);
    bool pressed = GetBool(env, args[2]);
    OH_LOG_INFO(LOG_APP, "inject mouseButton tl=%{public}u btn=%{public}u down=%{public}d",
                tid, btn, pressed ? 1 : 0);
    WaylandServer::GetInstance()->DispatchMouseButton(tid, btn, pressed);
    return nullptr;
}

napi_value SendMouseAxis(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) return nullptr;
    WaylandServer::GetInstance()->DispatchMouseAxis(
        GetUint32(env, args[0]), GetDouble(env, args[1]), GetDouble(env, args[2]));
    return nullptr;
}

napi_value SendMouseEnterLeave(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return nullptr;
    uint32_t tl = GetUint32(env, args[0]);
    bool inside = GetBool(env, args[1]);
    if (inside) {
        WaylandServer::GetInstance()->DispatchMouseEnter(tl, 0, 0);
    } else {
        WaylandServer::GetInstance()->DispatchMouseLeave(tl);
    }
    return nullptr;
}

}  // namespace iwnapi
