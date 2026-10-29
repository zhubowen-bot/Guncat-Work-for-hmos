// procmgr/command_map.c — 命令表实现
//
// 这是 procmgr 的决策数据:命中 → kSoMain(dlopen 对应 so + 调入口符号),
// 未命中 → kElf(交 elfloader 按 ELF 装载)。
//
// 表现在还有第二个身份：**命令启动器文件的生成器** —— shell.cpp 在会话启动时按它
// 往 $SYSROOT/bin 写一批 "#BSHSO" 文件（cmd_make_launchers），之后 procmgr 见到
// 那种文件就照里面写的 so/入口/参数个数起进程（Resolve 第 1.5 步）。
// 换句话说：命令集正在从"编译期数据"变成"磁盘上的数据"，表暂时只当生成器用。
//
// 内容:
//   - hellobsh: BetterSH HelloWorld 程序;
//   - toybox multicall:ls/cat/… 共用一个 libtoybox.so + bsh_toybox_main;
//   - sh(mksh); vim; fastfetch; python; wayland 客户端;
//     so 未打进 HAP 时 dlopen 失败 → 表现为 command not found。
#include "command_map.h"

#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define TOY(name) { name, "libtoybox.so", "bsh_toybox_main" }

static const struct CommandEntry kMap[] = {
    /* Hello World */
    {"hellobsh",        "libhellobsh.so",   "main"},

    /* bshutil:改 BetterSH 自己的设置客户端。 */
    {"bshutil",         "libbshutil.so",    "bshutil_main"},

    /* sh(mksh,so 化,后续接入) */
    {"sh",              "libmksh.so",       "main"},

    /* toybox applet 子集(全量清单可由构建脚本从 toybox toys.list 生成) */
    TOY("ls"), TOY("cat"), TOY("echo"), TOY("grep"), TOY("egrep"),
    TOY("fgrep"), TOY("sed"), TOY("awk"), TOY("cp"), TOY("mv"),
    TOY("rm"), TOY("mkdir"), TOY("rmdir"), TOY("touch"), TOY("ln"),
    TOY("chmod"), TOY("chown"), TOY("head"), TOY("tail"), TOY("wc"),
    TOY("sort"), TOY("uniq"), TOY("tr"), TOY("cut"), TOY("tee"),
    TOY("xargs"), TOY("find"), TOY("which"), TOY("env"), TOY("printenv"),
    TOY("pwd"), TOY("true"), TOY("false"), TOY("yes"), TOY("sleep"),
    TOY("date"), TOY("uname"), TOY("id"), TOY("whoami"), TOY("ps"),
    TOY("kill"), TOY("free"), TOY("df"), TOY("du"), TOY("tar"),
    TOY("clear"), TOY("reset"), TOY("stty"),
    TOY("readlink"), TOY("dirname"), TOY("basename"), TOY("realpath"),
    TOY("printf"),
    /* timeout 必须登记到我们自己这份:系统 /bin/timeout 会 fork+exec 子命令,而它 exec
     * 到的是 $SYSROOT/bin 下那些 `#BSHSO` 启动器(纯文本),内核直接 ENOEXEC ——
     * 实测 `timeout 3 echo hi` → "timeout: exec echo: Exec format error"(rc=126)。
     * 走我们的 toybox 则在进程内分发、子命令经 exec shim 交给 procmgr,一切都对。 */
    TOY("timeout"),
    /* 文件系统/压缩/网络类(旧工程也有;能否用取决于 toybox 编入的 applet) */
    TOY("mount"), TOY("umount"), TOY("gzip"), TOY("gunzip"), TOY("zcat"),
    TOY("wget"), TOY("ping"), TOY("netstat"), TOY("ifconfig"),
    /* multicall 入口本身:`toybox` 列出 built-in applet,`toybox <applet> …` 调用 */
    TOY("toybox"),

    /* clang 编译链 (LLVM so 化后;内部 -cc1 经 exec 委托本表) */
    /* (libclangbsh.so / liblld.so)已从项目移除，编 aarch64 改走 pkg 的
     * `ohos-sdk-prune` 包 —— 里面是可执行的 clang/lld，按路径/加进 PATH 直接跑。 */
    // {"clang",           "libclangbsh.so",   "main"},
    // {"clang++",         "libclangbsh.so",   "main"},
    // {"ld.lld",          "liblld.so",        "main"},
    // {"lld",             "liblld.so",        "main"},

    /* 其他应用 */
    {"vim",             "libvim.so",        "main"},
    {"vi",              "libvim.so",        "main"},
    {"guiduo",          "libguiduo.so",     "main"},
    {"fastfetch",       "libfastfetch.so",  "main"},

    /* 包管理器（见 scripts 之外的 entry/src/main/cpp/programs/pkg/）：下载走 mbedTLS
     * （编在这个 so 里）、解包走自带的 tar 实现；包源默认 https://bsh.y1yan.com/，
     * 可用 `pkg source <url>` 改。 */
    {"pkg",             "libpkg.so",        "pkg_main"},
    /* `zstd`：只做解压，跟 pkg 共用 libpkg.so（同一份 libzstd 静态库，见
     * programs/pkg/zstd_main.c）。用处是把官方 .deb 里的 data.tar.zst 解成 .tar ——
     * 设备上没有 ar/python3/toybox-zstd，`code --download` 只能靠它 + toybox tar。 */
    {"zstd",            "libpkg.so",        "zstd_main"},
    /* apt：从 Ubuntu/Debian 镜像装 .deb（自动解析依赖树、下依赖、解包、代偿软链）。
     * 与 pkg 共用 libpkg.so —— mbedTLS/http/tar/zstd 已经都在里面了，见
     * programs/pkg/apt_main.c 的文件头。镜像地址由 BSH_APT_MIRROR 指定。 */
    {"apt",             "libpkg.so",        "apt_main"},

    /* CPython 3.12(模块全静态内置;入口用 PyAPI 的 Py_BytesMain —— 核心对象带
     * -fvisibility=hidden,Programs/python.c 里的 main 是局部符号) */
    {"python",          "libpython.so",     "Py_BytesMain"},
    {"python3",         "libpython.so",     "Py_BytesMain"},
    /* pip:同一个 so,但要把 argv 拼成 `python -m pip …`,所以走自己的薄入口
     * (scripts/python-ohos/bsh_pip_entry.c,编进 libpython.so 的链接行)。 */
    {"pip",             "libpython.so",     "bsh_pip_main"},
    
    /* Wayland 冒烟客户端(画一帧后退出;连接经 BSH_WL_FD 交内嵌 compositor) */
    {"wldemo",          "libwldemo.so",     "main"},

    /* Qt6 wayland 客户端示例(QApplication+QWidget;Qt 栈与 QPA/shell-integration
     * 插件见 scripts/build_qt.sh,插件由 QT_PLUGIN_PATH 平扫加载) */
    /* 现在不再默认提供。 */
    // {"qtwl-demo",       "libqtwl-demo.so",  "main"},

    /* SSH(dropbear 五合一,见 scripts/build_dropbear.sh):一个 so 按 argv[0]
     * 分发到各程序 —— dbmulti.c 认 "ssh"→dbclient、"ssh-keygen"→dropbearkey */
    {"ssh",             "libsshcore.so",    "bsh_dropbear_main"},
    {"dbclient",        "libsshcore.so",    "bsh_dropbear_main"},
    {"scp",             "libsshcore.so",    "bsh_dropbear_main"},
    {"ssh-keygen",      "libsshcore.so",    "bsh_dropbear_main"},
    {"dropbearkey",     "libsshcore.so",    "bsh_dropbear_main"},
    {"dropbearconvert", "libsshcore.so",    "bsh_dropbear_main"},
    {"dropbear",        "libsshcore.so",    "bsh_dropbear_main"},

    /* qemu-user(TCI + .so 形态,见 scripts/build_qemu.sh 的 so 变体):跑 Linux ELF
     * 的用户态仿真。走 kSoMain(dlopen)**不需要可写可执行内存**,是无 JIT 设备上
     * 唯一可行的执行路径;入口是包装过的 qemu_entry(argc, argv)。 */
    {"qemu-aarch64",    "libqemu-aarch64.so", "qemu_entry"},
    {"qemu-x86_64",     "libqemu-x86_64.so",  "qemu_entry"},

    /* box64(x86_64→ARM64 动态翻译器,见 scripts/build_box64.sh):跑 x86_64 Linux
     * ELF。dynarec 要可执行内存,所以比 qemu 的 TCI 快得多;入口是包装过的
     * bsh_box64_entry(argc, argv) —— box64_run 是三参数,包装层补 environ。 */
    {"box64",           "libbox64.so",        "bsh_box64_entry"},

    /* Node.js(见 scripts/build_node.sh):node 源码以 --shared 编出 libnode.so,
     * 再由我们重链一遍,补上 C 入口 bsh_node_main(guest 侧就是 node::Start)
     * 与 exec 委托(child_process / npm lifecycle 的 spawn 要走命令表)。 */
    {"node",            "libnode.so",         "bsh_node_main"},
    {"nodejs",          "libnode.so",         "bsh_node_main"},
    /* npm / npx:入口是 JS,由 bsh_npm_main 拼成
     * [node, $HOME/npm/bin/npm-cli.js, …] 再交给 node::Start。
     * JS 树本身是 rawfile/tools/npm.tar,启动时解到 $HOME/npm。 */
    {"npm",             "libnode.so",         "bsh_npm_main"},
    {"npx",             "libnode.so",         "bsh_npx_main"},

    /* OpenJDK 21(java / javac / jar,见 scripts/build_jdk.sh 与
     * scripts/jdk-ohos/README.md):一个 so 三个入口,都在进程内用
     * JNI_CreateJavaVM 起 VM —— 沙箱没有真 exec,JDK 自带的 bin/java 启动器
     * (JLI_Launch)还要求 execv 自己重跑一遍,那条路不成立。
     * 分家:JDK 的 .so 全平铺在 bundle libs($HOME 是 noexec,dlopen 不了),
     * lib/modules、conf/ 等数据解包在 $HOME/jdk21(见 shell.cpp initResource)。 */
    /* java 暂时不再内置。 */
    // {"java",            "libjdk.so",         "bsh_java_main"},
    // {"javac",           "libjdk.so",         "bsh_javac_main"},
    // {"jar",             "libjdk.so",         "bsh_jar_main"},

    /* Info-ZIP zip 3.0 / unzip 6.0(见 scripts/build_zip.sh 与 scripts/zip-ohos/)。
     * 两个独立 so:zip 与 unzip 是两套互不相干的代码库,各自一份 crc32/ttyio/globals,
     * 合成一个会撞符号。so 名带 cmd 后缀是躲 libzip.so —— 那个名字被 JDK 的
     * java.util.zip 原生库占着(build_jdk.sh 的 install 阶段拷进 entry/libs),
     * 同名会互相覆盖。 */
    {"zip",             "libzipcmd.so",     "bsh_zip_main"},
    {"unzip",           "libunzipcmd.so",   "bsh_unzip_main"},
};

