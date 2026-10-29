# jdk-ohos —— 把 OpenJDK 21 交叉编译到 aarch64-linux-ohos(musl)

配套脚本：`scripts/build_jdk.sh`（阶段：`src|sysroot|stubs|patches|configure|build|pack|all`）。

源码：OpenJDK **jdk21u**，tag `jdk-21.0.5-ga`（codeload tar 包，非 git clone）。
工具链：DevEco / command-line-tools 自带的 **OHOS clang 15.0.4**（`$CLANG_DIR/clang`）。
boot JDK：宿主 `/usr/lib/jvm/java-21-openjdk-amd64`。
目标三元组：`aarch64-unknown-linux-musl`（OpenJDK 侧的 target），
实际编译器 target 是 `aarch64-linux-ohos`。

> 思路参考了社区项目 `LZZLHY/amcl` 的 `docker/{setup_toolchain,run_configure,build_jdk21_ohos}.sh`
> 与 `prebuilt/jdk/21/patches/`。补丁与 stub 都是照着**本仓库源码的实际调用点**重写的，
> 不是复制粘贴；每条补丁的必要性在文件头有说明。

---

## 关键前提（踩坑记录）

### P0 `git apply` 不能用：jdk 源码落在 BetterSH 这个 git 仓库里

`build/` 被 `.gitignore` 忽略（`**/build`），但 `git` 仍会把
`build/jdk/jdk21u-jdk-21.0.5-ga/` 当成仓库 `/workspace/dev/BetterSH` 的工作区，
`git apply` 会从仓库根解析补丁路径，可能"成功返回 0 却一个 hunk 都没打"。
所以补丁一律用 **GNU `patch -p1`**，并且 `cd` 到源码目录再执行。

### P1 源码是 codeload tar，不带 `.git`

`apply_patches.sh` 那套 `git apply --3way` 回退链在这里没意义（没有 object 库）。
本仓库的 `patches` 阶段自己做幂等：`patch -p1 -R --dry-run` 判"已打过"。

### P2 工具链自带驱动，`bits` / libc++ 头都能自动找到

`$CLANG_DIR/clang --target=aarch64-linux-ohos --sysroot=$SYSROOT` 的默认搜索路径是

```
<clang>/include/libcxx-ohos/include/c++/v1
<clang>/lib/clang/15.0.4/include
<sysroot>/usr/include/aarch64-linux-ohos
<sysroot>/usr/include
```

`stdio.h` → `#include <bits/alltypes.h>` 靠第三条命中，**不需要** `usr/include/bits` 符号链接；
C++ 头也不需要额外 `-isystem`。`sysroot` 阶段仍然建这两样（可写副本 + `bits` 链接 + CRT 链接），
因为它们是"换工具链/换 SDK 版本时最容易踩的雷"，留着是廉价的保险。

### P3 SDK sysroot 里完全没有 libc++ 运行时

`usr/lib/aarch64-linux-ohos/` 里没有 `libc++.so` / `libc++abi.so` / `libunwind.so`
（OHOS 的 C++ 运行时是随 app 走的 `libc++_shared.so`）。
所以目标端 C++ 链接一律 `-stdlib=libc++ -nostdlib++`，C++ ABI 符号自己补：
`stubs/cxxabi_shim.cpp` + `stubs/eh_stubs.c` → `libcxxabi_shim.so`，
再通过 `--with-extra-ldflags='-L<jdk-libs> -lcxxabi_shim'` 挂到所有目标链接上。

`-rtlib=compiler-rt -unwindlib=none` 是配套的：OHOS sysroot 没有 gcc 风格的
`libgcc*`/`crtbeginS.o`，SDK clang 自带 `libclang_rt.builtins.a` + `clang_rt.crtbegin.o`。

### P4 三个"必须有"的外部依赖头：cups / fontconfig / alsa

`make/autoconf/libraries.m4` 对非 windows/macosx 的 target 一律
`NEEDS_LIB_CUPS/NEEDS_LIB_FONTCONFIG/NEEDS_LIB_X11=true`，且 `OPENJDK_TARGET_OS=linux`
时 `NEEDS_LIB_ALSA=true` —— **即使 `--enable-headless-only` 也躲不掉**，
configure 阶段就必须找到它们（缺一个直接 `AC_MSG_ERROR`）。

* cups / fontconfig / X11：只在**编译期**要头（运行时 `dlopen`），所以我们自己写 stub 头，
  用 `--with-cups-include` / `--with-fontconfig-include` / `--x-includes` 直接指过去。
* alsa：`libjsound` 真的要被链接上去（`LIBS_linux := $(ALSA_LIBS)`，`-lasound`），
  所以要头 + 一份 `libasound.so` 桩。头我们**不自己写**：`libjsound` 用了近百个
  `snd_*` 符号和 `SND_*` 常量，手写桩等于复刻 alsa-lib 公共 API，错一个就是编译不过。
  `stubs` 阶段从宿主 `/usr/include/alsa` 拷一份（`libasound2-dev`）。
  实测这些头在 OHOS 工具链下能过编译。
* **不要**让 configure 走宿主 `pkg-config`：`lib-alsa.m4` 在 `--with-sysroot` 为空时
  会跑 `PKG_CHECK_MODULES(ALSA, alsa)`，命中宿主 `alsa.pc` 后 `ALSA_CFLAGS` 可能带上
  宿主 glibc 的 `-I`。显式传 `--with-alsa-include/--with-alsa-lib` 就没这个问题。

