// shell/shell.cpp — 基础 shell 实现
#include "shell.h"
#include "../tty/bsh_tty.h"
#include "bshutil/bsh_cfg.h"
#include "bshutil/bsh_util_proto.h"
#include "bshutil/bsh_util_server.h"
#include "bshutil/bshutil.h"
#include "common/bsh_paths.h"
#include "common/bsh_rawfile.h"
#include "common/bsh_thread.h"
#include "complete.h"
#include "lexer.h"
#include "lineedit.h"
#include "rcfile.h"
#include "procmgr/bsh_client.h"
#include "procmgr/command_map.h"
#include "procmgr/procmgr.h"
#include "wayland_server.h"

#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <pwd.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "rawfile/raw_file_manager.h"
#include "rawfile/raw_file.h"

#undef LOG_TAG
#define LOG_TAG "BSH_Session"
#include <hilog/log.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace bsh {

/* 主窗口的 bsh 会话号:固定 0(会话号的分配与上限见 tty/bsh_tty.h 的 BSH_SID_MAX)。
 * 从 `bshutil newtab` 开出来的 tab 是**别的**会话(>0),它们的输入/尺寸不走这里 ——
 * 那些是独立进程里的 mksh,由各自的会话对象处理。 */
constexpr int kBshSid = 0;

BasicShell* g_shell = nullptr;
bool g_started = false;
napi_threadsafe_function g_tsfn = nullptr;

// 当前前台子进程(顶层 shell fork 出来的命令);-1 表示无。
// 输入路径据此把 ISIG 字符转成信号(见 BshTermInputNAPI)。
std::atomic<int> g_fgChild{-1};

/* ─────────────────────────── 终端会话表 ───────────────────────────
 * sid 0 = 主窗口的 bsh(唯一一个,跑在**宿主进程**里,pty 挂在 g_shell 上);
 * sid >0 = `bshutil newtab` 开出来的 tab —— 那是一个**独立的 mksh 进程**,跑在它
 *          自己的软 pty(还是 socketpair)上。
 *
 * 为什么新 tab 不复用 bsh:每个会话要有各自的行编辑器历史 / cwd / 前台进程,那是三份
 * 状态;而 mksh 本来就是个完整 shell,起一个进程比把 bsh 改造成多实例省得多。宿主这一
 * 侧只需要照看它的 pty:读输出送窗口、写输入给它、把尺寸与 Ctrl+C 转过去。
 *
 * 每个会话自己的 termios/winsize/前台组在 tty/bsh_tty.cpp(按 sid 分);宿主只在这里
 * 记"这个 sid 的 pty 是哪一对、子进程是谁"。 */
struct TermSession {
    bool   used = false;      // AllocSession 占的号(即使还没 start)
    bool   started = false;   // StartSession 成功了
    int    master = -1;       // 宿主侧的读端(写完 slave 那份就只剩这一端)
    pid_t  pid = -1;          // mksh 的 pid
    napi_threadsafe_function tsfn = nullptr;   // 这一会话的输出回调
};
TermSession g_sess[BSH_SID_MAX];
std::mutex  g_sess_mu;
int         g_nextSid = 1;    // 0 留给 bsh;在这里单调递增(不重用刚结束的号)

/* 取某个会话的输出回调(调用方负责别拿着它做长事)。 */
napi_threadsafe_function SessionTsfn(int sid) {
    if (sid == kBshSid) return g_tsfn;
    std::lock_guard<std::mutex> lk(g_sess_mu);
    if (sid <= 0 || sid >= BSH_SID_MAX) return nullptr;
    return g_sess[sid].tsfn;
}

/* 会话结束(子进程退出 → master 读到 EOF):告诉窗口一声,再把这个槽释放掉。 */
void OnSessionEnded(int sid) {
    napi_threadsafe_function fn = SessionTsfn(sid);
    if (fn) {
        auto* s = new std::string("\r\n\x1b[2m[会话已结束]\x1b[0m\r\n");
        napi_call_threadsafe_function(fn, s, napi_tsfn_blocking);
    }
    std::lock_guard<std::mutex> lk(g_sess_mu);
    if (sid <= 0 || sid >= BSH_SID_MAX) return;
    if (g_sess[sid].master >= 0) { ::close(g_sess[sid].master); g_sess[sid].master = -1; }
    g_sess[sid].pid = -1;
    g_sess[sid].started = false;
    g_sess[sid].used = false;
}

/* 会话输出回调被 ArkTS 释放(页面销毁但我们没收到 stop)时把引用清掉,
 * 免得后面的输出打进已释放的 tsfn。 */
void SessionTsfnFinalize(napi_env, void* data, void*) {
    const int sid = (int)(intptr_t)data;
    if (sid <= 0 || sid >= BSH_SID_MAX) return;
    std::lock_guard<std::mutex> lk(g_sess_mu);
    g_sess[sid].tsfn = nullptr;
}

BasicShell::BasicShell() = default;
BasicShell::~BasicShell() { Stop(); }

bool BasicShell::Start() {
    if (!PseudoTtyCreate(&pty_)) return false;
    if (pipe(stopPipe_) != 0) { PseudoTtyClose(&pty_); return false; }
    running_ = true;
    pthread_t th;
    if (pthread_create(&th, nullptr, &BasicShell::RunTramp, this) != 0) {
        running_ = false;
        PseudoTtyClose(&pty_);
        return false;
    }
    pthread_detach(th);
    return true;
}

void BasicShell::Stop() {
    running_ = false;
    if (stopPipe_[1] >= 0) {
        char c = 'x';
        ssize_t n = write(stopPipe_[1], &c, 1);
        (void)n;
    }
    // 等 shell 线程自然退出后关 pty(由 Run 收尾),这里只唤醒
}

/* ---------- slave 侧输出 ---------- */
static void SlaveWrite(int fd, const std::string& s) {
    if (fd < 0 || s.empty()) return;
    size_t off = 0;
    while (off < s.size()) {
        ssize_t w = write(fd, s.data() + off, s.size() - off);
        if (w <= 0) { if (w < 0 && errno == EINTR) continue; break; }
        off += (size_t)w;
    }
}

/* ---------- 分词与变量展开:见 shell/lexer.cpp(宿主可单测) ---------- */

static bool LooksLikeNumber(const std::string& s) {
    if (s.empty()) return false;
    for (char c : s) if (c < '0' || c > '9') return false;
    return true;
}

static int RunBuiltin(const std::vector<std::string>& av, int fd, bool* doExit);

/** 无人值守自检(临时件):rawfile 里若有 tools/autorun.sh,每会话启动都覆盖写到
 *  $HOME/autorun.sh 并在后台跑一遍,输出落 $HOME/autorun.log。定义在下面 CopyRawFile 之后。 */
static void MaybeRunAutorun(int fd);

/* ---------- 外部命令:统一交给 procmgr(经 control socket)创建 ---------- */
// 宿主不再自己 fork/dlopen/装载:把 argv 与 stdio 交给 procmgr,由它按命令表
// 决定 dlopen 哪个 so,或按路径/ELF 探测交 elfloader 装载。前台 pid 由 procmgr
// 的 hook 回填(见 Run() 里注册的那个 lambda),所以这里不碰 g_fgChild。
static int RunSpawn(const std::vector<std::string>& av, int fd) {
    std::vector<std::string> store = av;
    std::vector<char*> argv(store.size() + 1, nullptr);
    for (size_t i = 0; i < store.size(); i++) argv[i] = &store[i][0];

    // stdio 都接到会话 pty slave;同一个 fd 传三次,procmgr 会先 dup 归一化
    int fds[3] = { fd, fd, fd };
    int rc = bsh_spawnv_sync(store[0].c_str(), argv.data(), fds);
    if (rc < 0) {
        const char* err = bsh_client_last_error();
        SlaveWrite(fd, std::string(err && *err ? err : "spawn failed") + "\n");
        return 127;
    }
    return rc;
}

/* ---------- 统一命令入口 ----------------------------------- */
static int RunCommand(const std::vector<std::string>& av, int fd, bool* doExit) {
    // 1. Builtin(在宿主进程内直接改会话状态)
    int rc = RunBuiltin(av, fd, doExit);
    if (rc != 127) return rc;

    // 2. 其余一律经 procmgr:命令表 so / 裸 ELF 由它判定
    return RunSpawn(av, fd);
}

/* 执行**一行**（分词时做 $VAR / $? 展开；未定义变量展开成空串），返回这条的退出码。
 * 交互式主循环和 .bshrc 都走这里 —— 两条路必须是同一套语义，否则"rc 里能用的写法"
 * 和"手敲能用的写法"就会漂。
 * *doExit 只在用户显式敲 exit 时置位；.bshrc 那边会忽略它（见 RunRcFile）。 */
static int ExecuteLine(int fd, const std::string& line, int last_rc, bool* doExit) {
    std::vector<std::string> av = SplitLine(
        line, last_rc, [](const std::string& name) -> std::string {
            const char* v = getenv(name.c_str());
            return v ? std::string(v) : std::string();
        });
    if (av.empty()) return last_rc;
    int rc = RunCommand(av, fd, doExit);
    // 非 0 退出码给一条提示(bshutil set exit-hint off 可关)。
    // 只在失败时打:成功也打的话,交互式会话每敲一条命令都多一行噪音。
    if (rc != 0 && !*doExit && bsh_cfg_exit_hint())
        SlaveWrite(fd, "\x1b[2m[exit " + std::to_string(rc) + "]\x1b[0m\n");
    return rc;
}

/* ---------- $HOME/.bshrc ----------------------------------- */

