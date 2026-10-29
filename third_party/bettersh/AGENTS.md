# AGENTS.md — BetterSH 开发指引（给 AI 编码代理）

本文件面向**对本项目一无所知**的读者，概述仓库结构、技术栈、构建/测试流程与本项目特有的
约定。内容全部依据仓库中的实际文件与脚本整理；更深的机理、历史与踩坑记录见 `README.md`
（约 1500 行，是权威长文档）与 `CHANGELOG.md`（按版本记录"为什么"）。

项目文档、代码注释、提交信息**一律用中文**。新增代码请沿用这一点。

---

## 1. 项目概述

**BetterSH** 是一个运行在 **HarmonyOS** 上的终端模拟器 App。

- bundleName `com.yiyan.bettersh`，versionName `0.8.0`，versionCode `1000005`
  （`AppScope/app.json5`）。
- 前端用 **ArkTS + WebView + xterm.js** 渲染终端；native 侧（C/C++）自己实现了一套
  **软 pty**、一个**迷你 shell**、一个 **in-process elfloader**（无 `exec` 沙箱里装载
  aarch64 ELF）、一个 **Wayland compositor**，以及一个**进程管理器 procmgr**。
- 外部程序（`toybox`/`mksh`/`vim`/`python`/`node`/`ssh`/`zip`/`box64`/`qemu`…）以
  `.so` 形式随 HAP 打包，由 shell 经 procmgr `dlopen` 后调用其入口符号。**沙箱里几乎
  没有真 `exec`、没有真 pty、不能建符号链接**——这些缺口由一组 shim 在用户态模拟。
- 目标平台：**仅 arm64-v8a**。若某些"根路径"（如 `/bin`、`/usr/lib`）在宿主上不存在，
  有 sysroot 绝对路径回退等机制。

这是一台"把 POSIX 环境搬进 HarmonyOS 沙箱"的工程，**大量时间花在跟沙箱、ABI 与进程边界
打交道**，因此"结论/原因"往往比代码本身更重要——改动前先读相关注释。

---

## 2. 技术栈与运行时架构

### 2.1 语言与工具

- **ArkTS**（HarmonyOS Stage 模型）写 UI 与 Ability；native 通过 NAPI（`libentry.so`）暴露。
- **C17（gnu11）+ C++17**：native 主体；CMake 构建（`feature/bsh_main/src/main/cpp/CMakeLists.txt`），
  C++ 标准在 CMake 里设为 17。
- 交叉编译用 **OHOS SDK 自带 clang/clang++**（`$OHOS_SDK/native/llvm/bin`，
  `--target=aarch64-linux-ohos --sysroot=$SYSROOT`）。部分目标用 musl 交叉工具链
  （`MUSL_TOOLCHAIN`，见 §5）。
- 构建系统：**Hvigor**（`hvigorw assembleHap`），配置 `modelVersion 6.1.1`；
  根 `hvigorfile.ts` 用 `appTasks`，各 product 的 `hvigorfile.ts` 用 `hapTasks`。

### 2.2 运行时分层（详见 README「架构总览」）

```
ArkTS:  EntryAbility → 页面(Index/ClientWindow) → WebView(xterm.js)
          └ WaymonyService → AppRunnerAbility(multiton) → ClientWindow(子窗口)
终端:   BasicShell(shell.cpp) → softpty(socketpair) → procmgr(control socket)
          ├ 命令 so → dlopen + 调入口符号
          ├ shim(fs/tty/pty/exec/dlopen)
          ├ elfloader(同 ISA aarch64) / box64(x86_64) / qemu-user(无 jit 兜底)
          └ 命令表 command_map.c
Wayland: WaylandServer(compositor 线程) → 每 toplevel 一个独立子窗口
以上 native 全部经 libentry.so(NAPI) 与 ArkTS 交互
```

