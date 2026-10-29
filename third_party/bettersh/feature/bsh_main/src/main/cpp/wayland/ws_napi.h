#pragma once
// ws_napi.h — Wayland 客户端窗口的 ArkTS 绑定（Wayland 线程 → ArkTS UI 线程）
#include <napi/native_api.h>

namespace wsnapi {
napi_value SetToplevelCallback(napi_env env, napi_callback_info info);
napi_value CreateRenderer(napi_env env, napi_callback_info info);
napi_value DestroyRenderer(napi_env env, napi_callback_info info);
napi_value ResizeRenderer(napi_env env, napi_callback_info info);
napi_value NotifyToplevelResize(napi_env env, napi_callback_info info);
napi_value SendToplevelClose(napi_env env, napi_callback_info info);
napi_value GetToplevelInfo(napi_env env, napi_callback_info info);
}  // namespace wsnapi
