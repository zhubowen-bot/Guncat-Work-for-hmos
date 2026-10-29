/*
 * javawrap.c —— 设备侧 usr/bin/java 的转发壳（认 -jar，换到原生替身）。
 *
 * ── 症状 ────────────────────────────────────────────────────────────────
 * hvigor 的打包/签名不是 JS 干的，而是 fork 出
 *     java [-Dxxx] -jar <SDK>/toolchains/lib/app_packing_tool.jar --mode hap ...
 *     java [-Dxxx] -jar <...>/hap-sign-tool.jar sign-app ...
 * 而沙箱里的 JVM 起不来：Error occurred during initialization of VM /
 * "Failed to mark memory page as executable" —— 当前应用没有 jit 权限，
 * 沙箱拒绝 RW→RX 的可执行内存（同一类限制见 scripts/glibc-ohos/README.md）。
 *
 * ── 修法 ────────────────────────────────────────────────────────────────
 * 这台设备其实不缺"打包/签名能力"：同一个源仓库里就有 C++ 版，已被
 * scripts/build_haptools.sh 编成静态原生可执行文件（usr/bin/{app_packing_tool,
 * hap-sign-tool}）。缺的只是"一个能替 java 把命令行接过来的东西"。于是这个壳：
 *   1. 扫 argv 找 `-jar`，拿它后面那个 jar 的 basename；
 *   2. 按 basename 映射到**同一个目录下**的原生工具；
 *   3. 把 jar 路径之后的参数原样交给它，execv 换过去。
 * 认不出的 jar 一律打一行错误并非零退出 —— 这是转发壳，不是 java 实现，不要假装能跑。
 *
 * ── 为什么必须是**动态**链接，而不是像那两个工具一样静态 ────────────────
 * 本项目的 shim（tty/软链/exec 委托）在 guest 侧**只走 LD_PRELOAD 符号插入**，
 * 而静态 guest 没有动态符号表、吃不到 preload（见 README.md「明确不做：静态链接的
 * guest」与 feature/bsh_main/src/main/cpp/shim/README.md §11.5）。关键在这里：
 * 沙箱里 guest 调 execve 一律 EACCES，"起一个程序"必须由 exec_shim 委托给 procmgr。
 * 静态 guest 的 execv 会直接打到内核/SDK 的 noexec 限制上 —— 而这正是本程序存在的
 * 全部意义（它就要 exec 另一个程序）。所以哪怕只有几十 KB，也必须动态链：
 * 只有动态 guest 的 execv 才会被 shim 接住、交给 procmgr 创建进程。
 * 先例：设备侧的 make/ninja（devtools 包）与 clang（ohos-sdk-prune 包）都是动态
 * musl guest，靠这条路起子进程，实测能跑。
 *
 * ── 子命令 ──────────────────────────────────────────────────────────────
 * 原生 app_packing_tool 的 CLI 是 `app_packing_tool pack --mode ...`（argv[1] 必须
 * 是 `pack`/`unpack`/`help`，见上游 shell_command.cpp 的 commandMap_），而 hvigor 给
 * jar 的是 `--mode hap ...`（没有子命令，见 hvigor 的 packing-tool-options.js）。所以
 * 对打包工具只在"首参缺失或以 - 开头"时补一个 `pack`，调用者自己写了真子命令就原样
 * 传；hap-sign-tool 不用补 —— hvigor 本来就传 `sign-app`。
 */

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

struct tool_map {
    const char *jar;    /* -jar 后面那个参数的 basename */
    const char *tool;   /* 同目录下的原生可执行名 */
    const char *env;    /* 覆盖整条工具路径的环境变量 */
    const char *argv1;  /* 转发前要补的子命令；NULL = 不补 */
};

static const struct tool_map TOOLS[] = {
    { "hap-sign-tool.jar",         "hap-sign-tool",    "BSH_SIGN_TOOL",    NULL   },
    { "app_packing_tool.jar",      "app_packing_tool", "BSH_PACKING_TOOL", "pack" },
    { "hmos_app_packing_tool.jar", "app_packing_tool", "BSH_PACKING_TOOL", "pack" },
};

/* 自己所在目录：优先 /proc/self/exe。本项目 shim 会把 guest 自己的路径填给它
 * （见 shim/README.md §3.1b），所以设备上拿到的就是装 java 的那个 usr/bin。 */