/* 生成/更新 $HOME/.bshrc 的**托管块**（定界与替换规则见 shell/rcfile.h）。 */
static void WriteBshrc() {
    const std::string path = std::string(bsh_home_dir()) + "/.bshrc";
    
    std::vector<std::string> block = {
        "# =============================================================",
        "# Core environment variables, Do not edit this if not needed!",
        "export BSH_SYSROOT="   + std::string(bsh_sysroot()),
        "export HOME="          + std::string(bsh_home_dir()),
        "export BSH_HOME_DIR="  + std::string(bsh_home_dir()),
        "export BSH_CTRL_SOCK=" + std::string(bsh_ctrl_sock_path()),
        "# =============================================================",
        "",
        "export PATH=\"$HOME:$BSH_SYSROOT/bin:$BSH_SYSROOT/usr/bin:$PATH\"",
        "",
        "export TERM=xterm-256color",     // 全屏程序(vim)用;匹配 ncurses fallback terminfo
        "export SHELL=sh",
        "",
        "export VIMRUNTIME=$BSH_SYSROOT/vim-runtime",
        "export PYTHONHOME=$BSH_SYSROOT/python",
        // pip 三件套：
        //  · 别每次跑都联网查有没有新版本（设备上多一次往返不值）；缓存目录不再另设
        //    —— 默认就是 $HOME/.cache/pip，落在可写的 HOME 下。
        //  · find-links 指向资源根下的 pkgs/：预编译好的 wheel（如 numpy）放那儿，
        //    于是 `pip install numpy` 不必联网、也不需要设备上有编译器。
        //  · --only-binary：设备上没有编译器，sdist 现场构建永远是死路；宁可让 pip
        //    直接说"没有匹配的发行版"，也别让它下完源码再报一堆构建错误。
        //    ⚠ 不要设 PIP_PLATFORM —— pip 26 直接拒绝："Can not use any platform or
        //      abi specific options unless installing via '--target'"。轮子那边用
        //      py3-none-any 的 tag 就够了（见 build_numpy.sh 里那段说明）。
        "export PIP_DISABLE_PIP_VERSION_CHECK=1",
        "export PIP_FIND_LINKS=$BSH_SYSROOT/pkgs",
        "export PIP_ONLY_BINARY=:all:",
        "",
        // ── 在设备上自己编 C 扩展（pip 装 sdist 时走这条路）──────────────
        // 编译器来自 pkg 装的 ohos-sdk-prune；Python 头文件来自 pkg 的
        // python-headers 包（同样不随 HAP，`pkg install python-headers`）。
        // **必须在这里覆盖 CC/LDSHARED** —— sysconfig 里那
        // 两个值是构建期写死的**宿主**路径（.../build/python/cc-wrap.sh），设备上
        // 根本不存在。SDK 没装时这些路径无效，编译会以"文件不存在"失败，一眼能看出。
        // 值**不能带空格**：.bshrc 由基础 shell 执行，而它对 `export X="a b"` 只取
        // 第一个词（实测 CC 变成光秃秃的 clang 路径，--target/--sysroot 全丢）——
        // 所以参数都写进 $SYSROOT/bin/{cc-ohos,ldshared-ohos} 两个包装脚本里
        // （shell.cpp 的 WriteCcWrapper 生成），这里只留不含空格的路径。
        "export CC=$BSH_SYSROOT/bin/cc-ohos",
        "export CXX=$BSH_SYSROOT/bin/cxx-ohos",
        "export LDSHARED=$BSH_SYSROOT/bin/ldshared-ohos",
        // SDK 的 llvm/bin 也进 PATH：meson 会去找 `ar`/`ranlib`（它按
        // ['llvm-ar-15','llvm-ar','ar','gar'] 逐个试），那儿有 llvm-ar／llvm-ranlib。
        // 这一条与上面三条包装脚本不冲突：包装脚本只是给 clang 补 --target/--sysroot。
        // ⚠ $BSH_SYSROOT/bin 排在它**前面**：那里有我们生成的 clang/clang++ 包装
        // （带 --target/--sysroot），而 SDK 那个 clang 裸跑是不行的（见 WriteCcWrapper）。
        "export PATH=\"$BSH_SYSROOT/bin:$BSH_SYSROOT/opt/ohos-sdk/openharmony/native/llvm/bin:$PATH\"",
        // pip 装的脚本（cython/meson/ninja 的入口）落在 PYTHONHOME 的 bin 下，
        // 而 meson/numpy 会按 PATH 去找 `cython` —— 不挂上就是
        // "Running `cython -V` gave No such file or directory"。
        "export PATH=\"$BSH_SYSROOT/python/bin:$PATH\"",
        // SDK 自带的构建工具（ninja/cmake）**不进 PATH**：它们是给 aarch64 Linux(glibc)
        // 宿主编的，跑起来要 libstdc++.so.6，我们这儿没有 —— 实测 ninja 直接报
        // "cannot open shared object file"。ninja 改由 scripts/build_devtools.sh 自己
        // 编（musl），落在 $SYSROOT/usr/bin，PATH 里本来就有那一条。
        // LD_LIBRARY_PATH 保留：资源根里摆着 glibc 的 libc.so.6 与 ld-linux-aarch64.so.1，
        // 那是给 qemu / glibc guest 用的。
        "export LD_LIBRARY_PATH=$BSH_SYSROOT/lib:$BSH_SYSROOT/lib64",
        // 实验开关：**伪装平台 tag**，让 pip 去 PyPI 挑 aarch64 的 manylinux 轮子。
        // 默认空 = 用真实身份（harmonyos_<内核版本>_aarch64，PyPI 上没有）。
        // 想试就改成 manylinux_2_28_aarch64（或 linux-aarch64）再重开会话。
        // ⚠ 这样装下来的扩展是给 glibc 编的，能不能跑取决于进程内装载器的符号解析
        //   （见 cpp/shim/README.md §9）—— 简单扩展常常行，碰 glibc 专属 API 的不行。
        "export BSH_PIP_FAKE_PLATFORM=",
        "",
        // ── node 原生扩展（npm 装带 .node 的包，走 node-gyp）──────────────
        // node-gyp 会把环境里的 `npm_config_*` **当命令行选项**（lib/node-gyp.js 那段
        // "继承 npm 配置"），所以这一条等于 `node-gyp --nodedir=<...>`：用它就不必让
        // node-gyp 联网下 8.7MB 的 headers、也不会写 $HOME/.cache/node-gyp。
        // headers 是 pkg 的包（`pkg install node-headers`，顶层 node-headers/）。
        // 没装那个包时 node-gyp 会退回自己下载那条路（设备有网就能用）。
        "export npm_config_nodedir=$BSH_SYSROOT/node-headers",
        // make 的 SHELL。**GNU make 从不从环境取 SHELL**（手册明说："Unlike most
        // variables, the variable SHELL is never set from the environment"），默认就是
        // `/bin/sh` —— 而沙箱里的 /bin 是系统的、我们不可访问，于是任何 make 都死在
        // "起 recipe 的 shell" 这一步：
        //     make: /bin/sh: Permission denied
        //     make: *** [bufferutil.target.mk:111: ...o] Error 127
        // （实测：`make SHELL=$SYSROOT/bin/sh` 一给，gyp 生成的 Makefile 整条就通了 ——
        //   CC(target) → SOLINK_MODULE → COPY Release/xxx.node。）
        // MAKEFLAGS 里的变量赋值等价于**命令行定义**，会传给子 make，且优先级高于
        // makefile 里的 `SHELL :=`（gyp 的 Makefile 本来也不设它）。
        "export MAKEFLAGS=SHELL=$BSH_SYSROOT/bin/sh",
        /* ⚠ 这里给的是**父目录**：libxkbcommon 会在这个值后面**再拼一次 "xkb"**。
         * 原来写的是 $BSH_SYSROOT/usr/share/x11/xkb，于是它去找 .../x11/xkb/xkb（不存在）
         * → "There are no include paths to search" → xkb_keymap 编译失败 → Chromium 在
         * ozone-wayland 初始化之后静默 SIGSEGV(139)。基线那组的日志最后两行正是：
         *     xkbcommon: ERROR: [XKB-338] There are no include paths to search
         *     xkbcommon: ERROR: Failed to compile keymap
         * 注意：libxkbcommon **不认** XKB_CONFIG_ROOT 这条的说法是当年基于错值得到的结论，
         * 实际它认（probe5 打出的就是它的值）。它另有 XKB_CONFIG_EXTRA_PATH，code.sh 里
         * 两个都设，互为兜底。 */
        "export XKB_CONFIG_ROOT=$BSH_SYSROOT/usr/share/x11",
        "export WESTON_DATA_DIR=$BSH_SYSROOT/usr/share/weston",
        "export FONTCONFIG_FILE=$BSH_SYSROOT/fonts.conf",
        "export FONTCONFIG_PATH=$BSH_SYSROOT",
        // qemu-user 的 guest rootfs 基准：摆 lib/ 的那段准备工作在 shell.cpp 里
        // （那是动作，不是配置），值放这儿是为了可见、可改。
        "export QEMU_LD_PREFIX=$BSH_SYSROOT",
        "",
        "export WAYLAND_DISPLAY=wl-sock",
        "export XDG_RUNTIME_DIR=$BSH_SYSROOT",
        "export QT_QPA_PLATFORM=wayland",
        "export QT_PLUGIN_PATH=\"$BSH_SYSROOT/qtapp:$BSH_SYSROOT/qtapp/plugins-probe:"
            + std::string(BSH_BUNDLE_LIBS) + "\"",
        "",
        "export BSH_PKG_CACHE=" + std::string(BSH_PKG_CACHE_DIR),
        "",
        // apt 的镜像源。换国内源就改这一行，例如：
        //   export BSH_APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports
        //   export BSH_APT_MIRROR=https://mirrors.aliyun.com/ubuntu-ports
        // **必须 https**（内置客户端只做 TLS）；`apt source <url>` 也能改，那条路写进
        // $SYSROOT/pkgs/apt-source，优先级比这个环境变量高。
        "export BSH_APT_MIRROR=" + std::string(BSH_APT_MIRROR_DEFAULT),
    };

    std::string existing;
    if (FILE* f = fopen(path.c_str(), "rb")) {
        char buf[8192];
        size_t n;
        while ((n = fread(buf, 1, sizeof buf, f)) > 0) existing.append(buf, n);
        fclose(f);
    }
    const std::string next = ApplyManagedBlock(existing, block);
    if (next == existing) return;        // 没变就不写：别让 mtime 每次会话都跳
    FILE* f = fopen(path.c_str(), "w");
    if (!f) return;
    fwrite(next.data(), 1, next.size(), f);
    fclose(f);
    chmod(path.c_str(), 0644);
}