**procmgr 是全工程唯一的 `fork`/进程创建入口**（`feature/bsh_main/src/main/cpp/procmgr/`）。
shell 自己不 `fork`，统一发 CREATE 帧给 `<资源根>/bsh-ctrl.sock`。改"起一个程序"的逻辑，
改 `procmgr.cpp` 的 `Resolve()`，不要在各命令 so 里另起一套判断。

---

## 3. 仓库结构与模块划分

```
AppScope/                  应用级配置与图标（app.json5 定义 bundleName/version）
feature/bsh_main/          共享 HAR：ArkTS 界面 + native(libentry.so) + rawfile 资源
  Index.ets                对外出口（两个薄 entry re-export 这里的 ability 与页面组件）
  build-profile.json5      HAR 构建配置（abiFilters=arm64-v8a；native 在这里编）
  libs/arm64-v8a/          命令 so / wayland so（脚本产出，gitignore）
  src/main/
    module.json5           HAR 声明（name=bsh_main / type=har，入库）
    ets/                   entryability/ apprunnerability/ terminalrunnerability/
                           entrybackupability/ service/ pages/ components/ utils/
    resources/rawfile/     term/（xterm.js 前端） + tools/（tar 生成物 + hello.c 等）
    cpp/                   native 源码（见下）
    test/ ohosTest/ mock/  hypium 测试脚手架（见 §7）
product/tablet/            薄 entry：平板 + 2in1（带 JIT 权限）
product/phone/             薄 entry：手机（无 JIT 权限）
  build-profile.json5      entry 构建配置（无 native，全部来自 HAR）
  src/main/module.json5    设备类型 + 权限集合（不入库，由 versions/ 提供；基线见 .example）
  src/main/ets/            ability 薄子类 + @Entry 页面壳（真正实现在 HAR）
scripts/                   构建/签名/部署脚本 + 各平台补丁目录（glibc-ohos/ musl-ohos/ …）
thirdparty/                git submodule + 下载解压的非 git 源码
build/ dist/ versions/     构建中间产物 / wayland SDK 交付物 / 发行变体快照（均不入库）
```

### 3.1 为什么分 HAR + 两个薄 entry

HarmonyOS **权限只能按模块给**：`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`
（JIT 必需）在手机上拿不到，平板/2in1 要给。`module.json5` 每模块一份，所以想要"同一个
应用、按设备给不同能力"就必须有多个 entry 模块。两个 entry 都是几十行壳，真正的代码只在
HAR 一份。**改代码基本只需动 `feature/bsh_main/`**；`product/*` 只在加设备/权限时改。

### 3.2 native 源码目录（`feature/bsh_main/src/main/cpp/`）

| 目录 | 内容 |
| --- | --- |
| `common/` | `bsh_paths.h`（应用私有目录布局 + 运行期访问器 `bsh_sysroot()` 等）、`bsh_rawfile.cpp`（rawfile 统一访问口） |
| `logger/` | `logger.h`/`logger.cpp` 日志门面：printf 风格的 `LogI/LogW/LogE`，输出目标（hilog / stdout / 会话 tty / 文件）运行期可切换 |
| `procmgr/` | `procmgr.cpp`（决策+fork+进程表）、`command_map.c`（命令表）、`ctrl_socket.cpp`、`caps.cpp`、`bsh_client.c`（客户端） |
| `shell/` | `shell.cpp`、`lineedit.cpp`（行编辑器）、`lexer.cpp`（分词/展开）、`complete.cpp`（Tab 补全）、`rcfile.cpp`（`.bshrc`） |
| `shim/` | `fs_shim.c`（软链模拟）、`tty_shim.c`、`pty_shim.c`、`exec_shim.c`、`open_shim.c`、`dlopen_shim.c`、`netif_shim.c` 等；**必读 `shim/README.md`** |
| `tty/` | `softpty.cpp`、`bsh_tty.cpp`（共享 termios，按会话号 sid 分）、`bsh_pty.c`（weston-terminal 的 forkpty/ioctl/read wrap） |
| `elfloader/` | `elf_loader.cpp`、`elf_dl.cpp`（进程内 dlopen 兜底）、`guest_switch.S`、`tlsdesc.S` |
| `wayland/` | compositor 相关（`include/`、`protocol/` 为生成物，gitignore） |
| `bshutil/` | `bshutil.cpp`（子命令实现）、`bsh_cfg.cpp`、`ui_bus.cpp`、`bsh_util_server.cpp` |
| `ssh/` | `sandbox_compat.c`、`pwshim.c`（dropbear 沙箱适配） |
| `programs/` | 示例与独立程序：`hellobsh/`、`wldemo/`、`testx64/`、`bshutil/`、`pkg/`、`selfexe/` 等 |
| `types/libentry/` | `libentry.so` 的 ArkTS 声明（`Index.d.ts`），**必须与 `napi_init.cpp` 的导出保持一致** |

