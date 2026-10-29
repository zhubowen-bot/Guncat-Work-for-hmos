// procmgr/procmgr.cpp — 进程创建的唯一入口
//
// 决策在 Resolve(req):命令表命中 → dlopen 该 so 调入口符号;否则按路径找文件、
// 确认是 ELF → elfloader 装载。调用方(宿主 shell、命令 so 的 exec 委托)只说
// "跑什么",不关心怎么跑 —— 全工程的 fork 只在这里发生。
//
// 子进程里做的事:fd 重映射(含 tty 身份)→ 关掉多余继承 fd → 信号复位 →
// chdir/prctl/env → dlopen+main 或 elfloader。失败码约定沿用:dup2 失败 _exit(124)、
// dlopen 失败 _exit(125)、dlsym 失败 _exit(126)、ELF 装载失败 _exit(127)。
#include "procmgr.h"

#include "command_map.h"
#include "../common/bsh_paths.h"   /* BSH_CTRL_SOCK / BSH_SYSROOT / BSH_HOME_DIR */
#include "../elfloader/elf_loader.h"
#include "../tty/bsh_tty.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#undef LOG_TAG
#define LOG_TAG "BSH_ProcMgr"
#include <hilog/log.h>

namespace bsh {
namespace procmgr {

namespace {

// bundle 内命令 so 的位置(hvigor 会把 entry/libs/<abi> 打成 libs/<abi>)——见 common/bsh_paths.h
constexpr const char* kBundledLibDir = BSH_BUNDLE_LIBS;

// ================= 进程表 =================

class Manager {
public:
    static Manager& Instance() { static Manager s; return s; }

    void Register(const ProcessInfo& info) {
        std::lock_guard<std::mutex> lk(mu_);
        table_[info.pid] = info;
    }
    std::optional<ProcessInfo> Lookup(pid_t pid) {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = table_.find(pid);
        return it == table_.end() ? std::nullopt : std::make_optional(it->second);
    }
    void MarkExited(pid_t pid, int code) {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = table_.find(pid);
        if (it != table_.end()) { it->second.alive = false; it->second.exit_code = code; }
    }
    std::vector<ProcessInfo> Snapshot() {
        std::lock_guard<std::mutex> lk(mu_);
        std::vector<ProcessInfo> out;
        out.reserve(table_.size());
        for (auto& kv : table_) out.push_back(kv.second);
        return out;
    }
private:
    std::mutex mu_;
    std::unordered_map<pid_t, ProcessInfo> table_;
};

int64_t NowMillis() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
}

const char* KindCStr(LaunchKind k) {
    switch (k) {
        case LaunchKind::kElf:    return "elf";
        case LaunchKind::kQemu:   return "qemu";
        case LaunchKind::kExecve: return "execve";
        default:                  return "so";
    }
}

// 前台 pid 回调(Spawn 里 fork 后、wait 前调用一次;wait 结束再回调 -1)。
// **按会话分**:0 = 主窗口的 bsh,>0 = 新开的 tab(见 tty/bsh_tty.h 的 BSH_SID_MAX)。
// 不分会话的话,两个窗口各跑一个 sleep 时后者会覆盖前者,在 A 窗口按 Ctrl+C 打到
// B 的进程上 —— 这是加 newtab 之前就存在的洞(code-server 的多个终端也共享这一份)。
std::mutex g_fg_mu;
std::function<void(int sid, pid_t pid)> g_fg_hook;
// 每个会话再各存一个 pid:hook 是给"同进程的宿主 shell"用的回调,而 guest 里的
// pty_shim 不在这个进程里,只能经 control socket 来问(见 SignalForeground)。
pid_t g_fg_pid[BSH_SID_MAX] = { -1, -1, -1, -1, -1, -1, -1, -1 };

void NotifyForeground(int sid, pid_t pid) {
    std::function<void(int, pid_t)> hook;
    {
        std::lock_guard<std::mutex> lk(g_fg_mu);
        if (sid >= 0 && sid < BSH_SID_MAX) g_fg_pid[sid] = pid;
        hook = g_fg_hook;
    }
    /* 打出来：前台 pid 是"Ctrl+C 到底发给谁"的唯一依据，而它只有一份、还可能被
     * 别的并发 spawn 覆盖 —— 排查假 pty 里 Ctrl+C 不生效时全靠这条时间线。 */
    OH_LOG_INFO(LOG_APP, "fg-notify sid=%{public}d pid=%{public}d", sid, pid);
    if (hook) hook(sid, pid);
}

// ================= 决策 =================

struct Resolved {
    LaunchKind  kind = LaunchKind::kSoMain;
    std::string so;        // kSoMain:so 文件名或绝对路径
    std::string entry;     // kSoMain:入口符号
    /* kSoMain 的入口是几参：2 = int(*)(int,char**)（默认，绝大多数命令 so），
     * 3 = int(*)(int,char**,char**)（多一个 envp）。来自 "#BSHSO" 启动器文件第 4 行。 */
    int         entry_argc = 2;
    std::string path;      // kElf / kExecve:装载/执行的绝对路径
    /* kSoMain 且非空 = "用某个 so 去跑一个 guest 文件"(box64 / qemu 这种形态:
     * so = libbox64.so 或 libqemu-*.so, guest = 那个 ELF)。argv 按
     * [<guest_name>, guest, …] 组。 */
    std::string guest;
    /* guest 形态里 argv[0] 用哪个名字(box64 / qemu-aarch64 / qemu-x86_64)——
     * 它们都靠 argv[1] 取 guest,argv[0] 只用于自报与打印。 */
    std::string guest_name;
    /* kSoMain 且非空 = argv 换一套前缀(丢掉调用方原来的 argv[0])。
     * 目前只有一种用途:#! 脚本 —— 要变成 [解释器名, (,解释器参数,) 脚本路径, 原参数…],
     * 交给命令表里那个解释器(如 sh → libmksh.so)去跑。 */
    std::vector<std::string> argv_prepend;
    std::string error;     // 非空 = 决策失败
};

bool IsElfFile(const char* path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    unsigned char m[4] = {0};
    int n = (int)read(fd, m, 4);
    close(fd);
    return n == 4 && m[0] == 0x7f && m[1] == 'E' && m[2] == 'L' && m[3] == 'F';
}

/* 是不是 #! 脚本 */
bool IsScriptFile(const char* path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    char m[2] = {0};
    int n = (int)read(fd, m, 2);
    close(fd);
    return n == 2 && m[0] == '#' && m[1] == '!';
}

/* 读 #! 那一行:给出解释器路径与它后面可选的一个参数(内核只认一个)。
 * 只读前 256 字节 —— 这一行不会更长,也不值得为一个探测多读。 */
bool ReadShebang(const char* path, std::string* interp, std::string* arg) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    char buf[257];
    int n = (int)read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n < 3 || buf[0] != '#' || buf[1] != '!') return false;
    buf[n] = '\0';
    char* p = buf + 2;
    while (*p == ' ' || *p == '\t') p++;
    char* e = p;
    while (*e && *e != '\n' && *e != '\r' && *e != ' ' && *e != '\t') e++;
    interp->assign(p, (size_t)(e - p));
    if (interp->empty()) return false;
    while (*e == ' ' || *e == '\t') e++;
    char* a = e;
    while (*a && *a != '\n' && *a != '\r' && *a != ' ' && *a != '\t') a++;
    arg->assign(e, (size_t)(a - e));
    return true;
}

/* 读 "#BSHSO" 启动器（4 行，格式见 command_map.h）。
 *
 * 启动器是**数据**：写错一行要一眼能查，所以失败时 err 里带上是第几行、哪里不对，
 * 而且**不静默回退**去猜别的解释方式。第 4 行（arity）只认 2 或 3。 */
bool ReadSoLauncher(const char* path, std::string* so, std::string* entry,
                    int* arity, std::string* err) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { *err = std::string("open 失败: ") + strerror(errno); return false; }
    char buf[4096 + 1];
    int n = (int)read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) { *err = "文件是空的"; return false; }
    buf[n] = '\0';

    std::string lines[4];
    int li = 0;
    const char* p = buf;
    while (li < 4 && p && *p) {
        const char* e = strchr(p, '\n');
        std::string l = e ? std::string(p, (size_t)(e - p)) : std::string(p);
        while (!l.empty() && (l.back() == '\r' || l.back() == ' ' || l.back() == '\t'))
            l.pop_back();
        lines[li++] = l;
        p = e ? e + 1 : nullptr;
    }
    if (li < 4) {
        char m[96];
        snprintf(m, sizeof m, "只有 %d 行，格式要求 4 行", li);
        *err = m;
        return false;
    }
    if (lines[0] != BSH_LAUNCHER_MAGIC) {
        *err = "第 1 行不是 " BSH_LAUNCHER_MAGIC;
        return false;
    }
    if (lines[1].empty() || lines[1][0] != '/') {
        *err = "第 2 行必须是 so 的绝对路径";
        return false;
    }
    if (lines[2].empty()) { *err = "第 3 行（入口符号）是空的"; return false; }
    if (lines[2].size() > 255) { *err = "第 3 行（入口符号）太长"; return false; }
    if (lines[3] != "2" && lines[3] != "3") {
        *err = "第 4 行只能是 2 或 3（得到 \"" + lines[3] + "\"）";
        return false;
    }
    *so = lines[1];
    *entry = lines[2];
    *arity = (lines[3] == "3") ? 3 : 2;
    return true;
}

/* ELF 的 e_machine(偏移 18,小端 2 字节)。读不到/不是 ELF/非小端都返回 0。 */
uint16_t ElfMachine(const char* path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    unsigned char h[20] = {0};
    int n = (int)read(fd, h, sizeof h);
    close(fd);
    if (n < 20 || h[0] != 0x7f || h[1] != 'E' || h[2] != 'L' || h[3] != 'F') return 0;
    if (h[5] != 1 /* ELFDATA2LSB */) return 0;
    return (uint16_t)(h[18] | (h[19] << 8));
}

/* e_machine 的取值(只列我们认的) */
#define EM_386     3
#define EM_X86_64  62
#define EM_AARCH64 183

// 不含 '/' 的名字按 PATH 逐个试,返回第一个"能跑"的绝对路径 —— ELF **或 #! 脚本**。
// 命令行里同一名字若已在命令表命中,不会走到这里;走到这里的多半是用户自己
// 编译出来的可执行文件(clang 产物)、PATH 上真实二进制、包装脚本。
//
// 为什么必须把脚本也算进来:/data/service/hnp/bin/python3.12 就是个 `#!/bin/sh`
// 的包装脚本。只认 ELF 时,SearchPath 会**跳过它**、继续找别的目录,最后返回空 →
// 报 "command not found",而 `which python3.12` 明明找得到 —— 症状自相矛盾,
// 但成因就这么朴素。
// 裸名按 PATH 查找时该用哪条 PATH —— **调用方想让孩子看到的那条**（req.env 是覆盖项，
// 见 ApplyEnv：调用方给什么就是什么，没给才用 procmgr 自己的 environ）。
//
// 为什么必须这样：调用方经常在 env 里换 PATH。最典型的是 npm —— 它给生命周期脚本
// 前插 `node_modules/.bin` 与自带的 `@npmcli/run-script/lib/node-gyp-bin`，而
// `node-gyp` 就在后者里（设备上实测两个文件都在）。只看 procmgr 自己的 PATH 时，
// node-gyp-build 回退那条路上就报 "cannot exec: node-gyp: command not found" ——
// 文件明明在调用方的 PATH 上。
std::string RequestPath(const SpawnRequest& req) {
    for (auto it = req.env.rbegin(); it != req.env.rend(); ++it)
        if (it->rfind("PATH=", 0) == 0) return it->substr(5);
    const char* own = getenv("PATH");
    return own ? own : "";
}

