// bsh/terminal_napi.h — 终端 NAPI 的兼容入口。
//
// 名字沿用旧的 bshTerm* 导出，让 ArkTS 不必改调用点；实现换成
// bsh/terminal.cpp 编出的 libterminal.so（经 IEC 的 tty/exec warp shim 起会话）。
#pragma once

#include "napi/native_api.h"

namespace bsh {

#if !defined(INTERCEPT_VERSION) || INTERCEPT_VERSION == 2

napi_value BshTermStartNAPI(napi_env env, napi_callback_info info);
napi_value BshTermInputNAPI(napi_env env, napi_callback_info info);
napi_value BshTermResizeNAPI(napi_env env, napi_callback_info info);
napi_value BshTermStopNAPI(napi_env env, napi_callback_info info);

#endif

}  // namespace bsh