### 3.3 ArkTS 侧的入口关系

- HAR 的 `feature/bsh_main/Index.ets` 统一导出 `EntryAbility`/`AppRunnerAbility`/
  `TerminalRunnerAbility`/`EntryBackupAbility` 与页面组件 `Index`/`ClientWindow`。
- **HAR 里的页面组件不带 `@Entry`**；`@Entry` 由 `product/<名>/src/main/ets/pages/Index.ets`
  这类薄壳提供（`loadContent('pages/Index')` 只在当前模块解析路由）。路由表在
  `product/<名>/src/main/resources/base/profile/main_pages.json`（`pages/Index`、`pages/ClientWindow`）。
- 主终端页是 `feature/bsh_main/src/main/ets/pages/Index.ets`（`@Component struct Index`），
  由会话号 `sid` 区分窗口（0 = 主窗口，>0 = `bshutil newtab` 开的 tab）。
- native 导出在 `napi_init.cpp` 注册，`types/libentry/Index.d.ts` 是 ArkTS 侧声明。

---

## 4. 关键配置文件

| 文件 | 作用 | 是否入库 |
| --- | --- | --- |
| `AppScope/app.json5` | bundleName/versionName/versionCode/图标 | ✅ |
| `build-profile.json5`（根） | products/modules/signingConfigs，SDK 版本 | ❌（gitignore；从 `build-profile.json5.example` 拷） |
| `build-profile.json5.example` | 根 profile 模板（`signingConfigs` 为空） | ✅ |
| `feature/bsh_main/build-profile.json5` | HAR：`abiFilters=[arm64-v8a]`、`externalNativeOptions.path=cpp/CMakeLists.txt` | ✅ |
| `feature/bsh_main/oh-package.json5` | HAR 包元数据，依赖 `libentry.so: file:./src/main/cpp/types/libentry` | ✅ |
| `feature/bsh_main/src/main/module.json5` | HAR 声明 | ✅ |
| `product/<名>/build-profile.json5` | entry 构建配置（无 native） | ✅ |
| `product/<名>/oh-package.json5` | 依赖 `bsh_main: file:../../feature/bsh_main` | ✅ |
| `product/<名>/src/main/module.json5` | 设备类型 + 权限集合 | ❌（由 `scripts/switch_version.sh` 生成；基线 `module.json5.example`） |
| `oh-package.json5`（根） | devDeps：`@ohos/hypium` / `@ohos/hamock` | ✅ |
| `code-linter.json5` | ETS 静态检查（`@performance`、`@typescript-eslint`、`@security/*`） | ✅ |
| `hvigor/hvigor-config.json5` | Hvigor 配置（`modelVersion 6.1.1`） | ✅ |
| `scripts/env.sh` | 构建公共环境变量（被所有脚本 source） | ❌（从 `scripts/env.sh.example` 拷） |
| `.gitmodules` | 子模块来源与版本 | ✅ |

**SDK 版本**：`compatibleSdkVersion 6.1.0(23)` / `targetSdkVersion 6.1.1(24)`
（根 `build-profile.json5`）。`runtimeOS: HarmonyOS`，`nativeCompiler: BiSheng`。