static int self_dir(char *buf, size_t len)
{
    ssize_t n = readlink("/proc/self/exe", buf, len - 1);
    if (n <= 0 || (size_t)n >= len - 1) {
        return -1;
    }
    buf[n] = '\0';
    char *slash = strrchr(buf, '/');
    if (slash == NULL) {
        return -1;
    }
    *slash = '\0';
    return 0;
}

/* 工具路径：环境变量覆盖 > 自己目录下的同名文件 > $BSH_SYSROOT/usr/bin。
 * BSH_SYSROOT 是 procmgr 一定会设的环境变量（资源根），是可靠兜底。 */
static int resolve_tool(const struct tool_map *m, char *out, size_t len)
{
    const char *override = getenv(m->env);
    if (override != NULL && override[0] != '\0') {
        snprintf(out, len, "%s", override);
        return 0;
    }

    char dir[PATH_MAX];
    if (self_dir(dir, sizeof(dir)) == 0) {
        snprintf(out, len, "%s/%s", dir, m->tool);
        if (access(out, X_OK) == 0) {
            return 0;
        }
    }

    const char *root = getenv("BSH_SYSROOT");
    if (root != NULL && root[0] != '\0') {
        snprintf(out, len, "%s/usr/bin/%s", root, m->tool);
        return 0;
    }
    return -1;
}

int main(int argc, char **argv)
{
    const char *jar = NULL;
    int jar_idx = -1;
    int i;

    for (i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "-jar") == 0) {
            jar = argv[i + 1];
            jar_idx = i + 1;
            break;
        }
    }
    if (jar == NULL) {
        fprintf(stderr, "java: 没有找到 `-jar <jar>`；本沙箱的 java 只是个转发壳，"
                        "会把已知的 .jar 换成原生工具，用法与原命令一致。\n");
        return 2;
    }

    const char *base = strrchr(jar, '/');
    base = (base != NULL) ? base + 1 : jar;

    const struct tool_map *m = NULL;
    for (i = 0; i < (int)(sizeof(TOOLS) / sizeof(TOOLS[0])); i++) {
        if (strcmp(base, TOOLS[i].jar) == 0) {
            m = &TOOLS[i];
            break;
        }
    }
    if (m == NULL) {
        fprintf(stderr, "java: 不支持 %s：这台设备没有 JVM（沙箱无 jit 权限），"
                        "只有打包/签名工具有原生替身。\n", base);
        return 2;
    }

    char tool[PATH_MAX];
    if (resolve_tool(m, tool, sizeof(tool)) < 0) {
        fprintf(stderr, "java: 定位不到 %s（%s 未设，且拿不到 /proc/self/exe）\n",
                m->tool, "BSH_SYSROOT");
        return 1;
    }
    if (access(tool, X_OK) != 0) {
        fprintf(stderr, "java: 原生工具不可用 %s: %s\n", tool, strerror(errno));
        return 1;
    }

    /* 组装转发用的 argv：argv[0] = 工具路径，可选补子命令，然后 jar 之后原样。
     * `-jar` 之前的 JVM 选项（-Dfile.encoding… / -Xmx…）不转发。 */
    char **nargv = calloc((size_t)(argc - jar_idx) + 3, sizeof(char *));
    if (nargv == NULL) {
        fprintf(stderr, "java: out of memory\n");
        return 1;
    }
    int n = 0;
    nargv[n++] = tool;
    /* 只有"首参缺失"或"首参是选项(以 - 开头)"时才补子命令：
     * 打包工具的 CLI 是 `<工具> {help|pack|unpack} <选项…>`，hvigor 走 jar 时
     * 直接给的是 `--mode hap …`（没有子命令），所以要补 `pack`；但如果调用者
     * 自己写了 `help`/`unpack` 这类真子命令，补了就会变成 `pack help` 出错。 */
    if (m->argv1 != NULL &&
        !(jar_idx + 1 < argc && argv[jar_idx + 1][0] != '-')) {
        nargv[n++] = (char *)m->argv1;
    }
    for (i = jar_idx + 1; i < argc; i++) {
        nargv[n++] = argv[i];
    }
    nargv[n] = NULL;

    execv(tool, nargv);
    fprintf(stderr, "java: cannot exec %s: %s\n", tool, strerror(errno));
    return 1;
}