std::string SearchPath(const std::string& name, const std::string& path_env) {
    if (name.empty()) return {};
    const std::string& plist = path_env;
    if (plist.empty()) return {};
    size_t st = 0;
    while (st <= plist.size()) {
        size_t en = plist.find(':', st);
        if (en == std::string::npos) en = plist.size();
        std::string dir = plist.substr(st, en - st);
        if (!dir.empty()) {
            std::string cand = dir + "/" + name;
            if (IsElfFile(cand.c_str()) || IsScriptFile(cand.c_str()) ||
                cmd_is_launcher(cand.c_str()))
                return cand;
        }
        if (en == plist.size()) break;
        st = en + 1;
    }
    return {};
}

bool Resolve(const SpawnRequest& req, Resolved* out) {
    switch (req.kind_hint) {
        case KindHint::kForceSo:
            out->kind = LaunchKind::kSoMain;
            break;
        case KindHint::kForceElf:
            out->kind = LaunchKind::kElf;
            out->path = req.cmd;
            return true;
        case KindHint::kAuto:
            break;
    }

    if (req.kind_hint == KindHint::kAuto) {
        // 1) 命令表命中 → dlopen so + 入口符号
        if (const struct CommandEntry* e = cmd_lookup(req.cmd.c_str())) {
            out->kind = LaunchKind::kSoMain;
            out->so = e->so;
            out->entry = e->entry;
            return true;
        }
        // 1.5) "#BSHSO" 启动器文件（命令启动器，格式见 command_map.h）—— 见下面
        //      "路径解析之后"那一段：类型判断统一放在拿到最终路径之后做，
        //      这样裸名（走 PATH 找到启动器）与显式路径两条路都覆盖得到。
        // 2) 显式 .so 路径 → 入口符号按 "main"
        if (req.cmd.size() > 3 && req.cmd.rfind(".so") == req.cmd.size() - 3) {
            out->kind = LaunchKind::kSoMain;
            out->so = req.cmd;
            out->entry = "main";
            return true;
        }
    } else if (out->kind == LaunchKind::kSoMain) {
        // 调用方坚持按 so 起:表里没有就按普通 so 处理
        const struct CommandEntry* e = cmd_lookup(req.cmd.c_str());
        if (e) { out->so = e->so; out->entry = e->entry; }
        else   { out->so = req.cmd; out->entry = "main"; }
        return true;
    }

    // 3) 路径归一 + 存在性/ELF 校验(不 exec,所以只接受 ELF)
    //
    // 相对路径要按**调用方的** cwd 解析,不是 procmgr 自己的:调用方可能是另一个
    // 进程里的 shell(比如 mksh),它在自己进程里 cd 走了,而 procmgr 一直待在
    // $HOME。下面 IsElfFile 的 open 是相对**本进程** cwd 的,不拼就会把一个明明
    // 存在的文件判成 "not executable"。
    // (mini shell 与 procmgr 同进程,它的 cd 顺带改了 procmgr 的 cwd,所以外层
    //  直接 cd 再 ./prog 一直是好的 —— 只有从 mksh 里才暴露。)
    // 拼成绝对路径还有个附带好处:后面交给 elfloader/box64 的是绝对路径,不再依赖
    // 子进程的 cwd。
    std::string path;
    if (req.cmd.find('/') != std::string::npos) {
        std::string rel = req.cmd;
        while (rel.rfind("./", 0) == 0) rel = rel.substr(2);   // 去掉开头的 "./"
        path = (rel[0] != '/' && !req.cwd.empty()) ? (req.cwd + "/" + rel) : rel;

        /* guest 里的**绝对路径**（/usr/lib/…、/opt/…）在宿主上通常不存在 —— guest
         * 没有真正的根文件系统，sysroot 挂在 $BSH_SYSROOT 下。而 deb 自带的启动器
         * 几乎全是这个写法：code-server 的 `usr/bin/code-server` 就是
         *     exec /usr/lib/code-server/bin/code-server "$@"
         * 不兜这一下就只会报 "inaccessible or not found"。
         *
         * 只在宿主上确实没这个文件时才回退 —— 真实路径优先，不抢。回退成 sysroot
         * 绝对路径还有个好处：后面把它塞进 argv 传给解释器时，脚本里的
         * `cd "$(dirname "$0")"` 拿到的是正确路径（code-server 的 bin/code-server
         * 正是靠 $0 推导 ROOT 的）。 */
        if (!path.empty() && path[0] == '/' && access(path.c_str(), F_OK) != 0) {
            std::string alt = std::string(bsh_sysroot()) + path;
            if (access(alt.c_str(), F_OK) == 0) path = alt;
        }
    } else {
        path = SearchPath(req.cmd, RequestPath(req));   // 裸名按 PATH 找(与 POSIX 一致:不查 cwd)
    }
    if (path.empty()) { out->error = req.cmd + ": command not found"; return false; }

    // 3.2) "#BSHSO" 命令启动器文件 → 照它写的 so / 入口符号 / arity 起。
    //
    // 放在**路径解析之后**：裸名（由上面的 SearchPath 按 PATH 找到启动器）与显式路径
    // 两条路在这里合一，类型判断就只需要做一次。必须早于下面的 "#!" 脚本判断 ——
    // IsScriptFile() 只看头两字节 "#!"，我们的文件是 "#BSHSO"，不被它认，但顺序上
    // 先判启动器更清楚，也免得将来有人给 magic 加个别的前缀就撞上。
    // 格式错**不静默回退**：报清楚是第几行的问题（启动器是数据，写错要一眼可查）。
    if (cmd_is_launcher(path.c_str())) {
        std::string lerr;
        int arity = 2;
        if (!ReadSoLauncher(path.c_str(), &out->so, &out->entry, &arity, &lerr)) {
            out->error = "启动器格式错 " + path + ": " + lerr;
            return false;
        }
        out->kind = LaunchKind::kSoMain;
        out->entry_argc = arity;
        return true;
    }

    // 3.3) 系统**安装目录**(HNP 的公有挂载点)下的可执行文件 → 真 execve。
    {
        const char* kHnpDir = "/data/service/hnp/";
        size_t dl = strlen(kHnpDir);
        // 只对**真 ELF** 走 exec
        if (path.compare(0, dl, kHnpDir) == 0 && Capabilities().exec &&
            IsElfFile(path.c_str())) {
            out->kind = LaunchKind::kExecve;
            out->path = path;
            return true;
        }
        // 注意:exec 探不通时**故意不 return**,继续往下走 elfloader/box64 —— 那条路
        // 不需要 exec 能力,照样能把 hnp 里的程序跑起来(慢一层,但能用)。
    }

    // 3.5) 系统 bin 目录下的路径,若 basename 命中命令表 → 改按命令表起。
    //
    // 起因(node child_process 实测):libuv / node 的 `execSync`/`spawn` 默认起
    // `/bin/sh -c <cmd>`。而设备上的 /bin 是**系统 toybox 的符号链接林**
    // (/bin/sh → /system/bin/…),在应用沙箱里 elfloader 读得到这个文件、却读不到
    // 它要的解释器(/lib/ld-musl-aarch64.so.1),必然报
    //   elfloader: cannot read /bin/sh or ldso ld-musl-aarch64.so.1
    // 于是 node 那边表现为 spawn ENOENT。可用户/调用方心里要的就是「sh 这个命令」,
    // 我们自己的 libmksh.so 才是对的那个 —— 命令表按 basename 认它。
    //
    // 2026-10-04 补记（gyp/node-gyp 现场编原生扩展那一轮）：构建系统把 SHELL 写死
    // `/bin/sh` 时，除了这条改判，还有**别的东西也会踩**——如果 `/bin/sh` 那条 exec 没
    // 走到这里（例如静态 guest 没装 shim），系统的 sh 会去 exec 我们的 `#BSHSO` 启动器、
    // 拿到 ENOEXEC 后**把启动器当 shell 脚本逐行解释**，症状是启动器自己的三个字段被
    // 当命令跑：
    //     printf[2]: …/libtoybox.so: can't execute: Permission denied
    //     printf[3]: bsh_toybox_main: inaccessible or not found
    //     printf[4]: 2: inaccessible or not found
    // 那种情况下这条改判救不了（请求根本没到 procmgr）。**根治在环境侧**：
    // `.bshrc` 里 `export MAKEFLAGS=SHELL=$BSH_SYSROOT/bin/sh`（GNU make 从不从环境
    // 取 SHELL，只能用命令行定义传下去），见 shim/README.md §11.8。
    //
    // ⚠ **全项目就这一处**做"路径 basename → 命令表"的改判（3.6 那处是 shebang 的解释器，
    //   来源不同）。要加新前缀就加进下面的 kSysBins，别另起一段重复逻辑。
    //
    // 安全性:只在**系统 bin 目录**前缀下做这个改判,而且只有命令表真认得 basename
    // 才生效;认不得就照原路走(交给 SearchPath/elfloader 或报错),行为不变。
    {
        const char* kSysBins[] = {
            "/bin/", "/usr/bin/", "/usr/local/bin/", "/sbin/", "/usr/sbin/",
            "/system/bin/", "/vendor/bin/", "/system/lib/", "/data/app/bin/",
        };
        for (const char* d : kSysBins) {
            size_t dl = strlen(d);
            if (path.compare(0, dl, d) != 0) continue;
            const struct CommandEntry* e = cmd_lookup(path.c_str() + dl);
            if (e) {
                out->kind = LaunchKind::kSoMain;
                out->so = e->so;
                out->entry = e->entry;
                return true;
            }
            /* 命令表认不得这个 basename。这些路径大多是**系统 toybox 的符号链接**
             * (/bin/timeout、/bin/od → /system/bin/toybox):它们要的解释器是**系统那份**
             * ld-musl,和我们打包进去的 ld-musl-aarch64.so.1 不是一回事 —— 交给 elfloader
             * 会"装载成功、进 guest 就崩":落点固定在 ld.so+0x62534、pc=0,rc=139 外加一串
             * [crash];而同一个二进制让系统 shell 跑是完全正常的(实测 /bin/timeout → rc=0)。
             *
             * 这类文件本来就是系统自带运行时伺候的,交给内核 execve 才对。
             * exec 探不通时**故意不 return**,继续往下走老路(ChildRunExec 失败时自己也会
             * 退回 elfloader),所以行为不倒退。 */
            if (Capabilities().exec && IsElfFile(path.c_str())) {
                out->kind = LaunchKind::kExecve;
                out->path = path;
                return true;
            }
            break;
        }
    }

    if (!IsElfFile(path.c_str())) {
        // 3.6) 不是 ELF,但是 #! 脚本 → 交给我们自己的解释器命令去跑。
        // 
        // 脚本本身不该由 elfloader 硬啃(它不是 ELF),
        // 也不适合交给内核的 shebang(它要的解释器 /bin/sh 在沙箱里 exec 不通),
        // 所以按 shebang 里的解释器名去命令表找现成的命令(#!/bin/sh → sh →
        // libmksh.so),argv 组成 [解释器名, (,解释器参数,) 脚本路径, 原参数…]。
        //
        // 解释器认不得就把路径原样报出来 —— 这种失败要能一眼看出是"哪一行 #!"
        // 的问题,而不是又一句 command not found。
        if (IsScriptFile(path.c_str())) {
            std::string interp, iarg;
            if (ReadShebang(path.c_str(), &interp, &iarg)) {
                size_t slash = interp.rfind('/');
                std::string ibase = (slash == std::string::npos) ? interp : interp.substr(slash + 1);
                if (const struct CommandEntry* e = cmd_lookup(ibase.c_str())) {
                    out->kind = LaunchKind::kSoMain;
                    out->so = e->so;
                    out->entry = e->entry;
                    out->argv_prepend.push_back(ibase);
                    if (!iarg.empty()) out->argv_prepend.push_back(iarg);
                    out->argv_prepend.push_back(path);
                    return true;
                }
                out->error = path + ": 脚本的解释器 " + interp + " 不在命令表里";
                return false;
            }
        }
        // 路径压根不存在 → 报 "not found"（execve 的 ENOENT 语义）。
        // 为什么值得单独分一句：shim 侧把服务端文案里带 "not found" 的映射成 ENOENT、
        // 其余映射成 EACCES，而 CPython 的 subprocess 做 PATH 搜索时**只对 ENOENT
        // 继续试下一个候选**（`_posixsubprocess.c` 的 child_exec）。两句混在一起时，
        // `pip install` 里的 `uname -rs` 就死在这一步（2026-10-03）。
        struct stat st;
        if (stat(path.c_str(), &st) != 0 && (errno == ENOENT || errno == ENOTDIR))
            out->error = path + ": not found";
        else
            out->error = path + ": not executable";
        return false;
    }
    // 4) 裸 ELF:按 e_machine,再按"有没有 jit"决定谁去跑,这样终端里 `./x86_64-xxx`
    //    与 `./aarch64-xxx` 都不用带前缀。
    //      jit 可用(快路):AARCH64 → elfloader(同 ISA,直接跳执行,最快);
    //                      x86_64/i386 → box64(跨 ISA 动态翻译)。
    //      jit 不可用:这两条都要可写可执行内存,全都起不来(实测 elfloader 报
    //        `mprotect(PROT_EXEC) failed: A/B/C=Invalid argument`,box64 报
    //        "cannot allocate … for bridge")→ 改交 qemu-user 的**解释**执行
    //        (TCI,kSoMain/dlopen,不需要可执行页),它是无 jit 设备上唯一活得下来的路。
    //    其它架构(cpu 不认识)→ 仍然交给 elfloader,让它照常报 bad ELF header,
    //    比在这里编一句"不支持"更能说明问题。
    const bool jit = Capabilities().jit;
    uint16_t mach = ElfMachine(path.c_str());
    if (mach == EM_X86_64 || mach == EM_386) {
        out->kind  = LaunchKind::kSoMain;
        out->so    = jit ? "libbox64.so" : "libqemu-x86_64.so";
        out->entry = jit ? "bsh_box64_entry" : "qemu_entry";
        out->guest = path;      // 让 argv 变成 [<guest_name>, <这个文件>, …]
        out->guest_name = jit ? "box64" : "qemu-x86_64";
        return true;
    }
    // 开发/自举用:BSH_FORCE_QEMU=1 时 aarch64 访客也交给 qemu(TCI,不需要可执行页)。
    // 为什么需要:某些**大号 glibc ET_EXEC**(实测 SDK 的 cmake,16MB)在 elfloader 里
    // 一进 guest 就 SIGSEGV(rc=139,连 [elf] fault: 都来不及打),而同一个二进制交给
    // qemu 解释执行是好的(实测它只差 glibc 那几个 stub 库)。自举链路先用它绕过去。
    const bool force_qemu = getenv("BSH_FORCE_QEMU") != nullptr;
    if (mach == EM_AARCH64 && (!jit || force_qemu)) {
        out->kind  = LaunchKind::kSoMain;
        out->so    = "libqemu-aarch64.so";
        out->entry = "qemu_entry";
        out->guest = path;
        out->guest_name = "qemu-aarch64";
        return true;
    }
    out->kind = LaunchKind::kElf;
    out->path = path;
    return true;
}