---

## 5. 环境准备

需要 DevEco Studio（或 command-line-tools）提供的 OHOS SDK；交叉编译走 SDK 自带 clang。
宿主还需要 `meson`/`ninja`/`pkg-config`、`python3`、`java`、`tic`（vim 的 ncurses fallback）。
`hdc`（HarmonyOS 设备连接工具）用于部署。

```bash
git submodule update --init --recursive

cp scripts/env.sh.example scripts/env.sh
cp build-profile.json5.example build-profile.json5   # 再填入 signingConfigs
```

`scripts/env.sh`（不入库）里需要留意的变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `TOOL_HOME` | `/apps/harmony` | command-line-tools 根，需有 `bin/hvigorw` |
| `OHOS_SDK` | `$TOOL_HOME/sdk/default/openharmony` | SDK 路径 |
| `HDC` | Windows 下 `hdc.exe` 路径 | 部署脚本使用 |
| `BUILD_PROFILE_FILE` | `/mnt/c/.../build-profile.json5` | 备用签名配置来源（`build_test.sh` / `switch_version.sh` 用；`sign_hap.sh` / `build_release.sh` 默认读仓库根的 `build-profile.json5`） |
| `BUNDLE_NAME` | `com.yiyan.bettersh` | 安装/卸载使用 |
| `DEVICE_SN` | 空 | 目标设备序列号，空则用 `hdc` 默认设备 |
| `NATIVE_ARCH` | `arm64-v8a` | 也接受 `x86_64`（未验证） |
| `MUSL_TOOLCHAIN` | 指向 ElfLoaderDemo 里的 aarch64-linux-musl-cross | **不在 `env.sh.example` 里，需自己 `export`**；多个 build 脚本读它 |

脚本还默认会探测 WSL 下的宿主代理（`BSH_PROXY_HOST`/`BSH_PROXY_PORT` 可覆盖），
仅在探测到端口可达时启用。

---

## 6. 构建流程与常用命令

### 6.1 推荐顺序（详见 README「构建步骤」）

命令 so 与 rawfile tar 是**分步产出**的，HAP 需要在它们产出后再打一次。典型流程：

```bash
# 0) 子模块
git submodule update --init --recursive

# 0.5) 依赖解析：两个 entry 通过本地 file: 依赖引 feature/bsh_main，不会自动链。
#      第一次构建前必须跑一次（会把各模块的 oh_modules 建好；libentry.so 类型声明也随之生效）
ohpm install

# 1) Wayland 必须先于 build_hap（CMakeLists 链接 libwayland-server.so 并编译 wayland/protocol/*.c）
./scripts/build_wayland.sh

# 2) 首次 build_hap：把 wayland so 与 native 编进 HAP
./scripts/build_hap.sh

# 3) 各命令 so / guest 运行时（按需，产物进 feature/bsh_main/libs/arm64-v8a/ 或 rawfile/tools/）
./scripts/build_toybox.sh      # libtoybox.so
./scripts/build_fastfetch.sh   # libfastfetch.so
./scripts/build_vim.sh         # libvim.so、rawfile/tools/vim-runtime.tar
./scripts/build_mksh.sh        # libmksh.so
./scripts/build_shim.sh        # libbshguest-{musl,glibc}.so
./scripts/build_glibc.sh       # 自编 ld-linux-aarch64.so.1 + libc.so.6
./scripts/build_musl.sh        # 打补丁的 ld-musl-aarch64.so.1
./scripts/build_node.sh        # libnode.so、rawfile/tools/npm.tar
./scripts/build_python.sh      # libpython.so、rawfile/tools/python-stdlib.tar（需先 build_openssl.sh）
./scripts/build_zip.sh         # libzipcmd.so、libunzipcmd.so
./scripts/build_box64.sh       # libbox64.so
./scripts/build_qemu.sh        # libqemu-{aarch64,x86_64}.so（TCI 解释执行）
./scripts/build_dropbear.sh    # libsshcore.so
./scripts/build_testprogs.sh   # rawfile/tools/testprogs.tar（9 个 ABI 组合验收程序）

# 4) 再次 build_hap：把以上 .so 与 tar 打进 HAP
BSH_PRODUCT=tablet ./scripts/build_hap.sh    # 或 phone；默认 tablet

# 5) 签名 + 部署
./scripts/build_test.sh                      # 设备自测一条龙（见下）
```

