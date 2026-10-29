// bsh_java_entry.cc — BetterSH 的 java / javac / jar 三个入口。
//
// 目标:在"没有真 exec"的鸿蒙沙箱里,把交叉编译好的 OpenJDK 21 跑成终端里的三条命令。
// 三件事都必须在**本进程内**完成 —— 宿主是 procmgr fork 出来的子进程,不能换镜像:
//
//   1) 用 JNI Invocation API 起 VM(JNI_CreateJavaVM + JNI_VERSION_10),不走 JLI_Launch;
//   2) 把 bin/java 的启动器逻辑(libjli/java.c)搬过来一个等价子集:解析启动器选项、
//      把主类交给 sun.launcher.LauncherHelper —— 这样 -cp / -jar / -m / -XshowSettings /
//      -version 的语义与 JDK 原版一致;
//   3) 起 VM 之前把「OHOS 特殊信号链」接到 HotSpot 导出的信号入口上(见「信号转发」)。
//
// ── 为什么不走 JLI_Launch ────────────────────────────────────────────────────
// 上游 launcher 在 musl 上会先设好 LD_LIBRARY_PATH 再 **execv 自己** 重跑一遍
// (java_md.c 的 RequiresSetenv,脚本里的 0009 补丁把它改成 JNI_FALSE 才绕开)。
// 沙箱没有 exec,JLI 这条路根本不成立。JNI_CreateJavaVM 与 JLI_Launch 起的是同一个
// VM,JLI 之后做的事(LauncherHelper 加载主类)我们在这里重做一遍即可。
//
// ── 文件摆位(bundle libs vs 资源根/$HOME) ──────────────────────────────────
// 应用数据目录(entry/files,下称**资源根**)是 **noexec**:
// 实测从那里 dlopen 一份 .so 会直接 `Permission denied`。所以 JDK 的 26 个 .so
// 全部随 HAP 打进 `/data/storage/el1/bundle/libs/arm64/`(平铺),其余数据
// (lib/modules、conf/、tzdb.dat、lib/ct.sym …)解包在 `<资源根>/jdk21` 下。
// 由此:
//   JAVA_HOME             = <资源根>/jdk21      (java.home,定位 lib/modules 等数据)
//   SUN_BOOT_LIBRARY_PATH = bundle libs 目录    (hotspot 的 dll_dir:从这里 dlopen
//                                                libjava/libzip/libjimage…)
//   java.library.path     = bundle libs 目录    (System.loadLibrary 的搜索路径)
// 资源根从 BSH_SYSROOT 环境变量取;用户的 $HOME 是 `<资源根>/home`,两者不同,
// 别再把它们当成一回事(改布局前它们是同一个目录)。
//
// ── 信号转发(为什么必须在这里做) ────────────────────────────────────────────
// OHOS 的 libc 自带一条「信号链」(musl 的 sigchain,MUSL-SIGCHAIN):
//   * 崩溃类信号(libc 的 crash 路径)会先走链上的 special handler,
//     普通 sigaction 注册的处理器优先级比它低 —— 鸿蒙自带的 DFX 崩溃处理器
//     就挂在这条链上。VM 初始化期 HotSpot 还没装自己的 handler,它那些
//     "故意 fault 一下再自己接住"的探测(safepoint polling 等)会被当成真崩溃杀掉。
//   * libc 导出 `add_special_signal_handler(int, struct signal_chain_action*)`,
//     HotSpot 导出 `JVM_handle_linux_signal(int, siginfo_t*, void*, int)`
//     (jvm_md.h 里那个"给嵌入者用"的四参数入口,第四位是 abort_if_unrecognized)。
// 于是:起 VM 前把 SIGNAL_CHAIN_ACTION 注册到链上,收到同步硬件异常就 **转发** 给
// JVM 的入口;返回值 true = VM 认领了(init 期探测、polling page 等),false = 真故障。
//
// 两个必须照做的细节(都是踩过的坑,别改回去):
//   * 注册链之前先把 1..31 号信号的**普通**处置复位成 SIG_DFL:子进程从 app 主进程
//     继承了 DFX/ArkWeb 的一批 handler,不清掉会与 VM 自己的安装过程打架;
//   * 同步硬件异常**不能** SIG_IGN。未认领时不能只返回 false —— 那样会一路落到
//     VM 自己的 handler,而 VM 对未识别信号只是"不 abort 地返回"(0006 补丁),
//     等于让 CPU 反复重试同一条出错指令(信号死循环)。这里显式再调一次
//     JVM_handle_linux_signal(…, 1) 走它的致命报告路径,仍不返回就 _exit(128+sig)。
//
// ── 与宿主(procmgr)的接口约定 ──────────────────────────────────────────────
// 命令表里三条命令都指向本 .so,分别 dlsym 下面三个 extern "C" 符号;
// 入口签名与其它命令 so 一致:int(int argc, char** argv),argv[0] 保持命令名
// (`java` 会在 Bad option 之类的文案里用到它)。退出码按 procmgr 的约定走返回值,
// 但 Java 调 System.exit(n) 时是 VM 自己 os::exit(n),那条路不会回到这里。

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <ucontext.h>
#include <unistd.h>

#include <string>
#include <vector>

#include "jni.h"