#undef TOY

const struct CommandEntry* cmd_lookup(const char* name) {
    if (!name) return NULL;
    /* 表小,线性查找即可 */
    for (size_t i = 0; i < sizeof kMap / sizeof kMap[0]; i++) {
        if (strcmp(name, kMap[i].cmd) == 0)
            return &kMap[i];
    }
    return NULL;
}

size_t cmd_name_count(void) {
    return sizeof kMap / sizeof kMap[0];
}

const char* cmd_name_at(size_t i) {
    if (i >= cmd_name_count()) return NULL;
    return kMap[i].cmd;
}

const struct CommandEntry* cmd_entry_at(size_t i) {    if (i >= cmd_name_count()) return NULL;
    return &kMap[i];
}

/* 启动器文件（"#BSHSO"）—— 格式见 command_map.h。这里只负责"写"：
 *   第 1 行 magic、第 2 行 <so_dir>/<so>、第 3 行入口符号、第 4 行 arity。
 * 表里没有 arity 字段(现有入口全是 int(*)(int,char**))，所以一律写 2；
 * 将来真有要 envp 的条目，给它加个字段或手写一个启动器即可。 */
int cmd_make_launchers(const char* dir, const char* so_dir) {
    if (!dir || !*dir || !so_dir || !*so_dir) return 0;
    mkdir(dir, 0755);
    int made = 0;
    size_t n = cmd_name_count();
    for (size_t i = 0; i < n; i++) {
        const struct CommandEntry* e = cmd_entry_at(i);
        if (!e || !e->cmd || !e->so || !e->entry) continue;
        char path[512];
        int pl = snprintf(path, sizeof path, "%s/%s", dir, e->cmd);
        if (pl <= 0 || (size_t)pl >= sizeof path) continue;

        /* 内容先攒进内存再一次性写，避免半截文件被看见 */
        char body[1600];
        int bl = snprintf(body, sizeof body, BSH_LAUNCHER_MAGIC "\n%s%s\n%s\n2\n",
                          so_dir, e->so, e->entry);
        if (bl <= 0 || (size_t)bl >= sizeof body) continue;

        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
        if (fd < 0) continue;
        ssize_t w = write(fd, body, (size_t)bl);
        close(fd);
        if (w == bl) { chmod(path, 0755); made++; }
    }
    return made;
}

int cmd_is_launcher(const char* path) {
    if (!path || !*path) return 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    char buf[sizeof(BSH_LAUNCHER_MAGIC)];   /* 含结尾 NUL 的那一位 */
    int n = (int)read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = '\0';
    /* 只要**首行**是 magic 就算（后面几行交给解析器校验，这里只做分类） */
    return strncmp(buf, BSH_LAUNCHER_MAGIC, sizeof(BSH_LAUNCHER_MAGIC) - 1) == 0;
}