### P5 X11 的 5 个探针头

`lib-x11.m4` 用 `AC_CHECK_HEADERS` 验
`X11/extensions/{shape,Xrender,XTest,Xrandr}.h` + `X11/Intrinsic.h`（前置 `X11/Xlib.h`+`Xutil.h`）。
`--x-includes=/dev/null` 这种写法在 autoconf 里会走
`case $x_includes,$x_libraries in *,NONE|NONE,*) _AC_PATH_X;; *) have_x=yes;; esac`
—— 两个都不是 `NONE` 就直接认定 `have_x=yes`，**不做任何探测**，
然后 `X_CFLAGS=-I/dev/null` 再 `AC_CHECK_HEADERS([X11/extensions/shape.h ...])` 就必然失败。
所以本脚本给 X11 也备了一份自己的 stub 头目录，用 `--x-includes=<stub>` 指过去。

### P6 补丁：jdk21u 源码本身的 musl 支持是半成品

jdk21u 的 `flags-cflags.m4` 在 target libc 是 musl 时会自动加 `-DMUSL_LIBC`，
`src/` 里也有 4 处 `#ifdef MUSL_LIBC`，但它们是按 **Alpine 那种完整 musl** 写的，
OHOS 的 musl 缺了其中几样（`dlinfo`、`utmpx` 函数族），而 `dlvsym` 反过来是
"OHOS 有、上游还当它没有"。详见下面「补丁清单」。

---

（后续每解决一个坑都追加到这里）

### P7 宿主机是 WSL2 → config.guess 把 build 平台判成 windows

症状：configure 一开头就 `checking build system type... x86_64-pc-wsl`、
`checking openjdk-build os-cpu... windows-x86_64`，随后
`generated-configure.sh: line 13281: import: command not found` →
`configure: error: The path of TOPDIR ... could not be imported.`

根因：`make/autoconf/build-aux/config.guess` 第 70-77 行看到
`uname -r` 里有 `microsoft` 且三元组是 `*-linux-gnu`，就改写成 `*-pc-wsl`；
`platform.m4` 再把 `*-wsl` 映射成 `OPENJDK_BUILD_OS=windows`。
我们是**在 WSL2 里做原生 Linux 构建**，不走它那套 cmd.exe 路径转换。

修法：补丁 `0011-config-guess-no-wsl.patch` 删掉这段改写。

### P8 `libawt` / `libawt_headless` 的 `!HEADLESS` 分支要真的 X11 类型

症状：`color.h: unknown type name 'XPixmapFormatValues'`、
`img_util_md.h: unknown type name 'Region'`、`glx.h: unknown type name 'XVisualInfo'`。

根因：`--enable-headless-only` 只保证不构建 `libawt_xawt` / `libsplashscreen`，
但 `libawt` 与 `libawt_headless` 的 CFLAGS 里仍有 `$(X_CFLAGS)`，而
`awt.h` / `color.h` / `img_util_md.h` / `J2D_GL/glx.h` 都无条件
`#include <X11/...>`（`rect.h` 甚至直接 `typedef XRectangle RECT_T`）。
它们只用**类型**、不调用 X 函数（libawt 不链接 `-lX11`），
所以 stub 头只要把结构体铺齐就能过编译。

修法：给 `stubs/x11/include/X11/` 补齐 `Region` / `XPixmapFormatValues` /
`XChar2b` / `XCharStruct` / `XVisualInfo`（含 C++ 下 `class`→`c_class` 的
关键字规避）以及一批函数原型。注意 `XGetWindowProperty` 的形参不能叫
`delete`（C++ 关键字），改名 `delete_prop`。

### P9 宿主 ocl 与 musl 的 `strerror_r` 声明不一致（补丁 0012）

症状：`libjava.so` 里 `U __xpg_strerror_r`，dlopen 时符号找不到；
把它简单关掉又会让 **buildjdk**（宿主 glibc）编译失败：
`incompatible pointer to integer conversion returning 'char *' from a function with result type 'int'`。

根因：`jni_util_md.c` 的重定向条件是 `LINUX && _GNU_SOURCE`，而
JDK 对 linux target 无条件加 `-D_GNU_SOURCE`，**并且 `OS_CFLAGS` 会漏进
buildjdk 的编译**（实测 buildjdk 的 cmdline 里有 `-DMUSL_LIBC`、没有
`-D__MUSL__`）。于是：
* 目标（musl）走这条分支 → 引用不存在的 `__xpg_strerror_r`；
* 宿主（glibc + `_GNU_SOURCE`）的 `strerror_r` 是返回 `char*` 的 GNU 变体，
  而下一行代码按 XPG 语义（返回 `int`）用它 → 必须保留重定向。

修法：条件改成 `defined(LINUX) && defined(__GLIBC__) && (...)` ——
判据是"当前 libc 是不是 glibc"，两侧都对。

> 顺带记一个教训：写补丁时 `#ifdef MUSL_LIBC` **不能**当作"这是 OHOS 目标"的
> 判据（它在 buildjdk 里也为真）。要区分目标/宿主请用 `-D__MUSL__`
> （走 `--with-extra-*flags`，只作用于 target）。