namespace {

// ── 路径 / 常量 ────────────────────────────────────────────────────────────

// 随 HAP 打包的 .so 目录(运行时:feature/bsh_main/libs/arm64-v8a → 这里)。
// 与 procmgr.cpp 的 kBundledLibDir 是同一个位置,那边也拿它拼命令 so 的绝对路径。
constexpr const char* kBundledLibDir = "/data/storage/el1/bundle/libs/arm64";
// 只在 getenv("HOME") 取不到时兜底。真正的布局定义在应用侧
// feature/bsh_main/src/main/cpp/common/bsh_paths.h,改那里要同步这一行。
constexpr const char* kDefaultHome = "/data/storage/el2/base/haps/entry/files/home";

// JDK 数据根在**资源根**下(不是 $HOME):<sysroot>/jdk21。
// 资源根从环境变量 BSH_SYSROOT 取(宿主 shell.cpp 导出;见 common/bsh_paths.h),
// 取不到就退回 $HOME —— 那是改布局之前的形态。
constexpr const char* kJdkDirName = "jdk21";

// sun.launcher.LauncherHelper 里的私有 LM_* 常量(见 LauncherHelper.java)。
constexpr int kLmUnknown = 0;
constexpr int kLmClass = 1;
constexpr int kLmJar = 2;
constexpr int kLmModule = 3;
constexpr int kLmSource = 4;

// java.c 的 SOURCE_LAUNCHER_MAIN_ENTRY:java Foo.java 实际起的是它。
constexpr const char* kSourceLauncherMain =
    "jdk.compiler/com.sun.tools.javac.launcher.Main";

// USE_STDERR / USE_STDOUT:LauncherHelper 那些 print 方法的 printToStderr 实参。
constexpr jboolean kUseStderr = JNI_TRUE;
constexpr jboolean kUseStdout = JNI_FALSE;

enum Command { kCmdJava = 0, kCmdJavac, kCmdJar };

// ── 信号转发 ───────────────────────────────────────────────────────────────

// libc 的 `struct signal_chain_action`(musl 的 sigchain,MUSL-SIGCHAIN):
// 每条信号最多 4 个槽,单槽 144 字节 —— 8(函数指针)+128(sigset_t)+4(flags)+4(对齐)。
// 类里字段顺序/类型必须与之一致,否则 libc 复制进来的东西会被解释错。
struct SignalChainAction {
    bool (*sca_sigaction)(int, siginfo_t*, void*);
    sigset_t sca_mask;
    int sca_flags;
};

typedef int (*HotspotSignalHandler)(int, siginfo_t*, void*, int);

// libjvm 导出:按名字从**引导**加载器找类(等价 libjli 的 FindBootStrapClass)。
// 找不到符号就退回 JNI 的 FindClass(对 java.base 里的类是等价的)。
typedef jclass (*JVM_FindClassFromBootLoaderFn)(JNIEnv*, const char*);

HotspotSignalHandler g_jvmSignal = nullptr;
SignalChainAction g_chainAction{};   // 必须是静态的:libc 只存指针,不复制
bool g_signalBridgeReady = false;

// 转发给 HotSpot。返回值只认 VM 自己的判定(不能拿"PC 有没有变"当依据)。
bool ForwardToJvm(int sig, siginfo_t* info, void* context) {
    if (g_jvmSignal == nullptr || info == nullptr || context == nullptr) return false;
    const int saved_errno = errno;
    const int handled = g_jvmSignal(sig, info, context, /*abort_if_unrecognized=*/0);
    errno = saved_errno;
    return handled != 0;
}

// 链上的 special handler:VM 没认领 = 真硬件故障。
// 不能返回 false(会落到 VM 那个"不 abort"的普通 handler → 指令重试死循环),
// 而是再调一次 VM 入口、让它走官方致命路径(hs_err),仍不返回就直接死。
bool JvmSignalChainEntry(int sig, siginfo_t* info, void* context) {
    if (ForwardToJvm(sig, info, context)) return true;
    if (g_jvmSignal != nullptr && info != nullptr && context != nullptr) {
        const int saved_errno = errno;
        if (g_jvmSignal(sig, info, context, /*abort_if_unrecognized=*/1) != 0) {
            errno = saved_errno;
            return true;
        }
    }
    // 致命报告应该不返回;真返回了就不再空转。
    _exit(128 + sig);
}

// 没有 sigchain 时的兜底:普通 sigaction 处理器。功能上等价的"低优先级"版本,
// 用于链 API 不存在的 OHOS 版本(那时热点自己的 handler 装好前这些先顶着)。
void JvmSignalActionEntry(int sig, siginfo_t* info, void* context) {
    if (ForwardToJvm(sig, info, context)) return;
    signal(sig, SIG_DFL);
    raise(sig);
}

// 1..31 号信号的普通处置复位成默认。理由见文件头:子进程继承了 app 主进程
// 的一堆 handler(DFX/ArkWeb),不清掉会与 VM 自己装 handler 的过程互相干扰。
void ResetOrdinarySignalDispositions() {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sigemptyset(&sa.sa_mask);
    sa.sa_handler = SIG_DFL;
    for (int s = 1; s < 32; ++s) {
        if (s == SIGKILL || s == SIGSTOP) continue;
        sigaction(s, &sa, nullptr);
    }
}

// 起 VM 前把信号桥架好。libjvm 已经 dlopen、JVM_handle_linux_signal 已经 dlsym。
void InstallSignalBridge() {
    ResetOrdinarySignalDispositions();

    if (g_jvmSignal == nullptr) return;

    typedef void (*AddSpecialHandlerFn)(int, SignalChainAction*);
    auto addSpecial = reinterpret_cast<AddSpecialHandlerFn>(
        dlsym(RTLD_DEFAULT, "add_special_signal_handler"));

    if (addSpecial != nullptr) {
        sigemptyset(&g_chainAction.sca_mask);
        g_chainAction.sca_flags = 0;
        g_chainAction.sca_sigaction = &JvmSignalChainEntry;
        // 只接管 HotSpot 可能认领的同步硬件异常;异步终止/采样保持各自的所有者。
        // (SIGABRT 不在这里:它是 VM 主动 abort 的出口,交给默认处置更有信息量。)
        const int kSignals[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE};
        for (int sig : kSignals) addSpecial(sig, &g_chainAction);
        g_signalBridgeReady = true;
        return;
    }

    // 兜底:走普通 sigaction。
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sigemptyset(&sa.sa_mask);
    sa.sa_sigaction = &JvmSignalActionEntry;
    sa.sa_flags = SA_SIGINFO;
    const int kSignals[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE};
    for (int sig : kSignals) sigaction(sig, &sa, nullptr);
    g_signalBridgeReady = true;
}

// ── 启动器状态 ─────────────────────────────────────────────────────────────

struct LaunchState {
    int mode = kLmUnknown;
    std::string what;                     // 主类 / jar / module 名
    std::vector<std::string> appArgs;     // 传给应用的参数
    std::vector<std::string> vmOptions;   // 给 VM 的 JavaVMOption
    // 应用类路径(java.c 的 appclassv 那一坨):-cp/-classpath/--class-path 给的值,
    // -jar 时就是那个 jar,什么都没有时按 java 的规矩补 "."。空 = 不加 -Djava.class.path。
    std::string classpath;
    // 用户在命令行上自己给了 -Djava.class.path=…:那就不要再替他补默认的 "."。
    bool classPathOptionSeen = false;
    bool printVersion = false;
    bool showVersion = false;
    bool printUsage = false;
    bool printXUsage = false;
    bool toStdout = false;                // --version / --help 走 stdout,其余 stderr
    std::string showSettings;
};

// 匹配 `name` / `name=value`。返回 0 不匹配;1 匹配且**没有**值;2 匹配且值在
// '=' 之后(写进 *value)。
int MatchOpt(const std::string& arg, const char* name, std::string* value) {
    const size_t n = strlen(name);
    if (arg.compare(0, n, name) != 0) return 0;
    if (arg.size() == n) return 1;
    if (arg[n] == '=') {
        *value = arg.substr(n + 1);
        return 2;
    }
    return 0;
}

// 类路径通配符(与 java 一样:`-cp 'lib/*'` 展开成该目录下所有 .jar)。
// 没有 `*` 就直接原样返回 —— 绝大多数情况走这条。
std::string ExpandClasspathWildcards(const std::string& cp) {
    if (cp.find('*') == std::string::npos) return cp;
    std::string out;
    size_t pos = 0;
    while (pos <= cp.size()) {
        size_t colon = cp.find(':', pos);
        const bool last = (colon == std::string::npos);
        std::string entry = cp.substr(pos, last ? std::string::npos : colon - pos);
        bool expanded = false;
        if (!entry.empty() && entry[entry.size() - 1] == '*' &&
            (entry.size() == 1 || entry[entry.size() - 2] == '/')) {
            std::string dir = (entry.size() == 1) ? std::string(".")
                                                  : entry.substr(0, entry.size() - 2);
            DIR* d = opendir(dir.c_str());
            if (d != nullptr) {
                std::vector<std::string> jars;
                struct dirent* e;
                while ((e = readdir(d)) != nullptr) {
                    const std::string name = e->d_name;
                    if (name.size() > 4 &&
                        (name.compare(name.size() - 4, 4, ".jar") == 0 ||
                         name.compare(name.size() - 4, 4, ".JAR") == 0)) {
                        jars.push_back(dir + "/" + name);
                    }
                }
                closedir(d);
                for (size_t i = 0; i < jars.size(); ++i) {
                    if (!out.empty()) out += ':';
                    out += jars[i];
                }
                expanded = true;
            }
        }
        if (!expanded) {
            if (!out.empty() || pos > 0) out += ':';
            out += entry;
        }
        if (last) break;
        pos = colon + 1;
    }
    return out;
}

bool IsSourceFile(const char* arg) {
    if (arg == nullptr) return false;
    const size_t n = strlen(arg);
    if (n < 6 || strcmp(arg + n - 5, ".java") != 0) return false;
    struct stat st;
    return stat(arg, &st) == 0;
}

// 与 java.c 的 SetClassPath 对应(那边是立刻 AddOption,我们是攒到最后一起加)。
// 注意别在这里动 classPathOptionSeen:那个旗子只表示"用户显式写了
// -Djava.class.path=",用它判断要不要补默认的 "."。
void SetClasspath(LaunchState* st, const std::string& value) {
    st->classpath = ExpandClasspathWildcards(value);
}

// ── 启动器选项解析(java.c ParseArguments 的等价子集) ──────────────────────
//
// 支持: -cp/-classpath/--class-path、-jar、-m/--module、--module-path/-p 等模块系
//        长选项、-D/-X/-XX 透传、-version/--version/-showversion、-XshowSettings[:x]、
//        -help/--help/-X/--help-extra、-ms/-mx 这类老式堆选项、javac/jar 的 -J 前缀。
// 不支持(会得到 VM 自己的报错,或按下面的说明处理):
//        @argfile、--list-modules/--describe-module/--validate-modules/--dry-run。
//        这几个都要 LauncherHelper 的对应静态方法,真需要时再补。
bool ParseArguments(const std::vector<std::string>& args, LaunchState* st) {
    const int argc = (int)args.size();
    int i = 1;
    // 应用参数在 args 里的起点。只有"确定主入口"的那几处会推进它 —— 用下标而不是
    // 依赖循环变量 i,是因为 -jar/-m 要先吃掉自己的值再 break。
    int appStart = argc;
    for (; i < argc; ++i) {
        const std::string arg = args[i];
        if (arg.empty() || arg[0] != '-') break;   // 第一个非选项 = 主类/jar

        std::string value;
        int kind = 0;

        // -cp / -classpath / --class-path
        if ((kind = MatchOpt(arg, "-cp", &value)) ||
            (kind = MatchOpt(arg, "-classpath", &value)) ||
            (kind = MatchOpt(arg, "--class-path", &value))) {
            if (kind == 1) {
                if (i + 1 >= argc) return false;
                value = args[++i];
            }
            SetClasspath(st, value);
            if (st->mode == kLmUnknown) st->mode = kLmClass;
            continue;
        }

        if (MatchOpt(arg, "-jar", &value)) {
            if (i + 1 >= argc) return false;
            st->what = args[i + 1];
            appStart = i + 2;
            st->mode = kLmJar;
            break;
        }

        if ((kind = MatchOpt(arg, "-m", &value)) ||
            (kind = MatchOpt(arg, "--module", &value))) {
            if (kind == 1) {
                if (i + 1 >= argc) return false;
                value = args[i + 1];
                appStart = i + 2;
            } else {
                appStart = i + 1;
            }
            st->what = value;
            st->mode = kLmModule;
            break;
        }

        if ((kind = MatchOpt(arg, "--source", &value))) {
            if (kind == 1) {
                if (i + 1 >= argc) return false;
                value = args[++i];
            }
            st->vmOptions.push_back("-Djdk.internal.javac.source=" + value);
            st->mode = kLmSource;
            continue;
        }

        // 模块系"空白分隔"选项:短写要拼成 `--xxx=value` 再交给 VM。
        {
            static const char* kWhiteSpace[] = {
                "--module-path", "-p", "--upgrade-module-path", "--add-modules",
                "--enable-native-access", "--limit-modules", "--add-exports",
                "--add-opens", "--add-reads", "--patch-module",
            };
            bool handled = false;
            for (const char* name : kWhiteSpace) {
                kind = MatchOpt(arg, name, &value);
                if (kind == 0) continue;
                if (kind == 1) {
                    if (i + 1 >= argc) return false;
                    value = args[++i];
                }
                st->vmOptions.push_back(std::string(name) + "=" + value);
                handled = true;
                break;
            }
            if (handled) continue;
        }

        // 命中下面这些"打完就退"的选项后,后面的参数一律不再看(与 java.c 立即
        // return 的行为一致);i 直接推到末尾,免得后面的参数被当成主类。
        if (arg == "-version") {
            st->printVersion = true;
            i = argc;
            break;
        }
        if (arg == "--version") {
            st->printVersion = true;
            st->toStdout = true;
            i = argc;
            break;
        }
        if (arg == "-showversion") { st->showVersion = true; continue; }
        if (arg == "--show-version") {
            st->showVersion = true;
            st->toStdout = true;
            continue;
        }
        if (arg == "-help" || arg == "-h" || arg == "-?" || arg == "--help") {
            st->printUsage = true;
            if (arg == "--help") st->toStdout = true;
            i = argc;
            break;
        }
        if (arg == "-X" || arg == "--help-extra") {
            st->printXUsage = true;
            if (arg == "--help-extra") st->toStdout = true;
            i = argc;
            break;
        }
        if (arg == "-XshowSettings" ||
            arg.compare(0, strlen("-XshowSettings:"), "-XshowSettings:") == 0) {
            st->showSettings = arg;
            continue;
        }
        if (arg == "-Xdiag") {
            st->vmOptions.push_back("-Dsun.java.launcher.diag=true");
            continue;
        }
        if (arg == "--show-module-resolution") {
            st->vmOptions.push_back("-Djdk.module.showModuleResolution=true");
            continue;
        }
        if (arg == "-verbosegc") { st->vmOptions.push_back("-verbose:gc"); continue; }
        if (arg == "-debug") { st->vmOptions.push_back("-Xdebug"); continue; }
        if (arg == "-noclassgc") { st->vmOptions.push_back("-Xnoclassgc"); continue; }
        if (arg == "-verify" || arg == "-Xfuture") {
            st->vmOptions.push_back("-Xverify:all");
            continue;
        }
        if (arg == "-verifyremote") { st->vmOptions.push_back("-Xverify:remote"); continue; }
        if (arg == "-noverify") { st->vmOptions.push_back("-Xverify:none"); continue; }
        if (arg.compare(0, 5, "-splash") == 0) continue;   // 老启动画面参数,忽略
        // -ss/-oss/-ms/-mx<size> → -Xss/-Xoss/-Xms/-Xmx<size>
        if (arg.size() > 3 &&
            (arg.compare(0, 3, "-ss") == 0 || arg.compare(0, 4, "-oss") == 0 ||
             arg.compare(0, 3, "-ms") == 0 || arg.compare(0, 3, "-mx") == 0)) {
            st->vmOptions.push_back("-X" + arg.substr(1));
            continue;
        }

        // 其余一律当 VM 选项透传(-D / -X / -XX / --add-opens=… 等)。
        if (arg.compare(0, strlen("-Djava.class.path="), "-Djava.class.path=") == 0)
            st->classPathOptionSeen = true;
        st->vmOptions.push_back(arg);
    }

    // 第一个非选项参数就是主类/-jar 值还没定的话,它就是主类。
    if (st->what.empty() && i < argc) {
        st->what = args[i];
        appStart = i + 1;
    }
    for (int k = appStart; k < argc; ++k) st->appArgs.push_back(args[k]);

    // 与 java.c 一样:-jar 的应用类路径就是那个 jar(否则应用类加载器找不到主类)。
    if (st->mode == kLmJar) SetClasspath(st, st->what);

    if (!st->what.empty()) {
        if (st->mode == kLmUnknown) {
            if (!st->classPathOptionSeen) SetClasspath(st, ".");
            st->mode = IsSourceFile(st->what.c_str()) ? kLmSource : kLmClass;
        } else if (st->mode == kLmClass && IsSourceFile(st->what.c_str())) {
            st->mode = kLmSource;
        }
    }

    if (st->mode == kLmSource) {
        // java.c:把源文件名塞回应用参数的开头,主类换成 source launcher 的入口。
        st->vmOptions.push_back("--add-modules=ALL-DEFAULT");
        st->appArgs.insert(st->appArgs.begin(), st->what);
        st->what = kSourceLauncherMain;
    }
    return true;
}

// ── JavaVMOption ───────────────────────────────────────────────────────────

class VmOptionStore {
public:
    void Add(const std::string& s) { entries_.push_back({s, nullptr}); }
    // JNI 钩子("exit"/"abort"/"vfprintf"):optionString 只写钩子名,
    // 函数指针走 extraInfo —— 这是 HotSpot 给嵌入者留的那条口子。
    void AddHook(const std::string& name, void* fn) { entries_.push_back({name, fn}); }
    std::vector<JavaVMOption>& options() {
        options_.clear();
        for (auto& e : entries_) {
            JavaVMOption o;
            o.optionString = const_cast<char*>(e.first.c_str());
            o.extraInfo = e.second;
            options_.push_back(o);
        }
        return options_;
    }

private:
    std::vector<std::pair<std::string, void*>> entries_;
    std::vector<JavaVMOption> options_;
};

// ── 走到 Java 侧的那几步(与 libjli/java.c 的 JavaMain 一一对应) ─────────────

jclass FindBootClass(JNIEnv* env, JVM_FindClassFromBootLoaderFn fromBoot,
                     const char* name) {
    if (fromBoot != nullptr) {
        jclass c = fromBoot(env, name);
        if (c != nullptr) return c;
        if (env->ExceptionOccurred()) env->ExceptionClear();
    }
    return env->FindClass(name);
}

// 与 libjli 一样走 LauncherHelper.makePlatformString:参数字节 → 平台字符串,
// 它经 sun.jnu.encoding 转换,不是简单的 NewStringUTF。
jstring NewPlatformString(JNIEnv* env, jclass helper, const std::string& s) {
    jbyteArray bytes = env->NewByteArray((jsize)s.size());
    if (bytes == nullptr) return nullptr;
    env->SetByteArrayRegion(bytes, 0, (jsize)s.size(), (const jbyte*)s.data());
    if (env->ExceptionOccurred()) return nullptr;
    jmethodID mid = env->GetStaticMethodID(helper, "makePlatformString",
                                          "(Z[B)Ljava/lang/String;");
    if (mid == nullptr) return nullptr;
    jstring str = (jstring)env->CallStaticObjectMethod(helper, mid, kUseStderr, bytes);
    env->DeleteLocalRef(bytes);
    return str;
}

jclass LoadMainClass(JNIEnv* env, jclass helper, int mode, const std::string& what) {
    jmethodID mid = env->GetStaticMethodID(helper, "checkAndLoadMain",
                                          "(ZILjava/lang/String;)Ljava/lang/Class;");
    if (mid == nullptr) return nullptr;
    jstring name = NewPlatformString(env, helper, what);
    if (name == nullptr) return nullptr;
    jobject cls = env->CallStaticObjectMethod(helper, mid, kUseStderr, (jint)mode, name);
    env->DeleteLocalRef(name);
    if (env->ExceptionOccurred()) return nullptr;
    return (jclass)cls;
}

jobjectArray NewPlatformStringArray(JNIEnv* env, jclass helper,
                                    const std::vector<std::string>& strs) {
    jclass stringCls = env->FindClass("java/lang/String");
    if (stringCls == nullptr) return nullptr;
    jobjectArray ary = env->NewObjectArray((jsize)strs.size(), stringCls, nullptr);
    if (ary == nullptr) return nullptr;
    for (size_t i = 0; i < strs.size(); ++i) {
        jstring s = NewPlatformString(env, helper, strs[i]);
        if (s == nullptr) return nullptr;
        env->SetObjectArrayElement(ary, (jsize)i, s);
        env->DeleteLocalRef(s);
    }
    return ary;
}

void PrintJavaVersion(JNIEnv* env, JVM_FindClassFromBootLoaderFn fromBoot,
                      bool toStdout) {
    jclass cls = FindBootClass(env, fromBoot, "java/lang/VersionProps");
    if (cls == nullptr) return;
    jmethodID mid = env->GetStaticMethodID(cls, "print", "(Z)V");
    if (mid == nullptr) return;
    env->CallStaticVoidMethod(cls, mid, toStdout ? kUseStdout : kUseStderr);
}

void ShowSettings(JNIEnv* env, jclass helper, const std::string& option) {
    jmethodID mid = env->GetStaticMethodID(helper, "showSettings", "(ZLjava/lang/String;JJJ)V");
    if (mid == nullptr) return;
    jstring s = env->NewStringUTF(option.c_str());
    env->CallStaticVoidMethod(helper, mid, kUseStderr, s, (jlong)0, (jlong)0, (jlong)0);
    if (s != nullptr) env->DeleteLocalRef(s);
}

void PrintUsage(JNIEnv* env, jclass helper, bool xUsage, bool toStdout) {
    const char* method = xUsage ? "printXUsageMessage" : "printHelpMessage";
    jmethodID mid = env->GetStaticMethodID(helper, method, "(Z)V");
    if (mid == nullptr) return;
    env->CallStaticVoidMethod(helper, mid, toStdout ? kUseStdout : kUseStderr);
}

void ReportException(JNIEnv* env) {
    if (env->ExceptionOccurred()) env->ExceptionDescribe();
}

// ── 退出码:靠 JVM 自己的 exit hook ─────────────────────────────────────────
//
// 症状  凡是 Java 侧 System.exit(n) / LauncherHelper 的 abort 走掉的那条路,
//       进程退出码一律变成 0(javac 语法错误、找不到主类、System.exit(7) 全都 rc=0)。
// 根因  与 procmgr 里 `--wrap=exit` 那条注释写的是同一件事:命令 so 跑在宿主的
//       fork 子进程里,而宿主主进程在 fork 之前就注册了一堆 atexit(ArkTS/NAPI 收尾)。
//       HotSpot 的 System.exit → vm_exit → os::exit → libc exit() 会把那些 handler
//       跑起来,进程最后以 0 收场,真是退出码被丢在中间。
//       其它命令 so 的解法是链接期 `-Wl,--wrap=exit`;libjvm.so 是预先编好的,
//       没法重链,而且我们在全局符号表里抢不过更早加载的 libc。
// 修法  用 HotSpot 给嵌入者留的钩子:Arguments::parse_each_vm_init_arg() 里有一条
//         } else if (match_option(option, "exit")) { _exit_hook = option->extraInfo; }
//       (同族的还有 "vfprintf" / "abort")。VM_Exit::doit() 收尾时会调它,注释写明
//       "exit hook should exit"。我们注册一个 fflush + _exit(code) 的实现,
//       退出码就由我们说了算,顺带也对齐了项目里 __wrap_exit 的语义。
// 函数体在 TraceEnabled/TraceLoadedLibs 之后(钩子里也顺带打一份已加载的 .so:
// javac/jar 这些 System.exit 掉的路只经过钩子、不经过 leave())。

// 诊断开关:把 VM 选项与已加载的 .so 打到 stderr。
// 用来回答"跑 java -version/javac/jar 到底加载了哪些 JDK native 库"(判定哪些
// java.desktop 的 .so 可以不带);平时零开销、零输出。
//
// 触发方式是环境变量 BSH_JAVA_TRACE_LIBS **或** $HOME/.jdk-trace 这个文件。
// 为什么还要文件:宿主(procmgr)起子进程时用的是主进程的 environ,
// 终端里 `VAR=1 java …` 那种前缀赋值透不到命令进程(见 procmgr/bsh_exec.c),
// 所以设备上给自己开诊断只能靠一个文件。
std::string HomeDir() {
    const char* home = getenv("HOME");
    return (home != nullptr && *home != '\0') ? home : kDefaultHome;
}

/* **资源根**(宿主 shell.cpp 从 BSH_SYSROOT 注入,见 common/bsh_paths.h):
 * JDK 的数据在它下面(jdk21/);$HOME 是它下面那个 home/,两者不能混用。 */
std::string SysrootDir() {
    const char* root = getenv("BSH_SYSROOT");
    if (root != nullptr && *root != '\0') return root;
    return HomeDir();   // 旧布局(资源根就是 $HOME)时的兜底
}

bool TraceEnabled(const std::string& homeDir) {
    if (getenv("BSH_JAVA_TRACE_LIBS") != nullptr) return true;
    return access((homeDir + "/.jdk-trace").c_str(), F_OK) == 0;
}

void TraceLoadedLibs(bool enabled, const std::string& homeDir, const char* phase) {
    if (!enabled) return;
    // 用 /proc/self/maps 而不是 dl_iterate_phdr:OHOS 的 linker 有 namespace,
    // dl_iterate_phdr 只列出 appspawn/dfx 那几个(实测 JDK 的一个都看不到)。
    //
    // 同时把**原始** maps 追加到 $HOME/.jdk-maps.txt:maps 行里路径后面偶尔还跟
    // 着别的东西(例如 `…libabilitystage.z.so_15392_1]`),当场解析容易看不全;
    // 落一份原文,事后 grep 才查得清"到底加载了哪些 .so"。
    FILE* f = fopen("/proc/self/maps", "re");
    fprintf(stderr, "[bsh-java] libraries mapped into this process (%s):\n", phase);
    if (f == nullptr) {
        fprintf(stderr, "  (打不开 /proc/self/maps: %s)\n", strerror(errno));
        return;
    }
    FILE* dump = fopen((homeDir + "/.jdk-maps.txt").c_str(), "ae");
    if (dump != nullptr) fprintf(dump, "=== pid %d (%s) ===\n", (int)getpid(), phase);
    char line[1024];
    std::string seen;
    while (fgets(line, sizeof line, f) != nullptr) {
        if (dump != nullptr) fputs(line, dump);
        // 只看应用自己随 HAP 带进来的那批(JDK 的 .so 都在里面)。
        char* p = strstr(line, "/data/storage/");
        if (p == nullptr) continue;
        std::string path(p);
        while (!path.empty() && (path.back() == '\n' || path.back() == ' '))
            path.pop_back();
        if (path.find(".so") == std::string::npos) continue;
        if (seen.find("\n" + path + "\n") != std::string::npos) continue;
        seen += "\n" + path + "\n";
        fprintf(stderr, "  %s\n", path.c_str());
    }
    if (dump != nullptr) fclose(dump);
    fclose(f);
}

// 退出码钩子(注释见上面「退出码」那段)。VM_Exit::doit() 收尾时调它。
// 诊断开着时顺带打一份已加载的 .so:javac/jar 这些 System.exit 掉的路只经过钩子、
// 不经过 leave(),不在这里打就看不到它们的 native 库清单。
void BshExitHook(jint code) {
    const std::string homeDir = HomeDir();
    if (TraceEnabled(homeDir)) TraceLoadedLibs(true, homeDir, "at exit hook");
    fflush(nullptr);              // 直接 _exit 会丢掉还在 stdio 缓冲里的输出
    _exit((int)code & 0xFF);
}

// ── 主流程 ─────────────────────────────────────────────────────────────────

int RunCommand(Command cmd, int argc, char** argv) {
    const std::string homeDir = HomeDir();
    const std::string javaHome = SysrootDir() + "/" + kJdkDirName;
    const std::string libDir = kBundledLibDir;
    const std::string jvmPath = libDir + "/libjvm.so";

    // 三条命令的 argv 都保持用户敲的那个命令名(java/javac/jar):
    // 报错文案、usage 里的程序名都用它。
    std::vector<std::string> args;
    args.push_back((argc > 0 && argv[0] != nullptr && argv[0][0] != '\0') ? argv[0]
                                                                         : "java");
    // javac / jar 等价于 `java <launcher args> <用户参数>`(见 make/common/modules/
    // LauncherCommon.gmk 的 SetupBuildLauncher:MAIN_CLASS 会被编成 -m <mod>/<class>)。
    if (cmd == kCmdJavac) {
        args.push_back("--add-modules");
        args.push_back("ALL-DEFAULT");
        args.push_back("-m");
        args.push_back("jdk.compiler/com.sun.tools.javac.Main");
    } else if (cmd == kCmdJar) {
        args.push_back("-ms8m");
        args.push_back("-m");
        args.push_back("jdk.jartool/sun.tools.jar.Main");
    }
    for (int i = 1; i < argc; ++i) {
        const char* a = argv[i];
        if (a == nullptr) continue;
        // javac/jar 的 -J<vmopt>:透传给 VM(与 JDK 的 TranslateApplicationArgs 一致)。
        if (cmd != kCmdJava && a[0] == '-' && a[1] == 'J' && a[2] != '\0') {
            args.push_back(std::string("-") + (a + 2));
            continue;
        }
        args.push_back(a);
    }

    LaunchState st;
    if (!ParseArguments(args, &st)) {
        fprintf(stderr, "%s: option requires an argument\n", args[0].c_str());
        return 1;
    }

    // 环境变量必须在 JNI_CreateJavaVM 之前落:0003/0004 两个补丁让 HotSpot 从这里读
    // dll_dir 与 java.home。LD_LIBRARY_PATH 只当保险(musl 在进程启动时就缓存了搜索
    // 路径,setenv 改不动它;真正靠得住的是 libjvm.so 的 RPATH=$ORIGIN 与全局符号表)。
    setenv("JAVA_HOME", javaHome.c_str(), 1);
    setenv("SUN_BOOT_LIBRARY_PATH", libDir.c_str(), 1);
    setenv("LD_LIBRARY_PATH", libDir.c_str(), 1);
    // java.io.tmpdir 落在 $HOME 下(沙箱里 /tmp 不一定可写),顺手建出来。
    const std::string tmpDir = homeDir + "/tmp";
    mkdir(tmpDir.c_str(), 0755);

    VmOptionStore opts;
    opts.Add("-Djava.home=" + javaHome);
    opts.Add("-Dsun.boot.library.path=" + libDir);
    opts.Add("-Djava.library.path=" + libDir);
    opts.Add("-Duser.home=" + homeDir);
    opts.Add("-Djava.io.tmpdir=" + tmpDir);
    // musl 的默认 locale 报 ASCII,不钉死会让含非 ASCII 的路径/classpath 坏掉。
    opts.Add("-Dfile.encoding=UTF-8");
    opts.Add("-Dsun.jnu.encoding=UTF-8");
    // headless:没有 X11/xawt,java.desktop 的 native 库我们一个都没带。
    opts.Add("-Djava.awt.headless=true");
    // 鸿蒙沙箱里 /dev/random 不可达,SecureRandom 播种会卡住;绕开 JDK 对
    // "file:/dev/urandom" 的特判,直接去开这个文件。
    opts.Add("-Djava.security.egd=file:/dev/./urandom");
    // 某些设备的 C2 会生成 SVE 指令 → SIGILL。
    opts.Add("-XX:UseSVE=0");
    // hsperfdata 要写目录,CLI 用不上,关掉省事。
    opts.Add("-XX:-UsePerfData");
    // 鸿蒙上 primordial thread 的栈 guard page 分配失败会变成随机崩溃(与 amcl 同款处置)。
    opts.Add("-XX:+UnlockExperimentalVMOptions");
    opts.Add("-XX:+DisablePrimordialThreadGuardPages");

    for (const std::string& o : st.vmOptions) opts.Add(o);

    // 与 java.c 同序:解析完才补 java.class.path / sun.java.command / sun.java.launcher。
    // 放在用户参数之后,所以 -jar / -cp 算出来的类路径会盖掉用户自己写的
    // -Djava.class.path(与 java 一致:命令行上后出现的那个赢)。
    if (!st.classpath.empty())
        opts.Add("-Djava.class.path=" + st.classpath);
    if (!st.what.empty()) {
        std::string cmdline = st.what;
        for (const std::string& a : st.appArgs) cmdline += " " + a;
        opts.Add("-Dsun.java.command=" + cmdline);
    }
    opts.Add("-Dsun.java.launcher=SUN_STANDARD");
    // 退出码专用钩子(见 BshExitHook 的注释)。放在最后只是习惯,顺序不影响。
    opts.AddHook("exit", reinterpret_cast<void*>(&BshExitHook));

    // 选好之后一次性物化(JavaVMOption.optionString 指向strings_ 里持久存在的
    // std::string,到这里不再新增,指针才稳)。
    std::vector<JavaVMOption>& options = opts.options();

    const bool trace = TraceEnabled(homeDir);
    if (trace) {
        fprintf(stderr, "[bsh-java] java.home=%s\n[bsh-java] libs=%s\n[bsh-java] options:\n",
                javaHome.c_str(), libDir.c_str());
        for (const JavaVMOption& o : options)
            fprintf(stderr, "[bsh-java]   %s\n", o.optionString);
    }

    if (access(jvmPath.c_str(), R_OK) != 0) {
        fprintf(stderr,
                "%s: libjvm.so not found at %s\n"
                "        (HAP 里的 feature/bsh_main/libs/arm64-v8a 没带上 libjvm.so?)\n",
                args[0].c_str(), jvmPath.c_str());
        return 1;
    }

    // RTLD_GLOBAL:libjava/libzip/libjimage 都 NEEDED libjvm.so,符号要靠全局作用域
    // 复用已经加载的那一份;libjvm.so 自身的 libcxxabi_shim.so 由它的 RPATH=$ORIGIN
    // 在同一个目录里解析。
    void* jvmHandle = dlopen(jvmPath.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (jvmHandle == nullptr) {
        fprintf(stderr, "%s: cannot dlopen %s: %s\n", args[0].c_str(), jvmPath.c_str(),
                dlerror());
        return 1;
    }

    auto createVm = reinterpret_cast<jint (*)(JavaVM**, void**, void*)>(
        dlsym(jvmHandle, "JNI_CreateJavaVM"));
    if (createVm == nullptr) {
        fprintf(stderr, "%s: JNI_CreateJavaVM not found in %s\n", args[0].c_str(),
                jvmPath.c_str());
        return 1;
    }
    auto fromBoot = reinterpret_cast<JVM_FindClassFromBootLoaderFn>(
        dlsym(jvmHandle, "JVM_FindClassFromBootLoader"));
    g_jvmSignal = reinterpret_cast<HotspotSignalHandler>(
        dlsym(jvmHandle, "JVM_handle_linux_signal"));
    InstallSignalBridge();

    JavaVMInitArgs vmArgs;
    memset(&vmArgs, 0, sizeof vmArgs);
    vmArgs.version = JNI_VERSION_10;
    vmArgs.nOptions = (jint)options.size();
    vmArgs.options = options.empty() ? nullptr : options.data();
    vmArgs.ignoreUnrecognized = JNI_FALSE;   // 与 JLI 一致:坏选项要报错而不是被吞

    JavaVM* vm = nullptr;
    JNIEnv* env = nullptr;
    jint rc = createVm(&vm, (void**)&env, &vmArgs);
    if (rc != JNI_OK || env == nullptr) {
        fprintf(stderr, "%s: JNI_CreateJavaVM failed (rc=%d)\n", args[0].c_str(), (int)rc);
        return 1;
    }
    if (trace)
        fprintf(stderr, "[bsh-java] signal bridge: %s\n",
                g_jvmSignal != nullptr ? (g_signalBridgeReady ? "ready" : "not installed")
                                       : "unavailable");

    int ret = 0;
    jclass helper = FindBootClass(env, fromBoot, "sun/launcher/LauncherHelper");

    auto leave = [&](int code) -> int {
        if (vm->DetachCurrentThread() != JNI_OK) code = 1;
        TraceLoadedLibs(trace, homeDir, "after main");
        vm->DestroyJavaVM();
        return code;
    };

    if (!st.showSettings.empty()) {
        if (helper != nullptr) ShowSettings(env, helper, st.showSettings);
        if (env->ExceptionOccurred()) {
            ReportException(env);
            return leave(1);
        }
    }

    if (st.printVersion || st.showVersion) {
        PrintJavaVersion(env, fromBoot, st.toStdout);
        if (env->ExceptionOccurred()) {
            ReportException(env);
            return leave(0);
        }
        if (st.printVersion) return leave(0);   // -version:打完就退,ret=0
    }

    if (st.printXUsage || st.printUsage || st.what.empty() || st.mode == kLmUnknown) {
        if (helper != nullptr) PrintUsage(env, helper, st.printXUsage, st.toStdout);
        return leave(1);
    }

    ret = 1;
    jclass mainClass = LoadMainClass(env, helper, st.mode, st.what);
    if (env->ExceptionOccurred() || mainClass == nullptr) {
        ReportException(env);
        return leave(1);
    }

    jobjectArray mainArgs = NewPlatformStringArray(env, helper, st.appArgs);
    if (env->ExceptionOccurred() || mainArgs == nullptr) {
        ReportException(env);
        return leave(1);
    }

    // getMainType() 告诉我们是 static void main(String[]) 还是别的形态(无参/non-static)。
    jmethodID getMainType = env->GetStaticMethodID(helper, "getMainType", "()I");
    if (getMainType == nullptr) {
        ReportException(env);
        return leave(1);
    }
    const int mainType = env->CallStaticIntMethod(helper, getMainType);
    if (env->ExceptionOccurred()) {
        ReportException(env);
        return leave(1);
    }

    // MAIN_WITHOUT_ARGS = 1, MAIN_NONSTATIC = 2(见 java.c 的同名宏)。
    const int hasArgs = (mainType & 1) ? 0 : 1;
    const int isStatic = (mainType & 2) ? 0 : 1;
    jobject mainObject = nullptr;
    if (!isStatic) {
        jmethodID ctor = env->GetMethodID(mainClass, "<init>", "()V");
        if (ctor == nullptr) {
            ReportException(env);
            return leave(1);
        }
        mainObject = env->NewObject(mainClass, ctor);
    }
    jmethodID mainId = isStatic
        ? env->GetStaticMethodID(mainClass, "main", hasArgs ? "([Ljava/lang/String;)V" : "()V")
        : env->GetMethodID(mainClass, "main", hasArgs ? "([Ljava/lang/String;)V" : "()V");
    if (mainId == nullptr) {
        ReportException(env);
        return leave(1);
    }
    if (isStatic) {
        if (hasArgs) env->CallStaticVoidMethod(mainClass, mainId, mainArgs);
        else env->CallStaticVoidMethod(mainClass, mainId);
    } else {
        if (hasArgs) env->CallVoidMethod(mainObject, mainId, mainArgs);
        else env->CallVoidMethod(mainObject, mainId);
    }

    // 没调 System.exit 才会走到这:main 抛异常 → 退出码 1(与 java 一致)。
    ret = env->ExceptionOccurred() != nullptr ? 1 : 0;
    return leave(ret);
}

}  // namespace

// procmgr 命令表里的三个入口(同一个 .so,三个符号)。
extern "C" int bsh_java_main(int argc, char** argv) {
    return RunCommand(kCmdJava, argc, argv);
}

extern "C" int bsh_javac_main(int argc, char** argv) {
    return RunCommand(kCmdJavac, argc, argv);
}

extern "C" int bsh_jar_main(int argc, char** argv) {
    return RunCommand(kCmdJar, argc, argv);
}
