// exec_napi.h — registers the execution API on the HAR's NAPI exports.
#pragma once

#include <napi/native_api.h>

// Adds execStart / execPoll / execWait / execWrite / execCloseStdin /
// execTerminate / execSignal / execRelease / execList / execCount to the module
// exports. Called from Init() in napi_init.cpp, right after the existing
// properties are defined.
void RegisterExecNapi(napi_env env, napi_value exports);