### P10 SDK clang 对 `*-ohos` 默认用模拟 TLS，和 hotspot 手写 asm 打架

症状：`libjvm.so` 里留下
`U _ZN6Thread12_thr_currentE` 和一条 `R_AARCH64_TLSDESC` 动态重定位，dlopen 报
`Error relocating ...: _ZN6Thread12_thr_currentE: symbol not found`。

根因：OHOS SDK 的 clang 对 `aarch64-linux-ohos` 默认 `-femulated-tls`，
`__thread Thread* _thr_current` 被编成 `__emutls_v._ZN6Thread12_thr_currentE`；
而 `src/hotspot/os_cpu/linux_aarch64/threadLS_linux_aarch64.S` 是手写的
**native TLS** 访问（`:tlsdesc:_ZN6Thread12_thr_currentE`）。两边对不上。

参考实现没踩到这个坑，是因为它用 Ubuntu 的 clang-15 加
`--target=aarch64-linux-ohos`（Ubuntu 的 clang 不认识 `ohos` 这个 OS 名，
退化成通用 Linux/ELF 目标，天生就是 native TLS）。

修法：目标编译统一加 `-fno-emulated-tls`（脚本里的 `COMMON_FLAGS`）。
native TLS 需要 loader 支持 `R_AARCH64_TLSDESC`；实测 musl 1.2.2 的
`ld-musl-aarch64.so.1` 就能处理，OHOS 的 musl（有 `dlvsym`，≥1.2.4）只会更好。

### P11 `__cxa_thread_atexit` 只能我们自己补

症状：dlopen `libjvm.so` 报 `Error relocating ...: __cxa_thread_atexit: symbol not found`。

根因：它是 **libc++abi** 的符号，不在 libc 里（musl/glibc 只有
`__cxa_thread_atexit_impl`）；我们为了 `-nostdlib++` 没链 libc++abi。
libjvm.so 因为用到 `thread_local` 的非平凡析构而引用它。

修法：`stubs/cxxabi_shim.cpp` 里补上，实现是"`dlsym` 到
`__cxa_thread_atexit_impl` 就转发，否则退化成不登记"。

> 教训：`-nostdlib++` 之后要**主动审计产物的未定义符号**，不能等设备上炸。
> 本轮审计用 `llvm-nm -D -u` 把所有镜内 ELF 的未定义符号和
> （sysroot 的 libc/libm/... + 我们的 shim + 镜像自身的定义）做差集，
> 排掉 weak 之后必须为空。**当前状态：空。**

### P12 `libasound.so` 要含完整的 `snd_*` 符号表

症状：`libjsound.so` 有 119 个未定义的 `snd_*`；一个只含占位符号的
libasound.so 桩会让 `dlopen("libjsound.so")` 失败。

根因：ALSA 是真的被链接进去的（`LIBS_linux := $(ALSA_LIBS)`），
不像 cups/fontconfig/X11 那样只 dlopen。

修法：`make_alsa_stub` 在 `build` 阶段从刚编出来的 `libjsound.so` 里
`llvm-nm -D -u | grep '^snd_'` 反推出符号表，生成空函数定义
（`__attribute__((weak))`）再重出 libasound.so。既准确又不会随 JDK 版本漂移。

### P13 `SUN_BOOT_LIBRARY_PATH` 要指 `$JAVA_HOME/lib`，不是 `lib/server`

症状：`Error occurred during initialization of VM
Unable to load jimage library: .../lib/server/libjimage.so`。

根因：hotspot 的 `dll_dir` 就是 `<java_home>/lib`
（`os_linux.cpp` 里逐级截断 `/libjvm.so` → `/{server|client|hotspot}`），
`libjimage.so` / `libzip.so` / `libverify.so` 全从 `dll_dir` 找。
被 0004 补丁改成从环境变量取值之后，环境变量就得给对值。

修法：launcher 导出 `SUN_BOOT_LIBRARY_PATH=$JAVA_HOME/lib`。

---

## 验证（不只是编过）

宿主上有 `qemu-aarch64`，配一份 aarch64 musl 的 loader 就能真跑起来：

```bash
JDK=<镜像目录>
QL=/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross/aarch64-linux-musl
# 该工具链的 ld-musl-aarch64.so.1 是指向 /lib/libc.so 的绝对软链，qemu -L 解析不了，
# 先搭一个私有 root：
mkdir -p /tmp/ohosrt/lib && cp -L $QL/lib/libc.so /tmp/ohosrt/lib/libc.so \
  && ln -sf libc.so /tmp/ohosrt/lib/ld-musl-aarch64.so.1
# 宿主这份 musl 是 2021 年的 1.2.2，没有 dlvsym（OHOS 的 musl 有），
# 冒烟测试临时 LD_PRELOAD 一个转发实现：
cat > /tmp/dlvsym_shim.c <<'EOF'
#include <dlfcn.h>
void *dlvsym(void *h, const char *s, const char *v){ (void)v; return dlsym(h, s); }
EOF
/apps/harmony/sdk/default/openharmony/native/llvm/bin/clang \
  --target=aarch64-linux-ohos --sysroot=/apps/harmony/sdk/default/openharmony/native/sysroot \
  -shared -fPIC -o /tmp/libdlvsym_shim.so /tmp/dlvsym_shim.c -fuse-ld=lld

qemu-aarch64 -L /tmp/ohosrt -E LD_PRELOAD=/tmp/libdlvsym_shim.so \
  -E LD_LIBRARY_PATH=$JDK/lib:$JDK/lib/server:/tmp/ohosrt/lib \
  -E JAVA_HOME=$JDK -E SUN_BOOT_LIBRARY_PATH=$JDK/lib -E HOME=/tmp \
  $JDK/bin/java -version
```