/* 执行 $HOME/.bshrc。 */
static void RunRcFile(int fd) {
    WriteBshrc();
    const std::string path = std::string(bsh_home_dir()) + "/.bshrc";
    const std::vector<std::string> lines = LoadRcLines(path);

    int rc = 0;
    int bad = 0;
    for (const std::string& line : lines) {
        bool doExit = false;
        rc = ExecuteLine(fd, line, rc, &doExit);
        if (doExit) {
            /* rc 里的 exit **不执行**：一条 `exit` 就能把会话顶掉，而那时终端根本没起来，
               用户没有机会进终端把文件改回来，只能重装。忽略掉并说一句最省事。 */
            SlaveWrite(fd, "\x1b[2m[bshrc] exit 在 .bshrc 里被忽略(不会结束会话)\x1b[0m\n");
        }
        if (rc != 0) bad++;
    }

    if (bad > 0)
        SlaveWrite(fd, "\x1b[2m[bshrc] 有 " + std::to_string(bad) +
                        " 行退出码非 0(文件 $HOME/.bshrc)\x1b[0m\n");
}

/* ---------- 基础 builtin ---------- */
static int BuiltinEcho(const std::vector<std::string>& av, int fd) {
    bool nl = true;
    size_t i = 1;
    if (av.size() > 1 && av[1] == "-n") { nl = false; i = 2; }
    std::string s;
    bool first = true;
    for (; i < av.size(); i++) {
        if (!first) s += ' ';
        first = false;
        s += av[i];
    }
    if (nl) s += '\n';
    SlaveWrite(fd, s);
    return 0;
}

static int BuiltinHelp(int fd) {
    SlaveWrite(fd,
        "BetterSH builtin shell (c3)\n"
        "builtins: echo cd pwd export unset clear exit help\n"
        "  echo [-n] <text>   print text (no trailing newline with -n)\n"
        "  cd [dir]           change directory (default: HOME)\n"
        "  pwd                print working directory\n"
        "  export K=V ...     set environment variables\n"
        "  unset K ...        unset environment variables\n"
        "  clear              clear screen\n"
        "  exit               leave the shell\n"
        "quotes '...' \"...\", backslash escapes and $VAR / ${VAR} / $? are honored\n"
        "keys: Up/Down history, Left/Right move, TAB complete, Ctrl+C cancel\n");
    SlaveWrite(fd, std::string(bshutil_summary()) +
                    "(命令 so,在 mksh 里也能用;bshutil help 看子命令)\n");
    return 0;
}

static int RunBuiltin(const std::vector<std::string>& av, int fd,
                      bool* doExit) {
    const std::string& c = av[0];
    if (c == "echo")      return BuiltinEcho(av, fd);
    if (c == "help")      return BuiltinHelp(fd);
    if (c == "clear") {
        SlaveWrite(fd, "\x1b[H\x1b[2J\x1b[3J");
        return 0;
    }
    if (c == "pwd") {
        char buf[4096];
        if (getcwd(buf, sizeof buf)) { SlaveWrite(fd, std::string(buf) + "\n"); }
        return 0;
    }
    if (c == "cd") {
        const char* dir = av.size() > 1 ? av[1].c_str()
                        : getenv("HOME");
        if (!dir) dir = "/";
        if (chdir(dir) != 0) {
            SlaveWrite(fd, "cd: " + av[1] + ": no such directory\n");
            return 1;
        }
        char cw[4096];
        if (getcwd(cw, sizeof cw)) setenv("PWD", cw, 1);
        return 0;
    }
    if (c == "export") {
        for (size_t i = 1; i < av.size(); i++) {
            const std::string& kv = av[i];
            auto eq = kv.find('=');
            if (eq == std::string::npos) continue;
            setenv(kv.substr(0, eq).c_str(), kv.substr(eq + 1).c_str(), 1);
        }
        return 0;
    }
    if (c == "unset") {
        for (size_t i = 1; i < av.size(); i++) unsetenv(av[i].c_str());
        return 0;
    }
    if (c == "exit") {
        *doExit = true;
        return 0;
    }
    if (c == "true")  return 0;
    if (c == "false") return 1;
    if (LooksLikeNumber(c)) { SlaveWrite(fd, "\n"); return 0; }
    return 127;
}

