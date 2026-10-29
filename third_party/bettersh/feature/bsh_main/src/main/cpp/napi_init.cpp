// napi_init.cpp — BetterSH NAPI 入口
#include <napi/native_api.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <string>

#include <sys/stat.h>
#include <unistd.h>

#undef LOG_TAG
#define LOG_TAG "BSH_NAPI"
#include <hilog/log.h>

#include "bsh/terminal_napi.h"
#include "bshutil/bsh_cfg.h"
#include "bshutil/ui_bus.h"
#include "shell/shell.h"
#include "wayland/input_napi.h"
#include "wayland/ws_napi.h"

namespace {
/* ArkTS 注册 bshutil 的事件接收方(见 bshutil/ui_bus.h):设置类子命令
 * (keys / picker / win-scale)靠它把请求送到 UI 线程。
 * 参数是 (sid, cb) —— sid 是**这个窗口的会话号**(0 = 主窗口的 bsh,>0 = 新开的 tab):
 * 通知类事件广播给所有窗口,请求类(picker/newtab)要精确送回发起命令的那个窗口。 */
napi_value BshUiSubscribeNAPI(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return nullptr;
    int32_t sid = 0;
    napi_get_value_int32(env, args[0], &sid);
    bsh_ui_subscribe((int)sid, env, args[1]);
    return nullptr;
}

/* ArkTS 回填一条 ui 请求的结果(对应 bsh_ui_request 的等待) */
napi_value BshUiResolveNAPI(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return nullptr;
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    char buf[1024];
    size_t len = 0;
    if (napi_get_value_string_utf8(env, args[1], buf, sizeof buf, &len) == napi_ok)
        bsh_ui_resolve((int)id, buf);
    return nullptr;
}
// Sets the shell's home and working directory once, before any terminal is
// started. The application process inherits HOME=/storage/Users/currentUser
// from appspawn, which is not where IEC's .mkshrc and command launchers live.
void InitShellEnvironment() {
    constexpr const char* kIecRoot = "/data/storage/el2/base/files";
    const std::string home = std::string(kIecRoot) + "/home";

    if (mkdir(home.c_str(), 0755) != 0 && errno != EEXIST) {
        OH_LOG_WARN(LOG_APP, "cannot create IEC home %{public}s: %{public}s",
                    home.c_str(), std::strerror(errno));
    }
    if (chdir(home.c_str()) != 0) {
        OH_LOG_WARN(LOG_APP, "cannot chdir to %{public}s: %{public}s",
                    home.c_str(), std::strerror(errno));
    }
    setenv("HOME", home.c_str(), 1);
    setenv("PWD", home.c_str(), 1);
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "bshTermStart",           nullptr, bsh::BshTermStartNAPI, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "bshTermAllocSession",    nullptr, bsh::BshTermAllocSessionNAPI, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "bshTermInput",           nullptr, bsh::BshTermInputNAPI, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "bshTermStop",            nullptr, bsh::BshTermStopNAPI,  nullptr, nullptr, nullptr, napi_default, nullptr },
        { "bshTermResize",          nullptr, bsh::BshTermResizeNAPI, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "bshShellNotice",         nullptr, bsh::BshNoticeNAPI, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "initResourceManager",    nullptr, bsh::initResourceManagerNAPI,  nullptr, nullptr, nullptr, napi_default, nullptr },
        { "bshUiSubscribe",         nullptr, BshUiSubscribeNAPI, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "bshUiResolve",           nullptr, BshUiResolveNAPI, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        {"setToplevelCallback",     nullptr, wsnapi::SetToplevelCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"createRenderer",          nullptr, wsnapi::CreateRenderer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"destroyRenderer",         nullptr, wsnapi::DestroyRenderer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resizeRenderer",          nullptr, wsnapi::ResizeRenderer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifyToplevelResize",    nullptr, wsnapi::NotifyToplevelResize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendToplevelClose",       nullptr, wsnapi::SendToplevelClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getToplevelInfo",         nullptr, wsnapi::GetToplevelInfo, nullptr, nullptr, nullptr, napi_default, nullptr},

        {"sendKey",                 nullptr, iwnapi::SendKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendModifiers",           nullptr, iwnapi::SendModifiers, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMouseMove",           nullptr, iwnapi::SendMouseMove, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMouseButton",         nullptr, iwnapi::SendMouseButton, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMouseAxis",           nullptr, iwnapi::SendMouseAxis, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMouseEnterLeave",     nullptr, iwnapi::SendMouseEnterLeave, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    InitShellEnvironment();
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&demoModule);
}