2026-09-28 实测结果（全部通过）：

```
openjdk version "21.0.5-internal" 2024-10-15
OpenJDK Runtime Environment (build 21.0.5-internal-adhoc.suwan.jdk21u-jdk-21.0.5-ga)
OpenJDK 64-Bit Server VM (build 21.0.5-internal-adhoc.suwan.jdk21u-jdk-21.0.5-ga, mixed mode)

javac 21.0.5-internal            # javac -version
jar 21.0.5-internal              # jar --version
javac Hello.java                 # 产出 Hello.class
java -cp . Hello                 # → hello from OpenJDK 21 on aarch64-musl: aarch64/21.0.5-internal
jar cf hello.jar Hello.class     # 产出 jar
```

⚠ 这是 qemu-user + 通用 musl 的近似环境，不等于真机。真机上另有一批沙箱带来的
坑，见下面「运行期踩坑（真机）」。

---

# 运行期踩坑（真机）

设备：`3QC0225617000597`（2in1）。命令表里是三条命令 `java` / `javac` / `jar`，
都指向同一个 `libjdk.so`（三个 C 入口），launcher 源码在
`scripts/jdk-ohos/bsh_java_entry.cc`。

## R1 应用数据目录（`$HOME`）是 noexec —— JDK 的 .so 只能随 HAP 进 bundle libs

症状：把 `libjvm.so` 推到 `$HOME/jdk21/lib/server/` 再 `dlopen`，直接

```
Error loading shared library /data/storage/el2/base/haps/entry/files/…/libjvm.so: Permission denied
```

同一份文件放在 `/data/storage/el1/bundle/libs/arm64/` 里 `dlopen` 正常。

根因：应用数据目录（= 资源根，`BSH_SYSROOT`，`/data/storage/el2/base/haps/entry/files`）
挂在 noexec 上 —— `dlopen` 里头的 .so 会被内核拒绝。注意用户的 `$HOME` 是它下面的 `home/`，
两者不是一回事（改布局前它们曾是同一个目录）。

修法：JDK 的 **26 个 .so 全部平铺进 `feature/bsh_main/libs/arm64-v8a/`**（随 HAP 打包，运行时
路径 = `/data/storage/el1/bundle/libs/arm64`）；`lib/modules`、`conf/`、`tzdb.dat`、
`ct.sym`、`bin/` 等数据仍在 `$HOME/jdk21`。`bash scripts/build_jdk.sh install` 负责
这一步（幂等：先删后拷 + 重打 tar）。

## R2 `LD_LIBRARY_PATH` 在进程里 setenv 改不动

症状：launcher 里 `setenv("LD_LIBRARY_PATH", bundle libs)` 之后，`libjvm.so` 仍找不到
它 NEEDED 的 `libcxxabi_shim.so`（预编好的 `libjvm.so` 没有让 libc 记住搜索路径）。

根因：musl 在进程**启动**时（`__dls3`）就把 `LD_LIBRARY_PATH` 读进全局搜索路径，
之后的 `setenv` 对它无效。`LD_LIBRARY_PATH` 实测也是空的（appspawn 没给）。

修法：不依赖它 —— `libjvm.so` 自带 `RPATH=$ORIGIN`，把 .so **平铺到同一个目录**之后
它的依赖（`libcxxabi_shim.so`）自然解析；其余 JDK .so 的依赖只有
libc / libjvm / libcxxabi_shim，后两个已经在全局作用域里。launcher 里那行 setenv
只是保险，不是机制。

## R3 tar 的顶层目录名 + 沙箱不许建（符号/硬）链接

症状：每个会话都把 147M 重解一遍，而且 `$HOME/jdk21/lib/modules` **永远不存在**。

根因是两件事叠在一起：

1. tar 顶层叫 `jdk/`，而 initResource 期望的是 `<资源根>/jdk21`
   —— 解出来的是 `<资源根>/jdk`，于是每会话重解一次（当时是靠"标记文件"发现问题的：`UnpackRes`
   的标记写的是 `<资源根>/jdk21/lib/modules`，那个路径永远不存在；现在标记已经换成
   资源根下一个总标记，但"路径对不上 → 每次会话重解"这个判别方法仍然成立）；
2. 镜像里 `legal/<module>/{LICENSE,ASSEMBLY_EXCEPTION,ADDITIONAL_LICENSE_INFO}`
   共 205 个是**指向 `../java.base/*` 的符号链接**，而应用沙箱**不允许创建符号链接、
   也不允许创建硬链接**（EPERM）。toybox tar 逐条报
   `can't link …: Permission denied` 并以 rc=1 结束，`UnpackRes` 把非 0 当失败。

修法（`do_pack`）：`--transform='s,^jdk,jdk21,'` 改顶层目录名 +
`--dereference --hard-dereference`（链接全落成普通文件，多花约 2M）。
只加 `--dereference` 不够：GNU tar 会发现"这些链接最后指向同一个 inode"，
于是改成记**硬链接**（`hr--r--r-- … link to …`）——设备上照样建不了。