/* ---------- TAB 补全:列目录(宿主文件系统) ---------- */
// 补全逻辑在 shell/complete.cpp(纯逻辑,宿主可单测);这里只提供"列目录"这一件事。
// 目录条目带尾随 '/' —— 补全据此决定补完要不要加空格(见 complete.h)。
static std::vector<std::string> ListDirEntries(const std::string& dir) {
    std::vector<std::string> out;
    DIR* d = opendir(dir.c_str());
    if (!d) return out;
    struct dirent* e;
    while ((e = readdir(d)) != nullptr) {
        std::string n = e->d_name;
        if (n == "." || n == "..") continue;
        std::string full = dir;
        if (!full.empty() && full.back() != '/') full += '/';
        full += n;
        struct stat st;
        if (stat(full.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) n += '/';
        out.push_back(n);
        if (out.size() >= 200) break;   // 上限:大目录不值得为补全卡一下
    }
    closedir(d);
    return out;
}

/* ---------- shell 主循环(slave 侧) ---------- */
// 命令名占位文件由 procmgr 生成(cmd_make_placeholders):mksh 等子 shell 按 PATH
// 找到文件后才会 exec*,委托层再把名字交给 procmgr 决定怎么起进程。

void* BasicShell::RunTramp(void* arg) {
    static_cast<BasicShell*>(arg)->Run();
    return nullptr;
}

void BasicShell::Run() {
    int fd = pty_.slave;
    bool first = true;
    // 会话初始环境。两个基准都在 common/bsh_paths.h 里(都是**运行期**取的,见那里的说明):
    //   bsh_sysroot()  = files/    资源根:解包出来的 vim-runtime/python/usr/share/… 与三个
    //                             socket、bsh-ws.bin 都在这儿(像一套 sysroot)
    //   bsh_home_dir() = files/home  会话家目录:$HOME,只放用户的东西
    const char* kSysroot = bsh_sysroot();
    const char* kHome = bsh_home_dir();
    const char* kWaylandSock = bsh_wayland_sock_path();
    // 新装/改布局后的第一次会话,home 还不存在 —— 它原来是 initResource 里顺手 mkdir
    // 出来的,而 chdir 在 initResource 之前,所以必须先自己建好(否则 chdir 静默失败,
    // cwd 会停在旧目录,而 HOME/PWD 指向一个不存在的路径)。
    mkdir(kHome, 0755);
    chdir(kHome);
    setenv("HOME", kHome, 1);
    setenv("PWD", kHome, 1);
    // 资源根也要 0755:它是应用私有目录,默认 0770(组可写)会让 hdc 的 shell 用户
    // 连读都读不了(宿主机脚本 wait_autorun.sh 就是这么读日志的)。
    chmod(kSysroot, 0755);
    // SSH 的家当:~/.ssh 要存在且 0700。dropbear 的 checkpubkeyperms() 会逐级校验
    // 权限,group/other 可写就直接拒绝;known_hosts、私钥、authorized_keys 都在这里。
    // 已存在时 mkdir 返回 EEXIST,忽略即可。
    mkdir((std::string(kHome) + "/.ssh").c_str(), 0700);
    // dropbear 的 checkfileperm() 会从 authorized_keys 一路校验到 pw_dir(:group 可写
    // 就判定不安全、公钥登录直接失败)。pw_dir 就是 $HOME,所以它自己必须去掉组写位。
    chmod(kHome, 0755);
    // 应用设置(bshutil set 写的那些):会话开始时读一次,之后由 getter 提供
    bsh_cfg_load((std::string(kHome) + "/bettersh.conf").c_str());
    /* 把配置里要给命令 so 看的项导出成环境变量(目前是 BSH_NODE_JITLESS)。
     * 必须在这里做:子进程是 fork 出来的,继承的是**宿主当时的 environ**。 */
    bsh_cfg_export_env();
    /* 资源根也导出给命令 so:node 的 npm-cli.js、jdk 的 java.home 这些"编在 so 里
     * 从 $HOME 推路径"的地方改成读它,以后挪布局就不必再重编那些 so。
     * 走 setter 而不是裸 setenv:它同时刷新本单元的全局变量(见 bsh_paths.h)。 */
    bsh_set_sysroot(kSysroot);

    // qemu-user(无 jit 设备上跑 guest 的那条路,见 procmgr 的 Resolve 第 4 步)。
    // 动态 guest 的解释器由 qemu 按 QEMU_LD_PREFIX 找:它会在 <prefix>/lib/ 下按
    // guest 的 PT_INTERP 取文件(aarch64 musl → lib/ld-musl-aarch64.so.1;aarch64 glibc →
    // lib/ld-linux-aarch64.so.1 与 lib/libc.so.6;x86_64 musl → lib/ld-musl-x86_64.so.1)。
    // 运行时真身在 bundle libs 里是
    // **平铺**的,所以这里摆一个只有 lib/ 一层的"假根"把它们放进去。
    // 用拷贝而不是软链:这个沙箱里 symlink() 一律 EPERM(命令 so 与 guest 侧都得
    // 模拟软链,见 fs_shim),硬链又可能跨挂载失败 —— 一共不到 3MB,拷一次了事。
    {
        // ⚠ 这个目录不要挪到 $sysroot/qemu-root 之类的地方:qemu 的 OHOS 补丁
        // (qemu-ohos-patches/0009)把 **QEMU_LD_PREFIX 同时当作"guest rootfs 基准"** ——
        // 基准之外的路径,它给 guest 看到的是 `/mnt/host-root/…`,而 cmake 这类
        // "靠 /proc/self/exe 反推安装目录"的程序会因此算出不存在的 root(实测
        // "Could not find CMAKE_ROOT")。把基准放在 $sysroot(工具链就在它下面),
        // 还原出来的就是干净的 guest 路径。
        const char* kBundleLibs = "/data/storage/el1/bundle/libs/arm64/";
        std::string qroot = kSysroot;
        mkdir(qroot.c_str(), 0755);
        /* 目标相对路径 → bundle libs 里的源文件名。为什么不直接同名:同一份
         * libc.so.6 在包里同时有 aarch64(glibc-ohos)与 x86_64(宿主 glibc)两个 ABI,
         * 只能有一个叫 libc.so.6,所以 x86_64 那份进包时改名 libc-x86_64.so.6。 */
        struct QemuLib { const char* dst; const char* src; };
        const QemuLib kQemuLibs[] = {
            {"lib/ld-musl-aarch64.so.1",       "ld-musl-aarch64.so.1"},
            {"lib/libc.so",                    "ld-musl-aarch64.so.1"},  // musl:libc.so 就是 ldso
            {"lib/ld-linux-aarch64.so.1",      "ld-linux-aarch64.so.1"},
            {"lib/libc.so.6",                  "libc.so.6"},
            {"lib/ld-musl-x86_64.so.1",        "ld-musl-x86_64.so.1"},
            /* x86_64 glibc(宿主那份):interp 按 /lib64/ld-linux-x86-64.so.2 找,而它的
             * 库搜索路径是 Ubuntu 的 multiarch(/lib/x86_64-linux-gnu)—— 两个位置都摆上。 */
            {"lib64/ld-linux-x86-64.so.2",     "ld-linux-x86-64.so.2"},
            {"lib64/libc.so.6",                "libc-x86_64.so.6"},
            {"lib/x86_64-linux-gnu/libc.so.6", "libc-x86_64.so.6"},
        };
        for (const QemuLib& l : kQemuLibs) {
            std::string dst = qroot + "/" + l.dst;
            std::string dir = dst.substr(0, dst.rfind('/'));
            mkdir(dir.c_str(), 0755);            // 指到哪儿建到哪儿(只要一层)
            if (access(dst.c_str(), R_OK) == 0) continue;   // 已经有了
            std::string src = std::string(kBundleLibs) + l.src;
            FILE* in = fopen(src.c_str(), "rb");
            if (!in) continue;                   // 包里有哪份摆哪份,缺的不致命
            FILE* out = fopen(dst.c_str(), "wb");
            if (!out) { fclose(in); continue; }
            char buf[65536];
            size_t n;
            while ((n = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, n, out);
            fclose(in);
            fclose(out);
            chmod(dst.c_str(), 0755);
        }
        /* QEMU_LD_PREFIX 本身在 .bshrc 里设（值就是 $BSH_SYSROOT）—— 上面这些"摆文件"
         * 是动作、留在 C++，而"基准在哪"是可读可改的配置。 */
    }
    
    // 启动器由 procmgr 在会话启动时从命令表整批生成一次；表暂时保留，只当**生成器**。
    // 判据是 $SYSROOT/bin/sh 在不在（sh 是表里必备的一条）——想强制重生成就删掉它。
    {
        const std::string binDir = bsh_bin_dir();
        const std::string sentinel = binDir + "/sh";
        if (access(sentinel.c_str(), F_OK) != 0) {
            cmd_make_launchers(binDir.c_str(), BSH_BUNDLE_LIBS);
        }
    }

    // 共享软 tty 状态(MAP_SHARED):命令子进程复用同一份,宿主才能看到
    // mksh 的 tcsetpgrp/termios 变化并转发 ISIG 信号(Ctrl+C/Z)。
    // 必须在任何 fork 之前建好 —— 子进程 bind_stdio 时要用到它。
    bsh_tty_init_shared(kBshSid, 0, 0);

    // procmgr:进程创建的唯一入口。必须在第一个子进程 fork 之前起来 ——
    // 一来 BSH_CTRL_SOCK 靠环境继承传给命令 so(它们据此反向请求 spawn),
    // 二来下面的资源解包(UNPACK)本身就要经它起 tar。
    // 前台 pid hook:procmgr 在 fork 完成后立刻回调,宿主据此把 Ctrl+C 送给
    // 前台进程 —— 走 socket 也不会丢这个竞态窗口。
    procmgr::SetForegroundHook([](int sid, pid_t pid) {
        /* 只认 bsh 会话(0):别的会话是独立进程里的 shell 管自己那份前台
         * (它们经 control socket 的 CMD SIGNAL 找 procmgr)。 */
        if (sid == kBshSid) g_fgChild.store(pid);
    });
    if (procmgr::StartControlSocket(bsh_ctrl_sock_path())) {
        if (!bsh_procmgr_ping())
            SlaveWrite(fd, "procmgr: 控制通道自检失败(PING 无应答)\n");
    } else {
        SlaveWrite(fd, "procmgr: 启动控制通道失败,命令执行将不可用\n");
    }
    // 宿主能力探测(fork / exec / jit):必须在任何实际 spawn 之前探一次,
    // 结论供进程创建决策用(见 procmgr/caps.cpp)。放在控制通道之后,是因为
    // 它自己要 fork —— 而 StartControlSocket 要求先于任何 fork 完成。
    procmgr::ProbeCapabilities();

    // bshutil 服务:改设置必须改在**主进程**里(配置 bsh_cfg 是本进程内存的一份,
    // 界面事件 ui_bus 的 tsfn 也只在本进程有效),所以命令 so 只是个客户端,
    // 回到这里执行 —— 见 bshutil/bsh_util_server.h。放在 procmgr 之后:
    // proclist/kill/caps 这几个子命令要经它。
    if (!bshutil::StartService(bsh_util_sock_path()))
        SlaveWrite(fd, "bshutil: 服务启动失败(bshutil 命令将不可用)\n");

    /* $HOME/.bshrc:会话环境的**绝大部分**在这里落地(生成器见 WriteBshrc)。 */
    RunRcFile(fd);

    // 解包 rawfile 资源(clang 内置头/vim runtime 等;幂等,首次启动才动手)。
    initResource(fd);

    // 内嵌 Wayland compositor:随会话启动(客户端 wldemo 等 fork 前取连接 fd)
    WaylandServer::GetInstance()->Start(std::string(kWaylandSock));

    SlaveWrite(fd, "\x1b[1;32mBetterSH\x1b[0m v0.9 - A better shell for HarmonyOS!\n");
    SlaveWrite(fd, "\x1b[2mType `python readme.py` for more information!\x1b[0m\n");
    SlaveWrite(fd, "\n");
    SlaveWrite(fd, "\x1b[2m注意：本项目当前仍处于测试版本中，请注意及时备份您的数据，不要在本应用执行任何敏感操作！\x1b[0m\n");
    SlaveWrite(fd, "\n");

    // 无人值守自检(临时件,测完删):后台跑,不占住会话 —— 万一某个用例把子进程挂住,
    // 终端仍然可用,只是日志停在那一步。
    MaybeRunAutorun(fd);

    // 行编辑（历史/光标/TAB/补全）都交给 LineEditor；它只做"字节进 → 动作出"，
    // 这里负责按动作读写 pty。**只在空闲时读**：前台子进程运行期间本循环不 poll，
    // 字节由子进程取走（vim/mksh 因此不受行编辑器干扰）。
    LineEditor ed;
    const std::string kPrompt = "\x1b[33m$\x1b[0m ";
    const std::string kBinDir = bsh_bin_dir();   // 命令位补全的名单：命令启动器文件
    int last_rc = 0;                        // $? 用：上一条命令的退出码

    while (running_) {
        if (first) { first = false; }
        SlaveWrite(fd, kPrompt);
        ed.Clear();                         // 新的一行（历史保留）

        bool submitted = false;
        for (;;) {
            struct pollfd pf[2];
            pf[0].fd = fd; pf[0].events = POLLIN; pf[0].revents = 0;
            pf[1].fd = stopPipe_[0]; pf[1].events = POLLIN; pf[1].revents = 0;
            int pr = poll(pf, 2, -1);
            if (pr < 0) { if (errno == EINTR) continue; running_ = false; goto done; }
            if (pf[1].revents) { running_ = false; goto done; }   // Stop() 唤醒
            if (!(pf[0].revents & POLLIN)) continue;
            char ch;
            ssize_t n = read(fd, &ch, 1);
            if (n <= 0) {
                if (n < 0 && errno == EINTR) continue;
                running_ = false;
                goto done;
            }

            // UTF-8 组块、退格、ESC 序列全在 LineEditor 里处理
            LineEditor::Action act = ed.Feed((unsigned char)ch);
            switch (act) {
            case LineEditor::Action::None:
                ed.TakeEcho();                        // 取走（通常是空的）
                break;
            case LineEditor::Action::Echo:
                SlaveWrite(fd, ed.TakeEcho());
                break;
            case LineEditor::Action::Redraw:
                ed.TakeEcho();
                SlaveWrite(fd, ed.Render(kPrompt));
                break;
            case LineEditor::Action::Interrupt:       // Ctrl+C：回显 ^C，丢掉这一行
                ed.TakeEcho();
                SlaveWrite(fd, "^C\r\n");
                goto next_prompt;
            case LineEditor::Action::Submit:
                ed.TakeEcho();
                SlaveWrite(fd, "\r\n");
                submitted = true;
                break;
            case LineEditor::Action::Complete: {
                ed.TakeEcho();
                std::string word = ed.WordForCompletion();
                // 命令位 = 这个词之前只有空白（第一个词）
                size_t ws = ed.Cursor() - word.size();
                bool cmd_pos = true;
                for (size_t i = 0; i < ws; i++) {
                    char t = ed.Line()[i];
                    if (t != ' ' && t != '\t') { cmd_pos = false; break; }
                }
                CompletionResult cr = CompleteWord(word, cmd_pos, kBinDir,
                                                   ListDirEntries, ed.RepeatTab());
                if (cr.show_list) {                   // 第二次 TAB：列出候选
                    std::string list = "\r\n";
                    for (const std::string& cand : cr.candidates) {
                        list += cand;
                        list += "  ";
                    }
                    list += "\r\n";
                    SlaveWrite(fd, list);
                }
                if (cr.replacement != word) ed.ReplaceWord(cr.replacement, nullptr);
                SlaveWrite(fd, ed.Render(kPrompt));   // 补全后整行重画
                break;
            }
            }
            if (submitted) break;
        }

        ed.PushHistory(ed.Line());
        {   // 执行（分词/展开/退出码提示都在 ExecuteLine 里，与 .bshrc 共用同一条路）
            bool doExit = false;
            last_rc = ExecuteLine(fd, ed.Line(), last_rc, &doExit);
            if (doExit) {
                SlaveWrite(fd, "\x1b[2mexit(再见,重开应用恢复)\x1b[0m\n");
                running_ = false;
                break;
            }
        }
    next_prompt:
        ;
    }
done:
    // 收尾:关闭 slave,通知 master 端 EOF
    if (pty_.slave >= 0) { ::close(pty_.slave); pty_.slave = -1; }
    if (stopPipe_[0] >= 0) { ::close(stopPipe_[0]); ::close(stopPipe_[1]); stopPipe_[0] = stopPipe_[1] = -1; }
}

/* ---------- NAPI -------------------------------- */

void OutputTsfnCallJs(napi_env env, napi_value cb, void*, void* data) {
    auto* s = static_cast<std::string*>(data);
    if (env && cb && s) {
        napi_value arg;
        napi_create_string_utf8(env, s->c_str(), s->size(), &arg);
        napi_value undef;
        napi_get_undefined(env, &undef);
        napi_call_function(env, undef, cb, 1, &arg, nullptr);
    }
    delete s;
}

/* master 读线程:阻塞读 pty master → ONLCR(\n→\r\n) → 推送 JS 回调。
 * 软 pty 无内核输出处理;xterm.js 的 \n 只下移不回行首,须补 \r。
 * sid 0 = bsh 的 pty(= g_shell 的),>0 = 某个 tab 的。 */
void MasterReader(int sid, int master) {
    int m = master;
    char buf[4096];
    char out[8192];
    int lastCr = 0;
    for (;;) {
        ssize_t n = read(m, buf, sizeof buf);
        if (n <= 0) break;               // shell 退出(slave 关)→ master EOF
        size_t o = 0;
        for (ssize_t i = 0; i < n; i++) {
            unsigned char c = (unsigned char)buf[i];
            if (c == '\n' && !lastCr) {
                if (o + 2 <= sizeof out) { out[o++] = '\r'; out[o++] = '\n'; }
            } else {
                if (o + 1 <= sizeof out) out[o++] = (char)c;
            }
            lastCr = (c == '\r');
        }
        napi_threadsafe_function fn = SessionTsfn(sid);
        if (o == 0 || !fn) continue;
        auto* s = new std::string(out, o);
        napi_call_threadsafe_function(fn, s, napi_tsfn_blocking);
    }
    if (sid == kBshSid) g_started = false;
    else                OnSessionEnded(sid);
}

/* ───────────── tab 会话的创建 / 销毁 / 存活 ───────────── */

int AllocSession(void) {
    std::lock_guard<std::mutex> lk(g_sess_mu);
    for (int i = 0; i < BSH_SID_MAX; i++) {
        if (g_nextSid <= 0 || g_nextSid >= BSH_SID_MAX) g_nextSid = 1;
        int sid = g_nextSid++;
        if (!g_sess[sid].used) {
            g_sess[sid].used = true;
            g_sess[sid].started = false;
            g_sess[sid].master = -1;
            g_sess[sid].pid = -1;
            g_sess[sid].tsfn = nullptr;
            return sid;
        }
    }
    return 0;   // 槽用光了(BSH_SID_MAX 个 tab 同时开着,实际不会到)
}

int StartSession(int sid) {
    if (sid <= 0 || sid >= BSH_SID_MAX) return -1;
    {
        std::lock_guard<std::mutex> lk(g_sess_mu);
        if (!g_sess[sid].used || g_sess[sid].started) return -1;
    }

    PseudoTty pt;
    if (!PseudoTtyCreate(&pt)) return -1;

    /* 会话的软 tty 状态必须**在下面那次 spawn 之前**建好:它是一块 MAP_SHARED 内存,
     * 靠 fork 继承(procmgr 的 fork 就发生在 spawn 里),晚一步子进程就看不到它。 */
    bsh_tty_init_shared(sid, 0, 0);

    /* 环境:宿主 environ + BSH_SESSION=<sid>。
     * 为什么要把整套 environ 显式带过去:子进程是 procmgr fork 的,**只继承 procmgr
     * 自己的 environ**,而 mksh 要看到 PATH/HOME/BSH_SYSROOT/… 这些由宿主导出的变量
     * (它们挂在宿主 environ 上)。BSH_SESSION 则是这个会话的身份,后面对 tty 的读写
     * 与 Ctrl+C 都靠它找到正确的会话。 */
    char sidbuf[48];
    snprintf(sidbuf, sizeof sidbuf, "%s=%d", BSH_SESSION_ENV, sid);
    std::vector<char*> envp;
    extern char** environ;          // ⚠ 必须写全 ::environ —— 在 namespace bsh 里光写
                                    // environ 会绑到 bsh::environ 上去(链接期 undefined)
    for (char** e = ::environ; e && *e; e++) envp.push_back(*e);
    envp.push_back(sidbuf);
    envp.push_back(nullptr);

    char* argv[] = { (char*)"sh", nullptr };
    int src[3] = { pt.slave, pt.slave, pt.slave };   // 同一个 fd 给 0/1/2(同 UnpackRes 的做法)
    int tgt[3] = { 0, 1, 2 };
    int pid = -1;
    /* 异步 spawn:建好就返回,不等它结束 —— 这是个常驻的交互式 shell。
     * 命令名用 "sh":走命令表 → libmksh.so。 */
    if (bsh_spawnv_async_fdmap_env("sh", argv, envp.data(), src, tgt, 3, &pid) != 0 || pid <= 0) {
        PseudoTtyClose(&pt);
        return -1;
    }
    ::close(pt.slave);          // 父进程只留 master(子进程那份已经 dup 走了)

    int master = pt.master;
    {
        std::lock_guard<std::mutex> lk(g_sess_mu);
        if (!g_sess[sid].used) {   // 竞态:期间被 stop 了
            ::close(master);
            bsh_procmgr_terminate(pid);
            return -1;
        }
        g_sess[sid].started = true;
        g_sess[sid].master = master;
        g_sess[sid].pid = pid;
    }
    OH_LOG_INFO(LOG_APP, "session start sid=%{public}d pid=%{public}d", sid, pid);
    bsh::StartThreadDetached([sid, master] { MasterReader(sid, master); });
    return 0;
}

void StopSession(int sid) {
    pid_t pid = -1;
    napi_threadsafe_function fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_sess_mu);
        if (sid <= 0 || sid >= BSH_SID_MAX) return;
        pid = g_sess[sid].pid;
        fn = g_sess[sid].tsfn;
        g_sess[sid].tsfn = nullptr;
        /* master 不在这里关:读线程可能正阻塞在它上面,由 OnSessionEnded 收尾
         * (子进程一死,那条 read 就返回 0)。这里只把号释放掉。 */
        g_sess[sid].used = false;
    }
    if (fn) napi_release_threadsafe_function(fn, napi_tsfn_release);
    if (pid > 0) bsh_procmgr_terminate(pid);   // 先 SIGTERM,800ms 后 SIGKILL(procmgr 那条路)
}

