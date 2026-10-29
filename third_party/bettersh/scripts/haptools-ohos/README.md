# haptools-ohos — 设备侧的原生签名/打包工具（+ java 转发壳）

这个目录是 `scripts/build_haptools.sh` 的**构建期规格目录**：上游源码树之外的兼容层、补丁、
第三方替身、以及那个 `java` 转发壳的源码都在这儿。它是**纯输入**——产物全在 `build/haptools/`
与 `dist/pkgs/haptools.tar.zst`。

```
compat/                          上游依赖的替身（OHOS 源码树才有的东西）
  hapsigntool/{securec.h,securec.cpp,host_compat_prefix.h}
  packing_tool/{securec.h,securec.cpp,host_compat_prefix.h,nlohmann/json.hpp}
patches/                         只能靠改调用点解决的两处平台差异（都只给打包工具）
  0001-ifstream-from-directory-entry.patch
  0002-no-std-locale-for-ascii-lowercase.patch
third_party/                     hapsigntool 要的第三方（与上游 BUILD.gn 的 external_deps 对应）
  cJSON.{h,c}
  contrib/minizip/{unzip.h,unzip.c,ioapi.h,ioapi.c,crypt.h}
javawrap/javawrap.c              usr/bin/java 的转发壳（动态 musl，见下）
```

上游由 `scripts/build_haptools.sh src` clone 到 `thirdparty/developtools_hapsigner` 与
`thirdparty/developtools_packing_tool`，**只读**：编译时整棵拷进 `build/haptools/<tool>/src`，
补丁打在副本上。

## 这两个工具是干什么的

| 产物（`usr/bin/`） | 上游 | 为什么需要 |
| --- | --- | --- |
| `hap-sign-tool` | `developtools_hapsigner/hapsigntool_cpp` | hvigor 的 `@SignHap` 用 `java -jar hap-sign-tool.jar sign-app …` 给 HAP/so 签名，沙箱里 JVM 起不来 |
| `app_packing_tool` | `developtools_packing_tool/packing_tool/frameworks` | hvigor 的 `@PackageHap` 用 `java -jar app_packing_tool.jar --mode hap …` 打 HAP，同样起不来 |
| `java` | `javawrap/javawrap.c` | 把上面两条 `java -jar …` 命令行接到原生工具上 |

## 为什么走 C++ 版而不是 Java 版

两个仓库里都有 Java 实现（`hap-sign-tool.jar` / `app_packing_tool.jar`），但**这台设备跑不了
JVM**：

```
Error occurred during initialization of VM
Failed to mark memory page as executable
```

当前应用没有 jit 权限，沙箱拒绝 RW→RX 的可执行内存（同一类限制见
`scripts/glibc-ohos/README.md`）。所以问题不是"缺 Java 代码"，而是"缺一个能在无 jit 沙箱里
跑起来的原生执行体"。两个仓库的 C++ 实现与 Java 版**同源**（`app_packing_tool` 的
命令行解析 `shell_command.cpp` 与 jar 版同源，hvigor 传的全部 flag 在 `constants.h` 的
`LONG_OPTIONS` 里都有；`hap-sign-tool` 的 11 个命令与 Java 版对齐），编成 aarch64 静态
可执行文件即可。

两个产物都是 `Type: EXEC`、**无 PT_INTERP、无 DT_NEEDED**（纯静态，musl），设备里由
elfloader 装进匿名内存执行——与先例 `build/hapsigntool_cpp/build-aarch64.sh` 完全同形态。
宿主机上也能直接用 `qemu-aarch64` 跑（不需要任何 `.so`）。

## 依赖替身与补丁

上游是 GN + ohos-sdk 构建，依赖 OpenHarmony 源码树里的第三方。musl 交叉工具链里没有它们，
本目录用**替身**顶上（与两个原型 `build/hapsigntool_cpp`、`build/packing-tool-ohos` 一致）：

| 上游依赖 | 替身 | 说明 |
| --- | --- | --- |
| `<securec.h>`（`bounds_checking_function`） | `compat/*/securec.{h,cpp}` | 签名工具用到 8 个安全函数，打包工具只用到一个 `vsnprintf_s`——**按实际用量各留一份**，不硬凑成一个并集 |
| `"cJSON.h"` | `third_party/cJSON.{h,c}` | 与两个原型同一份 |
| `"contrib/minizip/{zip,unzip}.h"` | `third_party/contrib/minizip/*`（签名工具）<br>`thirdparty/zlib/contrib/minizip/*`（打包工具） | 签名工具只要 `unzip`，打包工具还要 `zip`，后者直接用本仓 zlib 源码 |
| `"nlohmann/json.hpp"` | `compat/packing_tool/nlohmann/json.hpp` | `--stat-duplicate` 只用 10 行用法 |
| OHOS 工具链传递包含图里的 `<vector>`/`<filesystem>`/`<limits.h>` 等 | `compat/*/host_compat_prefix.h`（`-include`） | 上游几个头依赖 OHOS clang 的传递包含图恰好带进来；只补声明不补行为，任何真实语义差异仍会被编译器抓到 |

`patches/` 里的两个补丁是**重载决议 / 运行期库行为**差异，`-include` 补不上，只能改调用点
（每个补丁文件头都写了完整的"症状/根因/修法"）：

- `0001-ifstream-from-directory-entry` — libc++ 的 `basic_ifstream` 有直接吃
  `std::filesystem::directory_entry` 的重载，libstdc++ 11 只有 `const std::string&`/`const char*`，
  而 `directory_entry → path → string` 是两次用户定义转换，语言上不允许隐式完成；
  显式写 `entry.path().string()`。
