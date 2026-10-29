// bshutil/bsh_util_server.h — bshutil 的常驻服务(主进程内的一个线程 + 一个 unix sock)
//
// 为什么不能只把 bshutil 做成普通命令 so:命令 so 是 procmgr **fork 出来的子进程**
// (procmgr.cpp 的 SpawnSoMain),而 bshutil 要改的两样东西都只存在于主进程:
//   - 应用设置(bsh_cfg)是主进程内存里的一份,shell 每次执行命令都直接读它
//     (exit-hint 立刻生效就是这个原因);
//   - 界面事件(ui_bus 的 napi_threadsafe_function)只能在创建它的进程里调。
// 子进程里改这些,子进程一退出就没了,而且 `set exit-hint off` 会"成功"但毫无效果。
//
// 所以命令 so 只是一层薄客户端:连这里的 sock,把 argv(外加自己的 cwd)交给服务端
// 线程,服务端在**主进程内**调用原来的 bshutil_exec(argc, argv, out_fd, cwd) ——
// 逻辑一行没改,只是 out_fd 从会话 pty 变成了客户端连接本身,输出由此流回客户端,
// 再由客户端写 stdout。
#pragma once

#include <string>

namespace bsh {
namespace bshutil {

/* 启动服务:socket/bind/chmod 0600/listen + 起一个 accept 线程。
 * sock_path 一般用 common/bsh_paths.h 的 bsh_util_sock_path()。重复调用是幂等的。 */
bool StartService(const std::string& sock_path);

/* 停服务(unlink sock + join 线程)。当前无人调用 —— procmgr 的 StopControlSocket
 * 也一样,进程退出时由系统回收;留着是为了对称与以后需要时能用。 */
void StopService();

}  // namespace bshutil
}  // namespace bsh