bool SessionAlive(int sid) {
    std::lock_guard<std::mutex> lk(g_sess_mu);
    return sid > 0 && sid < BSH_SID_MAX && g_sess[sid].started;
}

/* 取一个会话的 master fd(-1 = 该会话不可用)。bsh 会话拿 g_shell 的 pty。 */
static int SessionMaster(int sid) {
    if (sid == kBshSid) return (g_shell && g_started) ? g_shell->Pty()->master : -1;
    std::lock_guard<std::mutex> lk(g_sess_mu);
    if (sid <= 0 || sid >= BSH_SID_MAX || !g_sess[sid].started) return -1;
    return g_sess[sid].master;
}

/* 一个会话当前的前台 pid。bsh 会话用 hook 记下的那份(同进程,零成本);tab 会话问
 * procmgr —— 它的前台是 mksh 再往下起的进程,只有 procmgr 记着。 */
static int SessionForeground(int sid) {
    return sid == kBshSid ? g_fgChild.load() : (int)procmgr::ForegroundPid(sid);
}

/* 分配一个 tab 会话号(只占号,不启动东西 —— 见 shell.h)。
 * ArkTS 要先拿到号才能把它经 want.parameters 传给新 Ability。 */
napi_value BshTermAllocSessionNAPI(napi_env env, napi_callback_info) {
    napi_value ret;
    napi_create_int32(env, AllocSession(), &ret);
    return ret;
}

#if defined(INTERCEPT_VERSION) && INTERCEPT_VERSION == 1