// ================= 子进程工具 =================

void CloseInheritedFdsExcept(const std::vector<int>& keep) {
    DIR* d = opendir("/proc/self/fd");
    if (!d) return;
    int dfd = dirfd(d);
    struct dirent* e;
    while ((e = readdir(d))) {
        int fd = atoi(e->d_name);
        if (fd <= 2 || fd == dfd) continue;
        bool k = false;
        for (int x : keep) if (x == fd) { k = true; break; }
        if (!k) close(fd);
    }
    closedir(d);
}

void ApplyFdSet(int source, int target, std::vector<int>* keep) {
    if (source == target) {
        int fl = fcntl(target, F_GETFD);
        if (fl >= 0) fcntl(target, F_SETFD, fl & ~FD_CLOEXEC);
    } else {
        if (dup2(source, target) < 0) _exit(124);
        close(source);
        int fl = fcntl(target, F_GETFD);
        if (fl >= 0) fcntl(target, F_SETFD, fl & ~FD_CLOEXEC);
    }
    keep->push_back(target);
}

void ApplyEnv(const std::vector<std::string>& env) {
    for (const auto& kv : env) {
        auto eq = kv.find('=');
        if (eq == std::string::npos || eq == 0) continue;
        setenv(kv.substr(0, eq).c_str(), kv.substr(eq + 1).c_str(), 1);
    }
}

/* ── guest 环境预备(2026-09-28 加:为了能跑 glibc 编出来的 guest) ──────────
 *
 * 背景:elfloader 的加载链路对 glibc guest 其实是通的(实测:静态 guest 的
 * exit stub 注入/ET_EXEC 加载/跳执行全正常;动态 guest 能把控制权交给
 * **glibc 的 ld.so** 并让它自己报错),但两条环境上的坑会拦死它:
 *
 * 1) GLIBC_TUNABLES 里补 glibc.pthread.rseq=0 —— **必须是这一条**
 *    沙箱的 seccomp 对 rseq(aarch64 是 293)是直接 SIGSYS 打杀(逐号探针实测
 *    rc=159),而 glibc 2.35+ 在 __libc_start_main 里**无条件**注册 rseq,被信号
 *    杀死时连降级的机会都没有 —— 静态 glibc guest 就死在 glibc 自己的启动里
 *    (输出里 [elf] 几行都正常,最后 rc=159)。
 *    glibc 官方留了这个 tunable,实测有效(qemu -strace:默认启动期调 1 次 rseq,
 *    加上它变 0 次;把名字拼错则仍是 1 次,说明是这条开关起的作用、不是随便设个
 *    tunable 就行)。
 *    这里**无条件设**:静态 guest 没有 PT_INTERP,无从判断它是不是 glibc;而 musl
 *    根本不认这个变量,对 musl guest 无害。已有 GLIBC_TUNABLES 时追加,不覆盖
 *    用户自己的设置。放在 ForkChild 而不是 kElf 专用路径,是因为 qemu 那条兜底
 *    路线跑 glibc guest 时同样会被这个 syscall 拦(box64 自己拦 syscall,不需要)。
 *
 * 2) LD_LIBRARY_PATH(见 ChildRunElf 里那段)—— glibc 的 ld.so **不搜可执行文件
 *    所在目录**,得显式告诉它 guest 的库在哪。库只有一处:随 HAP 打的 bundle libs
 *    (我们自编的 ld-linux-aarch64.so.1 + libc.so.6,见 scripts/build_glibc.sh)。 */
static void EnvAppendColon(const char* key, const std::string& item) {
    const char* old = getenv(key);
    if (old && *old) {
        std::string v = std::string(old) + ":" + item;
        setenv(key, v.c_str(), 1);
    } else {
        setenv(key, item.c_str(), 1);
    }
}

static void EnvPrependList(const char* key, const std::string& items) {
    const char* old = getenv(key);
    if (old && *old) {
        std::string v = items + ":" + old;
        setenv(key, v.c_str(), 1);
    } else {
        setenv(key, items.c_str(), 1);
    }
}


// ── SIGSYS 取证(只在信号处理函数里跑,必须 async-signal-safe)───────────────
// 沙箱的 seccomp 对不在白名单的系统调用**不给 errno、直接 SIGSYS**(外部看到的就是
// rc=159),于是 guest 只留下"159"这一个数字,死在哪一号上完全看不出来。内核其实把
// 答案放进了 SIGSYS 的 siginfo(si_syscall / si_call_addr,4.14+ 稳定提供)。
// 这里手写十进制 + write(2):printf/malloc 在信号里可能正好撞上被中断的堆锁。
static void BshWriteDec(int fd, long v) {
    char b[24];
    int i = (int)sizeof b;
    bool neg = v < 0;
    unsigned long u = neg ? (unsigned long)(-v) : (unsigned long)v;
    if (u == 0) b[--i] = '0';
    while (u) { b[--i] = (char)('0' + (u % 10)); u /= 10; }
    if (neg) b[--i] = '-';
    ssize_t r = write(fd, b + i, sizeof b - (size_t)i);
    (void)r;
}

static void BshWriteHex(int fd, unsigned long a) {
    char b[16];
    int i = (int)sizeof b;
    for (int k = 0; k < 16; k++) {
        int d = (int)(a & 0xf);
        b[--i] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
        a >>= 4;
    }
    ssize_t r = write(fd, b + i, sizeof b - (size_t)i);
    (void)r;
}

// **只记录、不重发** —— 这是实测(2026-10-01)定的,也顺带把这一层变成了"优雅降级":
// seccomp 用的是 SECCOMP_RET_TRAP,有处理函数时只要它**正常返回**,内核就让那次调用
// 以 -ENOSYS 结束(等价于"内核没有这个调用"),只有没人接才按默认动作打死进程。
// 于是被拦的调用自动走 guest 自己的回退分支:
//   · hdc 的静态 libuv 在 loop 初始化时探 io_uring_setup(425) → ENOSYS → 退回 epoll;
//   · glibc 的 rseq(293) / clone3(435) 同理退回老路径。
// 这正是真实 Linux(内核不支持该调用)下的行为,guest 侧都写了这种分支 —— 而"一碰就
// rc=159"就是因为早先没人接这个信号(默认动作 = 死)。见下面安装处与 BshWriteDec 上方的注释。
// 日志按进程封顶,免得某个在循环里调用被拦调用的 guest 把 stderr 刷爆。
static volatile sig_atomic_t s_sigsysLogged = 0;

// 取证日志的开关(`BSH_SIGSYS_TRACE=1`):**默认不打**。
// 为什么默认关:这一行**每次运行都会出现**——最典型的是 hdc 那套静态 libuv,每次起
// 都要探一次 io_uring_setup(425)(同一次自举里至少两条),用户看到的"噪声"就是它。
// 处理函数本身**必须常驻**(那次调用要以降级方式返回 -ENOSYS,见上面那段),所以这里
// 只关打印、不关处理。
// 处理函数里**不能**用 getenv(不是 async-signal-safe 的东西),所以由 ForkChild 在装
// sigaction 之前问一次、存进下面这个静态量,处理函数只读它。
static volatile sig_atomic_t s_sigsysTrace = 0;