教训：打包后的自检**别写** `tar -tf f | grep -q x` —— grep 命中即退出会让 tar
吃 SIGPIPE（rc=141），`set -o pipefail` 下整条管道算失败，是个假警报。
现在先把清单落盘（`build/jdk/tar-list.txt` / `tar-vlist.txt`）再 grep，
并顺带断言"不能有 `l`/`h` 条目、不能带 .so"。

## R4 不能用 `JLI_Launch`

根因两条：

1. 上游 launcher 在 musl 上会先设好 `LD_LIBRARY_PATH` 再 **`execv` 自己重跑一遍**
   （`java_md.c` 的 `RequiresSetenv`，0009 补丁把它改成 `JNI_FALSE` 才绕开）；
   沙箱没有 exec，这条路根本不成立；
2. 宿主是 procmgr fork 出来的子进程，不能换镜像 —— 一切必须在进程内完成。

修法：launcher 自己在进程内 `JNI_CreateJavaVM`（`JNI_VERSION_10`），再把
`libjli/java.c` 的启动器逻辑搬一个等价子集过来：解析 `-cp/-classpath/-jar/-m/
--module-path/-XshowSettings/-version/-showversion/-help` 与 `-D/-X/-XX` 透传，
主类交给 `sun.launcher.LauncherHelper`（`checkAndLoadMain` + `getMainType` +
`makePlatformString` + `printVersion`/`showSettings`/`printHelpMessage`），
`javac`/`jar` 就是"预置 `--add-modules ALL-DEFAULT -m jdk.compiler/com.sun.tools.javac.Main`
或 `-ms8m -m jdk.jartool/sun.tools.jar.Main` 的 java"（对齐
`make/common/modules/LauncherCommon.gmk`）。jni.h/jni_md.h 从 JDK 镜像里拷了一份
放 `scripts/jdk-ohos/jni/`，避免依赖 build/ 目录。

## R5 信号：必须接 OHOS 的 sigchain，把同步异常转发给 HotSpot

症状（预期）：VM 初始化期 HotSpot 还没装自己的 handler，它那些"故意 fault 一下再
自己接住"的探测（safepoint polling 等）会被系统侧的崩溃处理器当**真崩溃**杀掉。

根因：OHOS 的 libc 有一条信号链（musl 的 `MUSL-SIGCHAIN`）：崩溃类信号先走链上的
special handler，普通 `sigaction` 的优先级比它低；而 HotSpot 是**起 VM 之后**才
`set_signal_handler(SIGSEGV/BUS/ILL/FPE)`。

修法：起 VM 之前用 libc 导出的

```
void add_special_signal_handler(int sig, struct signal_chain_action *action);
```

把 `SIGSEGV/SIGBUS/SIGILL/SIGFPE` 接到 HotSpot 导出的

```
int JVM_handle_linux_signal(int sig, siginfo_t *info, void *uc, int abort_if_unrecognized);
```

（`jvm_md.h` 里那个"给嵌入者用"的四参数入口）上：VM 认领了就 `return true`；
没认领就**再调一次**（第四位传 1）让它走官方致命路径（hs_err），仍不返回就
`_exit(128+sig)`。**不能**只 `return false` —— 那会落到 VM 那个"对未识别信号
不 abort"的普通 handler（0006 补丁），等于让 CPU 反复重试同一条出错指令
（信号死循环）。

两个细节：

* `struct signal_chain_action` 的布局是**从 SDK 的 `libc.a` 里反查 `sigchain.o`
  确认的**：`bool (*sca_sigaction)(int, siginfo_t*, void*)` + `sigset_t`(128B) +
  `int sca_flags`，单槽 144 字节、每信号最多 4 个槽。返回值按"第 0 位 = 已处理"
  用（反汇编 `signal_chain_handler` 里是 `tbnz w0,#0,<handled>`）。
* 注册链之前先把 1..31 号信号的**普通**处置复位成 `SIG_DFL`：子进程从 app 主进程
  继承了 DFX/ArkWeb 的一批 handler，不清掉会和 VM 自己装 handler 的过程互相干扰。
* 找不到 `add_special_signal_handler`（老版本 OHOS）时退回普通 `sigaction` 转发，
  语义相同、只是优先级低。

设备实测：`[bsh-java] signal bridge: ready`（符号都在、链已注册）。

## R6 退出码：JVM 的 `exit()` 会被宿主的 atexit 吃成 0

症状：`javac` 语法错误、找不到主类、`System.exit(7)` —— 输出全对，但退出码一律 0；
而 `java -version` 正常（它走 launcher 自己的 `return 0`）。用 `java -cp`（参数解析
就失败，走 launcher 的 `return 1`）对照，那条路 rc=1 —— 说明"退出码透传"本身没坏，
坏的只有 JVM 内部 `exit()` 这一条路。

根因：和 `procmgr/bsh_exec.c` 里 `__wrap_exit` 那段注释写的是同一件事 —— 命令 so
跑在宿主的 fork 子进程里，而宿主主进程在 fork **之前**就注册了一堆 atexit
（ArkTS/NAPI 收尾）。`System.exit` → `vm_exit` → `os::exit` → libc `exit()` 把它们
跑起来，进程最后以 0 收场，真正的退出码被丢在中间。