/* bshTermStart(sid, cb):sid 0 = 主窗口的 bsh(老路径,行为一字未改),
 * >0 = 从 newtab 开出来的 tab —— 给它建 pty、让 procmgr 把 mksh 挂上去。 */
napi_value BshTermStartNAPI(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return nullptr;
    int32_t sid = kBshSid;
    napi_get_value_int32(env, args[0], &sid);

    if (sid != kBshSid) {
        /* ── tab 会话 ── */
        {
            std::lock_guard<std::mutex> lk(g_sess_mu);
            if (sid <= 0 || sid >= BSH_SID_MAX || !g_sess[sid].used) {
                napi_value ret; napi_create_int32(env, -1, &ret); return ret;
            }
        }
        napi_threadsafe_function old = nullptr;
        {
            std::lock_guard<std::mutex> lk(g_sess_mu);
            old = g_sess[sid].tsfn;
            g_sess[sid].tsfn = nullptr;
        }
        /* 释放必须在锁外:release 会触发 finalize,而 finalize 要拿 g_sess_mu。 */
        if (old) napi_release_threadsafe_function(old, napi_tsfn_release);

        napi_value resName;
        napi_create_string_utf8(env, "BshTermOutput", NAPI_AUTO_LENGTH, &resName);
        napi_threadsafe_function fn = nullptr;
        if (napi_create_threadsafe_function(env, args[1], nullptr, resName,
                                            0, 1, (void*)(intptr_t)sid, SessionTsfnFinalize,
                                            nullptr, OutputTsfnCallJs, &fn) != napi_ok) {
            napi_value ret; napi_create_int32(env, -1, &ret); return ret;
        }
        {
            std::lock_guard<std::mutex> lk(g_sess_mu);
            g_sess[sid].tsfn = fn;
        }
        if (StartSession(sid) != 0) {
            StopSession(sid);   // 释放号与 tsfn
            napi_value ret; napi_create_int32(env, -1, &ret); return ret;
        }
        napi_value ret;
        napi_create_int32(env, 0, &ret);
        return ret;
    }

    /* ── bsh(主窗口)── */
    if (g_tsfn) {
        napi_release_threadsafe_function(g_tsfn, napi_tsfn_release);
        g_tsfn = nullptr;
    }
    napi_value resName;
    napi_create_string_utf8(env, "BshTermOutput", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, args[1], nullptr, resName,
                                    0, 1, nullptr, nullptr, nullptr,
                                    OutputTsfnCallJs, &g_tsfn);

    if (!g_started) {
        delete g_shell;
        g_shell = new bsh::BasicShell();
        if (!g_shell->Start()) {
            napi_value ret;
            napi_create_int32(env, -1, &ret);
            return ret;
        }
        g_started = true;
        int mfd = g_shell->Pty()->master;
        bsh::StartThreadDetached([mfd] { MasterReader(kBshSid, mfd); });
    }
    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

/* bshTermInput(sid, 文本) */
napi_value BshTermInputNAPI(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return nullptr;
    int32_t sid = kBshSid;
    napi_get_value_int32(env, args[0], &sid);

    char buf[8192];
    size_t len = 0;
    if (napi_get_value_string_utf8(env, args[1], buf, sizeof buf, &len) != napi_ok)
        return nullptr;

    int fd = SessionMaster(sid);
    int wrote = -1;
    if (fd >= 0) {
        // 有前台子进程时做 ISIG 转发:软 tty 无内核行规程,Ctrl+C/\/
        // Z 不会自动产生信号。命中(VINTR/VQUIT/VSUSP 且 ISIG 开)则
        // 发给前台进程组/前台子进程,该字节不再写入 pty(同真 tty)。
        // 另做 ICRNL 翻译:前端 Enter 发的是 CR,真 tty 会翻成 NL。
        // 两件都按**这个会话**的 termios(bsh_tty 按 sid 分),信号也发给这个会话的前台。
        int child = SessionForeground(sid);
        std::string pass;
        pass.reserve(len);
        for (size_t i = 0; i < len; i++) {
            unsigned char c = (unsigned char)buf[i];
            if (child > 0 && bsh_tty_forward_sig(sid, c, child)) continue;
            pass.push_back((char)bsh_tty_input_translate(sid, c));
        }
        ssize_t w = pass.empty() ? 0 : write(fd, pass.data(), pass.size());
        wrote = (int)w;
    }
    napi_value ret;
    napi_create_int32(env, wrote, &ret);
    return ret;
}

/* bshTermStop(sid):关掉这个会话。
 * sid 0 只停 bsh 本身(procmgr/bshutil/Wayland 这些是**进程级**的,不跟着走);
 * tab 则结束它的 mksh 并释放号。 */
napi_value BshTermStopNAPI(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sid = kBshSid;
    if (argc >= 1) napi_get_value_int32(env, args[0], &sid);
    if (sid == kBshSid) {
        if (g_shell) {
            g_shell->Stop();
            g_started = false;
        }
    } else {
        StopSession(sid);
    }
    return nullptr;
}

#endif

/* ArkTS 侧要往终端里回一句话时用(比如目录选择器的结果)。
 * 从 pty 的 slave 写进去,和 shell 自己的输出走同一条路。
 *
 * ⚠ 只有 bsh 会话(0)能做:宿主手上留着它的 slave。tab 会话的 slave 在 spawn 之后就
 *   关掉了 —— 留着会让 master 永远读不到 EOF(读线程就此收不了尾),而"注入一行输出"
 *   这件事本身不是必需(现在这条路的唯一使用者是 picker 的非请求分支,而 newtab 之后
 *   picker 一律走请求分支)。所以 tab 会话下这里退化成 no-op。 */
napi_value BshNoticeNAPI(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return nullptr;
    int32_t sid = kBshSid;
    napi_get_value_int32(env, args[0], &sid);
    if (sid != kBshSid || !g_shell || !g_started) return nullptr;
    char buf[1024];
    size_t len = 0;
    if (napi_get_value_string_utf8(env, args[1], buf, sizeof buf, &len) == napi_ok) {
        std::string s = std::string("\x1b[36m[notice]\x1b[0m ") + buf + "\n";
        ssize_t w = write(g_shell->Pty()->slave, s.data(), s.size());
        (void)w;
    }
    return nullptr;
}

#if defined(INTERCEPT_VERSION) && INTERCEPT_VERSION == 1

/* bshTermResize(sid, cols, rows) */
napi_value BshTermResizeNAPI(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) return nullptr;
    int32_t sid = kBshSid;
    uint32_t cols = 0, rows = 0;
    napi_get_value_int32(env, args[0], &sid);
    napi_get_value_uint32(env, args[1], &cols);
    napi_get_value_uint32(env, args[2], &rows);
    bsh_tty_set_shell_size(sid, (uint16_t)rows, (uint16_t)cols);
    // 尺寸落到共享状态后通知前台:vim 这类全屏程序靠 SIGWINCH 重排,
    // ssh 靠它给远端发 window-change。少了这一步,远端 pty 会一直停在
    // 会话建立时的行列。
    bsh_tty_forward_winch(sid, SessionForeground(sid));
    return nullptr;
}

#endif

// 资源管理器不再是这个文件独有的全局变量了:bshutil 的常驻服务线程也要读 rawfile,
// 登记口与两个共用操作都在 common/bsh_rawfile.h。

/* 参数：resourceManager, filesDir。
 * filesDir 是**分包的关键**：设备侧数据目录是 /data/storage/el2/base/haps/<模块名>/files，
 * 模块名随 product 变(tablet / phone)，编译期写死就绑死在一个模块名上。所以由 Ability
 * 把 context.filesDir 传进来，在这里 bsh_set_sysroot()，之后同进程的 bsh_sysroot()
 * 与 fork 出去的命令 so / guest 都拿到同一个值（前者读全局变量，后者读环境变量）。
 * 第二个参数缺席时退化成 bsh_paths.h 里的编译期默认值(老行为)。 */
napi_value initResourceManagerNAPI(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 1) {
        bsh::bsh_rawfile_set_manager(OH_ResourceManager_InitNativeResourceManager(env, args[0]));
    }
    if (argc >= 2) {
        size_t len = 0;
        if (napi_get_value_string_utf8(env, args[1], nullptr, 0, &len) == napi_ok && len > 0) {
            std::string dir(len, '\0');
            if (napi_get_value_string_utf8(env, args[1], dir.data(), len + 1, &len) == napi_ok) {
                bsh_set_sysroot(dir.c_str());
                std::fprintf(stderr, "BSH_SYSROOT=%s (from context.filesDir)\n", dir.c_str());
            }
        }
    }
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

