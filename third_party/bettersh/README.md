# BetterSH

BetterSH 是一个运行在 HarmonyOS 上的终端模拟器 App：前端用 ArkTS + WebView（xterm.js）渲染终端，
native 侧自己实现了一套**软 pty** 与一个迷你 shell；外部程序以 `.so` 形式被 `dlopen` 运行，另有
in-process 的 **elfloader** 在无 `exec` 沙箱里装载执行 aarch64 ELF；最新还内嵌了一个
**Wayland compositor**，可把 Wayland 客户端窗口渲染到应用内的独立子窗口。

本 README 只描述仓库中可验证的现状。凡代码/脚本中尚未接线、或需额外环境才能成立的部分，
都会显式标注为「未验证」或「未接线」。

- bundleName `com.yiyan.bettersh`，versionName `0.8.0`（versionCode `1000005`，`AppScope/app.json5`）
- SDK `compatibleSdkVersion 6.1.0(23)` / `targetSdkVersion 6.1.1(24)`（`build-profile.json5.example`），
  目标架构 `arm64-v8a`（HAR 的 `feature/bsh_main/build-profile.json5` 的 `abiFilters`；
  两个薄 entry 自己没有 native）
- 分包：`feature/bsh_main`(共享 HAR) + `product/tablet`(平板/2in1，带 JIT) + `product/phone`(手机，无 JIT)。
  构建哪个用 `BSH_PRODUCT=tablet|phone`（`scripts/env.sh`，默认 tablet）
- `product/<名>/src/main/module.json5` **不入库**：按发行变体由 `versions/<名>/module.json5`
  (tablet) / `versions/<名>/phone.module.json5` (phone，可选) 整份替换（`scripts/switch_version.sh`），
  仓库里的基线是 `product/<名>/src/main/module.json5.example`

## 特性

- **终端前端**：WebView 加载 `rawfile/term/index.html`，使用内置 xterm.js
  （`vendor/xterm.js` + `xterm-addon-fit.js`），配套自有 `term.js`/`term.css`/`fonts.css`。
- **内置 shell**：`feature/bsh_main/src/main/cpp/shell/` 的小 shell，prompt 为 `$`，支持
  `echo`/`cd`/`pwd`/`export`/`unset`/`clear`/`exit`/`help`/`true`/`false`，支持单双引号与反斜杠转义；
  自带行编辑器（`lineedit.cpp`：上下键历史、左右键按字符移动、`Tab` 补全）与
  `$VAR`/`${VAR}`/`$?` 展开（`lexer.cpp`），补全逻辑在 `complete.cpp`。
- **命令 so 化**：命令以共享库随 HAP 打包，shell 按命令表 `dlopen` 后调用其 `main`。
- **toybox multicall**：`libtoybox.so` 单库多 applet（`ls`/`cat`/`grep`/`sed`/`find`/`tar`/…，
  含 `mount`/`umount`/`gzip` 族/网络类），入口符号 `bsh_toybox_main`。
- **mksh / vim / fastfetch**：`sh` → `libmksh.so`（源内 `MKSH_VERSION "R59 …"`）；
  `vim`/`vi` → `libvim.so`（ncurses widec 静态 + 内嵌 `xterm-256color` fallback terminfo + zlib）；
  `fastfetch` → `libfastfetch.so`（子模块 `CMakeLists.txt` 中 `VERSION 2.64.2`）。
- **Clang/LLVM**：**不再随 HAP 打**。原来的 `libclangbsh.so`（clang/clang++）与 `liblld.so`
  已从项目移除，编 aarch64 改用 pkg 的 `ohos-sdk-prune` 包（里面有可执行的 clang/lld 与
  自带的 `--sysroot`，见「pkg：包管理器」一节）。
- **CPython 3.12**：`libpython.so`（入口 `Py_BytesMain`，模块全静态内置，OpenSSL 3.0 静态链在
  里面 ⇒ `ssl`/`hashlib` 可用）+ stdlib 随包，`python x.py` 与交互式都可用。
- **pip**：`pip` / `python -m pip` 直连 PyPI 装包（`pip` 本身是 pkg 的包：先
  `pkg install pip`）。带 C 扩展的包（numpy）不能从 sdist 现场
  构建（设备上没编译器），改由宿主机交叉编成 wheel 放进 `$SYSROOT/pkgs/`，pip 经
  `PIP_FIND_LINKS` 装上；那些扩展落在 **noexec** 的资源根里，靠 `dlopen` 兜底
  （见 `src/main/cpp/shim/README.md` §9）交给 elfloader 的进程内装载器。
- **平台 tag 伪装（实验，默认关）**：`export BSH_PIP_FAKE_PLATFORM=musllinux_1_2_aarch64`
  之后 pip 就去 PyPI 挑真正为 aarch64 编的轮子（`sitecustomize.py` 会顺便把对应的扩展
  后缀也认上，否则装进来 import 不到）。实测：**纯 C 的轮子可以直接跑**
  （markupsafe / msgpack 都验证过）；**C++ 的跑不了** —— PyPI 上那些 musllinux 轮子是
  Alpine 编的、用 libstdc++，而这儿是 libc++，ABI 不通用（详见 shim/README §9.2）。
- **在设备上自己编扩展（走 pkg 装的 SDK）**：`pip install --no-binary :all: <包>` 会在
  设备上现场编译 —— 编译器是 pkg 装的 `ohos-sdk-prune`，Python 头文件也是 pkg 的包
  （`pkg install python-headers` ⇒ `$SYSROOT/python-headers/`），`CC`/`CXX`/`LDSHARED`
  由 `.bshrc` 指向 `$SYSROOT/bin/{cc-ohos,cxx-ohos,ldshared-ohos}` 三个包装脚本
  （shell.cpp 的 `WriteCcWrapper` 生成）。实测通过：**纯 C**（markupsafe）与
  **C++**（手编的 `std::string`+异常扩展，NEEDED `libc++_shared.so`）。
  **构建工具**：`make` 与 `ninja` 由 `scripts/build_devtools.sh` 交叉编好（musl 版，
  **pkg 的包** → `pkg install devtools` 后落 `$SYSROOT/usr/bin/`）。SDK 自带的那两个
  ninja/cmake 是 **glibc** 的（要 `libstdc++.so.6`），所以不进 PATH。
  **边界**：包自己的构建脚本去找系统库时会失败（`cffi` 就硬找 `/usr/include/ffi`，
  而设备上没有系统 libffi）—— 这类仍由宿主机交叉编 wheel。
- **Node.js 22.19.0 / npm 10.9.3**：`libnode.so`（`--shared` 编出后重链，补 C 入口 `bsh_node_main`）；
  `npm`/`npx` 由 `bsh_npm_main` 拼成 `node npm-cli.js` 再交给 node。V8 拿可执行内存走
  `prctl('jit')` 夹层，无 jit 设备上可自动降级 `--jitless`（`bshutil set node-jitless`）。
  **为什么从 18 升到 22**：现代 agent 类 CLI（kimi-code、dsh-tui…）的 engines 都是
  `>=22.19`，而且一开头就用 ES2024 的 `v` 正则标志，Node 18 在**解析阶段**就 SyntaxError。
  移植代价记在三处：**`--with-intl=full-icu`**（small-icu 缺断词数据，`new Intl.Segmenter()`
  直接段错误，而 kimi 的 bundle 顶层就在用它）、**`clang 15` 不认的新写法**（V8 13.6 的
  可省略 `typename`、zlib 的 `target("arch=armv8-a+aes+crc")` —— 见
  `scripts/node-ohos/patches/0003~0005` 与 `build_node.sh` 头部的版本取舍）。
  实测：`node -v` → v22.19.0，`kimi --version/--help` 正常，`dsh-tui --version` → 0.2.19。
  **原生扩展（`.node`）**：libnode.so 也链了 dlopen 兜底那套（§9 同一套对象），所以
  `node_modules` 里的 `.node` 能加载、**自己编的 N-API 扩展已经跑通**
  （`require` → `hello()`/`sum([1,2,3,4])` 都对，按包名 require 连跑三轮也正常）。
  npm 的 install 脚本（`.bin/*` 是软链）也已经能起。**真 TLS 已支持**
  （`PT_TLS` + `R_AARCH64_TLSDESC`，含"resolver 除 x0 外不许改寄存器"那层汇编外壳
  `elfloader/tlsdesc.S`，见 `cpp/shim/README.md` §10.3）。
  **现场编译（node-gyp）已通**：`pkg install node-headers`（官方 headers 包，`.bshrc` 里
  设了 `npm_config_nodedir`）+ `devtools`（make/ninja，**动态链接 musl**）之后，
  `npm install --build-from-source <包>` 能在设备上编出 C 扩展并直接 `require` 使用
  （实测 bufferutil / utf-8-validate）。**注**：这条链当初是在 Node 18 上验的；升到 22.19 后
  `node-headers` 那个包也一起重出了（`NODE_MODULE_VERSION` 115 → 127，见下面 pkg 表）。
  这条链上一共修了八件事（从 PATH 语义到
  GNU make 的 `SHELL` 不从环境取），逐条记在 `cpp/shim/README.md` §11。
- **zip / unzip**：Info-ZIP 3.0 / 6.0 各编一个 so（`libzipcmd.so` / `libunzipcmd.so`）。
- **box64 / qemu-user**：x86_64 guest 交 box64 动态翻译；无 jit 设备上 aarch64/x86_64 的 ELF
  全部改走 qemu-user（TCI，不需要可执行页）。分流在 procmgr 的 `Resolve()`。
- **weston-terminal**（迁移自 weston 16.0.0）：**不再是命令 so，而是可执行程序** —— 和 qtapp
  同形（PIE + 自带 musl 解释器 + 依赖闭包），但按 FHS 摆位：`<资源根>/usr/bin/weston-terminal`
  ＋ `<资源根>/usr/lib/*.so`（rpath `$ORIGIN/../lib`），`<资源根>/usr/bin` 挂在 PATH 上，
  procmgr 认出 ELF → 交 elfloader 当 guest 起。数据落 `<资源根>/usr/share/{x11/xkb,weston}`。
  它同时是 **pkg 的第一个包**：同一份 tar 既随 HAP 走，也放在包服务器上供 `pkg install` 下载。
- **bshutil**：改应用自身设置的命令（虚拟键栏、窗口缩放、右键行为、node jitless…），
  也能看/取 hap 里打包的 rawfile（`bshutil rawfile list|get`）。
  实现是主进程里的常驻服务线程，命令 so 只是一层薄客户端，所以 bsh 与 mksh 里都能用。
- **elfloader**：无 `exec` 沙箱内 mmap + 跳转执行 aarch64 ELF（`elf_run_file` + `guest_switch.S`）；
  动态 guest 的 musl / glibc 解释器都从 bundle libs 取。
- **内嵌 Wayland compositor**：`wayland_server.cpp` + `xdg_shell.cpp`，server 编入 `libentry.so`；
  demo 客户端 `wldemo` 在应用内创建真实子窗口并持续渲染。
- **SSH（dropbear）**：`libsshcore.so` 是 dropbear 的 `dropbearmulti` 五合一，命令表里
  `ssh`/`dbclient`/`scp`/`ssh-keygen`/`dropbearkey`/`dropbearconvert`/`dropbear` 都指向它的
  `bsh_dropbear_main`，按 `argv[0]` 分发。客户端（密码/公钥认证、`-L/-R/-D` 转发）与服务端
  （公钥认证 + 软 pty 交互会话）均已在设备上验证。

## 架构总览

```
ArkTS:  EntryAbility ─ TerminalPage ─ WebView(xterm.js)
          │ 输入 Web onData / 虚拟键栏 → bshTermInput；输出 → window.termWrite
          └ WaymonyService ─ AppRunnerAbility(multiton) ─ ClientWindow
                               └ XComponent(SURFACE) → createRenderer
终端:   BasicShell(shell.cpp) ─ softpty.cpp(socketpair) ─ RunSpawn ─► procmgr(control socket)
          ├ 命令 so → dlopen + main  ├ shim(fs/tty/pty/exec)  ├ elfloader  └ 命令表(procmgr/)
Wayland: WaylandServer(compositor 线程) ─ wl_display/globals ─ per-toplevel 帧缓冲
          ├ wl_seat 注入(wlMutex_ 串行)  └ PluginManager → EglRenderer → OHNativeWindow
  以上 native 全部经 libentry.so (NAPI) 与 ArkTS 交互
```

## 目录结构

```
AppScope/                     应用级配置与图标(app.json5)
feature/bsh_main/             共享 HAR：ArkTS 界面 + native(libentry.so) + rawfile 资源
  build-profile.json5         HAR 构建配置(abiFilters=arm64-v8a；native 在这里编)
  Index.ets                   对外出口(ability 与页面组件都给薄 entry re-export)
  libs/arm64-v8a/             命令 so / wayland so(脚本产出，gitignore)
  src/main/
    module.json5              HAR 声明(name=bsh_main / type=har，入库)
    ets/                      entryability/ apprunnerability/ terminalrunnerability/
                              entrybackupability/ service/ pages/ utils/
                              —— terminalrunnerability/ 是 newtab 开出来的终端窗口
                              (multiton)，与 apprunnerability 同构；两者都加载
                              同一个 pages/TerminalPage，靠会话号 sid 区分
                              —— 注意页面组件**不带 @Entry**：@Entry 由 product 侧的薄页面提供
    resources/rawfile/        term/(xterm.js 前端) + tools/(tar 生成物 + hello.c
                              + readme.py/licenses.py，首屏横幅让用户跑的那两份)
    cpp/
      CMakeLists.txt napi_init.cpp
      common/    bsh_paths.h(应用私有目录布局:bsh_sysroot() 等运行期访问器 + 三个 sock)
                 bsh_rawfile.cpp/h(rawfile 的统一访问口:list / copy，宿主与 bshutil 共用)
      procmgr/   procmgr.cpp/h(决策+fork+进程表) ctrl_socket.cpp command_map.c/h
                 caps.cpp(启动期探 fork/exec/jit) bsh_client.c/h
                 guest_exec.cpp/h(guest 内 exec 委托的旧方案，**暂时不启用**)
      shell/     shell.cpp/h lineedit.cpp/h(行编辑器) lexer.cpp/h(分词/展开) complete.cpp/h(TAB 补全)
      shim/      fs_shim.c(软链模拟) open_shim.c tty_shim.c pty_shim.c exec_shim.c
                 os_shim.c compat_shim.c + shim_wrap.h / README.md / 两个 selftest
                 —— 命令 so 与 guest 共用的沙箱适配层；--wrap 清单见
                 scripts/shim-wrap-flags.sh
      bshutil/   bshutil.cpp(子命令实现) bsh_cfg.cpp/h(设置) ui_bus.cpp/h(native→ArkTS)
                 bsh_util_server.cpp/h(主进程常驻服务) bsh_util_proto.h(帧格式)
      tty/       softpty.cpp bsh_tty.cpp/h(共享 termios，**按会话号 sid 分**) bsh_pty.c(weston-terminal 的 forkpty/ioctl/read wrap)
      elfloader/ elf_loader.cpp/h elf_dl.cpp guest_switch.S
      ssh/       sandbox_compat.c(补 getpass 等) pwshim.c(passwd/身份遮蔽)
      wayland/   wayland_server xdg_shell egl_renderer plugin_manager input_napi ws_napi
                 include/ 与 protocol/ 为生成物(gitignore)
      programs/  hellobsh/(示例) wldemo/(Wayland 客户端) qtwl_demo/ selfexe/(自测)
                 testx64(8 组合验收程序) bshutil/(命令 so 入口 + 服务客户端) pkg/(包管理器)
      types/libentry/  libentry.so 的 ArkTS 声明
product/tablet/               薄 entry：平板 + 2in1(带 JIT 权限)
product/phone/                薄 entry：手机(无 JIT 权限)
  build-profile.json5         entry 构建配置(没有 native，全部来自 HAR)
  src/main/module.json5       设备类型 + 权限集合(不入库，由 versions/ 提供；基线见 .example)
  src/main/ets/               ability 的薄子类 + @Entry 页面壳(真正实现都在 HAR)
  src/main/resources/         base/(string/color/media/profile) + dark/
scripts/  构建/签名/部署脚本(另有 glibc-ohos/ jdk-ohos/ musl-ohos/ node-ohos/ 等补丁目录)
thirdparty/  git submodule + 下载解压的非 git 源码(box64/qt/pyqt6/numpy/jdk/node/glibc/musl/zip)
versions/    发行变体快照(**不入库**；switch_version.sh 整份替换 module.json5/app.json5/libs/rawfile)
dist/        wayland 客户端 SDK 交付物(生成物，gitignore)
```

### 为什么这么分包