**产物目录**：编译出的 `.so` 落 `feature/bsh_main/libs/arm64-v8a/`，tar 落
`feature/bsh_main/src/main/resources/rawfile/tools/`，最终 HAP 在
`product/<BSH_PRODUCT>/build/default/outputs/default/`。

### 6.2 分包构建

`BSH_PRODUCT=tablet|phone` 决定构建哪个 entry（默认 `tablet`）。`scripts/env.sh` 会据此
设置 `HAP_OUT_DIR` 等路径。

### 6.3 签名与部署

- `scripts/build_test.sh` —— **设备自测的固定入口：release 构建模式 + `debug-jit` 签名 +
  部署 + 拉起**。不要手拼这两个组合：签名会改变沙箱策略（`app.debug` 影响文件沙箱严格度），
  真正的 `release` profile 签出来的包 `hdc` 装不上（`not trusted app source`）。
  可用 `SKIP_DEPLOY=1`、`SKIP_BUILD=1`、`WAIT=1`、参数 `<serial|ip:port>`。
- `scripts/build_release.sh` —— 出**发布用**的包（release 模式 + `release` signingConfig，
  同时产出 `.hap` 与 `.app`）。签名材料默认读**仓库根的 `build-profile.json5`**
  （`SIGN_PROFILE_FILE` 可换，`SIGN_CFG_NAME` 选配置）。App Pack 必须"先签 hap → 重打 .app →
  再签 .app"，细节见脚本注释。
- `scripts/sign_hap.sh [<unsigned.hap>] [<signingConfigName>]` —— 底层签名（依赖 `java`/`node`）。
  签名材料默认读**仓库根的 `build-profile.json5`**（`SIGN_PROFILE_FILE` 可换），选哪一项由第二个
  位置参数或 `SIGN_CFG_NAME` 定（缺省 `debug`）。产物默认 `$HAP_OUT_DIR/<product>-default-signed.hap`。
- `scripts/sign_hap.py <profile.json5> <in> <out> [name]` —— 直接调 `hap-sign-tool.jar` 的那层。
- `scripts/debug.sh` —— 本机调试一条龙：debug 模式构建 + `debug` 签名 + 部署 + 拉起 + 轮询 autorun。
- `scripts/deploy_hap.sh [<ip:port>|<serial>]` —— 安装到设备；会先 `bm uninstall`
  （**等于清空应用资源根**与 `$HOME`）。
- `scripts/switch_version.sh [<名>] [-n]` —— 在 `versions/<名>/` 的发行变体间切换
  （改 bundleName/label、覆盖 entry 的 `requestPermissions`、提示该用哪套签名）。
  `versions/` 整目录不入库。

---

## 7. 测试与验收

本项目**没有统一的单测入口**，测试分几层，各有各的命令：

### 7.1 宿主机单测（不需要设备）

shell 的行编辑器 / 分词展开 / 补全 / `.bshrc` 解析，判据都在这个自测里（README 中给出）：

```bash
g++ -std=c++17 -O1 -g -Wall -Wextra -fsanitize=address,undefined \
    -Ifeature/bsh_main/src/main/cpp/shell \
    feature/bsh_main/src/main/cpp/shell/{lineedit,lexer,complete,rcfile}.cpp \
    feature/bsh_main/src/main/cpp/shell/lineedit_selftest.cpp -o /tmp/bsh_shell_tests \
  && /tmp/bsh_shell_tests
```