// 把 rawfile 里的 tar 流式落盘后用 toybox tar 解到 dest(tar 顶层内容直接进 dest)。
// 解包走 procmgr 起 tar(与命令行同一条路),stdio 接 /dev/null:解包是内部动作,
// 报错(如沙箱禁 symlink 的 EPERM)不该喷到用户终端上 —— 会出现在会话横幅之前,
// 看起来像应用出错。
static int UnpackRes(const char* rawfile, const std::string& dest) {
    NativeResourceManager* resMgr = bsh::bsh_rawfile_manager();
    if (!resMgr) return -1;
    RawFile* rf = OH_ResourceManager_OpenRawFile(resMgr, rawfile);
    if (!rf) return -1;
    long size = OH_ResourceManager_GetRawFileSize(rf);
    if (size <= 0) { OH_ResourceManager_CloseRawFile(rf); return -1; }

    /* `.tar.gz` 要**自己先解开**,不能让 tar 自己去猜。
     *
     * toybox 的 tar 认 gzip 魔数后,会用 xpopen_both() **vfork** 出一个子进程去跑
     * `zcat`/`gzip -d`(见 toys/posix/tar.c 的 "autodetect compression type")。
     * vfork 的子进程与父进程**共享地址空间**、父进程被挂起 —— 子进程在 exec 之前
     * 除了 _exit 什么都不该做(toybox 自己的注释就写着这条)。而我们的 exec 委托
     * (exec_shim.c 走 --wrap 进 libtoybox)在子进程里要 socket/组请求/收发,
     * 等于拿 tar 的内存当草稿纸。后果是 tar 一声不响地什么都没解出来 ——
     * 实测 code-server 那个 214MB 的 .tar.gz 就这样(同一批 .tar 全都正常,差别只在
     * 这一层),而 UnpackRes 的 stdio 接的是 /dev/null,连报错都看不见。
     *
     * 改成两步:`gzip -d` 这一步经 procmgr **正常 fork**,是验证过的路径(node/npm
     * 的子进程都走它);解完 tar 拿到的就是纯 tar,不会再产生子进程。
     * 所以临时文件按后缀取名,先写 `.tar.gz`,解出来才是 `.tar`。 */
    size_t rn = strlen(rawfile);
    bool gz = rn > 3 && strcmp(rawfile + rn - 3, ".gz") == 0;

    std::string tarPath = dest + "/.res-unpack.tar";   // 临时 tar 落在目标目录内
    std::string tmpPath = gz ? (tarPath + ".gz") : tarPath;
    mkdir(dest.c_str(), 0755);
    int out = open(tmpPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) { OH_ResourceManager_CloseRawFile(rf); return -1; }
    char buf[262144];
    bool readOk = true;
    for (;;) {
        int n = OH_ResourceManager_ReadRawFile(rf, buf, sizeof buf);
        if (n < 0) { readOk = false; break; }
        if (n == 0) break;
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(out, buf + off, (size_t)(n - off));
            if (w <= 0) { readOk = false; break; }
            off += w;
        }
        if (!readOk) break;
    }
    OH_ResourceManager_CloseRawFile(rf);
    close(out);
    if (!readOk) { unlink(tmpPath.c_str()); return -1; }

    int nul = open("/dev/null", O_RDWR);
    int fds[3] = { nul, nul, nul };

    if (gz) {
        std::vector<std::string> un = { "gzip", "-d", tmpPath };
        std::vector<char*> uargv(un.size() + 1, nullptr);
        for (size_t i = 0; i < un.size(); i++) uargv[i] = &un[i][0];
        int grc = bsh_spawnv_sync("gzip", uargv.data(), fds);
        if (grc != 0) {
            if (nul >= 0) close(nul);
            unlink(tmpPath.c_str());
            return -1;
        }
    }

    std::vector<std::string> store = { "tar", "-x", "-f", tarPath, "-C", dest };
    std::vector<char*> argv(store.size() + 1, nullptr);
    for (size_t i = 0; i < store.size(); i++) argv[i] = &store[i][0];

    int rc = bsh_spawnv_sync("tar", argv.data(), fds);
    if (nul >= 0) close(nul);
    unlink(tarPath.c_str());
    return rc == 0 ? 0 : -1;
}

// 单个 rawfile 文件拷到本地。overwrite=false 时"已存在就跳过"(供 hello.c 这类小资源),
// true 时每次都覆盖 —— 自检脚本用得上(改了脚本不该等下次装包才生效)。
// 实际读写在 common/bsh_rawfile.cpp(bshutil 的 `rawfile get` 用的是同一个函数);
// 这里保留薄壳只是为了不动下面那几处调用点。
static void CopyRawFile(const std::string& rawName, const std::string& dst,
                        bool overwrite = false) {
    bsh::bsh_rawfile_copy(rawName.c_str(), dst.c_str(), overwrite);
}

