#pragma once
// input_napi.h — 键鼠输入注入 NAPI（按 toplevelId 路由）
#include <napi/native_api.h>

namespace iwnapi {
napi_value SendKey(napi_env env, napi_callback_info info);
napi_value SendModifiers(napi_env env, napi_callback_info info);
napi_value SendMouseMove(napi_env env, napi_callback_info info);
napi_value SendMouseButton(napi_env env, napi_callback_info info);
napi_value SendMouseAxis(napi_env env, napi_callback_info info);
napi_value SendMouseEnterLeave(napi_env env, napi_callback_info info);
}  // namespace iwnapi