其它命令 so 的解法是链接期 `-Wl,--wrap=exit`；`libjvm.so` 是预先编好的没法重链，
而且它在全局符号表里抢不过更早加载的 libc（musl 按加载顺序查，libc 在最前）。

修法：用 HotSpot 给嵌入者留的钩子。`Arguments::parse_each_vm_init_arg()` 里有

```c
} else if (match_option(option, "exit")) {
  _exit_hook = CAST_TO_FN_PTR(exit_hook_t, option->extraInfo);
```

（同族还有 `"vfprintf"` / `"abort"`，都是 `JavaVMOption{optionString=名字,
extraInfo=函数指针}` 这种形态）。`VM_Exit::doit()` 收尾时会调它，注释写明
"exit hook should exit"。我们注册一个 `fflush(NULL); _exit(code)` 的实现，
退出码就由我们说了算 —— 语义与项目里 `__wrap_exit` 完全对齐。

## R7 java.desktop 的 native 库一个都不带（含一个同名冲突）

我们是 headless（`-Djava.awt.headless=true`），跑 `java -version` / `javac` / `jar`
/ 编译运行 Hello 这一套全程不碰 AWT / 字体 / 声音。所以：

* **带**（26 个，全部平铺在 bundle libs）：`libjvm.so` `libcxxabi_shim.so`
  `libjava.so` `libjimage.so` `libzip.so` `libverify.so` `libnet.so` `libnio.so`
  `libjli.so` `libsyslookup.so` `libj2pkcs11.so` `libextnet.so` `librmi.so`
  `libjaas.so` `libj2gss.so` `libj2pcsc.so` `lible.so` `libprefs.so`
  `libmanagement.so` `libmanagement_ext.so` `libmanagement_agent.so`
  `libinstrument.so` `libdt_socket.so` `libattach.so` `libjdwp.so` `libsaproc.so`
* **砍**（13 个，镜像里一共 39 个）：`libawt.so` `libawt_headless.so` `libjawt.so`
  `liblcms.so` `libmlib_image.so` `libjavajpeg.so` `libjsound.so` `libasound.so`
  （java.desktop / 声音，headless 用不到）；**`libfreetype.so`** —— 它与
  `feature/bsh_main/libs/arm64-v8a/` 里 **Qt 带来的 `libfreetype.so` 同名**，不能带；
  **`libfontmanager.so`** —— 它 NEEDED `libfreetype.so`，留着就会去绑 Qt 那份
  freetype，"半残的 AWT"比明确"没有 AWT"更难排查；**`libjsig.so`** —— 它实现的是
  标准 signal chaining，OHOS 上不起作用（R5 那条链才是），而且镜像里有 `lib/`
  与 `lib/server/` 两份副本；**`libsctp.so`** —— `com.sun.nio.sctp` 用，CLI 场景
  不需要（`java.base` 只有在真用到 SCTP socket 时才 dlopen 它）。

清单在 `scripts/build_jdk.sh` 的 `BUNDLE_LIBS_KEEP` 里，`install` 阶段按它拷；
tar 侧用 `--exclude='jdk/lib/*.so' --exclude='jdk/lib/server/*.so'` 保证不会重复解出。

**实测**（上面那个诊断开关，整套 16 条用例跑完后的 maps 合集）：真正被映射的 JDK 库
只有 **7** 个 —— `libjvm.so` `libjava.so` `libjimage.so` `libzip.so`（读 jar）
`libnet.so` `libnio.so`（IPv6 探测要走网络）、`libcxxabi_shim.so`。
另外 19 个（`libverify` `libjli` `libinstrument` `libattach` `libjdwp` `libdt_socket`
`libsaproc` `libmanagement*` `libjaas` `librmi` `libj2gss` `libj2pcsc` `libj2pkcs11`
`libextnet` `lible` `libprefs` `libsyslookup`）是**按需**的：JMX / RMI / SASL-GSSAPI /
智能卡 / 调试与 agent 那一摊，本套用例一次都没碰，但留着它们 JDK 才是"能用"的
（合计才约 4M）。真嫌大可以按这份实测再砍一轮，代价是那些能力直接
`UnsatisfiedLinkError`。
**砍掉的 13 个（含 libfreetype 同名冲突）一个都没被加载** —— 它们根本不随 HAP 走，
16 条用例全绿；需要的话第一次用到就会报错。

## R8 `UnpackRes` 的失败原来是静默的

解 rawfile 资源失败时它只 `return -1`，调用方又不看返回值，现场什么都查不到
（R3 就是先被这个瞒了一轮）。现在每条失败路径都补了一条 hilog
（`LOG_TAG=BSH_Shell`）：

```bash
hdc -t <sn> shell "hilog -x -T BSH_Shell"
```

能看到"打不开 rawfile / 大小为 <=0 / 落盘失败 errno=… / tar rc=… / 解包后仍找不到
标记文件"。查这种事别只盯 `$HOME/autorun.log`。

## R9 去掉 module.json5 里两条 kernel 权限之后（2026-09-28 实测）

`module.json5` 原本申请了两条跟可执行内存有关的权限：

```
ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY
ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION
```

把这两条**都删掉**、重新打包部署（其余四条文件/剪贴板/网络权限不动），同一套自检
跑出来的 A/B：