// ── 无人值守自检(临时件,测完删) ──────────────────────────────
// 为什么需要:设备上的回归测试要靠人在终端里敲命令,而这轮改动很多、又要等长时间构建,
// 所以做一条"启动即自检"的路:rawfile 里放 tools/autorun.sh → 每次会话启动覆盖写到
// $HOME/autorun.sh → 用 sh 跑一遍 → 输出(含 stderr)落 $HOME/autorun.log,stdin 接
// /dev/null(免得哪个用例等输入把子进程挂住)。结果直接用 hdc 读日志即可。
//
// 几个刻意的选择:
//   - 后台线程里跑(bsh_spawnv_sync 会等子进程):这样即使某个用例卡住,终端照样能用,
//     日志停在哪一步也一眼看得出。
//   - 每次都覆盖(overwrite=true):改了脚本不必等下次装包。
//   - 没有屏蔽开关 —— 这是**临时件**:rawfile 里不放 autorun.sh,它自己就什么都不做。
//
// (bsh_client 的 last_error 是进程内静态缓冲、非线程安全,所以并发的 spawn 只有错误
//  文案可能串;正常路径不受影响。)
static void MaybeRunAutorun(int fd) {
    // 自检脚本属于"会话家目录"的东西(用户会去 $HOME 找它,日志也落那儿)
    const std::string kHomeDir = bsh_home_dir();
    const std::string script = kHomeDir + "/autorun.sh";
    const std::string logPath = kHomeDir + "/autorun.log";

    // 完整版自检不再自动落盘。
    // CopyRawFile("tools/autorun-all.sh", std::string(kHomeDir) + "/autorun-all.sh", /*overwrite=*/true);
    CopyRawFile("tools/autorun.sh", script, /*overwrite=*/true);
    struct stat st;
    if (stat(script.c_str(), &st) != 0 || st.st_size <= 0) return;   // 没有这个 rawfile 就什么都不做

    SlaveWrite(fd, "\x1b[2mautorun: 自检已在后台运行,结果见 $HOME/autorun.log\x1b[0m\n");

    bsh::StartThreadDetached([script, logPath]() {
        int devnull = open("/dev/null", O_RDONLY);
        int lfd = open(logPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (lfd < 0) {
            if (devnull >= 0) close(devnull);
            return;
        }
        dprintf(lfd, "=== autorun(由 shell 启动时触发) ===\n");
        std::vector<std::string> store = { "sh", script };
        std::vector<char*> argv(store.size() + 1, nullptr);
        for (size_t i = 0; i < store.size(); i++) argv[i] = &store[i][0];
        int fds[3] = { devnull, lfd, lfd };
        int rc = bsh_spawnv_sync("sh", argv.data(), fds);
        dprintf(lfd, "=== autorun 结束 rc=%d ===\n", rc);
        close(lfd);
        if (devnull >= 0) close(devnull);
    });
}

// rawfile 资源解包。落点分两处(见 common/bsh_paths.h):
//   资源(sysroot)  vim-runtime/ fonts/ python/ npm/ testprogs/ usr/share/…
//   家目录(home)   hello.c、.harmony/(hdc 密钥)、autorun*.sh
//   vim 运行时(vim-runtime;$VIMRUNTIME 指向)
//   CPython stdlib(python/;PYTHONHOME 指向,见 build_python.sh)
//   PyQt6 包壳(python/lib/…/site-packages/PyQt6/;C 扩展平铺在 bundle libs,见 build_pyqt.sh)
// fontconfig 只认 conf 文件里的 <dir>,没有"覆盖字体目录"的环境变量;而 fonts.tar 里
// 那份写的是**打包时**的资源根绝对路径,分包后模块名变了就不对了(症状:窗口文字全变方块)。
// 所以按当前资源根重写一份。幂等,且**解包前后都要写**:只有 marker 不存在时才解包,
// 而解包会把 tar 里那份原样盖回来。
static void WriteFontsConf(const std::string& sysroot) {
    const std::string fontsConf = bsh_fonts_conf_path();
    const std::string fontsDir = sysroot + "/fonts";
    FILE* f = fopen(fontsConf.c_str(), "w");
    if (!f) return;
    fprintf(f,
        "<?xml version=\"1.0\"?>\n"
        "<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\">\n"
        "<fontconfig>\n"
        "  <dir>%s</dir>\n"
        "  <match target=\"pattern\">\n"
        "    <test name=\"family\"><string>monospace</string></test>\n"
        "    <edit name=\"family\" mode=\"prepend\" binding=\"strong\"><string>DejaVu Sans Mono</string></edit>\n"
        "  </match>\n"
        "  <match target=\"pattern\">\n"
        "    <test name=\"family\"><string>sans</string></test>\n"
        "    <edit name=\"family\" mode=\"prepend\" binding=\"strong\"><string>DejaVu Sans Mono</string></edit>\n"
        "  </match>\n"
        "</fontconfig>\n",
        fontsDir.c_str());
    fclose(f);
}

/* 生成两个编译器包装脚本：`$SYSROOT/bin/{cc-ohos,ldshared-ohos}`。
 *
 * 为什么需要包装：设备上用 pkg 装的 ohos-sdk-prune 编 C 扩展时，clang 必须带
 * `--target=aarch64-linux-ohos --sysroot=<sdk>/sysroot`，而 .bshrc 那边的 shell
 * **不支持带空格的变量值**（`export CC="clang --target=…"` 只会留下第一个词，实测
 * 就是这样丢的），所以把参数写进脚本、变量里只放路径。Python 头文件（pkg 的
 * `python-headers` 包解到 $SYSROOT/python-headers/）也在这里用 -I 带上，免得再往
 * CFLAGS 里塞空格。没装那个包时这条 -I 指向空目录，clang 会报找不到 Python.h。
 *
 * 每次会话重写一遍（内容只取决于 $SYSROOT，很便宜）。SDK 没装时它们指向不存在的
 * clang，编译会以"文件不存在"失败 —— 一眼看得出是没装 SDK。 */
static void WriteCcWrapper() {
    const std::string sdk = std::string(bsh_sysroot()) + "/opt/ohos-sdk/openharmony/native";
    const std::string inc = std::string(bsh_sysroot()) + "/python-headers";
    mkdir(bsh_bin_dir(), 0755);   // 启动器生成得更早，但这里不假设顺序
    struct W { const char* name; const char* cc; const char* extra; };
    const W kWrappers[] = {
        {"cc-ohos",       "clang",   ""},
        /* C++ 必须走 clang++：只有 C++ 驱动会自动链 libc++。用 clang（C 驱动）编出来的
         * 扩展 NEEDED 里只有 libc.so，std 那一族和 typeinfo 那些符号一个都解析不了
         * （实测 `unresolved symbol _ZTISt13runtime_error`）。
         * 链接期再显式带一把 -lc++_shared：设备上它是系统库，能被正常加载；
         * 不显式写的话某些 .so 会漏掉这条 NEEDED。 */
        {"cxx-ohos",      "clang++", ""},
        {"ldshared-ohos", "clang++", " -shared -lc++_shared"},
        /* 再给 `clang` / `clang++` 两个**同名**包装：构建系统（和自检脚本）经常直接写
         * `clang hello.c`，而 SDK 那个 clang 的默认 target 是 aarch64-unknown-linux-gnu
         * （不是 ohos），裸跑连 stdio.h 都找不到；带上 --sysroot 又会缺 musl 的
         * bits/alltypes.h。只有 --target=aarch64-linux-ohos + --sysroot 一起给才对 ——
         * 也就是本函数生成的那串。配合下面 PATH 里 $SYSROOT/bin 排在 llvm/bin 之前。 */
        {"clang",         "clang",   ""},
        {"clang++",       "clang++", ""},
    };
    for (const W& w : kWrappers) {
        const std::string path = std::string(bsh_bin_dir()) + "/" + w.name;
        FILE* f = fopen(path.c_str(), "w");
        if (!f) continue;
        fprintf(f,
            "#!/bin/sh\n"
            "# 由 BetterSH 生成(shell.cpp 的 WriteCcWrapper),别手改。\n"
            /* -U_FORTIFY_SOURCE：OHOS 的 sys/select.h 会把 FD_SET/FD_CLR 展开成
             * `__fd_chk(fd)`（它 musl 私有的越界检查），而 **bundle 里的
             * ld-musl-aarch64.so.1 是 vanilla musl 1.2.2、没有这个符号** —— 编出来的
             * 东西一装载就报 "Error relocating <so>: __fd_chk: symbol not found"
             * （实测 make/ninja 与 node-gyp 现场编的扩展都会踩）。关掉 fortify 即
             * 退回 vanilla 的 FD_SET，语义一致。
             * 根治办法是给我们的 musl 补一个 __fd_chk，见 README 的待办。 */
            "exec %s/llvm/bin/%s -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 "
            "--target=aarch64-linux-ohos --sysroot=%s/sysroot "
            "-I%s%s \"$@\"\n",
            sdk.c_str(), w.cc, sdk.c_str(), inc.c_str(), w.extra);
        fclose(f);
        chmod(path.c_str(), 0755);
    }
}

static void InstallPrograms() {
    std::vector<bsh::RawFileEntry> files;
    if (!bsh::bsh_rawfile_list(&files)) return;
    mkdir(bsh_bin_dir(), 0755);
    /* 仓库里按"看得出是什么"的名字存（`code.sh`），装到设备上要用户敲的名字（`code`）。
     * 只列需要改名的，其余原名落地。 */
    struct Ren { const char* raw; const char* name; };
    const Ren kRenames[] = {
        {"programs/code.sh",        "code"},
        {"programs/code-server.sh", "code-server"},
        {"programs/git.sh",         "git"},
        {"programs/zcode.sh",       "zcode"},
    };
    const std::string pfx = "programs/";
    for (const bsh::RawFileEntry& e : files) {
        if (e.path.compare(0, pfx.size(), pfx) != 0) continue;
        std::string base = e.path.substr(pfx.size());
        if (base.empty() || base.find('/') != std::string::npos) continue;   // 只装顶层文件
        bool renamed = false;
        for (const Ren& r : kRenames) {
            if (e.path == r.raw) { base = r.name; renamed = true; break; }
        }
        const std::string dst = std::string(bsh_bin_dir()) + "/" + base;
        if (bsh::bsh_rawfile_copy(e.path.c_str(), dst.c_str(), /*overwrite=*/true) != 0) continue;
        /* 可执行位：`*.sh` 与改过名的启动器（`code`）都要能直接跑；其余当数据（0644，
         * 比如 vscode-deps.urls）。漏了这一步的症状是 `can't execute: Permission denied`
         * —— rawfile 拷出来一律 0644（见 bsh_rawfile.cpp 的 open 模式）。 */
        const bool exec = renamed ||
            (base.size() > 3 && base.compare(base.size() - 3, 3, ".sh") == 0);
        chmod(dst.c_str(), exec ? 0755 : 0644);
    }
}

int initResource(int fd) {
    (void)fd;
    const std::string sysroot = bsh_sysroot();
    const std::string home = bsh_home_dir();
    const std::string marker = sysroot + "/.res-unpacked";

    WriteFontsConf(sysroot);   // 老装机(资源已解过)也刷一遍
    WriteCcWrapper();          // 同上：编译器包装脚本每次会话都刷
    InstallPrograms();         // 同上：用户态启动器脚本每次会话都刷

    struct stat st;
    if (stat(marker.c_str(), &st) == 0) {
        return 0;
    }

    int fail = 0;
    int warning = 0;   // 非必需资源(见下)解失败只记这里,不影响写标记

    fail += UnpackRes("tools/vim-runtime.tar", sysroot + "/vim-runtime") != 0;
    // 字体随包走（终端窗口没字体什么都看不见，且它不在 pkg 的包里）。
    // weston-terminal 本体与它的 xkb/weston 数据**不再随 HAP**：那三样是 pkg 的包，
    // 由用户在终端里 `pkg install weston-terminal` 下载安装（见 programs/pkg/）。
    fail += UnpackRes("tools/fonts.tar", sysroot) != 0;
    // CPython stdlib:tar 顶层是 python/,解到资源根 → <sysroot>/python/lib/python3.12/
    fail += UnpackRes("tools/python-stdlib.tar", sysroot) != 0;
    // 组合验收程序(见 scripts/build_testprogs.sh):同一份源码编出的 elf ——
    // x86_64 的 glibc/musl × 静态/动态四个交 box64,另两个 aarch64 musl 交 elfloader
    // 当参照;aarch64 的两只 selfexe-* 是 /proc/self/exe 自测(见 shim/README.md §3.1b)。
    // aarch64 动态那只需要的 musl 加载器(ld-musl-aarch64.so.1)**不在这个 tar 里** ——
    // 它随 HAP 打进 bundle libs,procmgr 只从那里按 PT_INTERP 的 basename 找解释器。
    // 顶层就是 testprogs/。
    fail += UnpackRes("tools/testprogs.tar", sysroot) != 0;
    // npm 10.5.0 的纯 JS 树(见 build_node.sh 第 5 步):tar 顶层是 npm/,解到资源根
    // → <sysroot>/npm/bin/npm-cli.js。入口由 bsh_npm_main 拼成 node 的命令行,它按
    // 环境变量 BSH_SYSROOT 找这个文件(见 node-ohos/bsh_node_entry.cc)。
    fail += UnpackRes("tools/npm.tar", sysroot) != 0;
    // 设备侧工具子集(34MB,见 build/dist/bshsign/):aarch64 的 hdc + hap-sign-tool +
    // 它们的 .so 闭包 + BetterSHDev 的签名材料(dev.cer/p7b/p12 + 口令的 README)。
    // 自举流水线要靠它:签名用 hap-sign-tool,安装/打开用 hdc(经 tconn 接设备自身的 hdcd)。
    // 原来那一包(hapsign.tar,631MB)大头是预编译的 dev HAP,现在自己构建了,不需要。
    // 暂时不进行导入
    // fail += UnpackRes("tools/bshsign-tools.tar", sysroot) != 0;
    // OpenJDK 21(见 scripts/build_jdk.sh 的 install 阶段):tar 顶层是 jdk21/,
    // 解到资源根后是 <sysroot>/jdk21 —— 里面只有**数据**(lib/modules、conf/、
    // tzdb.dat、lib/ct.sym、bin/…);JDK 的 .so 全部平铺在 bundle libs 里随 HAP
    // 走,因为 app 数据目录是 noexec,从那里 dlopen 会被内核拒绝(实测 Permission denied)。
    // java.home 由 jdk-ohos/bsh_java_entry.cc 按 BSH_SYSROOT 拼出来。
    // 暂时不进行导入
    // fail += UnpackRes("tools/jdk21-ohos.tar", sysroot) != 0;

    // 应用侧启动器脚本（rawfile/programs/*）不在这里装：它们在 initResource 开头
    // 由 InstallPrograms() 每次会话刷到 $SYSROOT/bin/，不受这个 marker 控制。

    // 首屏横幅让用户敲 `python readme.py`,所以这两份落在**家目录**(会话起来就在这儿),
    // 不是放 hdc 密钥的 .harmony/ —— 那边到下面才 mkdir,而且是给密钥用的隐藏目录。
    CopyRawFile("tools/readme.py",   home + "/readme.py");
    CopyRawFile("tools/licenses.py", home + "/licenses.py");

    // `clang hello.c -o hello`。
    CopyRawFile("tools/hello.c", home + "/hello.c");

    const std::string kKeyDir = home + "/.harmony";
    mkdir(kKeyDir.c_str(), 0700);
    chmod(kKeyDir.c_str(), 0700);
    CopyRawFile("tools/hdckey", kKeyDir + "/hdckey");
    CopyRawFile("tools/hdckey.pub", kKeyDir + "/hdckey.pub");
    chmod((kKeyDir + "/hdckey").c_str(), 0600);
    
    if (fail == 0) {
        int fd = open(marker.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (fd >= 0) close(fd);
    }

    /* 解包已经把 fonts.conf 从 tar 里原样解出来了,这里再写一遍盖掉那份错路径 */
    WriteFontsConf(sysroot);

    return fail + warning;
}

}  // namespace bsh
