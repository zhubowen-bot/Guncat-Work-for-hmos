// ⚠ 暂时不使用：见 guest_exec.cpp 顶部的说明。现在是 shim/exec_shim.c（LD_PRELOAD）那条路。
// procmgr/guest_exec.h — guest 内 exec 的委托层（见 guest_exec.cpp 的长注释）
#pragma once

namespace bsh {
namespace procmgr {

/**
 * 在**跳进 guest 之前**给这个子进程装 exec 委托层：
 *   装一条 seccomp 过滤器（execve/execveat → SECCOMP_RET_TRAP）+ SIGSYS handler，
 *   handler 把请求经 control socket 转给 procmgr，等它跑完再 _exit 它的退出码。
 *
 * 幂等；返回 true = 这次装上了（guest 内的 exec 会被委托出去），
 * false = 装不上（seccomp/sigaction 被拒，guest 内 exec 保持"不可用"，即现状）。
 * 必须在 fork 出来的子进程里、跳 guest 之前调用 —— 过滤器是进程属性。
 */
bool InstallGuestExecDelegate();

}  // namespace procmgr
}  // namespace bsh