| 用例 | 有权限（基线） | 去掉两条权限 |
|---|---|---|
| `java -version` | ✅ `21.0.5-internal` | ❌ rc=1 `Error occurred during initialization of VM` / `Failed to mark memory page as executable - check if grsecurity/PaX is enabled` |
| `javac Hello.java` / `java Hello` | ✅ | ❌ 同一个错 |
| `jar --version` | ✅ rc=0 | ❌ rc=1 |
| `node`（V8，真 JIT） | ✅ | ✅ **而且 `process.execArgv` 里没有 `--jitless`** |
| clang / python3 / vim / ssh / npm / 退出码 / 信号 / 超时自检 | 全绿 | 全绿 |
| 合计 | **PASS=38 FAIL=0** | **PASS=35 FAIL=3**（3 条全是 java） |

结论（也是这张表最有价值的地方）：

1. **这两条权限不是"可执行内存"的唯一来源**。node 那条 `auto` 判定走的是
   `prctl(0x6a6974,0,0)` 夹层 + `mmap` + `mprotect(RWX)` —— 它**在没有权限时依然成功**
   （否则 auto 会给 node 加上 `--jitless`，而实测没加）。也就是说：**走 prctl 这条路
   不需要那两条权限**，这正是 V8 补丁（`patches/0001`）的机制。
2. **HotSpot 走的是裸 `mprotect(PROT_EXEC)`**，没有 prctl 夹层 —— 所以没权限时必然失败
   （它的报错文本就是 `mark memory page as executable` 失败）。
3. ⇒ **可落地改进**：给 HotSpot 打同样的 prctl 夹层（`src/hotspot/os/linux/os_linux.cpp`
   里 `os::commit_memory` / `os::protect_memory` 那条 `mprotect`），就能把这两条 kernel
   权限从 `module.json5` 里去掉。**当前没做**，所以现在仍需要这两条权限。

## 设备验收（2026-09-28，SN `3QC0225617000597`）

`feature/bsh_main/src/main/resources/rawfile/tools/autorun.sh` 里那套验收脚本（临时件，
每次会话启动跑一遍、结果写 `$HOME/autorun.log`）实测：

| 用例 | 结果 |
|---|---|
| `java -version` | ✅ `openjdk version "21.0.5-internal" 2024-10-15` / `OpenJDK 64-Bit Server VM (…, mixed mode)`，rc=0 |
| `java -XshowSettings:properties -version` | ✅ `java.home=$HOME/jdk21`、`sun.boot.library.path=/data/storage/el1/bundle/libs/arm64` |
| `javac Hello.java` | ✅ 产出 `Hello.class`，rc=0 |
| `java Hello` | ✅ `hello from OpenJDK on OHOS: aarch64/21.0.5-internal`，rc=0 |
| `javac -version` / `jar --version` | ✅ `javac 21.0.5-internal` / `jar 21.0.5-internal` |
| `jar cf h.jar Hello.class` / `jar tf h.jar` | ✅ 产出 jar、列出 `Hello.class` |
| `java -jar app.jar` | ✅ `from jar` |
| `javac Bad.java`（语法错误） | ✅ rc=1 |
| `System.exit(7)` | ✅ rc=7 |
| `java NoSuchClass` | ✅ rc=1 |
| `java -cp`（参数缺失） | ✅ rc=1（launcher 自己的 return 路径） |
| `java -XX:+NoSuchFlag` | ✅ rc=1（`Unrecognized VM option`） |

顺带确认：**26 个 .so 之外的 JDK native 库一个都没被加载**（那 13 个砍掉的
.so 根本不随 HAP 走，上面每条用例都跑通 —— 需要它们的话会在第一次用到时报
`UnsatisfiedLinkError`）。

launcher 里留了个诊断开关：**`$HOME/.jdk-trace` 文件存在**（或环境变量
`BSH_JAVA_TRACE_LIBS`）时，每次调用都会把 VM 选项、以及从 `/proc/self/maps` 里
挑出来的应用侧 .so 打到 stderr，并把**原始 maps** 追加到 `$HOME/.jdk-maps.txt`
（maps 行里路径后面偶尔还跟着别的东西，落原文事后 grep 才查得清）。
两条退出路径都打了：`leave()`（正常返回）与退出钩子（`System.exit`）——
不然后者（javac / jar）就看不到。
为什么不用环境变量作为唯一入口：宿主起子进程时用的是主进程 environ，终端里
`VAR=1 java …` 那种前缀赋值透不进去（见 `procmgr/bsh_exec.c` 的 `__wrap_execve`）。
平时零开销、零输出。

用它量出来的 `java -version` 实际映射的 JDK 库：
`libjvm.so` `libjava.so` `libjimage.so` `libcxxabi_shim.so`（外加上宿主的
`libentry.so` / `libc++_shared.so` / `libwayland-server.so` 与我们的
`libjdk.so`）；其余 22 个按需加载（`libzip` 读 jar 时、`libnet`/`libnio` 用网络时…）。
**砍掉的那 13 个一个都不需要**：它们根本不随 HAP 走，16 条用例全绿 —— 需要的话
第一次用到就会 `UnsatisfiedLinkError`。

## 产物：装进 HAP 的两部分

设备侧的 JDK 被拆成两块（R1 的理由）：

