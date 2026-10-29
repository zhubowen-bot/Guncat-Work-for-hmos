// shim/os_shim.c — 让沙箱里的 uname(2) 报 "Linux"
//
// 为什么需要(2026-10-01,自举流水线实测):
//   这台设备上 `uname -s` 返回的是 **"HarmonyOS"**(内核是 HongMeng，不是 Linux)。
//   于是任何"看 uname 决定宿主机是什么系统"的工具都会认错平台 —— 最直接的一例是
//   hvigor 的 `@ohos/hvigor-common`：
//       isLinux() { return os.type() === 'Linux'; }        // node 的 os.type() = uname().sysname
//       getLibimageTranscoderShared() {
//           return isWindows() ? 'libimage_transcoder_shared.dll'
//                : isLinux()   ? 'libimage_transcoder_shared.so'
//                              : 'libimage_transcoder_shared.dylib';   // ← 落到这里
//       }
//   `:entry:default@CompileResource` 就这么死在这一行上:它去 dlopen 一个**不存在的
//   .dylib**(SDK 里只有 .so),报 "Failed to load the library .../libimage_transcoder_shared.dylib"。
//
// 为什么在这个层面修(而不是改 hvigor 的 js / 改 node 源码):
//   我们跑在别人的工具链里,要让它认为"宿主机是 Linux" —— 这正是沙箱该负责的事:
//   uname 是程序判断宿主 OS 的**标准入口**(configure、make、python 的 platform、
//   node 的 os.type 都走它)。在链接期把它截下来改一处,比去 patch 一堆第三方脚本稳。
//   做法沿用本项目既有的 `--wrap=<符号>` 惯例(见 scripts/shim-wrap-flags.sh 的说明),
//   不定义新符号、不碰 libc。
//
// 现状与范围:
//   目前**只有 node**(libnode.so)链它 —— 重链命令在 scripts/build_node.sh 里,
//   加一个对象和 `-Wl,--wrap=uname` 即可,代价极小。其余命令 so 没链,是因为
//   SHIM_WRAP_FLAGS 是共享清单,往那里加就得让**每一个**命令 so 都重新链一遍
//   (toybox/mksh/python/Qt…),收益不值当。以后哪个命令真的需要,照 build_node.sh
//   的做法单独加即可。
//
// 取舍:
//   只改 sysname(工具用来判 OS 的就是它),release/version/machine/nodename 原样保留
//   —— 那些是"这台机器的实情",改了反而会误导(比如 uname -m 该是 aarch64)。
//   诚实的代价:程序再也看不到"HarmonyOS"这个事实;要查真相用 `BSH_UNAME_REAL=1`
//   (见下),或直接看 `/proc/version`。
#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>

extern int __real_uname(struct utsname *buf);

int __wrap_uname(struct utsname *buf)
{
    int rc = __real_uname(buf);
    if (rc != 0 || buf == NULL) return rc;

    /* 逃生口:调试/诊断时想看见真值(HarmonyOS)就设它。 */
    const char *real = getenv("BSH_UNAME_REAL");
    if (real && *real && real[0] != '0') return rc;

    strncpy(buf->sysname, "Linux", sizeof(buf->sysname) - 1);
    buf->sysname[sizeof(buf->sysname) - 1] = '\0';
    return rc;
}