static void OnSigSys(int, siginfo_t* si, void*) {
    static const char kHead[] = "\n[bsh] SIGSYS: 系统调用 ";
    static const char kMid[]  = " 被沙箱拦下(seccomp)→ 交回 ENOSYS;调用点 0x";
    static const char kTail[] = "\n";
    // 无论打不打日志,这里都**必须正常返回**:处理函数返回后内核让那次调用以 -ENOSYS
    // 结束(等价"内核没这个调用"),guest 才会走自己的回退分支。开关只影响打印。
    if (s_sigsysTrace && s_sigsysLogged < 8) {
        s_sigsysLogged++;
        ssize_t r = write(2, kHead, sizeof kHead - 1); (void)r;
        BshWriteDec(2, si ? (long)si->si_syscall : -1L);
        r = write(2, kMid, sizeof kMid - 1); (void)r;
        BshWriteHex(2, si ? (unsigned long)si->si_call_addr : 0UL);
        r = write(2, kTail, sizeof kTail - 1); (void)r;
    }
}

// ── 崩溃取证:guest 崩在哪儿 ──────────────────────────────────────────────
// 症状:某些大号 glibc ET_EXEC(实测 SDK 的 cmake)在 elfloader 里"一进 guest 就
// SIGSEGV",外部只看到一个 rc=139,连 elfloader 自带的那句 [elf] fault: 都来不及打。
// 这里在 procmgr 的 child 侧再兜一层,除了信号/地址/PC,还把 **PC 落在哪个映射** 打出来 ——
// 那一行就能区分:崩在 guest 自己的段、崩在我们 JIT 出来的代码、还是压根没映射的地址。
// 同 BshWriteDec:只用 async-signal-safe 的东西(手写十六进制 + write/open/read)。
//
// 谁调用它:**没有任何地方直接调**。它是信号处理函数,触发源是内核。注册在
// ForkChild() 的子进程侧(见下面 sigaltstack/sigaction 那一段,就在 SIGSYS 处理的
// 同一个块里):信号恢复默认、屏蔽解开之后、guest 开跑之前,给
//   SIGSEGV / SIGBUS / SIGILL / SIGABRT
// 四个都挂上,并配一块 64KB 静态备用栈(SA_ONSTACK)—— guest 崩的时候原栈往往正是
// 坏的,不换栈连处理函数自己都进不去。于是**每个 procmgr 派生出来的子进程都带着它**,
// 常驻、无环境变量开关,代价只是每子进程一次 sigaction。
//
// 状态(如实记着,别当它是已验证的东西):
//   截至 2026-10-01 这一版,**它一次都没有被触发过**。会触发它的那条路(§3.1:cmake
//   在 elfloader 里 SIGSEGV)当时被"给 cmake 套一层 #! 壳转 qemu"绕过去了,而那才是
//   当前自举链路实际走的路径 —— 也就是说这段代码只有"编译通过"这一条证据,跑通自举
//   并不构成对它的验证。
//   等 elfloader 那条根因真去修的时候,它才是第一手证据:日志里出现 "[bsh] FAULT …"
//   就说明 guest 确实死在信号上,而且 "所在映射" 那一段直接告诉你是死在 guest 的段、
//   我们的 JIT 代码、还是没映射的地址。在那之前,别把它的存在当成"崩溃已被处理"
//   (它只取证,不改行为:处理函数返回后仍然按默认动作把进程打死)。
// 把故障现场写到某个 fd。**同时写 stderr 和 <资源根>/elf-fault.log**：elf 子进程里
// stderr 未必还在（也可能整条输出路径有问题），落一个文件最保险 —— 排查时先看那个文件。
static void FaultReport(int fd, int sig, unsigned long pc, unsigned long fault,
                        int has_addr, unsigned long faddr) {
    static const char kHead[] = "\n[bsh] FAULT sig=";
    static const char kAtAddr[] = " addr=0x";
    static const char kPc[] = " pc=0x";
    static const char kMap[] = " 所在映射: ";
    static const char kNone[] = " (不在任何映射里)";
    static const char kEnd[] = "\n";
    ssize_t r = write(fd, kHead, sizeof kHead - 1); (void)r;
    BshWriteDec(fd, sig);
    r = write(fd, kAtAddr, sizeof kAtAddr - 1); (void)r;
    BshWriteHex(fd, has_addr ? faddr : fault);
    r = write(fd, kPc, sizeof kPc - 1); (void)r;
    BshWriteHex(fd, pc);

    // 找 PC 落在哪一段映射上(/proc/self/maps 每行 "start-end perms ...")
    int mfd = open("/proc/self/maps", O_RDONLY);
    if (mfd >= 0) {
        char buf[8192];
        ssize_t n = read(mfd, buf, sizeof buf - 1);
        close(mfd);
        if (n > 0) {
            buf[n] = 0;
            char* p = buf;
            while (*p) {
                char* eol = p;
                while (*eol && *eol != '\n') eol++;
                unsigned long s = 0, e = 0;
                char* q = p;
                while (*q && *q != '-') { int d = (*q <= '9') ? *q - '0' : (*q | 32) - 'a' + 10; s = (s << 4) | (unsigned long)d; q++; }
                if (*q == '-') { q++; while (*q && *q != ' ') { int d = (*q <= '9') ? *q - '0' : (*q | 32) - 'a' + 10; e = (e << 4) | (unsigned long)d; q++; } }
                if (e > s && pc >= s && pc < e) {
                    r = write(fd, kMap, sizeof kMap - 1); (void)r;
                    r = write(fd, p, (size_t)(eol - p)); (void)r;
                    break;
                }
                p = (*eol) ? eol + 1 : eol;
            }
            if (!*p) { r = write(fd, kNone, sizeof kNone - 1); (void)r; }
        }
    }
    r = write(fd, kEnd, sizeof kEnd - 1); (void)r;
}

static void OnSigFault(int sig, siginfo_t* si, void* uctx) {
    unsigned long pc = 0, fault = 0;
    ucontext_t* uc = (ucontext_t*)uctx;
    if (uc) { pc = (unsigned long)uc->uc_mcontext.pc; fault = (unsigned long)uc->uc_mcontext.fault_address; }
    int has_addr = 0;
    unsigned long faddr = 0;
    if (si && (sig == SIGSEGV || sig == SIGBUS || sig == SIGILL)) {
        faddr = (unsigned long)si->si_addr;
        has_addr = 1;
    }
    FaultReport(2, sig, pc, fault, has_addr, faddr);
    /* 资源根是运行期值(bsh_paths.h),不能拿宏去拼字面量 */
    const std::string faultLog = std::string(bsh_sysroot()) + "/elf-fault.log";
    int lf = open(faultLog.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (lf >= 0) {
        FaultReport(lf, sig, pc, fault, has_addr, faddr);
        close(lf);
    }
    signal(sig, SIG_DFL);
    _exit(128 + sig);
}

// fork 通用前置:父进程返回 child pid(>0) 或 -1;子进程返回 0。
// 注意:procmgr 在主进程里 fork,子进程继承的是**主进程**的 fd 表 ——
// 调用方(可能是另一个进程里的命令 so)想带过来的 fd 必须经 SCM_RIGHTS 收下,
// 这里再 dup2 到目标号。
pid_t ForkChild(const SpawnRequest& req) {
    pid_t pid = fork();
    if (pid != 0) {
        // 新命令接管终端的起点:把**那个会话**的 tty 前台进程组拉回当前进程组。
        // 不做这一步,上一个命令留下的 pgrp 会让新前台命令收不到 ISIG。
        // (交互式 shell 随后会自己 tcsetpgrp 到它的子进程组。)
        // 只有 bsh 会话(sid 0)会真的动 —— 别的会话由它自己的 shell 管,见 bsh_tty.cpp。
        if (pid > 0) bsh_tty_session_reset_pgrp(req.sid);
        return pid;
    }

    // ---- child ----
    std::vector<int> keep;

    // 同一个 source 被多个 target 引用(典型:stdout/stderr 共用 pty slave):
    // 第一次 dup2+close 会让后续引用失效,先 dup 出独立副本。
    std::vector<SpawnRequest::InheritedFd> stdio_norm = req.stdio_fds;
    std::vector<SpawnRequest::InheritedFd> extra_norm = req.extra_fds;
    {
        std::unordered_set<int> seen;
        auto normalize = [&](std::vector<SpawnRequest::InheritedFd>& list) {
            for (auto& f : list) {
                if (!seen.insert(f.source_fd).second) {
                    int cp = dup(f.source_fd);
                    if (cp < 0) _exit(124);
                    f.source_fd = cp;
                }
            }
        };
        normalize(stdio_norm);
        normalize(extra_norm);
    }

    for (const auto& f : stdio_norm) ApplyFdSet(f.source_fd, f.target_fd, &keep);
    for (const auto& f : extra_norm) ApplyFdSet(f.source_fd, f.target_fd, &keep);

    keep.push_back(STDIN_FILENO);
    keep.push_back(STDOUT_FILENO);
    keep.push_back(STDERR_FILENO);
    CloseInheritedFdsExcept(keep);

    // stdio 接到什么上了?命令 so 不链接宿主,只能靠 BSH_TTY_STDIO 这个环境变量
    // 知道"我的 stdio 是终端";重定向到文件/管道时不设,isatty 因此保持为假
    // (与真 tty 语义一致)。
    {
        struct stat st;
        if (fstat(STDIN_FILENO, &st) == 0 && S_ISSOCK(st.st_mode))
            setenv("BSH_TTY_STDIO", "1", 1);
    }

    // box64 guest 的假 pts 开关(shim/pty_shim.c 的 BSH_FAKE_PTY)。
    // 这里沙箱三层都打不开真 /dev/ptmx(EACCES,实测),所以"能拿到 pty"只有一条路:
    // 用户态的 socketpair 假 pts。elfloader 的 guest shim 早就在用它(那份在这个函数
    // 之后由 ChildRunElf 单独设),box64 这条 kSoMain 路径没有 LD_PRELOAD,得靠这里设 ——
    // 否则同一台设备上"aarch64 guest 有 pty、x86_64 guest 没有"。
    setenv("BSH_FAKE_PTY", "1", 1);

    // 信号全部恢复默认并解除屏蔽(父进程的工作线程可能有 mask)
    for (int s = 1; s < 32; ++s) signal(s, SIG_DFL);
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, nullptr);

    /* SIGSYS 处理(见 OnSigSys 上面那段):装在这里是因为此刻所有信号刚被恢复默认、
     * 屏蔽也解开了,而 guest(连同给它预载的 shim、glibc 自己的启动)还没开始跑。
     *
     * 两件事一次做完:
     *   1) 取证 —— 被 seccomp 拦下的调用会打一行日志,带**系统调用号**和调用点;
     *      就是这一行在 2026-10-01 定出了 hdc 的 rc=159 元凶:io_uring_setup(425),
     *      由它静态链进去的 libuv 在 loop 初始化时探的。
     *   2) 降级 —— 处理函数正常返回,那次调用就以 **-ENOSYS** 交回 guest,而不是按
     *      默认动作打死进程(真实 Linux 内核不支持某调用时就是这个行为,guest 那边
     *      都写了回退分支:libuv 退回 epoll、glibc 退回非 rseq/clone3 的老路径)。
     *      这是**全局**语义变化:以前"碰一下就死"的 guest,现在会带着 ENOSYS 继续跑。
     * 处理函数**常驻、没有环境变量开关**(降级语义必须一直都在),代价只是每个子进程
     * 一次 sigaction;但上面第 1 条的**打印**由 `BSH_SIGSYS_TRACE=1` 控制,默认不打 ——
     * 那行本来就"每次运行都有"(hdc 每次起就探一次 425),不关就是噪声。
     * 这里先把开关问一次存进静态量:处理函数里不能调 getenv(非 async-signal-safe)。 */
    {
        s_sigsysTrace = (getenv("BSH_SIGSYS_TRACE") != nullptr) ? 1 : 0;
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = OnSigSys;
        sa.sa_flags = SA_SIGINFO;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGSYS, &sa, nullptr);
        /* 崩溃取证:**这里就是 OnSigFault 唯一的注册点**(它是信号处理函数,没有直接
         * 调用者,靠内核在子进程收到信号时跳进来;判据与状态见它上面那段注释)。
         * 挂的是四个"进程要没"的信号 SIGSEGV/SIGBUS/SIGILL/SIGABRT,单独配一块
         * 64KB 备用栈 —— 和 elfloader 自己的 fault handler 一样的理由:
         * guest 崩的时候原栈往往正是坏的,不换栈处理函数自己都进不去。
         * 注意它只取证、不改行为(返回后仍按默认动作打死进程)。
         * 实测状态:截至 2026-10-01 从未触发过 —— 见 OnSigFault 上面那段"状态"。 */
        {
            static char faultStack[64 * 1024];
            stack_t ss;
            memset(&ss, 0, sizeof ss);
            ss.ss_sp = faultStack;
            ss.ss_size = sizeof faultStack;
            ss.ss_flags = 0;
            sigaltstack(&ss, nullptr);
            sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
            /* ⚠ 必须重设 sa_sigaction：上面那个 sa 是给 SIGSYS 准备的（sa_sigaction =
             * OnSigSys），只改了 sa_flags 就注册的话，四个崩溃信号接到的仍是 OnSigSys ——
             * 它对任何信号都"正常返回"，于是 guest 的 SIGSEGV 会被反复重试（而且
             * OnSigFault 这个取证函数一次都不会跑，"从未触发过"就是这么来的）。 */
            sa.sa_sigaction = OnSigFault;
            sigaction(SIGSEGV, &sa, nullptr);
            sigaction(SIGBUS, &sa, nullptr);
            sigaction(SIGILL, &sa, nullptr);
            sigaction(SIGABRT, &sa, nullptr);
        }
    }

    if (!req.cwd.empty() && chdir(req.cwd.c_str()) != 0) { /* 保持原目录 */ }

    std::string name = req.proc_name.empty() ? req.cmd : req.proc_name;
    if (!name.empty()) prctl(PR_SET_NAME, name.c_str(), 0, 0, 0);

    ApplyEnv(req.env);
    /* 沙箱把 rseq 打成 SIGSYS,glibc guest 会因此在启动期直接死掉 —— 见上面
     * EnvAppendColon 前的长注释。musl guest 不认这个变量,无副作用。
     * ⚠ 注意这条现在兜的是**自带 libc 的 guest**:我们随包发的 glibc 已经打了
     * rseq no-op 补丁(scripts/glibc-ohos/patches/0002),用我们运行时的 guest 不再
     * 需要它;但**静态 glibc guest**(自带 libc,我们改不了它的源码)和自带 libc 的
     * 动态 guest 仍然靠这条活命,所以不能删。 */
    EnvAppendColon("GLIBC_TUNABLES", "glibc.pthread.rseq=0");

    /* 孩子必须能找回 procmgr:命令 so 与 guest 的 **exec 委托**都靠 BSH_CTRL_SOCK
     * 发请求(见 shim/exec_shim.c)。但**不保证每个孩子的环境里都有它** —— 实测 hvigor
     * 起 cmake 时传的是精简环境,cmake 再起 ninja 时那条委托就因为找不到 socket 退化成
     * 真 execve,撞上应用数据目录的 noexec,报 "Permission denied"(native 构建就死在这)。
     * 这里统一补上,与请求方的环境无关 —— 路径取自 common/bsh_paths.h,和宿主同一份定义。 */
    setenv("BSH_CTRL_SOCK", bsh_ctrl_sock_path(), 1);
    bsh_set_sysroot(bsh_sysroot());   /* 走 setter:一并刷新本单元的全局变量 */
    setenv("BSH_HOME_DIR", bsh_home_dir(), 1);
    /* 会话号:命令 so 与 guest 里的 tty_shim / exec 委托靠它知道"我属于哪个终端",
     * 从而问到**自己那个会话**的 termios/winsize(见 common/bsh_paths.h 的
     * BSH_SESSION_ENV)。req.sid 是从请求的 env 里派生来的,值可能来自调用方继承;
     * 这里再显式落一次,保证子进程看到的与 procmgr 记账用的是同一个数。 */
    setenv(BSH_SESSION_ENV, std::to_string(req.sid).c_str(), 1);
    return 0;
}