- `0002-no-std-locale-for-ascii-lowercase` — 上游为了 ASCII 小写化构造
  `std::locale("en_US.UTF-8")`，而 musl **不提供 locale 数据**，构造即抛
  `std::runtime_error`，被 `IsPathValid` 的 `catch (...)` 吞成 "Param parse error"，
  整个打包在参数校验阶段就死；改用 `<cctype>` 的 `std::tolower`（纯 ASCII 语义一致）。

上游仓库一个字节都不动：补丁只打在 `build/haptools/<tool>/src` 的副本上。

## javawrap：`usr/bin/java`

`javawrap/javawrap.c` 编出来的 `java` 是个**转发壳**，不是 JVM：

1. 扫 argv 找 `-jar`，取它后面那个 jar 的 basename；
2. 按 basename 映射到**同一个目录下**的原生工具：

   | jar basename | 原生工具 | 环境变量覆盖 | 补的子命令 |
   | --- | --- | --- | --- |
   | `hap-sign-tool.jar` | `hap-sign-tool` | `BSH_SIGN_TOOL` | 无 |
   | `app_packing_tool.jar` | `app_packing_tool` | `BSH_PACKING_TOOL` | 条件补 `pack` |
   | `hmos_app_packing_tool.jar` | `app_packing_tool` | `BSH_PACKING_TOOL` | 条件补 `pack` |

3. 把 `-jar <jar>` **之后**的参数原样交给它（`-jar` 之前的 `-Dxxx`/`-Xmx` 这类 JVM 选项不转发），
   `execv` 换过去；
4. 认不出的 jar 直接打一行清楚错误并非零退出——JDK 版 `java` 没内置，不假装能跑。

**为什么给打包工具补一个 `pack`**：原生 `app_packing_tool` 的 CLI 是
`app_packing_tool {help|pack|unpack} <选项…>`（`argv[1]` 必须是这三个之一，见上游
`shell_command.cpp` 的 `commandMap_`），而 hvigor 给 jar 的是 `--mode hap …`（没有子命令，
见 hvigor 的 `packing-tool-options.js`）。所以只在**首参缺失、或首参以 `-` 开头**时补一个
`pack`；调用者自己写了 `help`/`unpack` 这类真子命令就原样透传，避免变成 `pack help`。
`hap-sign-tool` 不用补，hvigor 本来就传 `sign-app`。

**为什么是动态 musl，而不是像那两个工具一样静态**：本项目的 shim（tty / 软链 / **exec 委托**）
在 guest 侧只走 `LD_PRELOAD` 符号插入，静态 guest 没有动态符号表、吃不到 preload（见仓库
根 `README.md` 的「明确不做：静态链接的 guest」，以及
`feature/bsh_main/src/main/cpp/shim/README.md` §11.5）。而这个程序存在的全部意义就是
**exec 另一个程序**——沙箱里 guest 调 `execve` 一律 `EACCES`，必须由 `exec_shim` 委托给
procmgr 创建进程。静态 guest 的 `execv` 会直接打到内核/SDK 的 noexec 限制上。所以它必须
动态链（用 OHOS SDK 的 clang + `--target=aarch64-linux-ohos --sysroot=<SDK>/sysroot`，
PT_INTERP 是 `/lib/ld-musl-aarch64.so.1`，由 bundle libs 提供）。先例：设备侧的
`make`/`ninja`（`devtools` 包）与 `clang`（`ohos-sdk-prune` 包）都是动态 musl guest，靠这条
路起子进程，实测能跑。

工具路径的定位顺序：`BSH_SIGN_TOOL`/`BSH_PACKING_TOOL`（整条路径覆盖）→ `/proc/self/exe`
的 readlink 拿到的自己所在目录（本项目 shim 会把 guest 自己的路径填给它）→
`$BSH_SYSROOT/usr/bin`（`BSH_SYSROOT` 是 procmgr 一定会设的环境变量）。

## 怎么构建

```bash
./scripts/build_haptools.sh all          # src + deps + build + javawrap + pack
```

各阶段可单独重跑：

| 阶段 | 做什么 |
| --- | --- |
| `src` | `git clone --depth 1` 两个上游仓到 `thirdparty/`（已存在则跳过；不 pull、不碰远端），并把两条路径补进根 `.gitignore` |
| `deps` | zlib + openssl 静态库。**默认复用 `build/hapsigntool_cpp/aarch64/sysroot`**（同工具链同 ABI）；不存在才自己编（openssl 优先用 `thirdparty/openssl-*`，否则下载 3.0.13） |
| `build` | 编出 `build/haptools/out/{hap-sign-tool,app_packing_tool}` |
| `javawrap` | 编出 `build/haptools/out/java`（动态 musl） |
| `pack` | 产出 `dist/pkgs/haptools.tar.zst`，顶层只有 `usr/bin/{hap-sign-tool,app_packing_tool,java}`，**无软链**（pkg 的 tar 解包器 `programs/pkg/bsh_tar.c` 只认普通文件/目录） |

可覆盖的变量：`MUSL_TOOLCHAIN`、`OPENSSL_PREFIX`、`OPENSSL_SRC`、`ZLIB_SRC`、
`GITCODE_HAPSIGNER`/`GITCODE_PACKING`、`JOBS`。

## 与原型的两点差异

- 原型里 `build/hapsigntool_cpp/inc/contrib/minizip/unzip.h` 与
  `third_party/contrib/minizip/unzip.h` 逐字节相同，`-I inc` 被 `-I third_party` 完全覆盖——
  不是"编译必需"，所以没有搬进来。
- 两份 `compat`（签名/打包）**保留各自的版本**（`securec` 的函数集合、`host_compat_prefix.h`
  的包含集合都不同），没有合并成一份。