照搬 [HiSH](https://github.com/harmoninux/HiSH) 的 `feature/`(共享 HAR) + `product/`(薄 entry) 结构，
动机是**权限只能按模块给**：`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`（JIT 必需）
在手机上拿不到，而平板/2in1 要给；`module.json5` 又是每模块一份，所以想要"同一个应用、按设备
给不同能力"，就必须有多个 entry 模块。两个 entry 都是几十行的壳，真正的代码只存在 HAR 一份。

⚠ **代价：设备侧资源根绑着模块名。** 应用私有目录是
`/data/storage/el2/base/haps/<模块名>/files`，模块名从 `entry` 变成 `tablet`/`phone` 之后，
任何**编译期写死**这个路径的地方都会指错。所以：
- native 侧的资源根是**运行期**值：Ability 把 `context.filesDir` 交给
  `initResourceManager`，native `setenv("BSH_SYSROOT")`，之后一律用 `common/bsh_paths.h`
  的 `bsh_sysroot()` / `bsh_home_dir()` 等访问器（**不要**再写死字面量，也不要再用旧的
  `BSH_SYSROOT` 宏建路径，那个宏现在只是"环境变量没设"时的兜底）。
- 少数**编进产物里**的绝对路径改不动，靠运行期环境变量覆盖：`VIMRUNTIME`、`PYTHONHOME`、
  `XKB_CONFIG_ROOT`、`BSH_SYSROOT`(node/java 入口读它)、`BOX64_PROCMGR_SOCK`，
  以及 fontconfig 的 `fonts.conf`（`<dir>` 只能写在文件里，由 `initResource` 按当前资源根
  重写，见 `WriteFontsConf`）。

## 环境准备

需要 DevEco Studio（或 command-line-tools）提供的 OHOS SDK；交叉编译走 SDK 自带 clang。
宿主还需要 `meson`/`ninja`/`pkg-config`、`python3`、`java`、`tic`（vim 的 ncurses fallback 生成）。

`scripts/env.sh` 被所有构建脚本 `source`，且**不入库**（gitignore）。从模板复制并按本机修改：

```bash
cp scripts/env.sh.example scripts/env.sh
cp build-profile.json5.example build-profile.json5   # 然后填入 signingConfigs
```

`env.sh.example` 中需要留意的变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `TOOL_HOME` | `/apps/harmony` | command-line-tools 根，需有 `bin/hvigorw` |
| `OHOS_SDK` | `$TOOL_HOME/sdk/default/openharmony` | SDK 路径 |
| `HDC` | Windows 下 `hdc.exe` 路径 | 部署脚本使用 |
| `BUILD_PROFILE_FILE` | `/mnt/c/.../build-profile.json5` | 签名配置来源 |
| `BUNDLE_NAME` | `com.yiyan.bettersh` | 安装/卸载使用 |
| `DEVICE_SN` | 空 | 目标设备序列号，空则用 `hdc` 默认设备 |
| `NATIVE_ARCH` | `arm64-v8a` | 也接受 `x86_64`（见「已知限制」） |
| `MUSL_TOOLCHAIN` | `/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross` | **不在 `env.sh.example` 里，需自己 `export`**；build_llvm/vim/mksh/sysroot/node/qemu/dropbear/toybox/testprogs 等读它 |

`env.sh.example` 里有两条注释值得注意（脚本本身没有额外处理逻辑）：一是注释称鸿蒙自带 `diff`
行为异常（对不存在的文件也返回 0），会破坏 autotools 的 `config.status`，**这对他人环境是否仍
成立未验证**，脚本未自动规避；二是对外网访问的代理探测（WSL 网关 + Clash 7890），默认仅在探测到
端口可达时启用，可用 `BSH_PROXY_HOST`/`BSH_PROXY_PORT` 覆盖。

`build-profile.json5` 同样不入库；模板中 `signingConfigs` 为空，需自行用 DevEco 生成签名材料。

### 子模块

```bash
git submodule update --init --recursive
```

| 路径 | 来源 | 用途 |
| --- | --- | --- |
| `thirdparty/toybox` | landley/toybox（0.8.14） | multicall 命令库 |
| `thirdparty/third_party_llvm-project` | gitcode openharmony | clang/lld so 化（**当前未用**：那套 so 已移除，编 aarch64 走 pkg 的 `ohos-sdk-prune`） |
| `thirdparty/vim` | gitee mirrors/vim（v9.2.1036） | vim |
| `thirdparty/zlib` | gitee mirrors/zlib（v1.3.1） | vim 依赖 |
| `thirdparty/ncurses` | gitcode openharmony | vim / python 依赖 |
| `thirdparty/fastfetch` | FastfetchOnHarmonyOSShell（OHOS fork） | fastfetch |
| `thirdparty/mksh` | gitcode openharmony | `sh` |
| `thirdparty/wayland` | atomgit waymony fork（含 WAYLAND_TCP patch） | compositor + 客户端库 |
| `thirdparty/wayland-protocols` | freedesktop（1.41） | xdg-shell/viewporter 等协议 XML |
| `thirdparty/libffi` | libffi | 静态链入 libwayland-client |
| `thirdparty/weston` | freedesktop（16.0.0） | weston-terminal 源码 |
| `thirdparty/dropbear` | mkj/dropbear（`DROPBEAR_2026.94`） | SSH 五合一 |
| `thirdparty/qemu` | qemu（v10.1.5） | qemu-user 兜底（TCI） |
| `thirdparty/pcre2` | PCRE2（10.45） | 工具依赖（glib 等） |
| `thirdparty/glib` | GNOME glib（2.82.0） | glib 系工具依赖 |

> 非子模块的源码由脚本按需 `git clone` / 下载解压到 `thirdparty/` 或 `build/`，均被 gitignore：
> `box64`、`qt-src`/`pyqt6-src`、`numpy-src`/`pysrc`、`node-v*.tar.gz`、`jdk21u-*.tar.gz`、
> `zip_*/unzip_*.orig.tar.gz`、`glibc-*.tar.gz`、`musl-*.tar.gz`、`x86_64-linux-musl-cross*`。
>
> 当前工作副本里 `thirdparty/third_party_llvm-project` 在 `git submodule status` 中带 `-` 前缀
> （未按 gitlink 正常初始化）。构建前请确认该子模块已就绪。

## 构建步骤

交叉产物分两类：`feature/bsh_main/libs/arm64-v8a/` 的 `.so` 由各 `build_*.sh` 产出，`rawfile/tools/` 的
`*.tar` 由对应脚本产出，两者都被 gitignore。
推荐顺序：

```bash
# 0) 子模块
git submodule update --init --recursive

# 0.5) 依赖解析：两个 entry 通过本地 file: 依赖引 feature/bsh_main，**不会自动链**，
#      第一次构建前必须跑一次（根目录跑就行，会把各模块的 oh_modules 都建好）。
#      副作用：libentry.so 的 type 声明从此真正生效（以前没链上时等于没有类型检查）。
ohpm install

# 1) Wayland：必须先于 build_hap。CMakeLists 链接 libwayland-server.so，
#    并直接编译 wayland/protocol/*.c(生成物)，缺失则 native 编译失败。
./scripts/build_wayland.sh
# → feature/bsh_main/libs/arm64-v8a/libwayland-{server,client,cursor,egl}.so
# → feature/bsh_main/src/main/cpp/wayland/{include,protocol}/  (gitignore)
# → dist/arm64-v8a/                                (客户端 SDK，gitignore)

# 2) build_hap：把 wayland so 与 native 编进 HAP（命令 so 的产物可后补，见第 4 步）
./scripts/build_hap.sh

# 3) 各命令 so / guest 运行时
./scripts/build_toybox.sh      # → libtoybox.so
./scripts/build_fastfetch.sh   # → libfastfetch.so
# clang/lld 与 musl sysroot 不再自编、不再随 HAP：编 aarch64 用 pkg 的 ohos-sdk-prune 包。
# （build_llvm.sh / build_sysroot.sh 还在，但产物已无人使用 —— 恢复方式见脚本头部注释。）
./scripts/build_vim.sh         # → libvim.so、rawfile/tools/vim-runtime.tar
./scripts/build_mksh.sh        # → libmksh.so
./scripts/build_shim.sh        # → libbshguest-{musl,glibc}.so(guest 侧的 fs/tty/pty/exec shim)
./scripts/build_glibc.sh       # → 自编的 ld-linux-aarch64.so.1 + libc.so.6(进 bundle libs)
./scripts/build_musl.sh        # → 打了"匿名预留+pread+mprotect"补丁的 ld-musl-aarch64.so.1
./scripts/build_node.sh        # → libnode.so、rawfile/tools/npm.tar
./scripts/build_zip.sh         # → libzipcmd.so、libunzipcmd.so
./scripts/build_box64.sh       # → libbox64.so(git clone + scripts/box64-ohos/ 的 files/ 与 patches/)
./scripts/build_qemu.sh        # → libqemu-{aarch64,x86_64}.so(TCI 解释执行，不需可执行页)

# 3.5) weston-terminal 终端仿真器(迁移自 weston 16.0.0;可执行程序，非命令 so)
./scripts/build_weston_deps.sh      # 静态依赖(cairo/fontconfig/xkbcommon/…，耗时较长)
./scripts/build_weston_terminal.sh  # → rawfile/tools/weston-terminal.tar(可执行 + wayland 闭包，平铺)
                                    # → rawfile/tools/{xkb,weston-data,fonts}.tar
                                    #   (xkb/weston-data 的 tar 顶层是 usr/share/…；首次联网下载源码)

# 3.5) OpenSSL 3.0(静态)—— 给 CPython 的 _ssl/_hashlib 用，pip 要 https
./scripts/build_openssl.sh          # → build/openssl/{libssl.a,libcrypto.a,include/}
                                    # 只编静态库(no-shared no-module)：命令 so 形态下额外的 .so
                                    # 必须落在可映射执行的位置，资源根是 noexec，静态链最省事

# 3.6) CPython 3.12(命令表 python/python3/pip)
./scripts/build_python.sh           # → libpython.so(模块全静态内置 + _ssl/_hashlib + OpenSSL)
                                    # → rawfile/tools/python-stdlib.tar
                                    # 需宿主机 python3.12(--with-build-python)与 thirdparty/ncurses
                                    # 需先跑 3.5(build_openssl.sh)
./scripts/build_pip.sh              # → dist/pkgs/pip.tar.zst(**pkg 的包**，不随 HAP 走)
                                    # 设备上 `pkg install pip` 后解到 site-packages；
                                    # pip 命令走 libpython.so 的 bsh_pip_main(scripts/python-ohos/)

# 3.7) python 科学栈 —— 现在按需装，不再随包：
#   `pip install numpy` 在设备上**不可能**成功：本机平台 tag 是
#   cp312-cp312-harmonyos_hongmeng_kernel_<版本>_aarch64，PyPI 上没有这种 wheel，
#   pip 退回 sdist 现场构建而设备上没编译器(实测 "Could not find a make program")。
#   所以带 C 扩展的包得由宿主机交叉编好、打成 wheel 交出去：
# ./scripts/build_numpy.sh
# ./scripts/build_kiwisolver.sh     # matplotlib 的硬依赖(C++ 扩展)
# ./scripts/build_pypure.sh         # matplotlib 的纯 Python 依赖
# ./scripts/build_contourpy.sh
# ./scripts/build_pillow.sh
# ./scripts/build_matplotlib.sh     # → matplotlib.tar + 5 个扩展平铺到 feature/bsh_main/libs

# 3.7) SSH(dropbear 五合一:客户端 + scp + keygen + convert + 服务端)
./scripts/build_dropbear.sh         # → libsshcore.so
                                    # 子模块 thirdparty/dropbear(钉 DROPBEAR_2026.94);
                                    # 源码副本在 build/dropbear-src 打 scripts/dropbear-ohos.patch,
                                    # 另有 ssh/sandbox_compat.c、ssh/pwshim.c 两个补丁对象

# 3.8) 验收程序(8 种 ABI 组合;开发机自测与设备侧对照)
./scripts/build_testprogs.sh        # → rawfile/tools/testprogs.tar

# 3.9) OpenJDK 21 与 Qt(默认不出包;见各自脚本与 scripts/jdk-ohos/README.md)
# ./scripts/build_jdk.sh             # → libjdk.so + 26 个 JDK .so + jdk21-ohos.tar
# ./scripts/build_qtwl_demo.sh app   # → qtapp.tar(Qt 应用目录，elfloader 当 guest 跑)

# 4) 再次 build_hap：把以上 .so 与 tar 打进 HAP
#    分包后要挑 entry：BSH_PRODUCT=tablet(平板/2in1) 或 phone(手机)，默认 tablet
BSH_PRODUCT=tablet ./scripts/build_hap.sh
                               # → product/tablet/build/default/outputs/default/tablet-default-unsigned.hap

# 5) 签名 + 部署
#   设备自测统一走这一个入口：release 构建模式 + debug-jit 签名（约定见下）
./scripts/build_test.sh                       # 出包 → 部署 → 拉起（自检随之开始）
./scripts/build_test.sh <serial|ip:port>      # 指定设备；WAIT=1 再等自检跑到主体结束
#   只想自己拼步骤、或要出发布包时，用底层那几个：
./scripts/sign_hap.sh          # → product/<product>/build/default/outputs/default/<product>-default-signed.hap
./scripts/deploy_hap.sh [<ip:port>|<serial>]
```

**设备自测的签名约定**（2026-10-02 起）：如无特殊情况，一律 **release 构建模式 +
`debug-jit` 签名**（`scripts/build_test.sh` 就是这个组合，不用手拼）。理由：

- **签名会改变沙箱策略**，不只是"谁签的"。HAP 里的 `app.debug` 由 hvigor 的 buildMode
  决定，而非 debug 应用的文件沙箱更严 —— 实测同一个 guest：debug 构建（`app.debug=true`）
  30 过 / 0 挂，release 构建（`false`）29 过 / 1 挂，差的正是硬链接那一档
  （非 debug 应用不给 `link(2)`）。两种混着测，等于每次都在比不同的东西。
- 真正的 `release` signingConfig 签出来的包 **hdc 装不上**：
  `code:9568322 signature verification failed due to not trusted app source`
  （发布型 profile 设备不信任）—— 所以"release 构建模式"只能靠 debug 类型 profile 验证。
- `debug-jit` 两者都满足：debug 类型 profile（能装）+ `ALLOW_WRITABLE_CODE_MEMORY`
  这条 restricted ACL（JIT 生效，`bshutil caps` 报 `jit=yes route=anon-rwx`）。

脚本要点：`build_wayland.sh` 依次构建静态 `libffi`、宿主 `wayland-scanner`、交叉 wayland，
再生成协议头/协议码并布局到 `feature/bsh_main/libs` 与 `dist`（wayland 1.22.0），依赖
`thirdparty/{wayland,wayland-protocols,libffi}`；`build_toybox.sh` 优先 OHOS SDK clang，其次
`TOYBOX_CC`，最后 musl 兜底；`build_vim.sh` 先交叉 ncurses（静态 widec + fallback
terminfo）与 zlib 再编 vim，需要宿主 `/usr/bin/tic`；`build_mksh.sh` 编译 mksh 源，并链接
`scripts/shim-wrap-flags.sh` 那份清单对应的 shim 对象（fs/tty/open + exec）与 `procmgr/bsh_client.o`。

**命令 so 与宿主已经解耦**：tty 的 termios/ioctl 与 exec 委托都经 procmgr 的 control socket，
编 vim/mksh/python 等 **不需要先存在 `libentry.so`**，产物 `NEEDED` 里只有
`libc.so`（验证方式：把中间产物的 `libentry.so` 移走再编）。
（weston-terminal 已不在这一类：它现在是 guest 可执行，见 3.5。）

### 验收程序（9 种 ABI 组合）

`feature/bsh_main/src/main/cpp/programs/testx64/` 是同一份源码编出来的验收程序：`main.c` 是 34 个用例块
（stdio/fs/symlink/pty/tty/signal/线程/fork/共享内存/auxv/JIT/dlopen/exec/exec-self/
`/proc/self/exe`…），`greet.c` 编成配套的 `libtgreet-<组合>.so`，`dlhost.c` 是"动态链接了那个
.so"的小程序。`scripts/build_testprogs.sh` 按 arch(x86_64/aarch64) × libc(glibc/musl) ×
链接(静态/动态) 编出 8 个组合，另加 `aarch64-glibc-dynamic-nopie`（动态但**非 PIE**，
`-no-pie`；给"ET_EXEC + `PT_INTERP` 走解释器"那条语义留的回归位），共 9 个；每个组合三个文件，
打进 `rawfile/tools/testprogs.tar`（设备侧由 `initResource()` 解到 `<资源根>/testprogs`）。

先在开发机上跑，确定工作正常：

```bash
./scripts/run_testprogs_host.sh   # 9 个组合：x86_64 原生执行、aarch64 走 qemu-user，要求 0 FAIL
```

设备侧用"启动即自检"：`rawfile/tools/autorun.sh`（本地临时件，已 gitignore）由 `shell.cpp`
每次会话启动时后台跑一遍、日志落 `$HOME/autorun.log`，用 `./scripts/wait_autorun.sh` 取。
完整版 `autorun-all.sh`（已入库）每次会话只**落盘**到 `$HOME`、不自动跑，需要时手动
`sh $HOME/autorun-all.sh`。

### 沙箱能力缺口与对策

这台设备的沙箱缺了几样本该有的东西（实测三层：宿主进程 / 命令 so / guest）。每条都有一层
"应用内的对策"，不是文档化的认输：

| 缺口 | 实测现象 | 对策 | 落在哪 |
| --- | --- | --- | --- |
| 建不了**符号链接** | `symlink()` 三层、所有可写目录都是 `errno=13`（硬链接可以） | 用户态模拟：`foo -> t` 表示成普通文件 `foo.BSH_SYMLINK`（内容为目标串），拦 libc 里碰路径的入口 | `feature/bsh_main/src/main/cpp/shim/fs_shim.c`（guest 侧已生效；命令 so 侧见其 README §0） |
| 拿不到 **pty** | `open("/dev/ptmx")` 三层 `EACCES` | 假 pts：socketpair 当 master/slave，`grantpt/unlockpt/ptsname/ioctl(TIOCGPTN)` 一套假实现，slave 登记成 tty 复用现有软 tty 语义 | `feature/bsh_main/src/main/cpp/shim/pty_shim.c` |
| guest 里**不能 exec** | `execve` 一律 `EACCES` | 拦 `execve/execv/execvp/execvpe/execl*/posix_spawn(p)`，把"起一个程序"作为请求发给 procmgr（进程只能由它创建），拿到退出码后 `_exit`；命令 so 侧走链接期 `-Wl,--wrap=`，guest 侧走 `LD_PRELOAD`（按 `PT_INTERP` 选 musl/glibc 那份） | `feature/bsh_main/src/main/cpp/shim/exec_shim.c`（`procmgr/guest_exec.cpp` 的 seccomp 方案保留但**未启用**，见其文件头） |
| guest 看不到 **tty** | 会话是 softpty(socketpair)，`isatty` 恒 0；命令 so 有 `tty_shim`，guest 没有 | 把同一套 tty 语义做成独立 .so，按 guest 的 PT_INTERP 挑对应 libc 那份设 `LD_PRELOAD`（musl/glibc 各一份） | `scripts/build_shim.sh` + `procmgr.cpp` 的 ChildRunElf |
| glibc guest **建线程被 SIGSYS 打死** | 沙箱对 `clone3(435)` 直接 SIGSYS；glibc 2.39 建线程优先走它 | 补丁让 `__clone3` 恒返回 ENOSYS（真实改点是 `aarch64/clone3.S`），glibc 自动回退 `clone` | `scripts/glibc-ohos/patches/0003-*` |
| musl guest **加载不了 .so** | musl 的 ld 用文件映射加载 .so → 被那道闸拒（dlopen 必失败） | 给 musl 的动态加载器打"匿名预留+pread+mprotect"补丁（与 glibc 补丁 0001 同思路），随 HAP 进 bundle libs | `scripts/build_musl.sh` + `scripts/musl-ohos/patches/0001-*` |

| 系统 `/bin` 下的二进制**不能当 guest 跑** | `/bin/timeout`、`/bin/od` 是系统 toybox 的符号链接，它们要的是**系统那份** `ld-musl`，与我们打进去的那份不是一回事：走 elfloader 会"装载成功、一进 guest 就崩"（落点固定 `ld.so+0x62534`、`pc=0`、rc=139 加一串 `[crash]`），而让系统 shell 跑同一个文件完全正常 | 这 9 个系统 bin 前缀下 **basename 认不得命令表**时改交内核 `execve`（系统签名，不触发"是否运行"确认框）；`ChildRunExec` 本来就会在 exec 失败时退回 elfloader，行为不倒退 | `procmgr.cpp` 的 `Resolve()` 3.5 |

**明确不做**：静态链接的 guest —— tty/软链 shim 与 exec 委托都靠 `LD_PRELOAD`，静态 guest 两条都
吃不到（`procmgr/guest_exec.cpp` 那套 seccomp 级方案本该覆盖它，但当前未启用）。

## 设备使用

安装后启动 `EntryAbility` 进入终端。会话的目录布局由 `common/bsh_paths.h` 一处定义，分两层：

```text
files/                    BSH_SYSROOT —— 资源根(性质像一套 sysroot)
  vim-runtime/ fonts/ fonts.conf
  usr/share/x11/xkb       ← weston-terminal 的键位映射(XKB_CONFIG_ROOT)
  usr/share/weston        ← weston 窗口装饰按钮 PNG(WESTON_DATA_DIR)
  weston-terminal/        ← 可执行 + wayland 依赖闭包(平铺;挂在 PATH 上)
  python/ npm/ testprogs/                 ← initResource 解包出来的运行期资源
  .res-unpacked                           ← 资源解包总标记(存在就跳过整段解包)
  wl-sock  bsh-ctrl.sock  bshutil.sock  bsh-ws.bin   ← 运行时共享的 socket/状态文件
files/home/               $HOME —— 会话家目录,只放用户的东西
  .ssh/ .harmony/(hdc 密钥) bettersh.conf
  hello.c autorun.sh autorun-all.sh autorun.log
```

**会话环境：`$HOME/.bshrc`。** 除四个"语义上只读"的（`HOME`/`PWD`、`BSH_SYSROOT`、
`BSH_CTRL_SOCK`/`BSH_HOME_DIR` —— 由 native 侧拥有、被改会让整片路径或 IPC 错乱），
其余环境变量都在 `$HOME/.bshrc` 里设，**每次会话启动执行一遍**：

- 文件**由函数生成**（`shell.cpp` 的 `WriteBshrc()`，不是随包放模板）—— 道理同 `fonts.conf`：
  里面的默认值引用的是**当前**资源根，而资源根挂在模块名下（分包后会变），写死在别处迟早漂；
- 但只重写 `>>> BetterSH managed >>>` / `<<< BetterSH managed <<<` 之间的**托管块**，
  块外你自己写的行原样保留。于是既能改，又不会"升级后新加的变量没了"（老装机下次会话自动跟上）；
- 整个文件删掉也没事：下次会话重新生成一份默认的；
- 语法就是内置 shell 的语法：`export K=V`、`$VAR`/`${VAR}`/`$?` 展开、引号与转义，
  `#` 只做**整行**注释（`echo a#b` 里的 `#` 是普通字符）。没有 `if`/函数/`for` —— 它是 rc，
  不是脚本语言；单行退出码非 0 不中断，也不影响会话启动；
- ⚠ **`PATH` 也归它管**：默认块第一行就是它，删掉那行所有外部命令都会找不到
  （`export` 是 builtin，改错了还能当场 `export PATH=…` 救回来）；
- ⚠ `.bshrc` 跑在**资源解包之前**（下面 `initResource()` 起的是裸名 `tar`，靠 PATH 找），
  所以里面别放需要资源的命令 —— 它的定位是"设环境"，不是"跑初始化任务"。

托管块里的默认值：`PATH=$HOME:$BSH_SYSROOT/bin:$BSH_SYSROOT/usr/bin:$PATH`（`<资源根>/bin`
就是**命令启动器文件**目录，见下节）、`TERM=xterm-256color`、`SHELL=sh`、
`VIMRUNTIME=$BSH_SYSROOT/vim-runtime`、`PYTHONHOME=$BSH_SYSROOT/python`、
`XKB_CONFIG_ROOT=$BSH_SYSROOT/usr/share/x11/xkb`、`WESTON_DATA_DIR=$BSH_SYSROOT/usr/share/weston`、
`FONTCONFIG_FILE=$BSH_SYSROOT/fonts.conf`、`FONTCONFIG_PATH=$BSH_SYSROOT`、
`WAYLAND_DISPLAY=$BSH_SYSROOT/wl-sock`、`XDG_RUNTIME_DIR=$BSH_SYSROOT`、`BSH_PKG_CACHE=…`。
另外两条有各自的坑：

- `QT_QPA_PLATFORM=wayland` + `QT_PLUGIN_PATH=$BSH_SYSROOT/qtapp:$BSH_SYSROOT/qtapp/plugins-probe:<bundle libs>`
  （Qt 侧已打补丁直接平扫每个 library path，不需要类别子目录）；
- `QEMU_LD_PREFIX=$BSH_SYSROOT`：会话启动时把 bundle libs 里的 guest 解释器/`libc.so{,.6}`
  按 `lib/`、`lib64/`、`lib/x86_64-linux-gnu/` **拷**成一份"假根"给 qemu（拷而不是软链：
  沙箱里 `symlink()` 一律 EPERM）。⚠ qemu 的补丁把这个变量**同时当 guest rootfs 基准**，
  所以它必须是资源根本身、不能是它的子目录（否则 guest 看到 `/mnt/host-root/…`）。
  —— 摆拷贝那半段是"动作"，留在 `shell.cpp`；变量本身在 `.bshrc` 里（可读可改）。
- `BSH_NODE_JITLESS`：由 `bsh_cfg_export_env()` 从 `bettersh.conf` 导出，node 入口读它决定
  JIT 策略（`bshutil set node-jitless`）。**`bettersh.conf` 是"应用设置"、不是会话环境**，
  它比 `.bshrc` 先导出 —— 于是 `.bshrc` 可以覆盖它，方向单一（越靠后越"用户"）。

可用命令（`feature/bsh_main/src/main/cpp/procmgr/command_map.c`）：

```text
内置:   help  echo  cd  pwd  export  unset  clear  exit
toybox: ls cat echo grep egrep fgrep sed awk cp mv rm rmdir mkdir touch ln chmod chown
        head tail wc sort uniq tr cut tee xargs find which env printenv pwd
        true false yes sleep date uname id whoami ps kill free df du tar
        clear reset stty readlink dirname basename realpath printf
        mount umount gzip gunzip zcat wget ping netstat ifconfig toybox
shell:  sh                                       # mksh
编辑:   vim / vi
编译:   pkg install ohos-sdk-prune 后，用它里面的 clang/clang++/ld.lld
        （<资源根>/opt/ohos-sdk/openharmony/native/llvm/bin；内置 libclangbsh/liblld 已移除）
解释器: python / python3 → libpython.so
        node / nodejs    → libnode.so
        npm / npx        → libnode.so(bsh_npm_main 拼出 node npm-cli.js)
终端:   weston-terminal                          # 可执行程序(非命令 so)：解到 <资源根>/weston-terminal，
                                                 # 挂在 PATH 上，procmgr 交 elfloader 当 guest 起
压缩:   zip / unzip                              # libzipcmd.so / libunzipcmd.so
SSH:    ssh dbclient scp ssh-keygen dropbearkey dropbearconvert dropbear
                                                 # libsshcore.so，按 argv[0] 分发
执行器: box64                                    # libbox64.so(x86_64 guest 动态翻译)
        qemu-aarch64 / qemu-x86_64               # libqemu-*.so(无 jit 设备上的兜底)
其他:   fastfetch
设置:   bshutil                                 # libbshutil.so，薄客户端：实现在主进程的常驻服务
                                                # 线程里，所以 bsh 与 mksh 里都能用
演示:   hellobsh                                 # libhellobsh.so
        wldemo                                   # libwldemo.so，Wayland 冒烟客户端
```

编 aarch64 并运行（内置 clang 已移除，用 pkg 装下来的 SDK；`rawfile/tools/hello.c` 是现成样张）：

```bash
pkg install ohos-sdk-prune           # 自带 clang/lld/sysroot，只下这一次（之后走缓存）
SDK=$BSH_SYSROOT/opt/ohos-sdk/openharmony
"$SDK/native/llvm/bin/clang" --target=aarch64-linux-ohos \
    --sysroot="$SDK/native/sysroot" -O2 hello.c -o hello -fuse-ld=lld
./hello
```

`wldemo` 连接应用内嵌 compositor，创建标题为 `wldemo`、默认 `480x320` 的 toplevel，以动画渲染
（移动色带 + 反弹方块），窗口关闭或收到 SIGTERM 后退出。宿主侧每个 toplevel 对应一个独立
`AppRunnerAbility` 子窗口（`module.json5` 中声明为 `exported`、`launchType: multiton`）。

虚拟键栏（非 2in1 设备默认显示）：左区为 `ESC`/`FN`/`TAB`/`CTRL` 与方向键组，`FN` 切换
`F1`–`F12` 层；`CTRL` 为开关态，激活后按 `a`–`z` 会转换为控制字节 `\x01`–`\x1a`。设置菜单可切
字号（12/14/16/18/20）与光标闪烁。

### 命令行编辑（bsh 自带的行编辑器）

行编辑是 bsh 自己实现的（`shell/lineedit.cpp`），不依赖 readline；它只在**前台没有子进程**时
才自己读 pty 字节，所以 `vim`/`mksh` 的全屏与行编辑不受影响。

| 键 | 行为 |
|---|---|
| `↑` / `↓` | 翻历史；`↓` 到底回到按 `↑` 之前那半截输入 |
| `←` / `→` | 按**字符**移动光标（UTF-8 感知，中日韩宽字符按 2 列退） |
| `Home`/`End`、`Ctrl+A`/`Ctrl+E` | 行首 / 行尾 |
| `Ctrl+U` / `Ctrl+K` / `Ctrl+W` | 删到行首 / 删到行尾 / 删前一个词 |
| `Delete` | 删光标处的字符 |
| `Tab` | 补全：命令位补内建命令与 `<资源根>/bin` 里的启动器文件名；其它位置按当前目录补路径。唯一命中直接补完（目录补 `/`、文件补空格），多候选先补公共前缀，**再按一次 Tab** 列出候选 |
| `Ctrl+C` | 丢弃当前行，回到新提示符 |

空行与"与上一条相同"的命令不进历史。

变量展开在分词时做（`shell/lexer.cpp`），与引号/转义同一遍扫描：

- `$NAME`、`${NAME}` 查环境变量，未定义展开成空串；`$?` 是上一条命令的退出码；
- 单引号内一切原样（`'$HOME'` 就是字面 `$HOME`）；双引号内照常展开；
- `\$` 是字面 `$`；孤立的 `$`（后面既不是名字也不是 `?`）也是字面。

宿主单测（不需要设备；行编辑器/分词展开/补全的判据都在这里，`lineedit_selftest.cpp`
的注释里也写了这条命令）：

```bash
g++ -std=c++17 -O1 -g -Wall -Wextra -fsanitize=address,undefined \
    -Ifeature/bsh_main/src/main/cpp/shell \
    feature/bsh_main/src/main/cpp/shell/{lineedit,lexer,complete,rcfile}.cpp \
    feature/bsh_main/src/main/cpp/shell/lineedit_selftest.cpp -o /tmp/bsh_shell_tests \
  && /tmp/bsh_shell_tests                # 81 条断言，含引号/转义/未定义/隐藏文件、.bshrc 注释与托管块等边界
```

设备上的人工验收（这三项只在交互终端里走得到 —— `lineedit.cpp` 只在没有前台子进程时读键，
而 `autorun` 跑在 mksh 里、非交互，验不到）：

1. **历史**：`touch $HOME/t1` 回车、`touch $HOME/t2` 回车，再连按两次 `↑` 回车 ——
   `ls -l --full-time $HOME/t1` 的时间应比 `t2` 新（重跑的是第一条）。
2. **补全**：`touch $HOME/tabprobe_zzz` 回车，然后 `touch tabp`（注意是相对路径：
   补全按当前目录扫）再按 `Tab` —— 应补成 `touch tabprobe_zzz`，不会生成 `tabp`。
3. **展开**：`mkdir $HOME/vprobe` 与 `mkdir ${HOME}/vprobe2` 都应成功建出目录
   （若没展开，字面量 `$HOME/...` 会因父目录不存在而失败）。

这三条也可以用 `uitest uiInput` 注入按键自动跑（判据就是上面那些文件系统副作用，
不看屏幕）：`uitest uiInput click <终端坐标>` 拿焦点 → `uiInput text '<命令>'` →
`uiInput keyEvent 2054`（回车）、`keyEvent 2012`（↑）、`keyEvent 2049`（Tab）。
注意 bsh 的 builtin `echo` **不支持重定向**，所以探针要用 `touch`/`mkdir` 这类命令，
不能用 `echo x > f`。

## 关键机制

### 软 pty 与 tty_shim

沙箱内没有真 pty。`tty/softpty.cpp` 用一对 `socketpair(AF_UNIX, SOCK_STREAM)` 模拟 master/slave，
并各自维护默认 `termios`（`ICANON|ECHO|OPOST|ONLCR|ISIG` 等）与 `winsize`。没有内核行规程，所以
行编辑器（`shell/lineedit.cpp`）自己做本地回显、光标移动与 UTF-8 组块；
master 读线程推送前端前补 CR（`\n` → `\r\n`）。

要让 vim/mksh 这类「全屏型」命令以为自己在真 tty 上，需要 `isatty`/`tcgetattr`/`ioctl(TIOCGWINSZ)`
一族返回合理结果。这部分由两半组成，**分处在不同进程**：

- **本地那一半**（`shim/tty_shim.c`，编进命令 so）：一张「哪些 fd 是会话 tty」的表，以及
  `open("/dev/tty")`、`fcntl(F_DUPFD)` 的副本登记。fd 号只在进程内有意义，主进程无从判断，
  所以这张表必须在本地；它由 procmgr spawn 时设的 `BSH_TTY_STDIO` 环境变量懒加载初始化
  （procmgr 判断 stdio 是软 tty socket 时才设，重定向到文件/管道时不设 → `isatty` 保持为假）。
- **共享那一半**（`tty/bsh_tty.cpp`，编进 libentry）：`termios`/`winsize`/前台进程组，存在
  `mmap(MAP_SHARED)` 的会话状态里，是这些值的**唯一真相**。命令 so 不链接它 —— 经 procmgr 的
  control socket 读写（`CMD TTY`，客户端封装在 `bsh_client.c` 的 `bsh_tty_remote_*`）。

于是命令 so 与宿主彻底解耦：编 vim/mksh/python 等 **不需要 `libentry.so` 存在**，
也不必先跑一次 `build_hap.sh`（验证方式：把中间产物的 `libentry.so` 移走再编，NEEDED 里只有 `libc.so`）。
weston-terminal 现在走的是另一条路（guest 可执行），它的 tty 语义由 guest 侧预载的
`libbshguest-musl.so` 提供，同样不依赖 `libentry.so`。

会话状态用 `MAP_SHARED` 建立（fork 出的命令继承同一映射），所以两侧看到的是同一份；软 tty 不产生
信号：输入路径在 ISIG 开启且命中 `VINTR`/`VQUIT`/`VSUSP` 时，由 `bsh_tty_forward_sig()` 向前台
进程组与 procmgr 记的前台 pid 补发 `SIGINT`/`SIGQUIT`/`SIGTSTP`（Ctrl+C 等）。

#### 一个踩过的坑：伪 pty 的 fd 号会被别的库抢

weston-terminal 内部靠 `forkpty` + `execl(shell)` 起 mksh，这两个都由我们 wrap
（`tty/bsh_pty.c`；它从"命令 so"改成 guest 可执行之后，这段 wrap 仍然编在程序里）。曾出现
"随机的窗口空白、进程却正常退出（code=0）"，链路是：

1. weston-terminal 链接的 cairo/fontconfig/xkbcommon/libwayland 等库，在 `fork` 前后也在**低位 fd 区间**
   反复分配 fd；
2. 于是同一个 fd 号（例如 12）在**父进程**里是 `socketpair` 给的 socket，到**子进程**却成了别的东西
   （实测是管道）；
3. 子进程 `dup2` 之后，mksh 的 stdio 根本不是那个伪 pty → slave 端**无人持有**；
4. master 上立刻 `EPOLLHUP` → weston 的 `io_handler` 走 `terminal_destroy` → `display_exit`
   → 窗口关掉、退出码 0（全程**静默**，`log_handler` 也不打印任何东西）。

修法：`fork` 之前把 slave 复制到**高位 fd**（`fcntl(sv[1], F_DUPFD_CLOEXEC, 200)`），子进程用高位号
做 `dup2`，避开那片被争抢的低位区域。诊断这个问题的过程也值得记一笔：`WAYLAND_DEBUG` 在这份
libwayland 里没编译进去、客户端 error 走 `log_handler` 但那次根本没有 error，最后是靠
`/proc/self/fd/<n>` 的 `readlink`（内核视角，比 `fstat` 更无歧义）才把"父子看到同一个 fd 却是不同
类型"这个矛盾钉死。

另外 `__wrap_read` 对 master 的读取要区分 `EAGAIN`/`EINTR` 与真错误：master 被 `terminal_run`
设成 `O_NONBLOCK`，而 weston 的 `io_handler` 把 `len < 0` 一律当读错误 → 同样会静默销毁退出。

### procmgr：进程创建的唯一入口

沙箱里通常没有真 `exec`，而"起一个程序"的代码只能活在主进程 `libentry.so` 里。`procmgr/` 就
是这个唯一入口：`procmgr.cpp`（决策 + fork + 进程表 + 前台 pid hook）、`command_map.c`（命令表）、
`ctrl_socket.cpp`（控制通道服务端）、`caps.cpp`（启动期探 fork/exec/jit）、`bsh_client.c`
（客户端，宿主与命令 so 共用）。

- **决策**（`Resolve`，先看调用方给的 `KindHint`：`kAuto` 才走下面的自动判定，`kForceSo`/`kForceElf`
  直接按指定形态起）：
  1. 命令表命中 → `kSoMain`（`dlopen(bundle libs/<so>)` + 调入口符号）；
  1.5 **`#BSHSO` 启动器文件** → 照文件里写的 `so` / 入口符号 / 参数个数起（见下面「命令启动器文件」一节）。
      放在第 5 条之前是**必须**的：`IsScriptFile()` 只看头两字节 `#!`，不先拦下来，我们的文件会被
      当成脚本、去找一个叫 `BSHSO` 的解释器。格式错**不静默回退**，报清楚是第几行的问题。
  2. 显式 `.so` 路径 → `kSoMain`，入口符号按 `main`；
  3. 路径落在 **`/data/service/hnp/`** 内、且是 ELF、且 `Capabilities().exec` 为真 → **`kExecve`**：
     fork 之后真 `execve`。这些应用自带解释器与依赖，没必要经我们的装载器（jit 映射、
     guest hand-off 都还要额外前提）；若 `execve` 仍然失败（挂载选项 noexec、SELinux 标签
     之类），**退回 elfloader** 而不是让命令直接死 —— 见 `ChildRunExec`（它同时按
     "库和可执行文件放一块"把 `<dir>`、`<dir>/../lib`、`<dir>/../lib64` 补进
     `LD_LIBRARY_PATH`，hnp 的真身都指望这个）；
     exec 探不通时**故意不 return**，继续往下走 elfloader/box64（慢一层但能用）；
     脚本（`#!`）不走 exec，见下面第 5 条。
  4. （代码注释里的 3.5）系统 bin 目录（`/bin`、`/usr/bin`、`/usr/local/bin`、`/sbin`、`/usr/sbin`、
     `/system/bin`、`/vendor/bin`、`/system/lib`、`/data/app/bin` 这 9 个前缀）下 basename 命中
     命令表 → `kSoMain` —— node 的 `spawn('/bin/sh')` 那条，理由见 `Resolve` 里 3.5 的长注释；
     basename **认不得**时 → `kExecve`（交给内核真 exec）。这些路径大多是**系统 toybox 的符号链接**
     （`/bin/timeout`、`/bin/od` → `/system/bin/toybox`），它们要的是**系统那份** ld-musl，跟我们打进去的
     那份不是一回事：交给 elfloader 会"装载成功、一进 guest 就崩"（落点固定 ld.so+0x62534、`pc=0`、
     rc=139 加一串 `[crash]`），而同一个文件让系统 shell 跑是完全正常的。exec 探不通时照样继续往下走
     （`ChildRunExec` 失败时自己会退回 elfloader），行为不倒退；
  5. 不是 ELF 但是 `#!` 脚本 → `kSoMain` + **命令表里的解释器**：`#!/bin/sh` 就交给 `sh`
     （`libmksh.so`），argv 重组成 `[解释器名, (,解释器参数,) 脚本路径, 原参数…]`。hnp 的 bin 里
     就有这种包装脚本（实测 `python3.12`：`bindir=$(dirname $(readlink -f $0))` +
     `exec "${bindir}/python3.12"`，真身在同级的 `python.org/` 下）；内核 shebang 那条路走不通
     （要的 `/bin/sh` 在沙箱里 exec 不了），所以用我们自己的 sh 跑。
  6. 确认是 ELF 魔数后按 `e_machine` **与 `Capabilities().jit`** 分流：`AARCH64` → `kElf`
     （elfloader 装载）；`x86_64`/`i386` → `kSoMain` + `libbox64.so`（跨 ISA 动态翻译）；
     jit 不可用时两者都改交 qemu-user（`libqemu-aarch64.so`/`libqemu-x86_64.so`，同样 `kSoMain`）。
     认不出的架构仍交 elfloader，由它报 `bad ELF header`。
  预留：`kQemu` 这个枚举值未实现 —— 现在的 qemu 兜底走的是 `kSoMain`。

  另外 `SearchPath`（裸名按 PATH 找）**同时接受 ELF 与 `#!` 脚本** —— 只认 ELF 时，
  `/data/service/hnp/bin/python3.12` 这种脚本会被跳过，最后报 `command not found`，
  而 `which python3.12` 明明找得到（实测踩过）。exec 委托侧同理
  （`shim/exec_shim.c` 的 target 解析）。

  自举旁路：`BSH_FORCE_QEMU=1` 时连 aarch64 guest 也交 qemu。
  （2026-10-04 注：以前这里还写着"某些大号 glibc ET_EXEC 在 elfloader 里一进 guest 就 SIGSEGV" ——
  那个已经修掉了，根因是 `ElfReadInterp()` **只认 ET_DYN**，把**非 PIE 的动态程序**判成静态 guest、
  直接跳 `_start`（GOT 全是 0 → `pc=0`）。现在 ET_EXEC + `PT_INTERP` 也走解释器，kimi-code 那份
  arm64 发行二进制就是这么跑起来的。`BSH_FORCE_QEMU` 对"jit 不可用"那条路仍然保留。）

  **命令启动器文件（`#BSHSO`）**：命令集不必只存在于编译进去的表里 —— `<资源根>/bin/<命令名>`
  下的 4 行小文件就是一条命令：

  ```
  #BSHSO
  /data/storage/el1/bundle/libs/arm64/libtoybox.so
  bsh_toybox_main
  2
  ```

  | 行 | 含义 | 约束 |
  |---|---|---|
  | 1 | magic `#BSHSO` | 严格相等（做成 `#` 开头是为了和"读首行"的探测共用一条路） |
  | 2 | so 的**绝对路径** | 相对路径直接报错，不猜不拼 bundle libs |
  | 3 | 入口符号 | 非空、≤255 字节 |
  | 4 | 参数个数 | 只认 `2`（`int(*)(int,char**)`）或 `3`（多一个 `envp`） |

  容错：行尾 `\n` 或 `\r\n`、行尾空白都接受；**任何一处不合法都报清楚"第几行、哪里错"并且
  不静默回退**（实测报错样：`启动器格式错 …: 第 4 行只能是 2 或 3（得到 "4"）`）。

  生成与生效：
  * `shell.cpp` 在会话启动时看 `<资源根>/bin/sh` **在不在** —— 不在就调
    `cmd_make_launchers()` 按命令表整批生成（表暂时保留，只当**生成器**用）；想强制重生成就
    删掉 `$SYSROOT/bin/sh`。
  * 手工放一个启动器就能加命令（含表里没有的名字）：procmgr 的 `Resolve` 第 1.5 步解析它。
  * 这不是权限边界：数据目录（资源根）是 noexec，系统 `dlopen` 会失败 —— 但 **pip 装在那里的
    C 扩展现在照样能用**：libpython.so 里的 `dlopen` shim 会把它转给 elfloader 的进程内装载器
    （详见 `src/main/cpp/shim/README.md` §9）。bundle libs 仍然是**唯一**能被系统加载器直接
    打开的位置，只是不再是"唯一能跑代码的位置"。
  * `shim/exec_shim.c` **不做类型判断**：它把"要跑什么"原样交给 procmgr（唯一例外是
    `clang` 用 `/proc/self/exe` 起自己 → 翻译成命令名）。所以裸名能不能找到启动器，取决于
    **procmgr 的 `SearchPath`** —— 它现在同时认 ELF、`#!` 脚本与 `#BSHSO` 启动器三种。
    ⚠ 这个 shim 被烤进十几个命令 so（mksh/toybox/vim/python/node/dropbear/zip…）：
    改动它要重编那些 so 才生效；旧副本行为兼容（它们自己判类型，判对了才转发）。
- **通道**：`<资源根>/bsh-ctrl.sock`（AF_UNIX + SOCK_STREAM；帧 = 4 字节大端长度 + 文本行 payload，
  fd 走 `SCM_RIGHTS`），路径经环境变量 `BSH_CTRL_SOCK` 传给子进程。请求/响应格式见
  `procmgr/ctrl_socket.cpp` 顶部注释；另有 `CMD PING` / `CMD LIST` / `CMD TERMINATE` 便于排查。
- **宿主也走 socket**：`shell.cpp` 不再自己 `fork`，统一发 CREATE 帧（`RunSpawn`），资源解包用的
  `tar` 同样如此 —— 全工程的 `fork` 只剩 procmgr 一处。
- **fd 怎么过去**（最容易做错的一处）：procmgr 是在**主进程**里 fork 的，新进程继承的是主进程的
  fd 表，**不是**调用方（可能是另一个进程里的命令 so）的。所以调用方必须显式经 `SCM_RIGHTS` 传：
  宿主把会话 pty slave 传成 0/1/2；命令 so 委托时枚举 `/proc/self/fd` 里所有非 `FD_CLOEXEC` 的 fd
  （0/1/2 优先，上限 16）连目标号一起传 —— 漏了这一步，mksh 的 `a | b`、`ls > f`、`toybox xargs`
  会静默失效。
- **tty 身份**：fork 出的子进程在 `dup2` 之后调 `bsh_tty_bind_stdio()`，把 0/1/2 绑到会话共享的
  tty 状态；少了这步 `isatty` 为假，vim/mksh 会报 `no controlling tty`。
- **前台 pid**：`SetForegroundHook` 在 fork 完成时回调宿主（wait 结束再回调 -1），宿主据此更新
  `g_fgChild` 供输入路径转发 ISIG 信号 —— 走 socket 也不会丢 Ctrl+C 的竞态窗口。
- **失败码**沿用：`dup2` 失败 `_exit(124)`、`dlopen` 失败 `_exit(125)`、`dlsym` 失败 `_exit(126)`、
  ELF 装载失败 `_exit(127)`。
- **崩溃取证**：`ForkChild` 给**每个**子进程挂 `OnSigFault`（SIGSEGV/SIGBUS/SIGILL/SIGABRT +
  64KB 备用信号栈），崩了打 `[bsh] FAULT sig=… addr=… pc=… 所在映射: …` 并追加一行到
  `<资源根>/elf-fault.log`。**命令 so 另有一路开关**：`export BSH_FAULT_TRACE=1` 时，procmgr 会在
  dlopen 之前、以及调入口之前各再装一次 elfloader 那份 handler（`elf_arm_fault_handlers`），
  崩溃时打 `[elf] fault: SIGSEGV pc=0x… addr=0x…`。
  ⚠ 两路都**可能被 libnode/V8 自己的 SIGSEGV handler 盖掉**（V8 的栈溢出兜底会链到前一个，
  非栈溢出时它自己就吃掉了），所以查 node 侧崩溃还得靠"在 V8 装完之后再抢一次"那种做法。
  正对照是 `BSH_FAULT_TRACE=1 sh -c 'kill -SEGV $$'` → 会打出 `[elf] fault: …`（验证装配本身有效）。

### kimi-code 交互 TUI 的两个崩溃（2026-10-05，都已定位并修复）

它们一度只有"rc=139 / rc=159、零输出"这一个现象（node 自己的 `--report-on-fatalerror` 也来不及
产出报告），排查顺序与排除清单记在 `CHANGELOG.md`。结论与修法：

1. **rc=139 —— `process.title` 触发的一次跨堆 memset**（`scripts/node-ohos/bsh_node_entry.cc`）。
   libuv 的 `uv_setup_args()`（`deps/uv/src/unix/proctitle.c`）把 `process.title` 的可写容量算成
   `argv[argc-1] + strlen + 1 - argv[0]`，前提是 **argv 各字符串在内存里首尾相接**（内核给的 argv
   确实如此）。而我们原来用 `std::vector<std::string>` 拼 argv，每个字符串各自一次堆分配，
   那个差值就成了两个无关堆地址之差（可以是几 MB），于是 `uv_set_process_title()` 里
   `memset(pt->str + len, 0, pt->cap - len)` 变成**以 argv[0]（"node"，一个 5 字节堆块）为起点、
   跨越整个堆的清零**，直到撞上未映射页才 SIGSEGV。修法：argv 改拼进**一整块连续内存**。
   这个 bug 的指纹很特别——崩点五花八门、崩在 musl 的 memcpy/memset 里、多线程同时崩，
   而 `--max-old-space-size=64` 时清零能在已映射区里跑完，就只表现为**堆被清空后的干净 OOM**
   （rc=134、`Reached heap limit`）而不是段错误。
2. **rc=159 —— `io_uring_setup`(425) 被沙箱判 TRAP、投出的 SIGSYS 没人接**（`shim/fs_shim.c`）。
   libuv 初始化 io_uring 后端时会裸调 `syscall(__NR_io_uring_setup, …)`，而鸿蒙沙箱对这一号是
   `SECCOMP_RET_TRAP`（内核日志：`[hmsecpt] sig=0 … syscall=425 … code=0x30000`）。本来 procmgr
   在子进程里装的 `OnSigSys` 会把它降级成 ENOSYS，但 **node 进程里那个 handler 被 V8 顶掉了**：
   `v8::base::debug::EnableInProcessStackDumping()` 用
   `sa_flags = SA_RESETHAND | SA_SIGINFO | SA_ONSTACK` 装 SIGSYS —— **带 SA_RESETHAND**，
   于是第一次之后 SIGSYS 复位成 `SIG_DFL`，再撞一次就按默认动作 core dump 打死。
   修法：在 `syscall()` 包装里让 `io_uring_setup` 直接判 ENOSYS（libuv 那边是
   `ringfd = uv__io_uring_setup(…); if (ringfd == -1) return;` 干净回退到 epoll/线程池）——
   **从源头不产生 SIGSYS，不再依赖任何 handler 是否还在**。
   顺带说明：`ptrace` 在沙箱里是 `EACCES`（不是 KILL），逐号探针（参数全 0）也测不出任何被杀的号
   —— 这次的定位靠的是**内核日志**（`hdc shell "hilog -t kmsg"`，grep `hmsecpt`/`coredump`），
   它会把每一条 seccomp 决策（含系统调用号与动作码）与每一次 core 写出来。

⚠ 读崩溃现场地址时注意：报告里的 `+0x偏移` 是**映射内**偏移，换算 ELF vaddr 要加**那一段
PT_LOAD 的 `p_vaddr`**（不是 `.text` section 的地址），否则会把 pc 归到隔壁函数上（实测踩过）。


### jit 的三种情况：能力与对策（2026-09-30 实测）

能不能拿到**可写可执行的内存**，决定了 guest/翻译器怎么跑。这里有**两道门**，不是一个开关：

1. **kernel 权限**：`module.json5` 里的
   `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY` +
   `ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION`。有它们时 `mmap(PROT_WRITE|PROT_EXEC)`
   直接就能成；
2. **prctl 门**：`prctl(0x6a6974 /* ASCII 'jit' */, 0, 0)` 开门 → `mmap`/`mprotect(PROT_EXEC)` →
   `prctl(..., 0, 1)` 关门。**这条路不需要上面那两条权限**（V8 的 `patches/0001` 与 elfloader 的
   `jit_toggle`/`mprotect_final` 走的就是它）。

检测一次即可看到自己在哪种情况：`bshutil caps`（输出 `fork=` / `exec=` / `jit=` /
`route=` / `jit errno=`）。

| 能力 / 用例 | ① 有 kernel 权限 | ② 无权限、允许 prctl | ③ 无权限、prctl 也不通 |
|---|---|---|---|
| `bshutil caps` | `jit=yes route=anon-rwx` | `jit=yes route=prctl-rwx` | `jit=no route=none errno=22` |
| aarch64 guest | ✅ elfloader | ✅ elfloader（Mode A 自带 prctl 夹层） | ❌ elfloader（`mprotect(PROT_EXEC)` 三种模式全 EINVAL）→ **自动改走 qemu-user** ✅ |
| x86_64 guest | ✅ box64 | ❌ box64（`cannot allocate … for bridge`）→ 目前无自动兜底，见下 | ❌ box64 → **自动改走 qemu-user** ✅ |
| node（V8） | ✅ 真 JIT | ✅ 真 JIT（自己走 prctl 夹层，`execArgv` 里没有 `--jitless`） | ✅ **自动降级** `--jitless --no-expose-wasm`（纯解释器，慢但功能完整） |
| java / javac（本项目自带 JDK 与 hnp 的 BiSheng JDK 都是） | ✅ | ❌ **TODO** | ❌ **TODO** |
| hnp 应用（真 `execve` 那条路） | ✅ | ✅ | ✅ 不受影响 |
| 命令 so（`dlopen` 那条路） | ✅ | ✅ | ✅ 不受影响 |
| 完整自检 `autorun-all.sh` | 全绿（基线见 `scripts/jdk-ohos/README.md`） | `PASS=52 FAIL=3`（3 条全是 java） | 未跑全套；上表逐项实测 |

几点说明：

- **分流在哪**：`procmgr` 的 `Resolve` 第 4 步按 `Capabilities().jit` 选路 —— jit 可用走快路
  （aarch64 → elfloader、x86_64 → box64），jit 不通则把两者都交给 qemu-user
  （`libqemu-aarch64.so` / `libqemu-x86_64.so`，入口 `qemu_entry`，走 `kSoMain`/dlopen，不需要可执行页）。
  情况 ② 不需要兜底：快路自己就能成。
- **qemu 那条路要 guest 的运行期**：qemu 老实按 guest 的 `PT_INTERP` 找解释器，所以包里得带
  `ld-musl-aarch64.so.1` / `ld-linux-aarch64.so.1`(+`libc.so.6`) / `ld-musl-x86_64.so.1`
  （`build_qemu.sh` 交付）/ x86_64 glibc 的 `ld-linux-x86-64.so.2`(+`libc.so.6`)。
  `shell.cpp` 会话启动时把它们从 bundle libs 拷成 `<资源根>/{lib,lib64,lib/x86_64-linux-gnu}/`
  并导出 `QEMU_LD_PREFIX=<资源根>`（摆拷贝而不是软链：这沙箱里 `symlink()` 一律 EPERM）。
  ⚠ 这个位置**必须是资源根本身**：qemu 的 OHOS 补丁把 `QEMU_LD_PREFIX` 同时当 guest rootfs 基准，
  放到子目录里（如 `<资源根>/qemu-root`）会让 guest 看到 `/mnt/host-root/…`，cmake 这类
  "靠 `/proc/self/exe` 反推安装目录"的程序会算出不存在的 root。
- **x86_64 guest 在情况 ② 还没有兜底**：box64 不需要 guest 的解释器（自带 libc 垫片），但它要
  可执行内存，而它**没做 prctl 夹层** → 拿不到就 `cannot allocate … for bridge`。要补的话有两条：
  给 box64 打同样的夹层（跟 V8 补丁一个思路），或者在 `jit=no` 之外再加一条"box64 起不来就转
  qemu-x86_64"的判据 —— 后者得先能判定"起不来"，不适合放进决策期。
- **java 是 TODO（情况 ②③ 都不可用）**：HotSpot 走的是**裸 `mprotect(PROT_EXEC)`**，既不开门也没有
  "拿不到就换模式"的逻辑，`-Xint` / `-XX:ReservedCodeCacheSize` 都救不了（实测三种写法全失败）。
  可落地改进是给 HotSpot 的 `os_linux.cpp` 里 `os::commit_memory`/`os::protect_memory` 那条
  `mprotect` 打上同样的 prctl 夹层 —— 机理、A/B 数据与验收表都在
  `scripts/jdk-ohos/README.md`。在这之前：情况 ① 才有 java。
- **情况 ③ 怎么复现**（不依赖真设备）：临时给 `prctl` 加 wrap ——
  `-Wl,--wrap=prctl` 外加一个 `int __wrap_prctl(int, ...) { return 0; }`，
  加在 `libentry.so`（CMake 的 `entry` 目标）上就能让 elfloader/procmgr/caps 这一侧"看不到 jit"；
  想连某个命令 so 一起模拟（例如证明 node 会自己降级），就把同样的 wrap 加进那个 so 的链接行。
  **测完要撤掉**：它会让情况 ② 的设备表现成情况 ③。

### exec 委托

沙箱没有真 `exec`。各命令 so 通过 `scripts/shim-wrap-flags.sh` 那份清单里的
`-Wl,--wrap=execve/execv/execvp/execvpe/execl/execlp/posix_spawn/posix_spawnp`（外加 `exit`）
接入 `shim/exec_shim.c`：在 exec 点把「要跑什么 + 当前可继承的 fd」写成 CREATE 请求发给
procmgr，等它创建进程并把退出码带回来，再 `_exit(该码)` —— 对上一层 `waitpid` 表现为一次正常的
exec + 退出。**归一**只做一件事：把"要跑什么"**原样**交给 procmgr（唯一的例外是 clang 用
`/proc/self/exe` + `-cc1` 起自己 → 翻译成命令名 `clang`）。类型判断 —— 启动器 / `#!` 脚本 /
ELF / hnp 真 `execve` / 按 `e_machine` 分流 —— **全在 procmgr 的 `Resolve()` 里**：客户端不重复
一遍，因为这个文件被烤进十几个命令 so，重复一遍就是两边必然不同步。`exec_shim.c` 自己不 dlopen、
不查命令表、也不 `NEEDED libentry`。

同一份源码还以 **`LD_PRELOAD`** 形态给 guest 用（`libbshguest-{musl,glibc}.so`，靠
`BSH_EXEC_SHIM` 开关）：guest 里的 shell/脚本要起别的程序同样转给 procmgr。两种形态的区别见
`shim/README.md` —— guest 侧失败要按 `execve` 语义返回 -1 + errno，命令 so 侧
（`-DBSH_SHIM_WRAP`）没有退路，打一行错误后 `_exit(127)`。

`posix_spawn` 的语义是"父立即返回 pid，孙由调用方 `waitpid`"：真实的孙进程由 procmgr 创建
（父是主进程），拿不回可 wait 的 pid，所以这一层自己 `fork` 一个中间进程扮演那个子进程 —— 它委托
完带着退出码退出，调用方 `waitpid` 拿到的码因此是正确的。

内置 clang 那套（命令 so 形态）已经移除；这段特判现在只在"命令表里还挂着 `clang`"时才有意义，
留着是为了**将来若再以 so 形态内置 clang** 时能直接用：判据是 `file == /proc/self/exe`
**且** argv 含 `-cc1`/`-cc1as`，命中则按命令名 `clang` 交给 procmgr 查表。
（pkg 装下来的 SDK clang 是普通 ELF，走的是 `clang -fintegrated-cc1`（driver 内联后端），
不会走到这里。）

### 命令表与命令启动器文件

`procmgr/command_map.c` 是命令表：`命令名 → { so 文件名, 入口符号 }`。它现在有**两个身份**：

1. **运行时的回退**：`Resolve` 第 1 条按名字查表（表里有的名字仍按老路起，零开销）；
2. **命令启动器文件的生成器**：`shell.cpp` 在会话启动时调 `cmd_make_launchers()`，按表往
   `<资源根>/bin/` 写一批 `#BSHSO` 文件（判据是 `<资源根>/bin/sh` 在不在，见前面「命令启动器文件」
   一节）。启动器是**数据**：手工放一个就能加命令，不必重编 procmgr。

表里还保留 `guiduo`（`libguiduo.so`）这个预留条目，仓库中**没有**对应 so，执行时会在 `dlopen`
失败后报错。`python`/`python3` 两个名字都指向 `libpython.so`，入口是 `Py_BytesMain` 而非
`main` —— CPython 的核心对象带 `-fvisibility=hidden`，`Programs/python.c` 里的 `main` 是局部
符号，而 `Py_BytesMain` 是导出 API，签名同为 `int(int, char**)`（就是 `main` 那一行）。

### elfloader

一个 in-process ELF loader：把 aarch64 ELF 的段映射到新内存、在自制栈上跳转执行
（`elf_switch_to_guest`，见 `elfloader/guest_switch.S`），不做 `exec`。参考 Termony 的
`build-hnp/elf-loader`，并用 `prctl('jit', …)` 包裹 `mprotect(PROT_EXEC)` 以适配 HarmonyOS 的 W^X。
约定：guest 必须是 aarch64，若能返回则控制权回到宿主；调用 `exit_group` 会结束整个进程，因此实际
调用点都在 procmgr `fork` 出的子进程里（`procmgr.cpp` 的 `ChildRunElf`）。
动态链接的 guest（带 `PT_INTERP`）由 `ChildRunElf` 读出解释器路径，把主镜像与解释器（musl 的
`ld-musl-*.so.1`，或 glibc 的 `ld-linux-aarch64.so.1`）一起 `mmap`，入口起解释器、由真正的动态
链接器做重定位后调 `main`（`elf_run_dyn_inproc`）。解释器**只从 bundle libs 按 basename 找**
（`kBundledLibDir`）。
**主镜像 PIE 与非 PIE 都认**：`ET_EXEC` + `PT_INTERP`（关掉 PIE 编出来的官方发行二进制，
kimi-code / SDK 的 cmake 都是这个形态）跟 PIE 一样要靠解释器重定位 —— 内核遇到它也是先起解释器。
以前 `ElfReadInterp()` 只认 `ET_DYN`、`elf_run_dyn_inproc()` 还额外要求 `!m.dyn`，于是这类二进制
被判成静态 guest 直接跳 `_start`：GOT 全 0，`[bsh] FAULT sig=11 addr=0x0 pc=0x0`，一进去就死
（2026-10-04 修）。自检里 `aarch64-glibc-dynamic-nopie` 这一格就是给它留的回归位。
另外 exit 桩只打给**真正的静态** guest（`!dyn && !has_interp`），动态主镜像的 `exit` 由解释器接管。`ChildRunElf` 另外给 guest 备好几样：

- `BSH_GUEST_EXE` —— guest 侧 shim 用它回答 `readlink/stat/open("/proc/self/exe")`：内核给的是
  宿主 appspawn，不是 guest 自己，不然"读 `/proc/self/exe` 再 exec 自身"这类程序必死；
- `LD_LIBRARY_PATH` —— 先 guest 自己的目录、再 bundle libs。glibc 的 ld.so **不搜**可执行文件
  所在目录，所以"库跟可执行文件放一块"的分发形状（Qt 应用目录）必须靠它；guest 同目录放在前面，
  应用自带的同名库才能盖住 bundle 里的；
- `LD_PRELOAD` —— 按 `PT_INTERP` 选同一个 libc 编出来的 shim（`libbshguest-musl.so` /
  `libbshguest-glibc.so`），并开 `BSH_FAKE_PTY` / `BSH_EXEC_SHIM` 两个开关。

静态 guest 走 `elf_run_file`（内部只 `elf_run_mem`），上面这些 `LD_*` 对它无效。

### box64：跑 x86_64 程序

`elfloader` 只管同 ISA 的 aarch64。x86_64（以及 i386）交给 box64 —— 源码在 `thirdparty/box64`
（由 `scripts/build_box64.sh` git clone 后打补丁，**不是**子模块），编出 `libbox64.so`，入口
`bsh_box64_entry`。它跟别的命令 so 走同一条 kSoMain 路：fork 出的子进程里 `dlopen` 再调符号，
全程不 exec。

**不用记前缀**：procmgr 的 `Resolve()` 读 ELF 的 `e_machine` 自己挑执行者 —— `AARCH64` 给
elfloader，`x86_64`/`i386` 给 box64，所以终端里 `./x86_64-xxx` 和 `./aarch64-xxx` 都是直接跑；
`box64 ./xxx` 这种显式写法也仍然有效。认不出的架构仍交 elfloader，由它报 `bad ELF header`。

三处与别的命令 so 不同的地方（原因都写在代码注释里）：

- `dlopen` 必须用 **`RTLD_GLOBAL`**：box64 的补丁把 `box64lib` 置成 NULL，它解析包装符号走
  `dlsym(RTLD_DEFAULT, "my_…")`，只搜**全局**作用域；用 `RTLD_LOCAL` 加载时每个 `my_*` 都找不到，
  表现为「Warning, function my_xxx not found」刷屏后 SIGSEGV。
- 子进程开头先 **`UnmapLowAnonRegions()`**：非 PIE 的 x86_64 可执行文件要落在固定基址
  `0x400000`，而应用主进程低 4GB 里有一大块**无名**的 ArkTS 堆预留挡着（只认 `[anon:` 前缀会漏掉它）。
- argv 要重组成 `[box64, <guest>, …]`，见 `ChildRunSoMain` 里 `guest` 非空那条分支。
- **禁掉了 box64 对 guest 镜像的"文件可执行映射"**（补丁 0041）：上游的 `AllocLoadElfMemory()`
  对每个 `PT_LOAD` 段先试"从文件 `mmap`"（PF_X 段带 `PROT_EXEC`），而这正是沙箱那道
  seccomp 确认闸拦的动作 —— 症状是**每加载一个 guest 就弹一次「是否运行 …」、不点就干等
  30 秒**（被拒后 box64 自己会退到"匿名映射 + `fread`"兜底，所以程序照跑，问题一直没被
  当成故障）。现在强制走兜底路径，语义等价，实测同一份自检 **306 秒 → 7 秒**；
  详情见 `scripts/box64-ohos/README.md` §11。

验收：x86_64 侧 glibc/musl × 静态/动态四种组合由 `scripts/build_testprogs.sh` 编出，随
`rawfile/tools/testprogs.tar` 解到 `<资源根>/testprogs`（另含 aarch64 的组合做对照）。testprogs
现已扩充到 31 个用例块（含 exec / exec-self / 软链 / pty / `/proc/self/exe` 等）。
**2026-10-03 实测**（release 构建模式 + `debug-jit` 签名，SN `3QC0225617000597`，
原始日志与 A/B 记录见 `scripts/box64-ohos/README.md` §8）：

| 组合 | 结果（2026-10-03 当晚，含 fs/tty/pty shim 与"禁文件可执行映射"几轮修改后） |
|---|---|
| `x86_64-musl-dynamic` | 31 块 / pass 27 / fail **3**，**rc=42 正常收尾** |
| `x86_64-glibc-dynamic` | 31 / 26 / **4**，rc=42 |
| `x86_64-{musl,glibc}-static` | 软链块已全 PASS（原先创建就失败）；仍**死在 `[signal]` 块**（rc=139）：box64 对**静态** guest 的信号路由问题，动态 guest 没这毛病，与我们的接入无关 |
| `aarch64-musl-dynamic`（对照） | 31 / 29 / 1（唯一 fail = 硬链接，release 模式下的沙箱策略） |

x86_64 剩下的 3~4 个 fail：`创建硬链接`（release 模式真禁 `link(2)`）、
`auxv 不自洽 ENTRY=0x0`、`子进程退出码或管道内容不对`、glibc 独有的 `exec 兄弟程序失败(139)`。
**软链 / tty / pty 三类已经补齐** —— `shim/{fs,tty,pty}_shim.c` 现在以 `-DBSH_SHIM_BOX64`
也编进 `libbox64.so`，box64 的 `my_*` 与裸 syscall 两条路都挂上了；x86_64 guest 的 pty
行为与 aarch64 guest **一字不差**（都是用户态假 pts —— 沙箱三层都打不开真 `/dev/ptmx`，
实测 `EACCES`）。细节见 `scripts/box64-ohos/README.md` §11。
i386 也路由到 box64（走它的 BOX32），但那条路验得少。

### 资源解包

`shell.cpp` 的 `initResource()` 在会话启动时把 rawfile 里的 tar 解到**资源根**（`BSH_SYSROOT`
= `files/`，见 `common/bsh_paths.h`），幂等靠**一个总标记** `<资源根>/.res-unpacked`：存在就整段
跳过，不存在才全量解一遍（早期是每个资源一个 doneMark；`UnpackRes()` 现在只剩
`(rawfile, dest)` 两个参数）。解包复用 `libtoybox.so` 的 `tar`，跑在 procmgr `fork` 出的子进程里，
stdio 接 `/dev/null`（沙箱禁 symlink 之类的 EPERM 不该喷到用户终端上）。

| rawfile | 落点 | 说明 |
| --- | --- | --- |
| `tools/vim-runtime.tar` | `<资源根>/vim-runtime` | `$VIMRUNTIME` |
| `tools/{xkb,weston-data}.tar` | `<资源根>` | 顶层 `usr/share/…` → `<资源根>/usr/share/{x11/xkb,weston}` |
| `tools/fonts.tar` | `<资源根>` | `fonts/` + `fonts.conf` |
| `tools/weston-terminal.tar` | `<资源根>/weston-terminal` | 可执行 + wayland 闭包（平铺，见下） |
| `tools/python-stdlib.tar` | `<资源根>` | 顶层 `python/`，`PYTHONHOME` |
| `tools/testprogs.tar` | `<资源根>` | 顶层 `testprogs/`，8 组合验收程序 |
| `tools/npm.tar` | `<资源根>` | npm 的纯 JS 树 → `<资源根>/npm/bin/npm-cli.js` |

只有两个小文件进 `$HOME`：`tools/hello.c` → `$HOME/hello.c`（编译样张；编它要用 pkg 的
`ohos-sdk-prune` 里那套 clang，见「命令表」下面那段），
`tools/hdckey{,.pub}` → `$HOME/.harmony/`（设备侧 hdc 的身份密钥，私钥 0600 且 gitignore）。
`autorun-all.sh` 由 `MaybeRunAutorun()` 每次会话覆盖写到 `$HOME`（只落盘、不自动跑）。

这几项**当前注释掉、不随包**：`bshsign-tools.tar`、`jdk21-ohos.tar`、`pyqt6.tar`、`qtapp.tar`、
`hvigor-cache.tar`（保留在 `initResource()` 里，便于按需打开）。

weston-terminal 的资源与本体：`tools/xkb.tar` → `<资源根>/usr/share/x11/xkb`（`XKB_CONFIG_ROOT`；
tar 里就是 `usr/share/x11/xkb/...`，脚本把发行版 deb 的 `X11` 改成了小写 `x11`）、
`tools/weston-data.tar` → `<资源根>/usr/share/weston`（`WESTON_DATA_DIR`，框架按钮 PNG）、
`tools/fonts.tar` → `<资源根>/fonts/` + `<资源根>/fonts.conf`（`FONTCONFIG_FILE`）、
`tools/weston-terminal.tar` → `<资源根>/weston-terminal/`（可执行 + 依赖闭包，平铺）。
四个 tar 由 `build_weston_terminal.sh` 生成（xkb 取发行版 `xkb-data` 包，weston-data 取
`thirdparty/weston/data/*.png`，字体取 DejaVu Sans Mono），源码缓存在 `build/weston-term/res-src/`。
⚠ `fonts.conf` 里 `<dir>` 是**写死资源根的绝对路径**（是文件内容，`FONTCONFIG_FILE` 只能指文件、
改不了它），所以挪布局时 `build_weston_terminal.sh` 那条也要跟着改。

CPython 的 stdlib 也走这条路：`tools/python-stdlib.tar` → `<资源根>/python/lib/python3.12/`
（tar 顶层就是 `python/`），前缀与 `configure --prefix` 写死的沙箱路径一致，会话里
`PYTHONHOME=<资源根>/python` 指过去，因此 python 不依赖 `argv[0]`/可执行路径定位 stdlib。
该 tar 由 `build_python.sh` 生成（`make install` 后裁掉 `test/idlelib/tkinter/ensurepip/lib2to3/
config-*/lib-dynload`），脚本与构建期的几个坑（`MODULE_BUILDTYPE` 必须 static、`libintl.h` 是空壳、
三元组自检、入口是 `Py_BytesMain`）都在脚本注释里。

npm 与 JDK 的数据同样在资源根下（`<资源根>/npm`、`<资源根>/jdk21`），它们的入口 so 里原本
**自己拼过这个路径**（`node-ohos/bsh_node_entry.cc` 找 `npm-cli.js`、`jdk-ohos/bsh_java_entry.cc`
定 `java.home`），现在改成从宿主导出的 `BSH_SYSROOT` 读 —— 以后再挪布局只改宿主，不用重编这两只 so。
（JDK 默认不出包：`.so` 平铺在 bundle libs、数据 tar 与 `java`/`javac`/`jar` 入口都在
`initResource()` / `command_map.c` 里注释着，见 `scripts/jdk-ohos/README.md`。）

### pkg：包管理器与"按需下载"的包

`pkg` 是命令 so（`programs/pkg/`，自带 mbedTLS + zstd 的解压半边），源默认
`https://bsh.y1yan.com/`（`pkg source` 可改），安装根就是**资源根**：包里 tar 的路径
直接相对资源根（`usr/bin/...`、`opt/ohos-sdk/...`），所以"安装"= `tar -C <资源根> -x`。
状态与缓存：`<资源根>/pkgs/{installed.json,cache/}`。

| 包 | 装到哪 | 用途 |
| --- | --- | --- |
| `weston-terminal` | `usr/bin` + `usr/lib` | 终端仿真器（可执行 + wayland 闭包），依赖 `xkb`/`weston-data` |
| `xkb` | `usr/share/x11/xkb` | `XKB_CONFIG_ROOT` |
| `weston-data` | `usr/share/weston` | 窗口装饰按钮 PNG |
| `ohos-sdk-prune` | `opt/ohos-sdk/openharmony` | **裁剪版 OHOS SDK**（`command-line-tools/sdk/default/openharmony`），供设备上自举编译；见 `scripts/pack_ohos_sdk_prune.sh` |
| `pip` | `python/lib/python3.12/site-packages` | pip 26.2.1（PyPI 的纯 Python wheel）。不装就没有 `pip` 命令 |
| `devtools` | `usr/bin` | GNU make 4.4.1 + ninja 1.12.1（musl 版），pip 装 sdist / 现场编 C 扩展要用；见 `scripts/build_devtools.sh` |
| `node-headers` | `node-headers` | 官方 headers 包（顶层 `node-headers/`，内容就是 Node 22.19.0 的 `include/node`，其中含 `common.gypi` / `config.gypi`）。node-gyp 现场编扩展用，配 `.bshrc` 里的 `npm_config_nodedir`。**版本必须与设备上 node 的 `NODE_MODULE_VERSION` 对齐**（22 → 127；上一版是 18 的 115，升 node 时要一起重出）。重出方式：取 nodejs.org 的 `node-v<VER>-headers.tar.gz`，把 `include/` 放到 `node-headers/` 下打包成 `node-headers.tar.zst`，传服务器并改 `index.json` 的 version/size/sha256 |
| `python-headers` | `python-headers` | CPython 3.12.14 的 `Python.h` + `pyconfig.h`（`build_python.sh` §5.5 产出）。只有现场编扩展要用 |
| `hdc` | `usr/bin` + `usr/lib` | 设备侧的 `hdc`（HarmonyOS command-line-tools 的 linux-arm64 那份，glibc 构建）+ 它的 `.so` 闭包。连设备自身的 hdcd（`hdc tconn`）装/拉起 HAP，自举流水线用；见 `scripts/pack_hdc.sh` |
| `haptools` | `usr/bin` + `usr/lib` | `hap-sign-tool` + `app_packing_tool` 的**原生重建**（静态链接，替代两个 jar）与 `java` 转发壳，设备上签名/打包 HAP 用；见 `scripts/build_haptools.sh` |
| `git` | `usr/bin` + `usr/libexec/git-core` + `usr/share/git-core` | git 2.56.0。musl **动态**可执行（要吃到 LD_PRELOAD 的那套 shim，否则它 exec 的 `ssh`/编辑器会被内核直接拒掉），第三方库（zlib/pcre2/openssl/libcurl）全静态链进去。`usr/bin/` 下是四个启动器（`git` / `git-upload-pack` / `git-receive-pack` / `git-upload-archive`，后三个必须在 `PATH` 上，本地 clone 才走通），自带 CA bundle，`clone https://` 与 `ssh://` 都能用；**不含** perl/python 写的子命令（`git-svn`/`git-p4`/`git-instaweb`/`git-send-email`）—— 设备上的 python 是命令 so、perl 没有，装了也是一跑就错。见 `scripts/build_git.sh` 与 `scripts/git-ohos/README.md` |
| `code-server` | `usr/lib/code-server` + `usr/bin/code-server` | VS Code 服务端（自带 glibc node 与运行时闭包）。解包 640MB，**不进 HAP**（HAP 因此从 458MB 降到 233MB），想用才装；见 `scripts/pack_codeserver.sh` |

加一个包 = 打 tar（相对资源根的路径）→ 传到服务器 `~/data/docker_data/typecho/typecho/bsh-packages/`
→ 在 `index.json` 的 `packages` 里加一条（`file` / `size` / `sha256` / `depends`）。
本地那份镜像清单是 `build/pkgserver/index.json`（在 `build/` 下，**未入库**，只是手边方便对账的副本），
两边要一起改（远端 `index.json` 改前先备份）。

**pkg 自己的几个约束，改包前先看**：

- **只认未压缩 tar、且不认符号链接**（`bsh_tar.c` 的 `on_member` 只管普通文件+目录；
  软链/硬链/设备节点/压缩一律跳过）。所以包里的软链要**展开成真副本**。要压缩就用
  `.tar.zst`：pkg 会先解成 `<cache>.tar` 再交给 tar（`bsh_zstd.c`，只用 zstd 的解压半边）。
  （`bsh_tar.c` 现在有三个可选的钩子 `on_member` / `on_link` / `skip`，**apt 用后两个**
  做软链代偿与"不覆盖已存在"；pkg 只传 `on_member`，行为与以前完全一致。）
- **缓存目录**：只由环境变量 `BSH_PKG_CACHE` 决定 —— **pkg 自己不含任何默认路径**，
  默认值是"会话环境"的事：`shell.cpp` 用 `common/bsh_paths.h` 的 `BSH_PKG_CACHE_DIR`
  导出 `/storage/Users/currentUser/Download/com.yiyan.bettersh/.pkg-cache`
  （`setenv(...,0)`，用户 `export BSH_PKG_CACHE=…` 可覆盖）。那是这个应用的
  **用户可见 Download 区**（属主 `file_manager`，应用可写），和资源根**不是**同一个目录：
  `deploy_hap.sh` 的 `bm uninstall` 会清空资源根，却清不到这里，所以把包缓存放这儿之后
  重新部署 HAP 不用重下（SDK 那个 252MB 的包实测一次下载、多次复用）。
  变量没设、或目录不存在/没授权/写不进去，就**退回** `<资源根>/pkgs/cache`（行尾会注明），
  `pkg` 在任何情况下都还能用；判断"能不能用"是**建目录 + 写一个探针文件**，不是只看
  `access()`。
- **缓存复用**：`<缓存目录>` 里已有同 `sha256` 的包就不重下（`pkg install --force` 因此能秒装）。
- **`installed.json` 按文件记清单**（`remove` 靠它逐个删）。清单是**动态数组**，5 万个文件
  （SDK 那个包）约 5 MB —— 原来的固定 512 项会让大包"装得上、删不干净"。
- ⚠ **`deploy_hap.sh` 会 `bm uninstall` 再装，等于清空资源根**：pkg 装的东西、
  `<资源根>/pkgs/*`、`installed.json` 全没（`$HOME` 里的用户文件也随之重建）。
  缓存放 `BSH_PKG_CACHE` 那个目录正是为了躲开这一刀。

**`ohos-sdk-prune` 为什么值得单列**（2026-10-02 实测）：

| | 体积 |
| --- | --- |
| 原 `command-line-tools` zip | 1788 MiB |
| 只打 `sdk/default/openharmony`（zstd -19） | 597 MiB |
| 再裁掉自举用不到的（lldb/LLVM 开发工具/非本机目标运行时/docs…） | **242 MiB** |

设备侧实测：**装下来 → 用装出来的 SDK 构建 → 执行**全通
（`clang --target=aarch64-linux-ohos … -fuse-ld=lld` 编出可执行，跑出 `hello from
ohos-sdk-prune`，C++ 前端也过）。两个踩过的坑：

1. **SDK 的 aarch64 clang 是 glibc 二进制**，NEEDED 里没有 `libm/libpthread/librt/libdl/
   libgcc_s`，SDK 与 HAP 都没带 → 包必须自己补这 5 个（`libgcc_s` 要用**glibc 版**，
   musl 那份的 NEEDED 是 `libc.so`，在设备上会解析成 musl libc）。
2. 补的闭包要放**跟 clang 同一个目录**（`native/llvm/bin/`），不能靠 clang 的
   `RUNPATH=$ORIGIN/../lib` —— guest 的 `/proc/self/exe` 是宿主 appspawn，ld.so 算出来的
   `$ORIGIN` 是错的（这是本项目的老坑，`fs_shim` 的 `/proc/self/exe` 替身救不了 ld.so 自己）。
   能用的那条路是 `LD_LIBRARY_PATH`：procmgr 会把 **guest 自己所在目录**塞进去。

### apt：从 Ubuntu/Debian 镜像装 .deb（自动解析依赖树）

`apt` 与 `pkg` 暂共用同一个 so（`programs/pkg/` 的第三个入口 `apt_main`），但打交道的
对象完全不同：`pkg` 装的是我们自己在 `bsh.y1yan.com` 上发的包，`apt` 装的是**发行版原生
deb** —— 依赖关系得从发行版的 `Packages` 索引里现查。

```
apt install ./code_1.141.0_arm64.deb          # 本地文件
apt install https://…/linux-deb-arm64/stable  # 直接用 URL（302 会跟）
apt install libgtk-3-0t64                     # 从镜像按包名装
apt install --dry-run …                       # 只看计划（闭包 + 体积）
apt remove <包名>                             # 按 pkgs/apt-installed.json 删文件
apt update | search <kw> | info <deb|包名> | source [url]
```

| 环境变量 | 默认 | 说明 |
| --- | --- | --- |
| `BSH_APT_MIRROR` | `https://ports.ubuntu.com/ubuntu-ports` | 镜像根（**必须 https**：内置客户端只做 TLS） |
| `BSH_APT_SUITE` / `BSH_APT_COMPONENTS` | `noble` / `main` | 索引拼成 `dists/<suite>/<comp>/binary-<arch>/Packages.gz` |
| `BSH_APT_ARCH` | 按编译目标 | `arm64` / `amd64` |
| `BSH_APT_CACHE` | 沿用 `BSH_PKG_CACHE` | deb 与索引缓存（落在 `<cache>/apt/`） |
| `BSH_APT_PUB` | `/storage/Users/currentUser/Download/com.yiyan.bettersh` | 用户自己下好的 deb 放这儿，优先于联网 |
| `BSH_APT_EXCLUDE_EXTRA` / `BSH_APT_EXCLUDE_NONE` | — | 增删排除名单 |

**索引规模（2026-10 实测 ports.ubuntu.com noble）**：`main` 1.7 MB(.gz) → 解压 7.0 MB →
5977 条；`universe` 19 MB → 72 MB → 63665 条。默认只吃 main（下载和解压都是秒级）。

**换源**：默认值在 `common/bsh_paths.h` 的 `BSH_APT_MIRROR_DEFAULT`，由 shell.cpp 写进
`$HOME/.bshrc`（`export BSH_APT_MIRROR=…`）—— 换国内源就改 .bshrc 里那一行。另外
`apt source <url>` 也能改，值落在 `$SYSROOT/pkgs/apt-source`，**优先级高于环境变量**。

四家实测（2026-10，平板，各下一次 1.7 MB 的 main 索引）：

| 镜像 | 耗时 | 结果 |
| --- | --- | --- |
| ports.ubuntu.com | 4s | 5977 包 |
| mirrors.tuna.tsinghua.edu.cn | 2s | 5977 包 |
| mirrors.aliyun.com | 13s | 5977 包 |
| mirrors.ustc.edu.cn | 2s | 5977 包 |

⚠ 换源换到"证书校验失败"时，多半是内建 CA 里没有那家的根 —— `bsh_ca_pem.h` 现在带了
四张（ISRG Root X1 / DigiCert Global Root G2 / GlobalSign Root R46 / ISRG Root X2），
覆盖上面四家；再换别家就要往里补。**必须 https**，内置客户端只做 TLS，明文 http 会被
判成 "URL 不合法"。

**三条从实战来的纪律**（也写在 `apt_main.c` 的文件头）：

1. **系统库不装**。默认排除 `libc6 / libc6-dev / libgcc-s1 / libstdc++6 / libcrypt1 /
   gcc-14-base` —— 它们由我们自编的 glibc 提供（bundle libs）。从 deb 装一份不配套的进来，
   ld.so 与 libc 的 TLS/内部 ABI 会对不上（实测 `glib-compile-schemas` 在
   `____strtod_l_internal` 里 SIGSEGV）。
2. **软链要代偿**。沙箱禁 `symlink(2)`，deb 里的软链解了等于没解。库软链（名字含 `.so`）
   复制成真文件，命令软链（`usr/bin` 下）生成 `sh` 包装脚本；目标已存在就**不动**
   （`--overwrite` 才覆盖）—— 这正是"已存在就不新建"。
3. **`--flatten DIR`** 把 `usr/lib/**/*.so*` 额外拷一份到该目录。VS Code 那种
   "本体与依赖必须同目录"的场景要靠它。

**t64 回退**：noble 为了 64 位 `time_t` 把一大批包改了名（`libgtk-3-0` → `libgtk-3-0t64`、
`libglib2.0-0` → `libglib2.0-0t64`…），而上游分发的 deb（VS Code 官方那份就是）的
`Depends` 里还写着**老名字**。所以 `bsh_depends.c` 的 `find_entry` 在查不到时，会精确
加一个 `t64` 后缀再查一次（不做前缀/模糊匹配 —— 那会误配）。没有这层回退，`code` 的依赖
会整片落进 missing：实测从「code + 9 个 missing」变成 **201 个包**、missing 只剩
`default-dbus-session-bus`（虚拟包，靠 Provides，我们没实现）。

**`--write-list FILE`**：解出依赖树后把清单（一行一个包名，按安装顺序）落盘。这样
**清单不需要预先算好打进 HAP** —— 设备上 `apt install --write-list $SYSROOT/bin/<名字>.list
<种子 deb 的 URL>` 一次就把依赖树解出来、装上、并留下清单备查。本地有 deb 时仍然优先用
本地的（`BSH_APT_PUB`）。

**实测：用 apt 装 VS Code（2026-10-08，平板）**

| 步 | 结果 |
| --- | --- |
| `apt install --flatten $S/usr/lib/vscode .vscode-dl/*.deb`（162 个本地 deb） | 新装 **225 个包**，平铺 **372 个库** |
| `apt install <官方 deb URL>` | 216 MB 的 `usr/share/code/code` + `resources/app` |
| 把 `usr/share/code` 铺进 `usr/lib/vscode` 后起 code | **窗口出来了**（1200×800 帧，`VizCompositorTh` 在跑） |
| **本地无 deb、无预打包清单**，直接 `apt install --flatten $V --write-list … <官方 deb URL>` | 65-114 秒装完 201 个包，铺过去之后**窗口照样出来** |

⚠ **本体必须与依赖放在同一个目录**（这一步不能省）。实测本体留在 `usr/share/code`
（依赖在 `usr/lib/vscode`、`LD_LIBRARY_PATH` 两个都给了）时，code 起来就**静默
SIGSEGV(139)**，日志停在 `Failed to initialize drm render node handle` 之后什么都没有。
这与 `ohos-sdk-prune` 那个坑同源：guest 的 `/proc/self/exe` 指向宿主 appspawn，
ld.so 与 Electron 算出来的 `$ORIGIN` 是错的 —— 光靠 `LD_LIBRARY_PATH` 不够，东西得真
放在一个目录里。

顺带踩到的两个坑：**VS Code 官方 deb 的依赖名是 jammy 时代的**（`libgtk-3-0` 而不是 noble 的
`libgtk-3-0t64`），所以它的依赖得靠我们那 162 个 deb 顶上。

**apt 装的 deb 常带"绝对路径启动器"，要靠两层机制兜住**。deb 里的 `usr/bin/xxx`
往往是个小脚本：

```sh
#!/usr/bin/env sh
exec /usr/lib/xxx/bin/xxx "$@"
```

而 guest 里**没有真正的根文件系统**（sysroot 挂在 `$BSH_SYSROOT`），`/usr/lib/…` 在宿主上
并不存在。两层配合才跑得起来：

1. **`fs_shim.c` 的 `kPathMap` 加了 `/usr` → `usr` 兜底** —— 让 `stat`/`open`/`cd` 这类
   文件系统调用能映过去。这一步**不能省**：mksh 在执行 `exec` 之前会自己 `stat` 一次路径，
   映不过去就只报 `inaccessible or not found`，**连 `execve` 都到不了**（所以只在
   procmgr 那层做回退是没用的，第一版就是这么白试的）。
2. **`procmgr` 的 `Resolve()` 加了绝对路径回退** —— 宿主上确实没有该文件时，试
   `$SYSROOT + path`。回退成 sysroot 绝对路径还有个附带好处：脚本里
   `cd "$(dirname "$0")"` 拿到的是正确路径（`code-server` 的 `bin/code-server` 正是靠
   `$0` 推导 ROOT 的）。

shebang 本身不用管：`#!/usr/bin/env sh` 会被 procmgr 按 basename（`env`）命中命令表里的
toybox `env`。

**实测**：`code-server_4.140.0_arm64.deb`（230 MB / 7135 个文件）—— `apt install` 12 秒装完，
`--version` 输出 `4.140.0 … with Code 1.140.0`，`--bind-addr 127.0.0.1:8080` 起服务并正常监听。

**`bsh_xz.c` 的来历**：个别老 deb（实测 `hicolor-icon-theme`）的 `control.tar` 和
`data.tar` 都是 xz，而设备上没有 xz 命令 —— 于是从 toybox 的 `toys/pending/xzcat.c`
提取了 xz-embedded（public domain）。那一份的配置项是 `default n`，**从来没被编译过**，
里面藏了五处 `char` 有符号的坑：`get_unaligned_le32` 的符号扩展、`xz_crc32/64` 查表拿
`*buf` 当负下标、`struct xz_buf` 的 `char *in/out`、range decoder 的 `const char *in`、
`dict_get` 返回 `char`。症状一路都是"能编译、一跑就错"（CRC 对不上 / 全解错 / 直接 SEGV），
都在 `bsh_xz.c` 里改掉并写了注释。

### Wayland compositor

- 会话启动时 `WaylandServer::Start(<资源根>/wl-sock)` 在独立线程跑 `wl_display` 事件循环
  （`wl_event_loop_dispatch` 50ms 超时轮询）。socket 放在**资源根**（`BSH_SYSROOT`）而不是
  `$HOME` —— 它和另外两个 sock 一样属于"应用基础设施"。libwayland 会在 socket 同目录自动建
  `<名字>.lock`，`XDG_RUNTIME_DIR` 由 server 从 socket 路径反推设置。
- 注册的 global：`wl_compositor`、`wl_shm`、`wl_subcompositor`、`wp_viewporter`、`wl_output`、
  `xdg_wm_base`、`wl_seat`。`build_wayland.sh` 另外生成 pointer-constraints / relative-pointer /
  tablet 的协议头，但这些 global 当前**未注册**；subcompositor / viewporter 只提供占位实现。
- toplevel 的 `wl_shm` 帧在 `surface_commit` 时按 `set_window_geometry` 裁剪后复制进 per-toplevel
  帧缓冲；首帧发 `created`（ArkTS 据此 `startAbility(AppRunnerAbility)` 建窗），尺寸变化发
  `resize`，销毁发 `destroyed`。
- 渲染与缩放：`PluginManager`（按 toplevelId 索引）为每窗口创建 `EglRenderer`，从
  `OH_NativeWindow_CreateNativeWindowFromSurfaceId` 拿到 XComponent surface，渲染线程把帧缓冲
  作为纹理上屏；窗口物理尺寸 = 客户端逻辑尺寸 × `UI_SCALE`（`WaymonyService.ets` 里是可变的
  `export let`，默认 2，终端里 `bshutil set win-scale <n>` 可改、**只对新开的窗口生效**），
  输入坐标按比例映射回客户端 buffer 坐标系并补偿 `window_geometry` 偏移。
- 输入：ArkTS 把键鼠事件经 NAPI 注入 `wl_seat`。注入来自 ArkTS 线程、事件循环在服务线程，二者用
  `std::recursive_mutex wlMutex_` 串行化（libwayland 非线程安全，递归锁是因为 commit 回调内也会
  进入该锁）。

### bshutil：改应用自己的设置

`bshutil` 是一个**命令 so**（`libbshutil.so`，入口 `programs/bshutil/bshutil_main.cc`），
但真正的实现在**主进程里一个常驻服务线程**（`bshutil/bsh_util_server.cpp`，随会话启动）。
它用来改应用设置、查进程表、取 hap 里打包的 rawfile，以及借 ArkTS 的手做 native 做不到的事。

**为什么是 so 却还要在主进程里有个服务**：命令 so 是 procmgr **fork 出来的子进程**
（`procmgr.cpp` 的 `SpawnSoMain`），而 bshutil 要改的两样东西都只存在于主进程 ——

- 应用设置（`bsh_cfg`）是主进程内存里的一份，shell 每次执行命令都直接读它，`set exit-hint off`
  当场生效就靠这个；
- 界面事件（`ui_bus` 的 `napi_threadsafe_function`）只能在创建它的进程里发。

子进程里改这些，进程一退出就没了，于是 `set` 会"成功"但毫无效果。所以 so 只是一层薄客户端：
连 `<资源根>/bshutil.sock`（路径来自 `common/bsh_paths.h`，与宿主、weston-terminal、dropbear 共用一份 ——
客户端是独立编译的命令 so，拿不到宿主的 `$HOME`，所以那个头就是它的路径来源），把 argv 交过去；
服务端在主进程里调用**原来的** `bshutil_exec(argc, argv, out_fd, cwd, sid)`（逻辑一行没改），只是 `out_fd`
换成了那条连接，输出流回客户端，再由客户端写自己的 stdout —— 所以 `bshutil conf > /tmp/x`、管道、
退出码都和普通程序一样。

顺带解决"mksh 里不能用"：`bshutil` 进了命令表，`<资源根>/bin/bshutil` 启动器由
`cmd_make_launchers` 自动生成，mksh 按 PATH 找到它 → exec 委托把路径交给 procmgr
（`shim/exec_shim.c` 认出 `#BSHSO` 就原样转发）。

**协议**（`bshutil/bsh_util_proto.h`）：一帧 = 4 字节大端长度 + 文本。请求是 `EXEC` /
`CWD <调用方当前目录>` / `ARGC n` / `ARG <i> <值>` / `END`；应答是**原始输出字节 + 4 字节大端退出码**，
末尾 `shutdown(SHUT_WR)` 收尾 —— 客户端据此把"末尾 4 字节"当退出码、其余当输出**流式**写出去
（服务端不攒输出，也没有临时文件）。`CWD` 那一行是给 `rawfile get` 用的：服务端跑在主进程里，
它的 cwd 是应用启动目录，跟用户在终端里 `cd` 到哪没关系（同 procmgr 的做法，见 `bsh_client.c`）；
客户端拿不到 cwd 时整行不写，那时相对路径会被明确拒掉。值里不能有换行，但**空白是安全的**
（解析取"第一个空格之后的全部"）。

**取舍**：服务端**串行**处理连接（accept → handle → close → 再 accept），所以 `bshutil picker`
等用户点选的那段时间里，别的 `bshutil` 调用会在 accept 队列上排队。换来的是没有并发状态 ——
只有 5 个配置标量需要 `std::atomic`（服务端线程写、shell 线程读）。防死等做了三件事：连接两级
超时（收 5s / 发 10s）、写 socket 一律 `MSG_NOSIGNAL`、服务端线程单独屏蔽 SIGPIPE（客户端中途
死掉不能连累整个应用）。

| 子命令 | 作用 |
|---|---|
| `bshutil conf` | 打印当前设置 + 配置文件路径 |
| `bshutil set exit-hint on\|off` | 命令**非 0 退出**时是否打印 `[exit N]` |
| `bshutil set elf-hint on\|off` | 装载 ELF 时是否打印 `[elf]` 行 |
| `bshutil set win-scale <n>` | Wayland 窗口缩放 0.25–4.0（**新开的窗口**生效） |
| `bshutil set right-click menu\|smart` | 终端右键行为：`menu` 弹菜单（内有复制/粘贴），`smart` 有选中就复制、没有就粘贴 |
| `bshutil set node-jitless auto\|on\|off` | node 的 JIT 策略：`auto`（默认）拿不到可执行内存就自动 `--jitless`、`on` 强制、`off` 禁止降级 |
| `bshutil keys show\|hide` | 显示/隐藏底部虚拟按键栏（即时，不持久化） |
| `bshutil newtab [-e <命令>]` | 新开一个**终端窗口**（独立会话，里面跑 mksh）；`-e` 起来后在该会话里跑一条命令 |
| `bshutil picker` | 拉起系统目录选择器，取得该目录的访问权限 |
| `bshutil proclist` / `kill <pid>` | 看 / 结束 procmgr 创建过的进程 |
| `bshutil caps` | 打印启动时探到的宿主能力（fork / exec / jit） |
| `bshutil rawfile list` | 递归列出 hap 里**打包的**全部 rawfile（路径 + 字节数 + 合计） |
| `bshutil rawfile get <名> <目标>` | 把某个 rawfile 拷到磁盘；目标可写相对路径（按**调用方** cwd 解析） |

`rawfile` 这两条只能在服务端实现：rawfile 的入口 `NativeResourceManager` 是 Ability 从
ArkTS 侧初始化进来的**进程级单例**，命令 so 在子进程里够不着。访问口收在
`common/bsh_rawfile.{h,cpp}`（`bsh_rawfile_manager()` / `_list()` / `_copy()`），
`shell.cpp` 的 `UnpackRes` / `CopyRawFile` 与这两个子命令走的是同一份实现。
`rawfile list` 用 `OpenRawDir` 递归 + `IsRawDir` 分辨目录，`GetRawFileName` 返回的是
"相对根"还是"相对本目录"在实现间不一致，所以拼路径时归一了一次，两种语义都能走通。

设置存在 `$HOME/bettersh.conf`，纯 `key=value` 文本（`#` 是注释），可以直接手改；默认值就是原有
行为，所以没写过配置的用户看不出差别。返回码即命令退出码（0 成功 / 1 设备或 UI 不满足 / 2 用法错），
脚本里能判成败（注意 `bshutil` 无参或未知子命令都会落回 Usage 并返回 **0**，与改造前一致）。

**native ↔ ArkTS**：`ui_bus`（`bshutil/ui_bus.{h,cpp}`）是 native 找 ArkTS 的通道。订阅**按会话号
登记**（`bshUiSubscribe(sid, cb)`），两种用法走不同的投递方式：

- **单向通知** `bsh_ui_notify(json)` → **广播给所有窗口**。按 `op` 区分：
  `{"op":"keys","show":true}`（键栏显隐）、`{"op":"scale","value":1.5}`（窗口缩放）、
  `{"op":"rightclick","mode":"smart"}`（右键行为）。这三件都是全局设置，只送给"最后订阅的那个"
  会让先开的窗口与新开的窗口表现不一致。
- **要回执的请求** `bsh_ui_request(sid, json, …)` → **精确送到那个会话所在的窗口**（找不到就失败，
  不兜底 —— 请求类动作必须发生在你敲命令的那个窗口里）。事件里自动补 `"req":<id>`，native 阻塞在
  条件变量上，直到 ArkTS 调 `bshUiResolve(id, text)` 回填。`bshutil picker` 与 `bshutil newtab`
  走这条，所以它们是**同步**的。sid 由 bshutil 客户端从自己的 `BSH_SESSION` 读出来随请求带上。
  订阅成功时 native 只给**这一个**窗口补推 `scale` 与 `rightclick`（别的窗口早就拿到过，再广播一遍
  只是让它们重复应用一次设置）。

**终端的复制/粘贴**（**不需要任何剪贴板权限**）：右键要做的事按模式分两路，`smart` 永远不弹菜单。

- **`menu` 模式（菜单）** —— 菜单由 ArkUI 提供：`@Builder ctxMenu()` 挂在 Web **上面**的一层透明
  覆盖层上（`Stack` 里 Web 之后那个 `Column`，`.hitTestBehavior(HitTestMode.Transparent)` +
  `.bindContextMenu(…, ResponseType.RightClick)`），这一层**只在 `menu` 模式存在**：
  - **复制** —— 菜单项向页面要选中文本（`window.termGetSelection()`，页面在 `term.getSelection()`
    为空时回退到右键按下那一刻的快照），拿到后由 ArkTS 写剪贴板。**写剪贴板不需要权限**。
  - **粘贴** —— 用的是 ArkUI **安全控件 `PasteButton`**：用户点它的那一刻系统才临时授予读剪贴板的
    权限，回调拿到 `PasteButtonOnClickResult.SUCCESS` 之后才 `getData()`。所以不需要
    `ohos.permission.READ_PASTEBOARD`。读到的文本用 `window.termPaste()` 递回页面，
    走 xterm 自己的粘贴路径（`\r\n` 归一 + 前台程序开了 bracketed paste 时自动包 `\x1b[200~…`）。
- **`smart` 模式（无菜单）** —— 有选中就调 `hbridge.ctxCopy` 直接复制；没有选中
  就调 `hbridge.ctxSmartPaste` 让 ArkTS 读剪贴板。失败（release 变体没声明读剪贴板权限时就是
  这种）只 toast 一句"没有读取剪贴板的权限,请使用 menu 模式"（`TerminalPage.ets` 的 `smartPaste`），
  不弹任何菜单。

两个入口对键栏的处理刻意不同：界面上的 ▼ 按钮隐藏后仍留一行 `▲ 键盘` 恢复条；而
`bshutil keys hide` 是彻底隐藏，只能用 `bshutil keys show` 找回。

### 多终端窗口（`bshutil newtab`）

`bshutil newtab` 起一个新的**终端窗口**：`TerminalRunnerAbility`（`launchType: multiton`，与
`AppRunnerAbility` 完全同构）加载**同一个** `pages/TerminalPage`，页面靠**会话号 sid** 区分自己是谁 ——
不再有"一个页面一个终端"的隐含假设。

**sid 从哪来**：0 固定给主窗口的 bsh；>0 由 native 的 `bshTermAllocSession()` 发号。发号放在 native
而不是 ArkTS，是因为这个号同时是 `bsh_tty` 与 procmgr 前台表的下标，只能由持有那两张表的一侧发。
链路：`newtab` → ui 请求 → ArkTS 拿号 → `startAbility` 带 `sessionId` → 新 Ability 登记 pending
（`TerminalWindows`，同 `WaymonyService.setPendingToplevel` 那套：`loadContent` 的 LocalStorage 传参
在页面里读不可靠）→ 页面 `aboutToAppear` 认领 → `onPageEnd` 里 `bshTermStart(sid, cb)`。

**新窗口里跑的是 mksh，不是第二个 bsh**。每个会话要有各自的行编辑器历史 / cwd / 前台进程，那是三份
状态；而 mksh 本来就是个完整 shell，起一个进程比把 bsh 改造成多实例省得多 —— `BasicShell`、`Run()`
里那堆进程级初始化（procmgr/bshutil 服务/Wayland/资源解包/`.bshrc`）一行没动。宿主这一侧只照看
新会话的 pty：`PseudoTtyCreate` 一对 socketpair，`bsh_spawnv_async_fdmap_env("sh", …, slave→0/1/2)`
把 mksh 挂上去，然后 `MasterReader(sid, master)` 读输出送窗口。

**每个会话各有一份**：pty、termios/winsize/前台进程组（`tty/bsh_tty.cpp` 按 sid 分，见那里的
`BSH_SID_MAX`）、输出回调（tsfn）、procmgr 的前台 pid。之所以非分不可：软 pty 是 socketpair，
**没有内核行规程**（`tty/softpty.cpp`），ONLCR/ICRNL/ISIG 全是用户态自己做的，一份只够一个会话用 ——
不分的话在 tab B 里跑 vim 会拿到 tab A 的网格尺寸，按 Ctrl+C 会打到 tab A 的前台进程上。

**身份怎么跨进程传**：环境变量 `BSH_SESSION`（`common/bsh_paths.h`）。procmgr 在 fork 子进程时按
`SpawnRequest.sid` 注入，而 `req.sid` 是从请求的 `ENV` 行里**派生**出来的 —— 协议里不单开一行，
因为 env 本来就是调用方 environ 的原样转发（`bsh_client.c`），两处各写一份迟早会漂。命令 so 的
`tty_shim`（经 `bsh_client.c` 的 `tty_request`）与 guest 里的 `pty_shim`（经
`bsh_procmgr_signal_fg`）都从它读出会话号塞进 `CMD TTY` / `CMD SIGNAL` 请求。
**缺席一律按 0**，所以加这个维度不改变任何既有行为（code-server 那些 guest、宿主自己发的请求都是这种）。

**`-e <命令>`**：新窗口起来后在那条会话里跑一条命令（同 `xterm -e`）。命令由**新窗口的页面**在
`bshTermStart` 之后写进自己会话的 pty（只有它知道自己拿到的是哪个号）。它同时是验证这条链路的唯一
手段：新窗口没法从外面敲键盘，所以让命令落个标记文件、外面检查它 —— 实测 `SID=2` 那一行就是
"环境 → spawn → 按会话的状态"整条链正确的证据。

窗口标题是 `BetterSH — 会话 N`；会话结束（mksh 退出 → master 读到 EOF）时窗口上打一行
`[会话已结束]`，槽位随之释放（最多 8 个会话同时开着，见 `BSH_SID_MAX`）。

**已知边界**（都是这台设备软 pty 的老限制，不是新引入的）：

- tab 里**没有 job control**：软 pty 没有真控制终端，mksh 会打那句
  `no controlling tty … won't have full job control`，`^Z` 无效。
- tab 跑 mksh，**不读 `.bshrc`**：它继承的是**进程环境**（PATH/HOME/`BSH_*` 这些由 bsh 的 `.bshrc`
  经 `setenv` 落进应用进程的），不是 bsh 的内建命令、别名与补全。
- `bshShellNotice`（往终端回一行 `[notice]`）只对主会话有效：tab 的 slave 在 spawn 之后就关掉了
  （留着它 master 就永远读不到 EOF，读线程收不了尾），而现在这条路的唯一使用者是 picker 的
  非请求分支，newtab 之后 picker 一律走请求分支。

**picker 的能力边界**：拿到权限后未做持久化，关闭重启后访问权限不一定继承。

### SSH（dropbear）

`libsshcore.so` 是 dropbear 的 `dropbearmulti` 编成的命令 so，**单一入口按 `argv[0]` 分发**：
`ssh`/`dbclient` 是客户端，`dropbear` 是服务端，另含 `scp`/`ssh-keygen`(`dropbearkey`)/
`dropbearconvert`。能这么接是因为 `dropbearmulti` 本来就是多调用形态（`src/dbmulti.c` 认
`ssh`/`ssh-keygen` 这些别名），我们只把它的 `main` 改名成 `bsh_dropbear_main`。

沙箱适配三处：

- **补 libc 缺口**（`feature/bsh_main/src/main/cpp/ssh/sandbox_compat.c`）：ohos libc 没有 `getpass()`，
  而 dropbear 是**无条件**调用它 —— 自建一个（软 pty 无内核行规程，所以按字节收行、自己处理
  退格、`\r` 与 `\n` 都当行尾）。同一文件还把 `stderr` 设为**行缓冲**并装了崩溃处理器：
  命令 so 的输出常被重定向到文件，全缓冲会把崩溃现场整段吞掉。
- **passwd 与身份**（`feature/bsh_main/src/main/cpp/ssh/pwshim.c`）：`/etc/passwd` 里没有当前 uid 的条目，
  服务端 `fill_passwd()` 拿不到 `pw_name` 就一律拒登。这里用**符号遮蔽**（配合
  `-Bsymbolic-functions`）给 dropbear 一个合成条目：`pw_uid/pw_gid` 即进程自身、
  `pw_dir=$HOME`、`pw_shell=sh`（裸名字才能落到命令表 → `libmksh.so`）。同时遮蔽
  `seteuid`/`setegid` —— `checkpubkey()` 读 `authorized_keys` 前会临时切换身份，而沙箱对这类
  调用**不给返回值的机会**（进程被不可捕获地强杀），短路掉即可。
- **服务端会话 pty**（`scripts/dropbear-ohos.patch`）：沙箱没有真 pty（`/dev/ptmx`、
  `openpty()` 都是 EACCES），`sessionpty()` 改用 socketpair，与会话 shell 的 stdio 约定同
  `tty/softpty.cpp`。patch 还把 `pass_on_env` 的默认值改成 1：dropbear 默认给会话清空环境，
  而本沙箱里"执行另一个程序"要走 exec 委托、靠 `BSH_CTRL_SOCK` 找 procmgr。

冒烟方式（不再随包分发脚本）：会话里手动备好 `~/.ssh/{hostkey,id_dropbear,authorized_keys}` 后，
`dropbear -F -p 2222 -r ~/.ssh/hostkey -s &` 起服务端（`-s` 禁密码），再用
`ssh -y -p 2222 user@127.0.0.1` 连自己；日志自己在命令里重定向到 `$HOME` 下。

## 如何新增一个命令 so

1. **加源码**：新增 submodule（或 vendored 源目录），确认许可证与目标 ABI。
2. **决定工具链**：能用 OHOS SDK clang 的（toybox / fastfetch / vim 优先路径）就复用；需要完整
   libc 交叉环境的用 `MUSL_TOOLCHAIN`。
3. **编成 `.so` 而不是可执行**：把 `main` 改名/包一层（toybox 用 `-Dmain=bsh_toybox_main`；需要
   保留原入口的可以用 `objcopy --redefine-sym main=xxx_main` + 自写包装 `main`）；全部对象 +
   `-shared -Wl,-soname,<name>.so` 聚合。若程序会 exec 别的程序，`source scripts/shim-wrap-flags.sh`
   拿 `$SHIM_WRAP_FLAGS`（exec 家族 + `exit`），并链入 `procmgr/bsh_client.o`（向 procmgr 下单）；
   若交互式/需要 tty，再把 shim 清单对应的 `.o` 一起链进去并加 `-Wl,-Bsymbolic-functions`
   （让 so 内部对 libc tty 函数的调用绑定到 shim）。**不需要 `libentry.so`** —— tty 状态与 exec
   委托都走 control socket。产物拷到 `feature/bsh_main/libs/arm64-v8a/`。
   ⚠ 清单里每个 `--wrap=<名>` 都必须有对应的 `__wrap_<名>` 定义在本 so 的链接里，否则不是"静默
   失效"而是 **dlopen 直接失败**（判据：`nm -D -u <so> | grep -E '__wrap_|__real_'` 必须为空，
   `build_hap.sh` 打包前会统一查这条）。
4. **注册命令集**：在 `procmgr/command_map.c` 的 `kMap` 增加 `{ "cmd", "libX.so", "main" }` 条目；
   procmgr 启动时会按表生成 `<资源根>/bin/cmd` 这个 `#BSHSO` 启动器（要 envp 就手写第 4 行 `3`）。
5. **若需随包资源**：打成 `rawfile/tools/*.tar`，在 `initResource()` 里新增一条
   `UnpackRes("tools/x.tar", <落点>)`（幂等由整段的 `<资源根>/.res-unpacked` 总标记负责），
   并在构建脚本中生成该 tar。
6. **验证**：看 hilog 中 `dlopen` 是否成功、`NEEDED` 是否只有 `libc.so`、导出符号是否存在。

最小示例见 `feature/bsh_main/src/main/cpp/programs/hellobsh/hellobsh.cpp`（CMake 直接产出 `libhellobsh.so`，
命令表注册为 `hellobsh`）。

## 已知限制

- **仅 arm64-v8a**：`product/<product>/build-profile.json5` 只配置 `arm64-v8a`；`env.sh` 与 CMake 虽有 x86_64
  分支，但多数 `build_*.sh` 的输出路径/工具链硬编码 arm64 —— x86_64 未验证。
- **无真 exec**：所有「执行其它程序」都经 procmgr（fork + dlopen/elfloader）模拟；依赖真 `exec`
  语义或 `vfork` 严格约束的程序可能异常。elfloader 只跑 aarch64；动态链接 guest 的解释器与
  运行时只从 bundle libs 按 basename 找（见上）。
- **「可写可执行内存」分三种情况**（见「jit 的三种情况」一节）：有 kernel 权限时一切都好；
  只有 prctl 门时 elfloader 能用、**box64 不行**（无兜底）、node 仍真 JIT；两道门都没有时
  elfloader/box64 全部改走 qemu-user 兜底，node 自动 `--jitless`，
  **java 两种情况都不可用（TODO，见 `scripts/jdk-ohos/README.md`）**。
- **C++ 编译不支持**：sysroot 打包刻意排除了 C++ 头与 libstdc++。
- **Wayland 覆盖有限**：仅 SHM、无 EGL/DMABUF 客户端；popup、subcompositor、viewporter 为占位；
  touch 只注册对象、不注入事件；不实现自定义光标；滚轮虽导出 `sendMouseAxis`，但 ArkTS 侧未调用
  （未接线）。
- **宿主主导的窗口尺寸回发未生效**：`WaymonyService.notifyConfigure()` 实现被注释为 TODO，
  `notifyToplevelResize` 在 ArkTS 侧没有任何调用点；因此 maximize/unmaximize/宿主拖拽回发的 xdg
  configure 实际不会发出（客户端自身尺寸变化会正常同步窗口）。
- **窗口缩放默认 200%**：`UI_SCALE` 默认 2，可用 `bshutil set win-scale <n>` 改
  （只对**新开**的窗口生效）。
- 命令表里的 `guiduo` 无对应 so；时间戳字段使用 `time()` 毫秒近似，非单调时钟。
- CPython 未编入 `_ssl`/`_hashlib`/`_sqlite3`/`_bz2`/`_lzma`/`_gdbm`/`_uuid`（缺对应库），
  `locale.gettext` 一族也关掉了（OHOS 的 `libintl.h` 是空壳）；`site-packages` 里只有随包的
  stdlib，当前不随包。
- **SSH 没有 sftp**：dropbear 路线固有 —— 既不提供 sftp 客户端，也不带 sftp 服务端
  （它默认指向外部的 OpenSSH `sftp-server`，本沙箱没有）。`scp` 可用。
- **私钥格式不通用**：`dbclient -i` 只认 dropbear 自有格式；OpenSSH 格式要先
  `dropbearconvert openssh dropbear <in> <out>`（加密的 OpenSSH 私钥不支持转换）。
  `scp` 调起的客户端已指向 `ssh`（走命令表），不再依赖 `/usr/bin/dbclient`。
- **服务端只开公钥认证**：`--disable-shadow` 之后没有可校验口令的数据源，
  所以 `dropbear` 要以 `-s` 起（禁密码）。客户端侧的密码认证是好的（`getpass` 已补）。
- **会话 pty 是 socketpair 模拟**：没有控制终端与内核行规程，`/dev/tty` 不可用，
  依赖真 tty 的程序与 `sh` 的 job control 相关提示属预期行为。
- **行编辑器刻意不做的事**（`shell/`）：没有 `!!`/`!n`/`^old^new` 历史展开，没有 glob，
  没有 `$(…)`/反引号命令替换，没有 `~` 展开；历史只在会话内存里，重开应用即清空。
  `Tab` 补全只查内建命令 + `<资源根>/bin`（命令位）与当前目录（其它位置）：不查 `PATH`、
  不递归、不引号感知，候选上限 200，隐藏文件要自己先打出 `.` 才补。
- **bshutil 服务是串行的**：`bshutil picker` 等用户点选期间，其它 `bshutil` 调用会在 accept 队列上
  排队（连接级超时 收 5s / 发 10s，不会永远挂住）。服务端 sock 路径来自
  `common/bsh_paths.h` 的 `BSH_UTIL_SOCK`（`bsh_util_proto.h` 只是给它起个别名），多实例/可配置
  会话暂时不支持。
- **会话里执行程序依赖 `BSH_CTRL_SOCK`**：本仓库构建已把 dropbear 的 `pass_on_env` 默认置 1
  （等价于永远带 `-e`），自编服务端时需自行加上。
- **服务端监听 `0.0.0.0`**：端口对整个局域网可达，除公钥校验外没有额外访问控制。

## 常见问题

- **起服务端报 `Address in use`，或客户端连上后 host key 指纹与预期不符**：上一次的 dropbear
  还在跑（占着端口，客户端连到的是**旧进程**，现象与当前代码无关）。用 `bshutil proclist`
  找 pid、`bshutil kill <pid>` 结束，或直接换端口。
- **会话刚建立就报 `cannot exec: BSH_CTRL_SOCK 未设置` 并以 127 退出**：服务端把会话环境
  清空了（见「已知限制」）。用本仓库的 `build_dropbear.sh` 产物，或给服务端加 `-e`。
- **`ssh` 问 `(y/n)` 时输了没反应**：软 pty 没有内核行规程、宿主也不替程序回显，
  敲 `y` 后要**再按一次回车**；用 `ssh -y` 可跳过主机密钥确认。
- **native 报缺 `wayland/...` 头或协议 .c**：先跑 `scripts/build_wayland.sh`（生成物且被 gitignore）。
- **命令 so `dlopen` 报 `__wrap_xxx: symbol not found` / `__real_xxx: symbol not found`**：
  `--wrap=<名>` 要求 `__wrap_<名>` 定义在该 so 的链接里；清单是 `scripts/shim-wrap-flags.sh` 那一份，
  判据是 `nm -D -u <so> | grep -E '__wrap_|__real_'` 必须为空（`build_hap.sh` 打包前会统一查）。
- **`build_vim.sh` 报缺 `/usr/bin/tic`**：安装宿主 ncurses；**`build_llvm.sh` 报缺
  `aarch64-linux-musl-gcc`**：设置 `MUSL_TOOLCHAIN`。
- **autotools/子模块配置异常**：留意 `env.sh.example` 中关于鸿蒙自带 `diff` 的注释（未自动化规避）。
- **签名失败**：`build-profile.json5` 需含 `signingConfigs`；`sign_hap.sh` 依赖 `java` 与
  `scripts/sign_hap.py`（按 `win_to_wsl` 转换 Windows 路径并解密 DevEco 密码）。
- **签名要多久 / 能不能用 qemu 解释执行 java 来签**：签名本身是
  `java -jar hap-sign-tool.jar sign-app …`（`scripts/sign_hap.py` 拼的命令）。**当时那份约 625MB**
  的 HAP（现包已缩到 ~390MB：unsigned 387MB / signed 390MB），宿主 native 实测
  **real 3.60s（页缓存热）/ 5.42s（冷）**，`verify-app` 通过。
  换成 `qemu-x86_64` 解释执行同一套 java/jar **跑不完**：客户机 JIT 开着会在 ~22s 时
  `qemu: uncaught target signal 6 (Aborted)`（退出码 250，产物缺 signing block、校验不过）；
  加 `-Xint` 能走到 `Sign successfully`（约 4m40s），但随后写产物那一步 25min 仍未落盘。
  可比的开销倍率只能从 JVM 启动看：`java -version` native ~0.10s / `qemu-x86_64` ~0.77s（**≈7.5×**）/
  `qemu-x86_64 + -Xint` ~0.39s。→ 签名请在宿主 native 跑。
- **在 qemu 下编 C++ 库比在开发机上（交叉）编慢多少**：2026-10-02 实测过一次（16 核 WSL2。
  两边都是 OHOS LLVM **15.0.4**、同一份源码与参数、同一个目标 `aarch64-linux-ohos`，只差
  "谁在执行编译器"：宿主 SDK clang++ 交叉编 vs 自编的 aarch64 clang++ 在 `qemu-aarch64` 下跑；
  两份 clang 的提交号略有差异，量级差异由模拟主导）。测完的临时脚本没有入库，数据留在这儿：

  | 库 | 宿主交叉编译 | qemu-aarch64 下 | 倍率 |
  |---|---|---|---|
  | tinyxml2（1 个小 TU） | 0.59s | 9.29s | 15.7× |
  | jsoncpp（3 个大 TU） | 4.30s | 62.85s | 14.6× |
  | fmt（2 个模板重的 TU） | 2.92s | 48.00s | 16.5× |
  | Catch2（2 万行单 TU） | 10.47s | 125.53s | 12.0× |
  | **合计** | **18.3s** | **245.7s** | **13.5×（差 ≈3min47s）** |

  即"没有 JIT、只能靠 qemu 兜底"时，编一个中等规模的 C++ 库从十几秒变成几分钟。
  ⚠ **别用 qemu-i386 去测这套**：那个交叉工具链是 i386 宿主二进制，宿主内核本来就能原生跑
  i386，而 qemu-user 会把 guest 的 `execve` 转给宿主内核 —— 于是真正干活的 `cc1plus`
  压根没进模拟器（14s 的 Catch2 单 TU 只"慢" 1%，`/proc/<pid>/exe` 一看就露馅）。
  要测模拟代价就得选宿主跑不了的架构（这里是 aarch64）。
- **`hdc` 连不上设备**：`deploy_hap.sh` 支持 `<ip:port>`（先 `tconn`）或 `<serial>`；无参会从
  `hdc list targets` 取第一个；设备端需授权调试。
- **`wldemo` 无窗口**：确认 `module.json5` 中已声明并 `exported` 的 `AppRunnerAbility`，以及
  socket 文件存在；日志 TAG 为 `BSH_WaylandServer`/`BSH_CW`/`BSH_ARA`。
- **命令报 `dlopen libX.so failed`**：该 so 未打进 `/data/storage/el1/bundle/libs/arm64/`，检查对应
  `build_*.sh` 是否已产出并重新 `build_hap.sh`。
- **生成物为何不在 git 里**：`feature/bsh_main/libs`、`dist`、`rawfile/tools/*.tar`、
  `cpp/wayland/{include,protocol}`、`build-profile.json5`、`scripts/env.sh` 均被 `.gitignore` 排除。

## 许可与致谢

仓库根目录**没有** `LICENSE` 文件，`feature/bsh_main/oh-package.json5` 的 `license` 字段为空；各第三方子模块
遵循其自身许可证，使用/分发前请核对：[toybox](https://github.com/landley/toybox)（0BSD 风格）、
[LLVM/clang/lld](https://github.com/llvm/llvm-project)（Apache-2.0 with LLVM Exceptions）、
[vim](https://www.vim.org/)（Vim License）、[mksh](https://github.com/MirBSD/mksh)（MirOS License）、
[ncurses](https://invisible-island.net/ncurses/)、[zlib](https://zlib.net/)、fastfetch 的 HarmonyOS
fork（上游为 MIT）、[wayland / wayland-protocols](https://wayland.freedesktop.org/)、
[libffi](https://github.com/libffi/libffi)；elfloader 参考 Termony `build-hnp/elf-loader` 与
`github.com/MikhailProg/elf`，xterm.js 及字体资源见 `rawfile/term/`（`fonts/LICENSE.txt`）。
准确版本以 `.gitmodules` 与 `git submodule status` 为准。
