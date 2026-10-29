// shell/shell.h — BetterSH 基础 shell
// 运行于 pty 的 slave 侧:阻塞读输入,简易行编辑(回显/退格),回车后按行解析
// 并执行 builtin;输出写回 slave → master → 前端显示。为后续接入 guest
// 程序留出同一 pty 抽象。
#pragma once

#include <cstring>
#include <string>
#include <thread>
#include <unistd.h>

#include "napi/native_api.h"

#include "../tty/softpty.h"

namespace bsh {

// 启动基础 shell 会话线程(内部新建 pty);返回 pty 或 nullptr。
// master 归调用方:前端写输入、读输出。stop 通过返回指针的 Stop() 触发。
class BasicShell {
public:
    BasicShell();
    ~BasicShell();

    bool Start();              // 建 pty + 起 shell/读线程,成功返回 true
    void Stop();               // 请求停止(线程退出、pty 关闭)

    PseudoTty* Pty() { return &pty_; }
    bool Running() const { return running_; }

private:
    static void* RunTramp(void* arg);
    void Run();                // slave 侧:读→行编辑→builtin

    PseudoTty pty_;
    bool running_ = false;
    int stopPipe_[2] = { -1, -1 };   // 用于唤醒阻塞读
    bool exited_ = false;
};

// bsh 本体仍然只有一个(会话 0),所以这几个还是全局变量。
extern BasicShell* g_shell;
extern bool g_started;
// napi回调也如此，并且目前应该只会存在napi回调一种输出方式。若是将来加入gpu渲染再考虑更改
extern napi_threadsafe_function g_tsfn;

int initResource(int fd);

/* ---------- NAPI -------------------------------- */

void OutputTsfnCallJs(napi_env env, napi_value cb, void*, void* data);

/* pty master 读线程(sid 0 = bsh 的 pty,>0 = 某个 tab 的)。 */
void MasterReader(int sid, int master);

/* 由 `bshutil newtab` 开出来的终端会话(见 shell.cpp 的会话表):
 *   - AllocSession 只**占一个号**,不启动任何东西 —— ArkTS 需要先拿到号才能把它
 *     经 want.parameters 传给新 Ability,而真正的 shell 得等页面 onPageEnd 才起
 *     (那时输出回调才有地方送)。占号不用的槽靠 bshTermStop 释放。
 *   - StartSession 建 pty + 让 procmgr 把 mksh 挂上去。返回 0 成功。 */
int  AllocSession(void);
int  StartSession(int sid);
void StopSession(int sid);
bool SessionAlive(int sid);

napi_value BshTermAllocSessionNAPI(napi_env env, napi_callback_info info);

#if defined(INTERCEPT_VERSION) && INTERCEPT_VERSION == 1

napi_value BshTermStartNAPI(napi_env env, napi_callback_info info);

napi_value BshTermInputNAPI(napi_env env, napi_callback_info info);

napi_value BshTermStopNAPI(napi_env env, napi_callback_info);

napi_value BshTermResizeNAPI(napi_env env, napi_callback_info info);

#endif

/* ArkTS 往终端回一句 [notice](如目录选择器的结果) */
napi_value BshNoticeNAPI(napi_env env, napi_callback_info info);

napi_value initResourceManagerNAPI(napi_env env, napi_callback_info info);

}  // namespace bsh