// argv 连续存放 + 指针表(生命周期覆盖整个子进程)
struct ArgvBlock {
    std::vector<char> blob;
    std::vector<char*> argv;
    void Build(const std::vector<std::string>& src, const std::string& fallback) {
        std::vector<std::string> st = src;
        if (st.empty()) st.push_back(fallback);
        const int argc = (int)st.size();
        std::vector<size_t> offs((size_t)argc);
        for (int i = 0; i < argc; i++) {
            offs[(size_t)i] = blob.size();
            blob.insert(blob.end(), st[(size_t)i].begin(), st[(size_t)i].end());
            blob.push_back('\0');
        }
        argv.assign((size_t)argc + 1, nullptr);
        for (int i = 0; i < argc; i++) argv[(size_t)i] = blob.data() + offs[(size_t)i];
    }
    int argc() const { return (int)argv.size() - 1; }
};

// ================= kSoMain =================

// 前置声明:定义在下面(见「低位地址让位」一段)。kSoMain 与 kElf 两条路都要用。
void UnmapLowAnonRegions();

/* BSH_FAULT_TRACE 是否要给这个子进程装崩溃取证 handler。
 * 两处都查:ForkChild 在子进程里跑过 ApplyEnv(req.env) 之后才轮到我们,所以 getenv
 * 一般就够;再扫一遍 req.env 是不想依赖那个时序(BSH_SPAWN_TRACE 也是这么写的)。
 * 写法上注意 "=0" 要当没开 —— 便于临时关掉而不用 unset。 */
bool FaultTraceWanted(const SpawnRequest& req) {
    const char* own = getenv("BSH_FAULT_TRACE");
    if (own && own[0] && own[0] != '0') return true;
    for (const auto& kv : req.env)
        if (kv.rfind("BSH_FAULT_TRACE=", 0) == 0 && kv.size() > 16 && kv[16] != '0')
            return true;
    return false;
}

[[noreturn]] void ChildRunSoMain(const SpawnRequest& req, const std::string& so,
                                 const std::string& entry, const std::string& guest,
                                 const std::string& guest_name, int entry_argc) {
    // 低 4GB 的匿名映射先让出来:guest 可能是带固定基址的 ET_EXEC(典型 0x400000),
    // box64 也会主动去要低地址。反正这是 fork 出来的新进程,用不上那些内存。
    //
    // 必须放在最前面:下面 ab.Build() 等会**分配内存**,先腾再分配才不会被腾掉自己
    // 刚拿到的页。(kElf 那条路是 Build 之后才调,顺序不同 —— 它一直是能用的,
    // 但这种"先分配再 munmap"的顺序理论上是有隐患的,新写的这条不照抄。)
    //
    UnmapLowAnonRegions();

    /* 可选的崩溃取证。命令 so 崩了(SIGSEGV 之类)平时**一行输出都没有** —— 调用方只
     * 拿到一个 rc=139,排查时全靠猜(实测 kimi-code 的 TUI 就卡在这一步:零输出、
     * 零系统调用痕迹)。BSH_FAULT_TRACE=1 时在 fork 出的子进程里装上 elfloader 那套
     * fault handler,崩溃时打:
     *     [elf] fault: SIGSEGV pc=0x… addr=0x…
     * 再 _exit(128+sig) —— 退出码语义不变。
     * 默认不开:这个 handler 会插进别人的信号链(node/V8 各自也装 SIGSEGV handler),
     * 平常没必要抢。要查的时候 `export BSH_FAULT_TRACE=1` 再跑那条命令即可。 */
    if (FaultTraceWanted(req)) elf_arm_fault_handlers();

    /* argv 组装。两种形态:
     *   普通命令 so  —— 原样用调用方给的 argv(argv[0] 是命令名,multicall 靠它分发);
     *   guest 形态   —— 用某个 so 去跑一个文件(box64 / qemu):argv 必须是
     *                   [<so 的惯用名>, <guest 路径>, 原参数(去掉 argv[0])…]
     *                   两者都按 argv[1] 取 guest,argv[0] 只是打印/自报用的标签
     *                   (qemu 还会用它选自身的名字,所以要让 Resolve 给准)。
     * 于是 `./x86_64-musl-static -x` 走的就是 `box64 ./x86_64-musl-static -x`。 */
    std::vector<std::string> args;
    if (guest.empty()) {
        args = req.argv;
    } else {
        args.push_back(guest_name.empty() ? "box64" : guest_name);
        args.push_back(guest);
        for (size_t i = 1; i < req.argv.size(); i++) args.push_back(req.argv[i]);
    }
    ArgvBlock ab;
    ab.Build(args, req.cmd);

    // so 名 → bundle 绝对路径(显式路径形式则原样用)
    std::string path = so;
    if (!path.empty() && path[0] != '/') path = std::string(kBundledLibDir) + so;

    // RTLD_GLOBAL:必须进全局命名空间。box64 的补丁集把 box64lib 置成 NULL
    // (src/box64context.c 的 OHOS_PATCH_SKIP_BOX64LIB),而它解析包装符号走的是
    //   dlsym(my_context->box64lib, "my_printf")     // = dlsym(RTLD_DEFAULT, …)
    // (src/librarian/library.c:921),只搜**全局**作用域 —— 用 RTLD_LOCAL 加载时
    // libbox64.so 的符号不在全局里,于是每一个 my_* 都返回 NULL、重定位全失败
    // (症状:「Warning, function my_xxx not found」刷屏后 SIGSEGV)。
    // 各命令 so 之间符号打架的风险:这里是 fork 后的子进程,一个子进程只跑一个
    // so,不会污染主进程,也不会和别的命令共存,所以这个代价可以接受。
    void* h = dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (!h && path != so) h = dlopen(so.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        const char* de = dlerror();
        OH_LOG_ERROR(LOG_APP, "dlopen %{public}s failed: %{public}s",
                     so.c_str(), de ? de : "?");
        dprintf(STDERR_FILENO, "[procmgr] cannot dlopen %s: %s\n", so.c_str(),
                de ? de : "?");
        _exit(125);
    }

    /* 再装一次(见函数开头的说明):node/V8 启动过程中会各自装 SIGSEGV handler,
     * 把上面那次盖掉。真正要取证的是"跑起来之后崩",所以调入口之前再抢回来一次。 */
    if (FaultTraceWanted(req)) elf_arm_fault_handlers();

    // 统一入口约定:int main(int argc, char** argv)；
    // arity==3 时多给一个 envp（"#BSHSO" 启动器文件第 4 行写的，见 command_map.h）。
    using EntryFn2 = int (*)(int, char**);
    using EntryFn3 = int (*)(int, char**, char**);
    int rc;
    if (entry_argc == 3) {
        auto fn3 = (EntryFn3)dlsym(h, entry.c_str());
        if (!fn3) {
            dprintf(STDERR_FILENO, "[procmgr] dlsym(%s) failed: %s\n", entry.c_str(),
                    dlerror());
            _exit(126);
        }
        rc = fn3(ab.argc(), ab.argv.data(), environ);
    } else {
        auto fn = (EntryFn2)dlsym(h, entry.c_str());
        if (!fn) {
            dprintf(STDERR_FILENO, "[procmgr] dlsym(%s) failed: %s\n", entry.c_str(),
                    dlerror());
            _exit(126);
        }
        rc = fn(ab.argc(), ab.argv.data());
    }
    fflush(nullptr);          // 冲刷 stdio 缓冲,保证输出落到 fd
    _exit(rc & 0xFF);
}