shim 自测（在 `shim/` 目录里，用 `gcc` 编，真软链 vs 模拟两种跑法逐字节对拍）：
`fs_shim_selftest.c`、`pty_shim_selftest.c`，编法与判据见 `shim/README.md` §7。

### 7.2 开发机验收程序（9 种 ABI 组合）

`feature/bsh_main/src/main/cpp/programs/testx64/main.c` 是同一份源码编出的验收程序
（stdio/fs/symlink/pty/tty/signal/线程/fork/共享内存/auxv/JIT/dlopen/exec/`/proc/self/exe`…）。
`scripts/build_testprogs.sh` 按 arch × libc × 链接方式编出 9 个组合，先在开发机跑：

```bash
./scripts/run_testprogs_host.sh   # x86_64 原生 + aarch64 走 qemu-user，要求 0 FAIL
```

x86_64 组合里 auxv/jit/maps 三条"沙箱判据"会跳过（本地无意义），其余用例照常断言。

### 7.3 设备侧自检

- `rawfile/tools/autorun.sh`（**本地临时件，已 gitignore**）由 `shell.cpp` 每次会话启动时
  后台跑一遍，日志落 `$HOME/autorun.log`；用 `./scripts/wait_autorun.sh` 取结果。
- `rawfile/tools/autorun-all.sh`（**已入库的完整版**）每次会话只**落盘**到 `$HOME`、不自动跑，
  需要时手动 `sh $HOME/autorun-all.sh`。末行 `=== autorun 结果: PASS=n FAIL=n ===` 便于 grep。
  注意其中个别小节会触发"是否运行 xxx"确认框，会把应用冻住。
- `scripts/build_hap.sh` 在打包前有一道**半成品自查**：扫 `feature/bsh_main/libs/arm64-v8a/*.so`
  有无未定义的 `__wrap_`/`__real_` 符号（wrap 清单与链接的 `.o` 不匹配会导致 `dlopen`
  直接失败），不通过就不让打包。

### 7.4 hypium（ArkTS）测试脚手架

`feature/bsh_main/src/test/`（LocalUnit，`LocalUnit.test.ets`/`List.test.ets`）与
`src/ohosTest/`（`Ability.test.ets`，instrumented）是 DevEco 生成的 hypium 模板，
当前只有示例用例。`src/mock/` 是 `libentry.so` 的 mock。**新增 ArkTS 测试放这里**，
用 `@ohos/hypium` 的 `describe`/`it`/`expect`。

---

## 8. 代码风格与开发约定

### 8.1 通用

- **注释与文档一律中文**，且倾向解释"为什么"（项目历史决定了很多看似奇怪的写法）。
- 提交信息、脚本头部注释都用中文。
- 生成物不进库：`feature/bsh_main/libs`、`dist/`、`rawfile/tools/*.tar`、
  `cpp/wayland/{include,protocol}`、`build-profile.json5`、`scripts/env.sh`、`versions/`
  均被 `.gitignore` 排除（见 `.gitignore`，里面有逐条说明）。

### 8.2 C/C++

- C 用 `gnu11`（shim 明确要求），C++ 用 C++17。
- 函数/文件命名以 `bsh_` 前缀为主；环境变量以 `BSH_` 前缀为主。
- 命令 so 的入口符号**不要用 `main`**：用 `-Dmain=bsh_xxx_main` 或
  `objcopy --redefine-sym`，并聚合为 `-shared -Wl,-soname,<name>.so`。
- 命令 so 若会 exec / 需要 tty，必须链接 `scripts/shim-wrap-flags.sh` 的
  `$SHIM_WRAP_FLAGS`，并链入 `procmgr/bsh_client.o`（向 procmgr 下单）。
  **`--wrap=<名>` 必须有对应的 `__wrap_<名>` 定义在该 so 的链接里**，否则是 `dlopen`
  直接失败（清单只有这一份，命令 so 都链同一套 shim：fs + tty + open + exec）。
