// procmgr/procmgr.h — 进程创建的唯一入口
//
// 沙箱里通常没有真 exec(无 execve/无可执行映射),所以"起一个程序"按环境选一条:
//   kSoMain:fork + dlopen(bundle libs 里的 .so) + 调入口符号;
//   kExecve:fork + execve，用于 hnp 目录下二进程文件的执行，以及未来沙箱开放时的直接执行;
//   kElf   :fork + elfloader(进程内 mmap 装载 aarch64 ELF;exec 不通时的同 ISA 路);
//   kQemu  :预留:异构 ELF(e_machine != AARCH64)交 qemu-user,未实现。
// 到底走哪条,由本模块按命令表 + 路径 + 文件探测决定 —— 调用方(宿主 shell、命令 so
// 内部的 exec 委托)只描述"我想跑什么",不关心怎么跑。
//
// 通信:宿主与命令 so 一律经 control socket($HOME/bsh-ctrl.sock)发 CREATE 请求;
// 进程内 API(Spawn)只给 procmgr 自己与自检用。协议见 ctrl_socket.cpp 顶部注释。
#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <sys/types.h>
#include <vector>

namespace bsh {
namespace procmgr {

// 创建方式(由 procmgr 决策,不由调用方指定)
enum class LaunchKind {
    kSoMain,   // fork + dlopen(bundle libs 的 .so) + 入口符号
    kElf,      // fork + elfloader(mmap PROT_EXEC 装载 aarch64 ELF)
    kQemu,     // 预留:异构 ELF(e_machine != AARCH64)交 qemu-user,未实现
    kExecve,   // fork + 真 execve
};

// 调用方的显式提示(auto = 交给 procmgr 决策)
enum class KindHint { kAuto, kForceSo, kForceElf };

struct SpawnRequest {
    struct InheritedFd { int source_fd; int target_fd; };

    std::string cmd;                    // 命令名(查命令表)或路径
    std::vector<std::string> argv;      // argv[0] 必须是命令名(multicall 依赖)
    std::vector<std::string> env;       // "K=V" 覆盖项,基础环境继承主进程
    std::string cwd;                    // 空 = 继承
    KindHint kind_hint = KindHint::kAuto;

    /* 这一条命令属于哪个终端会话:0 = 主窗口的 bsh,>0 = `bshutil newtab` 开的 tab。
     *
     * 不是协议里单独的一行,而是从 env 里 **BSH_SESSION** 派生出来的:env 本来就是
     * 调用方 environ 的原样转发(见 bsh_client.c),子进程看到的会话号与这里是同一个
     * 来源 —— 分两处写迟早会漂。宿主自己发的请求(它不在任何会话里)自然没有这个
     * 变量,于是落回 0,与加这个维度之前的行为完全一致。
     *
     * 用途:会话 tty 状态按 sid 分(bsh_tty)、前台 pid 按 sid 分(NotifyForeground)。 */
    int sid = 0;

    std::vector<InheritedFd> stdio_fds; // target ∈ {0,1,2}
    std::vector<InheritedFd> extra_fds; // target > 2