| 位置 | 内容 | 体积 |
|---|---|---|
| `feature/bsh_main/libs/arm64-v8a/`（→ 运行时 `/data/storage/el1/bundle/libs/arm64`） | JDK 的 26 个 `.so`，平铺 | 约 22M |
| `feature/bsh_main/src/main/resources/rawfile/tools/jdk21-ohos.tar`（→ 解到 `$HOME/jdk21`） | `lib/modules` / `conf/` / `tzdb.dat` / `ct.sym` / `lib/jrt-fs.jar` / `bin/` / `legal/` … | 148M / 397 项 |

tar 的顶层是 `jdk21/`（`--transform` 改的名），剔除了 `jmods`(79M)、`lib/src.zip`(52M)、
`demo`/`man`(6.6M) 与全部 `.so`；保留 `lib/ct.sym`(11M，javac `--release` 要用)。
未压缩（跟仓库里其它 rawfile tar 一致），gzip 后约 53M。

镜像目录里跟设备侧对得上的相对路径：

```
build/…/images/jdk/lib/modules             → $HOME/jdk21/lib/modules
build/…/images/jdk/conf/                   → $HOME/jdk21/conf/
build/…/images/jdk/lib/server/libjvm.so    → bundle libs/libjvm.so（平铺）
build/…/images/jdk/lib/libcxxabi_shim.so   → bundle libs（我们补进去的，所有 ELF 都 NEEDED 它）
build/…/images/jdk/lib/libjimage.so        → bundle libs（hotspot 从 dll_dir 找它）
```

launcher 里对应的环境变量/属性（`bsh_java_entry.cc`）：

```
JAVA_HOME              = $HOME/jdk21                → -Djava.home
SUN_BOOT_LIBRARY_PATH  = /data/storage/el1/bundle/libs/arm64
                                                    → 0003 补丁让 dll_dir 取它（不是 $JAVA_HOME/lib！）
-Djava.library.path    = 同一个目录                 → System.loadLibrary 的搜索路径
（LD_LIBRARY_PATH 也 set 了同一份，但那只是保险 —— 见 R2）
```

## 文件清单

```
scripts/build_jdk.sh                          阶段化构建脚本（src|sysroot|stubs|patches|configure|build|pack|install|all）
                                              install = 拷 .so 进 feature/bsh_main/libs + 重打 tar（幂等）
scripts/jdk-ohos/README.md                    本文件
scripts/jdk-ohos/patches/series               补丁清单
scripts/jdk-ohos/patches/0001..0012-*.patch   12 条补丁（每条头部有 症状/根因/修法）
scripts/jdk-ohos/stubs/cxxabi_shim.cpp        C++ ABI 垫片源码
scripts/jdk-ohos/stubs/eh_stubs.c             异常/operator new 等 C 侧符号
scripts/jdk-ohos/stubs/include/cups/*         CUPS 桩头（我们写的）
scripts/jdk-ohos/stubs/include/fontconfig/*   fontconfig 桩头（我们写的）
scripts/jdk-ohos/stubs/x11/include/X11/*      X11 桩头（我们写的）

scripts/jdk-ohos/bsh_java_entry.cc            java/javac/jar 三个入口（JNI_CreateJavaVM + sigchain + exit hook）
scripts/jdk-ohos/jni/{jni.h,jni_md.h}         从 JDK 镜像拷来的对应版本头（免得依赖 build/ 目录）
feature/bsh_main/src/main/cpp/procmgr/command_map.c      三条命令 → libjdk.so 的三个入口符号
feature/bsh_main/src/main/cpp/shell/shell.cpp            initResource 里加一行解 jdk21-ohos.tar（+ UnpackRes 失败落 hilog）
feature/bsh_main/src/main/cpp/CMakeLists.txt             删掉 jdkbsh 目标（改由 build_jdk.sh 编，见下）
scripts/build_jdk.sh                         launcher/install 阶段：编 libjdk.so + 拷 26 个 .so + 重打 tar
```

## 后续 / 未做

* `libjsound.so` 的 `snd_*` 全是空函数：真去用声音 API 会得到垃圾返回值。
  headless 场景用不到（而且它根本没随 HAP 走，见 R7）。
* **没有 AWT / 字体**：`libawt*` / `libfontmanager` / `libfreetype` 都不带（R7）。
  要让 Swing/AWT 真跑起来得另开一轮：至少得把 Qt 那份 `libfreetype.so` 与 JDK 的
  分开（改 soname 或换目录），再补 `fontconfig` / fontX11 之类。
* **没有 exec**：`Runtime.exec` / `ProcessBuilder` / `jspawnhelper` 在沙箱里不可用，
  `bin/java` 那三个可执行文件也别指望（tar 里带着只是为了完整）。
* launcher 是 `libjli/java.c` 的**等价子集**，没做的有：`@argfile`、
  `--list-modules` / `--describe-module` / `--validate-modules` / `--dry-run`、
  `-Xbootclasspath`。真需要哪条再补。
* `java Foo.java`（源码启动）按 java.c 的做法接了（换成
  `jdk.compiler/…/launcher.Main` + `--add-modules=ALL-DEFAULT`），但没实测。
* qemu 冒烟测试用的是通用 musl 1.2.2 + 一个 `dlvsym` 转发；真机是 OHOS 的 musl
  （自带 `dlvsym`），两边都跑通了。