pid_t SpawnSoMain(const SpawnRequest& req, const std::string& so,
                  const std::string& entry, const std::string& guest,
                  const std::string& guest_name, int entry_argc) {
    pid_t pid = ForkChild(req);
    if (pid < 0) return -1;
    if (pid == 0) ChildRunSoMain(req, so, entry, guest, guest_name, entry_argc);   // 不返回
    return pid;
}

// ================= kElf =================

bool ReadWholeFile(const char* path, std::vector<char>& out) {
    FILE* f = fopen(path, "rb");
    if (!f) return false;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return false; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return false; }
    rewind(f);
    out.resize((size_t)sz);
    bool ok = fread(out.data(), 1, (size_t)sz, f) == (size_t)sz;
    fclose(f);
    return ok;
}

// 动态 ELF(带 PT_INTERP)时取解释器路径;只需要读 ELF 头/程序头字节。
bool ElfReadInterp(const char* path, std::string* interp) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    unsigned char eh[64];
    if (read(fd, eh, 64) != 64) { close(fd); return false; }
    uint16_t e_type, e_phnum, e_phentsize;
    uint64_t e_phoff;
    memcpy(&e_type, eh + 16, 2);        // Elf64_Ehdr.e_type@16
    memcpy(&e_phoff, eh + 32, 8);       // e_phoff@32
    memcpy(&e_phentsize, eh + 54, 2);   // e_phentsize@54
    memcpy(&e_phnum, eh + 56, 2);       // e_phnum@56
    bool ok = false;
    /* 认两种类型：PIE(ET_DYN) 与**非 PIE 的动态程序**(ET_EXEC + PT_INTERP)。
     * 之前只认 ET_DYN,于是 kimi-code / cmake 这类官方 arm64 发行二进制被判成
     * "静态 guest",直接跳 _start 而不跑解释器 → GOT 全 0 → 一进去就 SIGSEGV(pc=0)。
     * 内核在 ET_EXEC + PT_INTERP 时也是先起解释器,这里对齐这个语义。 */
    if ((e_type == 2 /* ET_EXEC */ || e_type == 3 /* ET_DYN */) &&
        e_phentsize >= 56 && e_phnum > 0 && e_phnum < 4096) {
        unsigned char ph[56];
        for (int i = 0; i < e_phnum; i++) {
            off_t o = (off_t)(e_phoff + (uint64_t)i * e_phentsize);
            if (pread(fd, ph, 56, o) != 56) break;
            uint32_t p_type;
            uint64_t p_offset, p_filesz;
            memcpy(&p_type, ph, 4);
            memcpy(&p_offset, ph + 8, 8);
            memcpy(&p_filesz, ph + 32, 8);
            if (p_type == 3 /* PT_INTERP */ && p_filesz > 0 && p_filesz < 4096) {
                std::string s((size_t)p_filesz, '\0');
                if (pread(fd, &s[0], (size_t)p_filesz, (off_t)p_offset) ==
                    (ssize_t)p_filesz) {
                    interp->assign(s.c_str());
                    ok = true;
                }
                break;
            }
        }
    }
    close(fd);
    return ok;
}

// 低位地址让位:munmap 掉低 4GB 里所有**匿名**映射 —— 带名字的 [anon:*] 与无名的
// 都算;文件映射(__arkweb 的 db 之类)不动。
//
// 为什么需要:guest 可能是带固定基址的 ET_EXEC(典型 0x400000),box64 也会主动
// 去要低地址;不把这些腾出来就会撞上,表现为
//   cannot create memory map (@0x400000 0xd15c8) for elf "..." got 0x2008e000
// 然后是 SIGSEGV。kSoMain 与 kElf 两条路都在 fork 出的子进程里调用 —— 新进程用不上
// 这些内存,且不会影响主进程。
void UnmapLowAnonRegions() {
    FILE* f = fopen("/proc/self/maps", "r");
    if (!f) return;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        unsigned long lo = 0, hi = 0;
        char perms[8] = {0};
        char path[256] = {0};
        int n = sscanf(line, "%lx-%lx %7s %*s %*s %*s %255s", &lo, &hi, perms, path);
        if (n < 3 || hi <= lo) continue;
        if (hi > 0x100000000UL) continue;
        // 无名映射也要清(n < 4 = /proc/self/maps 那行没有路径列)。
        // 实测应用主进程低 4GB 里最大的占用者就是一行**无名**的
        //   00140000-20040000 rw-p        (≈512MB,ArkTS 堆的预留区)
        // 它正盖着 ET_EXEC 要的 0x400000。原来只认 "[anon:" 前缀,于是这行被漏掉,
        // 表现为 box64 报 "cannot create memory map (@0x400000 …) got 0x2009e000"。
        // 文件映射(路径列不是 [anon:)不动 —— 那些是 __arkweb 的 db,不碍事。
        if (n < 4 || strncmp(path, "[anon:", 6) == 0)
            munmap((void*)lo, hi - lo);
    }
    fclose(f);
}

// 重新挂崩溃取证 handler（OnSigFault），并配一块**新的**备用信号栈。
//
// 为什么要在 UnmapLowAnonRegions() 之后再来一次：ForkChild 里挂 handler 时那块 64KB
// 备用栈是 libentry 的静态数组（.bss），很可能落在低 4GB 的匿名区间里 —— 上面那个函数
// 会把它连同 ArkTS 的堆预留一起 munmap 掉。栈没了之后，guest 一旦 SIGSEGV，内核
// `get_sigframe` 失败 → 直接 force SIGSEGV：进程照旧按 rc=139 死，而 handler 一个字
// 都打不出来（这正是"从未触发过"的真正原因）。这里用 mmap 拿一块新的、且**不会再被清掉**
// 的栈，然后重挂四个信号。
static void RearmFaultHandlers() {
    static void* alt = nullptr;
    if (!alt) {
        void* p = mmap(nullptr, 64 * 1024, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED)
            return;
        alt = p;
    }
    stack_t ss;
    memset(&ss, 0, sizeof ss);
    ss.ss_sp = alt;
    ss.ss_size = 64 * 1024;
    ss.ss_flags = 0;
    sigaltstack(&ss, nullptr);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = OnSigFault;
    /* 用备用栈：guest 崩的时候它自己的栈往往正是坏的，在坏栈上构信号帧会二次故障
     * （内核直接 force SIGSEGV，handler 进不去）。这块栈是刚 mmap 的、不会再被清掉。 */
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, nullptr);
    sigaction(SIGBUS, &sa, nullptr);
    sigaction(SIGILL, &sa, nullptr);
    sigaction(SIGABRT, &sa, nullptr);
}