- 命令 so **不需要 `libentry.so`**：tty 状态与 exec 委托都走 control socket，
  产物的 `NEEDED` 里应只有 `libc.so`。

### 8.3 ArkTS

- 页面/Ability 用 `@Component`/`@Entry`/`@Ability` 结构；HAR 里的页面组件**不带 `@Entry`**
  （由 product 薄壳提供，见 §3.3）。
- 新增 native → ArkTS 的接口时，**同一改动里同时更新** `napi_init.cpp` 的注册与
  `types/libentry/Index.d.ts` 的声明（两者必须一致）。
- ETS 受 `code-linter.json5` 检查（含 `@security/no-unsafe-*` 等安全规则）。

### 8.4 新增一个命令 so 的步骤（README 有完整版）

1. 加源码（子模块或 vendored），确认许可证与目标 ABI；
2. 编成 `.so`（入口改名 + `-shared -Wl,-soname,…`）；会 exec/需要 tty 的链 shim 与 `bsh_client.o`；
3. 在 `procmgr/command_map.c` 的 `kMap` 注册 `{ "cmd", "libX.so", "入口符号" }`
   （procmgr 启动时会按表生成 `<资源根>/bin/cmd` 这个 `#BSHSO` 启动器文件）；
4. 若需随包资源，打成 `rawfile/tools/*.tar` 并在 `shell.cpp` 的 `initResource()` 里加一条；
5. 验证：看 hilog 中 `dlopen` 是否成功、`NEEDED` 是否只有 `libc.so`。

最小示例：`feature/bsh_main/src/main/cpp/programs/hellobsh/hellobsh.cpp`。

---

## 9. 安全与沙箱约束（务必先读）

这台设备的沙箱缺了几样本该有的能力，**每条都有应用内的对策**——不要"绕过"，要沿用它：

| 缺口 | 现象 | 对策 | 位置 |
| --- | --- | --- | --- |
| 不能建**符号链接** | `symlink()` 三层、所有可写目录 `EACCES`（硬链接可以） | 用户态模拟：`foo -> t` 表示成普通文件 `foo.BSH_SYMLINK`（内容=目标串） | `shim/fs_shim.c` |
| 拿不到 **pty** | `open("/dev/ptmx")` EACCES | 假 pts：socketpair 当 master/slave，`grantpt/unlockpt/ptsname/ioctl` 假实现 | `shim/pty_shim.c` |
| guest 里**不能 exec** | `execve` 一律 EACCES | 委托给 procmgr（进程只能由它创建）；命令 so 走 `--wrap`，guest 走 `LD_PRELOAD` | `shim/exec_shim.c` |
| guest 看不到 **tty** | 会话是 softpty，`isatty` 恒 0 | 按 guest 的 `PT_INTERP` 挑同一 libc 编的 shim 设 `LD_PRELOAD` | `scripts/build_shim.sh` + `procmgr.cpp` |
| glibc guest 建线程被 **SIGSYS** | 沙箱对 `clone3(435)` 直接 SIGSYS | 补丁让 `__clone3` 恒返回 ENOSYS，回退 `clone` | `scripts/glibc-ohos/patches/0003-*` |
| musl guest **加载不了 .so** | musl 的 ld 用文件映射加载 → 被拒 | 给 musl 动态加载器打"匿名预留+pread+mprotect"补丁 | `scripts/build_musl.sh` |
| 资源根（el2）是 **noexec** | 系统 `dlopen` 打不开装在那里的 `.so` | libpython.so/libnode.so 的 `dlopen` shim 转给 elfloader 进程内装载器 | `shim/dlopen_shim.c` + `elfloader/elf_dl.cpp` |

**JIT 有三种情况**（能不能拿到可写可执行内存）：①有 kernel 权限；②只有 `prctl('jit')`
门；③两道门都没有。不同情况下 elfloader/box64/node/java 走不同路径（③时 qemu-user 兜底、
node 自动 `--jitless`，**java 不可用**）。用 `bshutil caps` 查。详见 README「jit 的三种情况」。