    bool        sync_wait = true;       // 终端前台命令一律 true
    std::string proc_name;              // prctl(PR_SET_NAME),空则用 cmd
    pid_t       caller_pid = 0;         // socket 链上的逻辑父 pid
};

struct SpawnResult {
    pid_t      pid = -1;
    LaunchKind kind = LaunchKind::kSoMain;
    int        exit_code = -1;
    std::string error;
};

struct ProcessInfo {
    pid_t       pid = 0;
    pid_t       parent_pid = 0;
    LaunchKind  kind = LaunchKind::kSoMain;
    std::string cmd;
    int64_t     start_time_ms = 0;
    bool        alive = true;
    int         exit_code = -1;
};

// ---- 宿主能力探测(启动时一次,见 caps.cpp)----
// procmgr 在启动时探一次 fork / exec / jit,结论缓存在这里供决策使用:
//   - fork 不通 → procmgr 本身没意义(所有进程创建都建立在它之上);
//   - jit  不通 → 使用 qemu 执行二进制文件;
//   - exec 不通 → 使用 elfloader 执行二进制文件。
struct HostCapabilities {
    bool fork = false;              // fork + waitpid 可用
    bool exec = false;              // 能真 execve
    bool jit  = false;              // 能拿到可执行内存(elfloader / V8 的前提)
    int  exec_errno = 0;            // exec 失败时的 errno(诊断用)
    const char* jit_route = "none"; // "anon-rwx" / "memfd" / "mprotect" / "none"
    int  jit_errno = 0;             // 五条路都失败时的最后一个 errno
};

// 启动时探 fork / exec / jit(幂等)。须在任何实际 spawn 之前调用。
// 结论缓存在这里,`bshutil caps` 只读不重探(要重探就重开会话)。
void ProbeCapabilities();
const HostCapabilities& Capabilities();

// ---- 核心 API ----
SpawnResult              Spawn(const SpawnRequest& req);
void                     Terminate(pid_t pid);
std::vector<ProcessInfo> ListProcesses();

// fork 成功后(父进程侧、阻塞 wait 之前)同步回调一次,wait 结束后再回调 -1。
// 宿主 shell 用它更新前台 pid —— 输入路径据此把 Ctrl+C/Ctrl+Z 转成 ISIG 信号。
// 之所以做成 hook 而不是响应字段:走 socket 的请求在子进程退出前拿不到 pid,
// 而 procmgr 与宿主同进程,回调是零成本的。
// 前台 pid 回调:**按会话**(sid)通知。0 = 主窗口的 bsh,>0 = 新开的 tab。
// 前提:一个会话同时只有一个前台任务;同一会话内并发 spawn 时以后到者为准。
void SetForegroundHook(std::function<void(int sid, pid_t pid)> hook);

// 子进程结束时的收尾：清**那个会话**的前台 pid，但**只清自己那一个**（并发 spawn 下
// 别让早已退出的旧子进程把当前前台擦掉 —— 那一擦会让 Ctrl+C 找不到目标）。
// 与 NotifyForeground 配对。
void NotifyForegroundDone(int sid, pid_t pid);

// 把信号交给"当前前台"那个进程(见 SetForegroundHook 的说明)。//
// 为什么需要 procmgr 代发、而不是让调用方自己 kill:真正干活的进程是 procmgr fork
// 出来的,它**不在**请求方的进程组里 —— 调用方那条路上能拿到的只有"委托中间体"
// (阻塞在 control socket 上的那个)。所以假 pty 收到 Ctrl+C 时,发进程组只能杀掉
// 中间体,实际程序(python/… )收不到,表现就是"按了没反应"。
// 宿主会话那份走的是 bsh_tty_forward_sig 的双目标(进程组 + hook 记下的 pid);
// 这里给**不在宿主进程里**的消费者(guest 里的 pty_shim)补一条可达的路径。
// 返回 false = 该会话当前没有前台进程(或 kill 失败)。
bool SignalForeground(int sid, int sig);

// 某个会话当前的宿主侧"前台 pid"(-1 = 没有)。给宿主自己的输入路径用:tab 会话里
// 按 Ctrl+C 时,宿主只知道"这个会话",真正干活的进程是 mksh 再往下起的,只有 procmgr
// 记着它(hook 是按 sid 回调的)。bsh 会话(0)那条路走 hook 更省事,不必问这里。
pid_t ForegroundPid(int sid);
// ---- control socket(服务端)----
// bind+listen 到 sock_path,并 setenv("BSH_CTRL_SOCK") 让子进程能连回来。
// 必须在任何子进程 fork 之前调用。重复调用幂等。
bool StartControlSocket(const std::string& sock_path);
void StopControlSocket();

}  // namespace procmgr
}  // namespace bsh