[[noreturn]] void ChildRunElf(const SpawnRequest& req, const std::string& path) {
    ArgvBlock ab;
    ab.Build(req.argv, req.cmd);      // argv[0] 保持调用方原样(不改写成绝对路径)

    UnmapLowAnonRegions();
    /* 清完低位映射后必须重挂取证 handler：ForkChild 里挂那次用的备用信号栈在 libentry
     * 的 .bss，可能正好落在刚被 munmap 的区间里 —— 栈没了，内核构不出信号帧，就会
     * **force SIGSEGV**：guest 照旧 rc=139，而 handler 一个字都打不出来（实测现象）。 */
    RearmFaultHandlers();


    /* /proc/self/exe 的替身：guest 侧的 shim（shim/fs_shim.c 里那一层）读这个变量来回答
     * readlink/stat/open("/proc/self/exe")。内核给的是**宿主 appspawn**，不是 guest 自己，
     * 于是"读 /proc/self/exe 再 exec 自身"这类程序在沙箱里必死。
     * 值取**子进程视角**的绝对路径：ForkChild 已按 req.cwd chdir 过，此刻 realpath 出来的
     * 就是 guest 该看到的那条路径；realpath 失败（理论上不会，文件上面已经读过了）用原样。
     * 只在这一条路上设 —— 命令 so 侧不是"可执行文件"，box64/qemu 的 x86 guest 也不吃
     * LD_PRELOAD（它们自己模拟 syscall），设了反而误导。 */
    {
        char gxbuf[4096];
        const char* gx = realpath(path.c_str(), gxbuf) ? gxbuf : path.c_str();
        setenv("BSH_GUEST_EXE", gx, 1);
    }

    /* 让 guest 的 ld.so 找得到它自己的库 —— **只有一处:bundle libs**。
     * glibc 的 ld.so **不搜可执行文件所在目录**(不像 Windows),所以一个动态 glibc
     * guest 摆在任意目录里时,ld.so 会报
     *     error while loading shared libraries: libc.so.6: cannot open shared object file
     * (这句报错本身说明 hand-off 已经成功 —— 是 glibc 的 ld.so 在报,不是我们)。
     * 随 HAP 打进去的运行时(entry/libs/arm64/:我们自编的 ld-linux-aarch64.so.1 +
     * libc.so.6,见 scripts/build_glibc.sh 的 install 阶段)就在这个目录下。
     * **必须显式加进来**:实测这个进程的 LD_LIBRARY_PATH 本来就是空的(命令 so 之间
     * 靠默认搜索路径互相找得到,不需要它),不写这一句,guest 的 ld.so 就看不见
     * bundle libs 里的 libc.so.6。
     * 2026-09-28:去掉原来的 "guest 同目录" 与 "$HOME/guests" 两个来源 —— 运行时统一
     * 随包走(bundle libs 是唯一来源),少一个来源就少一份"同名库版本不一致"的风险,
     * 何况 guest 的 ld.so 会把整个 bundle libs 都看在眼里。
     * 2026-09-30:**"guest 同目录"又加回来了**,原因是"库跟可执行文件放一块"这种
     * 分发形状(现在的 Qt 应用目录 <sysroot>/qtapp 就是这样)在 elfloader 下**没法靠
     * rpath 表达**:musl 对"内核映射的"主程序用 /proc/self/exe 推 $ORIGIN,而那个 exe
     * 是宿主 appspawn,不是 guest 自己 —— 写 `-Wl,-rpath,'$ORIGIN'` 等于白写,症状是
     *     Error loading shared library libQt6Widgets.so: No such file or directory
     * (库其实就躺在同一个目录里)。所以按路径跑的 guest,把它的目录也当成库来源;
     * 顺序上放 bundle libs **之前**:应用自带的同名库要能盖住 bundle 里的
     * (bundle libs 现在已不含 Qt,不会互相打架)。 */
    /* ⚠ 这两句的**先后顺序就是"谁排前面"**，别调换：
     *   EnvPrependList 是往链表头插，所以**后插的排在最前**。
     * 原来写的是"先 guest 目录、后 bundle"，结果 bundle 反倒压在前面 —— 与上面那段
     * 注释写的意图（"应用自带的同名库要能盖住 bundle 里的"）正好相反。
     * 代价实测过一次：`code`（**glibc** 的 Electron）本该用自己闭包里的
     * `usr/lib/vscode/libglib-2.0.so.0`（NEEDED libc.so.6），却被塞进了 bundle 里那份
     * **musl** 的 libglib-2.0.so.0（NEEDED libc.so）—— 于是 GLib 的线程池在 glibc
     * 进程里跑 musl 代码，`pool-spawner` 线程空指针 SIGSEGV（FAR=0x18），
     * `code` 每次都在 ~6 秒静默退出。取证见 build/vscode/STATUS.md §20。
     * 所以：bundle 先插（兜底），guest 目录后插（优先）。 */
    EnvPrependList("LD_LIBRARY_PATH", kBundledLibDir);
    {
        size_t slash = path.rfind('/');
        if (slash != std::string::npos && slash > 0)
            EnvPrependList("LD_LIBRARY_PATH", path.substr(0, slash));
    }

    /* guest 侧的 shim（tty 软终端 + 软链接模拟，见 scripts/build_shim.sh）：
     * 命令 so 靠"把 shim 编进自己"获得这些语义，guest 是别人的二进制，只能预载。
     * 按 guest 的 PT_INTERP 挑**同一个 libc** 编出来的那份 —— musl 的 .so 塞给
     * glibc 的 ld 会在加载期就报错。
     * 没有 shim / 静态 guest（没有 PT_INTERP）时就什么都不做：静态链接的
     * LD_PRELOAD 本来也无效。 */
    {
        std::string interp_pre;
        if (ElfReadInterp(path.c_str(), &interp_pre) && !interp_pre.empty()) {
            const char* shimName = (interp_pre.find("ld-musl") != std::string::npos)
                                       ? "libbshguest-musl.so" : "libbshguest-glibc.so";
            std::string shim = std::string(kBundledLibDir) + shimName;
            struct stat shimSt;
            if (stat(shim.c_str(), &shimSt) == 0) {
                const char* oldPre = getenv("LD_PRELOAD");
                std::string v = shim;
                if (oldPre && *oldPre) {
                    /* 逐项筛旧值（2026-10-04 定位到的元凶就在第 2 条）：
                     *   1) 与本次要加的**同一份** → 跳过（去重，避免同一个 .so 预载两遍）；
                     *   2) **另一份 bshguest shim**（libbshguest-{musl,glibc}.so）→ **也跳过**。
                     *      调用方自己就是 elfloader 起的 guest 时，它那份 shim 会被继承下来，
                     *      而这里又按**目标的** PT_INTERP 加一份。ninja 起 clang 的症状就是这么
                     *      来的：clang 是 glibc 的 ELF（NEEDED libc.so.6 + INTERP
                     *      ld-linux-aarch64.so.1），继承下来的却是 **musl** 那份 shim →
                     *      glibc 的 ld.so 去预载一个 musl 的 .so → clang 直接 SIGSEGV。
                     *      两份 shim 按 libc 分家，本来就互斥，绝不该同时出现在一条 LD_PRELOAD 里。
                     *      （而"从 shell / python 里起同一个 clang 正常"是因为那些路径上
                     *        调用方不是 guest，环境里根本没有 LD_PRELOAD。）
                     *   3) 其余（用户自己设的预载）原样保留。 */
                    const size_t ol = strlen(oldPre);
                    for (size_t b = 0; b <= ol; ) {
                        size_t e = strcspn(oldPre + b, ":");
                        if (e > 0) {
                            std::string item(oldPre + b, e);
                            bool other_shim =
                                (item.find("libbshguest-musl.so") != std::string::npos) ||
                                (item.find("libbshguest-glibc.so") != std::string::npos);
                            if (!other_shim && !(item == shim)) v += ":" + item;
                        }
                        b += e + 1;
                        if (b > ol) break;
                    }
                }
                setenv("LD_PRELOAD", v.c_str(), 1);
                /* 两个开关，都跟着 shim 一起开（shim 没装上就不设，免得变量在
                 * 别的路径上被误读）：
                 *   BSH_FAKE_PTY —— 假 pts：这台沙箱三层都拿不到 /dev/ptmx（实测
                 *     EACCES），guest 里想自己开伪终端（posix_openpt / tmux / script）
                 *     只能走 socketpair 那套实现；见 shim/pty_shim.c。
                 *   BSH_EXEC_SHIM —— guest 内的 exec 委托：沙箱里 execve 一律 EACCES，
                 *     guest 的 shell/脚本要起别的程序只能转交给 procmgr；见 shim/exec_shim.c。
                 * 另：BSH_TTY_STDIO 不在这里设 —— 它由 ForkChild 按"stdio 是不是 socket"
                 * 判定（命令 so 与 guest 同一处逻辑），shim 只读它。 */
                setenv("BSH_FAKE_PTY", "1", 1);
                setenv("BSH_EXEC_SHIM", "1", 1);
            }
        }
    }

    int rc = 127;
    std::string interp;
    if (ElfReadInterp(path.c_str(), &interp)) {
        // 动态 ELF:解释器按 basename 在 bundle libs 里找(见下面 cands)。
        // 两个镜像都从内存装载,入口起解释器,由**真正的动态链接器**做重定位后调 main
        // (见 elf_run_dyn_inproc 注释)。解释器既可能是 musl 的 `ld-musl-*.so.1`
        // (= musl 的 libc 自身),也可能是 glibc 的 `ld-linux-aarch64.so.1`
        // —— 后者的接管已经验证可用(见 scripts/glibc-ohos/)。
        std::string base = interp.substr(interp.rfind('/') + 1);
        // bundle libs 是**唯一**来源:两套运行时都随 HAP 打进去,放在签名包内,
        // 内核不会把它当"外部二进制"弹确认框(放 $HOME 会:那是 noexec,mmap(PROT_EXEC)
        // 直接 EACCES)。文件名 = 解释器 basename,所以 guest 里写 /lib/ld-musl-… 或
        // /lib64/ld-linux-… 都一样能取到。
        std::vector<std::string> cands;
        cands.push_back(std::string(kBundledLibDir) + base);

        std::vector<char> mainb, ldsob;
        if (ReadWholeFile(path.c_str(), mainb)) {
            for (const auto& c : cands)
                if (ReadWholeFile(c.c_str(), ldsob)) break;
        }
        if (mainb.empty() || ldsob.empty()) {
            dprintf(STDERR_FILENO, "elfloader: cannot read %s or ldso %s\n",
                    path.c_str(), base.c_str());
            _exit(127);
        }
        rc = elf_run_dyn_inproc(mainb.data(), mainb.size(), ldsob.data(), ldsob.size(),
                                ab.argc(), ab.argv.data());
    } else {
        rc = elf_run_file(path.c_str(), ab.argc(), ab.argv.data());
    }
    fflush(nullptr);
    _exit(rc < 0 ? 127 : (rc & 0xFF));
}

pid_t SpawnElf(const SpawnRequest& req, const std::string& path) {
    pid_t pid = ForkChild(req);
    if (pid < 0) return -1;
    if (pid == 0) ChildRunElf(req, path);   // 不返回
    return pid;
}

// ================= kExecve =================

/* 直接 execve。
 *
 * 与 kElf/kSoMain 的区别是"真的把镜像换掉":进程映像、argv[0]、动态链接器全由内核
 * 按那个文件自己的 PT_INTERP 决定 —— 所以 hnp 应用自带的解释器/依赖能正常工作,
 * 我们也就不再是它的运行时。argv/env/fd/cwd 已由 ForkChild 按通用规则摆好,
 * 这里只剩一句 execv。
 *
 * 失败了怎么办:**不直接死,退回 elfloader**(同 ISA 的 aarch64 那条路,不需要 exec
 * 能力)。理由:探到的 exec 能力是"启动那一刻能不能 exec 系统 shell",而具体某个
 * 文件的能否 exec 还受挂载选项(noexec)、SELinux 标签影响 —— 这种差异不值得让
 * 用户的命令直接失败,慢一层跑起来更划算。失败原因打一行 stderr,别让它静默。 */
[[noreturn]] void ChildRunExec(const SpawnRequest& req, const std::string& path) {
    ArgvBlock ab;
    ab.Build(req.argv, req.cmd);

    /* hnp 应用自己的库就在它的目录附近,而真身往往没有 rpath(它们指望 HNP 的启动器
     * 把环境摆好)。execve 之后内核只按真身自己的 PT_INTERP 起解释器,解释器再按
     * LD_LIBRARY_PATH/默认路径找依赖 —— 我们不给就找不到。实测:
     *     .../python.org/python_3.12/bin/python3.12
     *   → "Error loading shared library libpython3.12.so.1.0: No such file or directory"
     * 而那个 .so 就在同一包的 ../lib/ 下。所以按"库和可执行文件放一块"的约定补上
     * <dir>、<dir>/../lib、<dir>/../lib64(kElf 那条路在 ChildRunElf 里做同一件事)。 */
    {
        size_t slash = path.rfind('/');
        if (slash != std::string::npos && slash > 0) {
            std::string dir = path.substr(0, slash);
            EnvAppendColon("LD_LIBRARY_PATH", dir);
            EnvAppendColon("LD_LIBRARY_PATH", dir + "/../lib");
            EnvAppendColon("LD_LIBRARY_PATH", dir + "/../lib64");
        }
    }

    execv(path.c_str(), ab.argv.data());
    dprintf(STDERR_FILENO, "[exec] %s: %s —— 退回 elfloader\n",
            path.c_str(), strerror(errno));
    ChildRunElf(req, path);   // 不返回
}

pid_t SpawnExec(const SpawnRequest& req, const std::string& path) {
    pid_t pid = ForkChild(req);
    if (pid < 0) return -1;
    if (pid == 0) ChildRunExec(req, path);   // 不返回
    return pid;
}

// ================= 等待 =================