### 9.1 权限与签名（会影响沙箱策略）

- 受限权限（`ohos.permission.kernel.*`）必须同时出现在 **`module.json5` 的
  `requestPermissions`** 和**签名 profile 的 `allowed-acls`** 里，否则装上也拿不到。
- 设备自测**固定用 release 构建模式 + `debug-jit` 签名**（`scripts/build_test.sh`），
  理由：签名类型改变文件沙箱严格度，混着测等于每次在比不同的东西。

### 9.2 绝对不能入库的东西

- 私钥：`rawfile/tools/hdckey`（hdc 身份密钥）、`versions/` 里的签名材料、
  `bettershdev-src.tar`（含 p12）。这些已被 `.gitignore` 排除，改动时别把私钥提交上去。
- `scripts/env.sh`、根 `build-profile.json5`（含本机路径/签名配置）也不入库。
- 仓库根**没有** `LICENSE`；各第三方子模块遵循其自身许可证（见 README「许可与致谢」）。

---

## 10. 常见陷阱与注意事项

- **不要写死资源根路径**。应用私有目录是
  `/data/storage/el2/base/haps/<模块名>/files`，模块名会随 product 变（tablet/phone）。
  native 侧的资源根是**运行期**值（`initResourceManager` 里 `setenv("BSH_SYSROOT")`），
  一律用 `common/bsh_paths.h` 的访问器（`bsh_sysroot()` 等），不要写死字面量。
  少数编进产物的绝对路径靠运行期环境变量覆盖（`VIMRUNTIME`/`PYTHONHOME`/`XKB_CONFIG_ROOT`…）。
- **改 `shim/exec_shim.c` 要重编一堆命令 so**：它被烤进 mksh/toybox/vim/python/node/
  dropbear/zip 等（`grep -ln exec_shim scripts/*.sh` 可查全）。
- **`deploy_hap.sh` 会先 `bm uninstall`**，等于清空应用资源根——pkg 装的东西、
  `installed.json`、`$HOME` 用户文件全没（包缓存在用户可见 Download 区，躲开了这一刀）。
- **打包前必须跑过 `build_hap.sh` 的自查**（§7.3），别绕过。
- **weston-terminal 不再是命令 so**，而是 guest 可执行（和 qtapp 同形），
  按 FHS 摆在 `<资源根>/usr/bin`；它不使用通用 wrap 清单。
- **`build_llvm.sh` / `build_sysroot.sh` 的产物已无人使用**（内置 clang/lld 已移除，
  编 aarch64 改用 pkg 的 `ohos-sdk-prune` 包）；脚本还在，恢复方式见脚本头部注释。
- 命令表里 `guiduo` 无对应 so，执行会 `dlopen` 失败；`python`/`python3` 的入口是
  `Py_BytesMain`（非 `main`）。
- 时区/时间：时间戳字段用 `time()` 毫秒近似，非单调时钟。

---

## 11. 进一步阅读

| 想了解 | 看哪 |
| --- | --- |
| 全项目机理、命令表、资源解包、Wayland/SSH/pkg/apt、已知限制、FAQ | `README.md` |
| 各版本"为什么这么改"与踩坑记录 | `CHANGELOG.md` |
| shim 家族（软链/pty/exec/dlopen 兜底 + TLS + npm 现场编译） | `feature/bsh_main/src/main/cpp/shim/README.md` |
| glibc/musl/node/jdk/box64/qemu/dropbear/git 等平台移植细节 | `scripts/<平台>-ohos/README.md`、对应 `build_*.sh` 头部注释 |
| pkg 包管理器与包清单 | README「pkg：包管理器」一节；远端包服务器 `https://bsh.y1yan.com/` |
| apt 装发行版 deb | README「apt」一节 |