void WaiterOnlyMain(int sid, pid_t pid) {
    int status = 0, code = -1;
    /* ⚠ EINTR 必须重试 —— 这是 2026-10-04 抓到的那个"编译器无声终止"的根因。
     *
     * procmgr 是主进程，信号很密（每起一个进程都有 SIGCHLD，还有 SIGSYS/SIGSEGV
     * 的取证 handler、前台任务切换……）。waitpid 被信号打断时返回 -1 且 errno=EINTR，
     * 而这里原来是 `if (waitpid(...) > 0)`，不重试 → code 直接留成 **-1**。
     * 上层的 bsh_wait_pid 拿到 -1 就当成"委托失败"（spawn_delegated 返回 -1），
     * 于是那条命令无声无息地失败：调用方只看到一个错误码，中间什么都不打印。
     * 实测证据（高并发编译 120 个文件时复现）：
     *     wait-exit pid=8713 code=-1 signaled=0 sig=0
     * 并发越高信号越密，所以只在并发构建里偶发。
     * WaitChildSync（WAIT 1 那条路）一直是有重试的，两条路要对齐。 */
    while (waitpid(pid, &status, 0) < 0)
        if (errno != EINTR) break;
    if      (WIFEXITED(status))   code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
    Manager::Instance().MarkExited(pid, code);
    /* 两段式委托（WAIT 0 那条路）走的就是这里 —— 以前这一路**不打日志**，
     * 于是"子进程被信号打死"与"自己退出个非零码"在日志里长得一模一样（都只有一个
     * code）。排查 numpy 构建里那个"编译器无声终止"时就卡在这一条上：失败的那条命令
     * 什么输出都没有，而 ninja 只报 FAILED。把 signaled/sig 打出来就能一眼分开。
     * 用 hilog：这个函数跑在 detach 出来的 worker 线程里。 */
    int sig = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
    OH_LOG_INFO(LOG_APP,
                "wait-exit pid=%{public}d code=%{public}d signaled=%{public}d sig=%{public}d",
                pid, code, sig ? 1 : 0, sig);
    NotifyForegroundDone(sid, pid);
}

// 最近一次等待的子进程"是怎么死的"（给 exit 日志用；WaitChildSync 与日志都在 procmgr
// 的主线程里串行调用，所以用普通全局量就够）
static int g_lastSignaled = 0;
static int g_lastTermSig = 0;

int WaitChildSync(pid_t pid) {
    int status = 0, code = -1;
    while (waitpid(pid, &status, 0) < 0)
        if (errno != EINTR) break;
    g_lastSignaled = WIFSIGNALED(status) ? 1 : 0;
    g_lastTermSig = g_lastSignaled ? WTERMSIG(status) : 0;
    if      (WIFEXITED(status))   code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
    Manager::Instance().MarkExited(pid, code);
    return code;
}

}  // namespace

// ================= 对外 API =================

SpawnResult Spawn(const SpawnRequest& req) {
    SpawnResult res;
    if (req.cmd.empty()) { res.error = "cmd is empty"; return res; }

    Resolved r;
    if (!Resolve(req, &r)) {
        res.error = r.error;
        res.exit_code = 127;
        return res;
    }
    res.kind = r.kind;

    /* #! 脚本那条路要换一套 argv(见 Resolved::argv_prepend):把调用方原来的
     * argv[0](命令名)丢掉,换成 [解释器名, (,解释器参数,) 脚本路径, 原参数…]。
     * 丢 argv[0] 是 POSIX 的语义:`sh script a b` 里脚本看到的是 $0=script、$1=a。 */
    SpawnRequest req2 = req;
    if (!r.argv_prepend.empty()) {
        std::vector<std::string> v = r.argv_prepend;
        for (size_t i = 1; i < req.argv.size(); i++) v.push_back(req.argv[i]);
        req2.argv = std::move(v);
    }

    pid_t pid = -1;

    /* ── spawn 取证（排查用，只在 BSH_SPAWN_TRACE 下打）──────────────────────
     * 起因：ninja 起 clang 崩、python 起同一个 clang 不崩，而两者在 procmgr 这侧的
     * spawn 日志逐字相同（都是 kind=elf cmd=…/clang）。既然"我这边做的"一样，
     * 差异只可能在**调用方递过来的东西**上 —— 而唯一没被看过的是这一刻还开着的 fd
     * （ninja 用 posix_spawn 的 file_actions 做了 pipe→stdout/stderr 的 dup2 与
     * /dev/null→stdin，而我们忽略 file_actions，那些 fd 会原样留在中间进程里，
     * 再被 collect_fds 收去交给 guest）。
     * 打的是 fork **之前**、procmgr 自己进程的 fd 表 —— 它就是子进程将要继承的那份。
     * ⚠ 开关从 **req.env** 里找，不用 getenv():ApplyEnv 是在 ForkChild 里(fork 之后)才
     * 生效的，这一刻 procmgr 的 environ 还是旧的，getenv 永远读不到。 */
    bool spawn_trace = getenv("BSH_SPAWN_TRACE") != nullptr;
    for (const auto& kv : req.env)
        if (kv == "BSH_SPAWN_TRACE=1") spawn_trace = true;
    if (spawn_trace) {
        std::string fds;
        int shown = 0;
        DIR* d = opendir("/proc/self/fd");
        if (d) {
            int dfd = dirfd(d);
            struct dirent* e;
            while ((e = readdir(d)) != NULL) {
                if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
                int v = atoi(e->d_name);
                if (v == dfd) continue;
                int fl = fcntl(v, F_GETFD);
                /* 只列**不带 CLOEXEC** 的 —— 那些才真的会被 guest 继承；
                 * 带 CLOEXEC 的在 exec 后会消失，列出来只是噪音（procmgr 自己
                 * 开着几十个 arkweb/hap 的 fd，全打出来日志没法看）。 */
                if (fl >= 0 && (fl & FD_CLOEXEC)) continue;
                if (++shown > 24) { fds += " …"; break; }
                char tgt[128] = {0};
                char lnk[64];
                snprintf(lnk, sizeof lnk, "/proc/self/fd/%d", v);
                ssize_t n = readlink(lnk, tgt, sizeof tgt - 1);
                if (n < 0) n = 0;
                tgt[n] = 0;
                fds += " " + std::to_string(v);
                if (n > 0) { fds += "->"; fds += tgt; }
            }
            closedir(d);
        }
        const char* lp = getenv("LD_PRELOAD");
        const char* llp = getenv("LD_LIBRARY_PATH");
        OH_LOG_INFO(LOG_APP,
            "spawn-detail cmd=%{public}s kind=%{public}s fd=[%{public}s] "
            "LD_PRELOAD=%{public}s LD_LIBRARY_PATH=%{public}s",
            req.cmd.c_str(), KindCStr(r.kind), fds.c_str(),
            lp ? lp : "(nil)", llp ? llp : "(nil)");
    }

    switch (r.kind) {
        case LaunchKind::kSoMain:
            pid = SpawnSoMain(req2, r.so, r.entry, r.guest, r.guest_name, r.entry_argc);
            break;
        case LaunchKind::kElf:    pid = SpawnElf(req2, r.path); break;
        case LaunchKind::kExecve: pid = SpawnExec(req2, r.path); break;
        case LaunchKind::kQemu:
            // 这个 kind 已无人使用:无 jit 时的分流直接落成 kSoMain(qemu 的 .so),
            // 见 Resolve 第 4 步。留着只是为了不改对外枚举的值。
            res.error = "qemu-user reserved, not implemented";
            res.exit_code = 127;
            return res;
    }
    if (pid <= 0) { res.error = "fork failed"; return res; }

    // fork 完成后立刻通知前台 pid:此刻子进程还没跑起来,但宿主已经能把
    // Ctrl+C 送给它 —— 消除"信号到了、前台 pid 还没登记"的窗口。
    NotifyForeground(req.sid, pid);

    ProcessInfo info;
    info.pid = pid;
    info.parent_pid = req.caller_pid > 0 ? req.caller_pid : getpid();
    info.kind = res.kind;
    info.cmd = req.cmd;
    info.start_time_ms = NowMillis();
    info.alive = true;
    Manager::Instance().Register(info);

    OH_LOG_INFO(LOG_APP, "spawn pid=%{public}d kind=%{public}s cmd=%{public}s",
                pid, KindCStr(res.kind), req.cmd.c_str());

    res.pid = pid;
    if (req.sync_wait) {
        res.exit_code = WaitChildSync(pid);
        NotifyForegroundDone(req.sid, pid);
        // 退出码也记一条:"spawn 了但立刻退出"是最常见的故障形态(命令 so 里
        // 的 main 早退、guest 崩、参数不对),没有这条只能靠猜。
        // 再带上"怎么死的":code=139 既可能是被 SIGSEGV 打死,也可能是自己 _exit(139),
        // 两者处理方向完全不同 —— signaled/sig 两个字段一眼分开。
        OH_LOG_INFO(LOG_APP, "exit pid=%{public}d code=%{public}d signaled=%{public}d sig=%{public}d cmd=%{public}s",
                    pid, res.exit_code, g_lastSignaled ? 1 : 0, g_lastTermSig,
                    req.cmd.c_str());
    } else {
        std::thread(WaiterOnlyMain, req.sid, pid).detach();
    }
    return res;
}

void Terminate(pid_t pid) {
    if (pid <= 0) return;
    kill(pid, SIGTERM);
    std::thread([pid]() {
        usleep(800 * 1000);
        if (kill(pid, 0) == 0) kill(pid, SIGKILL);
    }).detach();
}

std::vector<ProcessInfo> ListProcesses() { return Manager::Instance().Snapshot(); }

void SetForegroundHook(std::function<void(int sid, pid_t pid)> hook) {
    std::lock_guard<std::mutex> lk(g_fg_mu);
    g_fg_hook = std::move(hook);
}

// 定义在公开区域（不是文件顶部那个匿名 namespace）：调用它的是 ctrl_socket.cpp
// 的另一条编译单元，内部链接会变成 undefined symbol（实测踩过）。
bool SignalForeground(int sid, int sig) {
    if (sig <= 0 || sid < 0 || sid >= BSH_SID_MAX) return false;
    pid_t pid;
    {
        std::lock_guard<std::mutex> lk(g_fg_mu);
        pid = g_fg_pid[sid];
    }
    if (pid <= 0) return false;
    return kill(pid, sig) == 0;
}

pid_t ForegroundPid(int sid) {
    if (sid < 0 || sid >= BSH_SID_MAX) return -1;
    std::lock_guard<std::mutex> lk(g_fg_mu);
    return g_fg_pid[sid];
}

/* 子进程结束 → 清**那个会话**的前台 pid，但**只清自己那一个**。
 *
 * 为什么不能无条件清成 -1（原来就是这么写的）：并发 spawn 下"最后报到的才算前台"，
 * 而任何一个**早就退出的旧子进程**的收尾钩子都会把当前前台擦掉。实测坏法：假 pty 里
 * `sleep 60` 起好之后，另一个更早的子进程恰好在这时退出 → 前台被擦成 -1 → 用户按
 * Ctrl+C 时 procmgr 找不到目标（日志 `fg-signal sig=2 pid=0（没有前台进程）`），
 * 现象就是"Ctrl+C 没反应"。宿主会话那条路也用这个 hook，两边一起受益。 */
void NotifyForegroundDone(int sid, pid_t pid) {
    if (sid < 0 || sid >= BSH_SID_MAX) return;
    std::function<void(int, pid_t)> hook;
    {
        std::lock_guard<std::mutex> lk(g_fg_mu);
        if (g_fg_pid[sid] != pid) return;    // 前台已经换人了，别擦
        g_fg_pid[sid] = -1;
        hook = g_fg_hook;
    }
    if (hook) hook(sid, -1);
}

// socket 服务端需要访问的内部函数
namespace detail {
const char* KindName(LaunchKind k) { return KindCStr(k); }
bool LookupInManager(pid_t pid, ProcessInfo* out) {
    auto v = Manager::Instance().Lookup(pid);
    if (v && out) *out = *v;
    return v.has_value();
}
}  // namespace detail

}  // namespace procmgr
}  // namespace bsh
