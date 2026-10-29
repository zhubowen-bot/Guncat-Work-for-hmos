# 更新记录

版本号从 **0.3.0**（2026-09-10）开始标注；在此之前的三天是初始开发，一并记在 0.3.0 那段里。

每条尽量写清"为什么"，踩过的坑也留在里面 —— 这个项目大半时间花在跟沙箱、ABI 和
"谁在什么进程里"打交道，结论比改动本身更值得留。

---

## 0.9.0 · 2026-10-11

从 0.8.0 到这里跨了 10-09 ~ 10-11，**9 个提交**。三条主线：

一是**页面重构** —— 那个 545 行、什么都管的 `TerminalPage` 拆成 `Index`（页面壳：PC 顶部
按钮栏、设置/指南弹窗、Ability 相关的 context）+ `WebTerminal`（终端本体：WebView/xterm、
虚拟键栏、会话收发、右键菜单）+ 两个工具模块（`TerminalVirtualKeys`、`ImmersiveButton`）。
多终端窗口的会话号管理从页面收敛进 `TerminalWindows`。

二是**设置与使用指南**（参照 HiSH 精简）—— 设置弹窗只留"显示"与"终端"两块，终端外观项实时
套到 xterm.js；使用指南只留"基本功能 → Linux Shell"一项加一行提示，详细文档不塞进应用、
交给终端里的 `readme.py`。

三是**剪贴板与 bshutil 事件接入** —— 新增 `UIBus` 消费 native 的 `ui_bus` 事件，新增
`PasteBoardService` 负责右键菜单的复制/粘贴，顺手把右键菜单修回来。

### 页面重构：TerminalPage → Index + WebTerminal

- **为什么拆**：旧 `TerminalPage` 把"页面外壳"（PC 顶部按钮栏、设置弹窗、Ability context）
  和"终端本体"（WebView、虚拟键栏、会话收发）揉在同一个 struct 里 —— 手机/平板的布局复用
  不了，设置/指南这些页面级的东西也没地方放。
- **HAR 出组件、product 出 `@Entry` 薄壳**：`Index`/`ClientWindow`/`WebTerminal` 放在 HAR
  里不带 `@Entry`，路由入口由 `product/<名>/pages/*.ets` 各包一层（`loadContent('pages/X')`
  只在 entry 模块里解析路由）。设置页 / 指南页 / 指南正文页同样是 product 侧薄壳，路由在
  `product/<名>/resources/base/profile/main_pages.json` 注册。
- **会话号收敛到 `TerminalWindows`**：`WebTerminal.onPageEnd` 里 `allocateSessionId()` 认领、
  `aboutToDisappear` 里 `releaseSessionId()` 归还。踩过一次坑：认领是**单例上的破坏性 take**，
  `Index` 与 `WebTerminal` 若都认领会互相抢号（后者静默落到主会话 0），所以认领权唯一化到
  `WebTerminal`；`releaseSessionId` 刻意不碰 `pendingSid` —— 销毁期间新窗口可能刚登记进来，
  清掉会把它的号偷走。

### 设置与使用指南（参照 HiSH，精简）

- **显示**：保持屏幕常亮（经 `AppStorage('mainWindow')` 调 `setWindowKeepScreenOn`）。
- **终端四项**：字号 / 字体 / 光标样式 / 光标闪烁。写进 `AppStorage`，`WebTerminal` 用
  `@StorageProp` 监听并应用；前端 `term.js` 补了 `setTermFontFamily`/`setTermCursorStyle`。
- **使用指南**只放"基本功能 → Linux Shell"一项，底部一行 `更多内容参照：python readme.py`；
  正文 HTML（`rawfile/guide/01_Linux_Shell.html`）按"复制 HiSH 再删减"来，不搬它的截图。

### 剪贴板与 bshutil 事件

- **UIBus**：native `ui_bus` 推来的 JSON（`keys`/`scale`/`rightclick`/`picker`/`newtab`）集中
  在这里处理；页面只 `register(host)`/`unregister(sid)`，"只有页面能做"的动作（键栏显隐、
  右键模式、往 WebView 注 JS）经 `UiHost` 回调回去。`hosts` 按 sid 存 —— keys/scale/rightclick
  是 native **广播**给所有窗口的，每个窗口各收一份、各处理。
- **键栏恢复三态**：显示 / 隐藏但留恢复条（界面 ▼）/ 彻底隐藏（`bshutil keys hide`）。
- **剪贴板修复**：右键菜单宿主（`Stack` 里一层透明覆盖层）按 `rightClickMode` 只在 `menu`
  模式挂 `bindContextMenu`；`复制` 走 `setDataSync`（写剪贴板免权限），`粘贴` 必须点
  `PasteButton` 让系统临时授权 —— 始终不申请 `READ_PASTEBOARD`。
- **明确不做**：带命令的 newtab（`bshutil newtab -e`）、smart 模式的右键复制（有选区直接复制 /
  无选区直接粘贴）暂时不接入。

### 签名脚本收回仓库

- `sign_hap.sh` / `build_release.sh` 的签名材料默认改读**仓库根的 `build-profile.json5`**
  （`SIGN_PROFILE_FILE` 可换），用哪一项由 `SIGN_CFG_NAME` 选（`sign_hap.sh` 缺省 `debug`，
  发布走 `release`）。`build_test.sh` 固定要的 `debug-jit` 只在 `env.sh` 指的那份里，显式
  `SIGN_PROFILE_FILE="$BUILD_PROFILE_FILE"` 指过去。

### 其它

- 更新应用图标（`startIcon.png`）。
- 新增 `AGENTS.md`（给 AI 编码代理的开发指引）。
- 版本号 0.8.0 → 0.9.0（versionCode 1000006）；启动横幅顺带加一行"测试版本、注意备份数据"
  的提醒。

---

## 0.8.0 · 2026-10-09

从 0.7.0 到这里跨了 10-05 ~ 10-09，**29 个提交**。两条主线：

一是**把"终端"从"一个窗口"做成"一台能开多个窗口的终端"** —— 软 pty 补上 `forkpty` /
`openpty` / `posix_openpt` 三个入口与基础行规程，tty 状态与前台 pid 加上**会话号**这个
维度，于是 `bshutil newtab` 能开出各自独立（历史、cwd、前台进程各一份）的 mksh 会话，
code-server 的集成终端也才第一次真的能用。

二是**把"装东西"从自家 pkg 扩到发行版原生 `.deb`** —— 新增 `apt` 命令：解析 Depends
依赖树、从 Ubuntu 镜像下包、装进 sysroot、把沙箱不给的软链代偿掉。有了它，**官方发行的
二进制**（VS Code、code-server、git、ZCode）都能直接装进来跑：VS Code 出窗口、
code-server 起 HTTP 服务、`git clone https://…` 通、ZCode 出窗口。

中间为了回答"我们的合成器到底能不能承载一个真实 GUI 工具链"，把 **GTK3（只编 wayland
后端）** 交叉编译出来当探针 —— GTK3 起不来，Electron 一定起不来；顺手补掉了合成器缺的
`wl_data_device_manager`（缺它 GTK 窗口**收不到键鼠**，与剪贴板无关）。HAP 又削了一轮：
把它自己的 code-server（解包 640MB 出头）从包里挪进 pkg，**458MB → 233MB**。

### 假 pty：三个入口、行规程拆两侧

起因是 code-server 起不来：node-pty 走 `forkpty(3)`，报
`A native exception occurred during launch (forkpty(3) failed.)`。

- **三个入口都是同一个坑**。我们原有的假 pts 只有一个入口（应用自己
  `open("/dev/ptmx")`，被 `open_shim` 拦住转 `bsh_pty_maybe_open`），而 glibc 里
  `forkpty` / `openpty` / `posix_openpt` 最终都落在 `__open("/dev/ptmx")` 上 —— 那是
  **glibc 内部的 hidden alias，不走 PLT**，LD_PRELOAD 和 `-Wl,--wrap=` 都拦不到，直接
  落到内核吃 EACCES。所以补法不是去拦那次内部 open，而是**接管这三个外部入口**。
  `forkpty` 的子进程里两条环境变量是必需的：`BSH_FAKE_PTY_FDS=0,1,2`（告诉 pty_shim
  这一路 0/1/2 就是 pts 的 slave）与 `BSH_FAKE_PTY_ID=<pts_n>`（exec 委托是另起进程，
  内存里的登记表带不过去，只能走环境）。
- **行规程拆两侧，各做各能做的那一半**。master 侧（`pty_shim.c`）管 ONLCR / ISIG /
  ICRNL；slave 侧（`tty_shim.c`）只把 termios 记到 `<sysroot>/.ptyterm-<id>`。理由是
  "这一路 pty 的 termios"只在**本进程内**一致，而 ONLCR/ISIG 需要的信息只有 master
  进程有。另外 stdio 的 `fgets`/`scanf`、python 的 `input()` 走的是 **libc 内部 read**，
  在 slave 侧包 `read` 根本碰不到（走到这一步才发现路不通），所以
  read/write/readv/writev 四个入口留在 pty_shim，tty_shim 不再定义它们。
- **ICANON/ECHO 按需生效，ISIG/ICRNL/ONLCR 常开**。ICANON/ECHO 要等程序自己配置过
  pty（`.ptyterm-<id>` 存在）才接管 —— mksh **既不调 `tcgetattr` 也不调
  `ioctl(TCSETS)`**，它自带行编辑器会回显，我们一回显就成双份。而 ISIG 必须一直开
  （真 pty 默认就开），一度把它挂到那个 termios 文件上，结果 Ctrl+C 彻底失效。
- `ioctl(TCGETS/TCSETS*)` 也要接（很多程序不走 `tcgetattr`），接了之后假 pty 的
  termios 不再借道**会话**那份，顺带修掉"mksh 一进行编辑器就把用户自己的终端设成 raw"。
- **Ctrl+C 得让 procmgr 代发**。真正干活的进程是 procmgr fork 出来的，**不在**请求方的
  进程组里 —— 调用方那条路上能拿到的只有"委托中间体"（阻塞在 control socket 上的那个），
  发进程组只能杀掉中间体。所以新增 `CMD SIGNAL` + `SIG <n>` + `bsh_procmgr_signal_fg`。
  同一批还修了**前台 pid 被并发 spawn 擦掉**的既存缺陷（`NotifyForeground(-1)` 改成
  `NotifyForegroundDone(pid)`，只在 `g_fg_pid == pid` 时才清）：现象是"Ctrl+C 按了没
  反应"，日志里是 `fg-signal sig=2 pid=0（没有前台进程）`。
- `build_shim.sh` 加两道闸：符号自检清单补上 read/write/readv/writev/posix_openpt/
  openpty/forkpty；新增"**不该有未定义的自家人符号**"（`grep ' UND '` → 筛 `^bsh_`）。
  后者当场抓到 tty_shim 里误用 pty_shim 的 `static bsh_null` → libmksh.so dlopen 失败、
  终端里连 `sh` 都起不来。（末尾那个 `|| true` 不能省：本仓库开着 `pipefail`，最后一个
  grep 没匹配会让整条管道失败、`set -e` 静默退出。）

**明确不做**（已写进代码注释）：作业控制（^Z/SIGTSTP —— 本架构下 pgrp 落不到"作业"
上）、空行的 ^D（EOF 得读端看到才能回显，跨进程传不过去）、OPOST 等输出标志。

设备实测：`printf 'A\nB\n'` 的 `\r\n` 3 次、裸 `\n` 0 次；`python input()` 拿到整行；
^C 后 python 被杀、提示符回来；`code-server` 起在 `0.0.0.0:8099`（`/healthz` 200）。

### 多终端窗口（`bshutil newtab`）

一条完整的主线，五个提交：**sid 维度 → 宿主会话表 → bshutil → ArkTS 窗口 → 文档**。

- **为什么非分不可**：软 pty 是 socketpair，**没有内核行规程**，ONLCR/ICRNL/ISIG/
  termios/winsize 全在用户态自己做，而这份状态一份只够一个会话用。不分的话：在 tab B
  里跑 vim 会拿到 tab A 的网格尺寸；两个窗口各跑一个 sleep 时后者覆盖前者，**在 A 窗口
  按 Ctrl+C 会打到 B 的进程上**。这一条在加 newtab 之前就存在（code-server 的多个集成
  终端也共享这一份），只是没人踩到。
- **sid 从环境变量派生，且从 `ENV` 行派生**。命令 so 与 guest 都是 procmgr fork 出来的
  （不是调用方的孩子），只继承 procmgr 的 environ，内存里的东西带不过去。procmgr 侧
  **不单开协议字段**：`SpawnRequest.sid` 直接从请求的 `ENV` 行里取，子进程看到的会话号
  与 procmgr 记账用的就是同一个来源，分两处写迟早会漂。宿主自己发的请求没有这个变量 →
  落回 0 —— **缺席一律按 0，所以这个维度不改变任何既有行为**。
- **sid 0 是 bsh，sid >0 是一个独立的 mksh 进程**。为什么新 tab 不复用 bsh：每个会话要
  有各自的行编辑器历史/cwd/前台进程。而 mksh 本来就是完整 shell，起一个进程比把 bsh
  改造成多实例省得多 —— `BasicShell::Run()` 里那堆进程级初始化（procmgr / bshutil 服务 /
  Wayland / 资源解包 / `.bshrc` / banner）**一行没动**。顺带白拿一条：bsh 的 `.bshrc`
  已经把 PATH/HOME/`BSH_*` `setenv` 进了**应用进程**的 environ，fork 出去的 mksh 直接
  继承 —— "bsh 只有一个"在这件事上是有用的（它是环境建立者）。
- **宿主会话表**（`shell.cpp`）：`TermSession{used, started, master, pid, tsfn}` +
  `g_sess[8]`。`AllocSession()` 只**占号**不起东西 —— ArkTS 必须先拿到号才能经
  `want.parameters` 传给新 Ability，而真正的 shell 要等页面 `onPageEnd` 才起。
  三处必须点：环境要**整套**带过去；`BSH_SESSION=<sid>` 追加在最后（盖掉同名旧值）；
  `bsh_tty_init_shared(sid)` 必须在 **spawn 之前**（那是块 MAP_SHARED 内存，靠 procmgr
  的 fork 继承）。
- **`ui_bus` 按会话号登记，投递分两种且刻意不同**：**通知广播**（keys / win-scale /
  right-click 是全局设置）发给所有窗口 —— 只发给"最后订阅的那个"会让先开的窗口与新开的
  表现不一致；**请求精确路由**（picker / newtab）必须发生在**发起命令的那个窗口**，
  找不到就失败、不兜底 —— 弹在别人窗口上会让人莫名其妙。
- **ArkTS 侧用 multiton Ability 而不是应用内 Tab**：窗口级操作（拖动、最大化）是现成的，
  应用内 Tab 要在同一页面塞多份 ArkWeb/xterm。页面靠会话号区分自己是谁；待认领的哨兵用
  `-1` 而不是 `0` —— 0 是主窗口的**合法**会话号，用 0 当哨兵会让新窗口静默变成"第二个
  bsh"。`newWindow` 返回 Promise：`startAbility` 是异步的，直接返回号的话失败也会报
  "已开"。
- **`newtab -e <命令>`** 除了实用（同 `xterm -e`），更是**唯一能自动验证"新会话真的通
  了"的手段**：新窗口没法从外面敲键盘，所以让命令落个标记文件、外面检查它。实测新会话
  写出的 `SID=2` 就是"环境 → spawn → 按会话的状态"整条链正确的证据。超时给 5s 而不是
  picker 那样的 300s —— `startAbility` 本身是毫秒级的，给长了只会让 shell 白等，而
  bshutil 服务端是**串行**的，等太久会把后面的请求一起堵住。
- **新 Ability 的声明只能加在以 `.example` 结尾的那两份 `module.json5`**
  （真身是 gitignore 的），否则新 clone 出来的工程缺这个 Ability。

**两个只有回到设备才暴露的坑**（都在这批里修掉）：

1. `SID` 插到了 `CMD TTY` **前面** → 服务端按 `SplitKV(lines[0])` 分派，`CMD TTY` 被
   挤掉，**所有** termios/winsize/pgrp 查询失败，而失败路径不设 errno（`-1` 带着上一次
   connect 留下的 ENOENT）。实测就是那行 `sh: j_init: tcgetpgrp failed: No such file or
   directory`。修法是插到第一行**之后**（线协议注释里补了"第一行必须是 `CMD <动词>`"）。
2. **`tcgetpgrp` 照实回远端值会让 mksh 把自己的整个进程组停住**。mksh 的 `j_change()`
   里是死循环：`while (1) { if (tcgetpgrp(tty_fd) == 本进程组) break; kill(0, SIGTTIN); }`
   —— 而我们的 `tcsetpgrp` 是假成功的，于是**同一会话里第二个**交互 shell 一问就"发现
   自己不是前台" → `kill(0, SIGTTIN)` → 连应用进程组一起停住 → 终端假死。改成
   `tcgetpgrp`/`TIOCGPGRP` 一律回答"问的人就是前台"（写那侧照旧远写，宿主转发信号还要
   用）。这不是缩水，是假 tty 唯一自洽的语义：软 tty 没有按终端停/续进程组的机制，
   "你不是前台"这句话我们兑现不了，所以不说它。

顺带记一条**回归测不到**的教训：autorun 自己的 stdio 不是 tty（stdin=/dev/null、
stdout 是日志文件），所以命令 so 里 `isatty` 恒 0，**远端 tty 查询那条路一次都不会被
走到**。后来改成从 **tab 里**测（tab 的 fd 0 就是会话 pty）。

**已知边界**：tab 里没有 job control、不读 `.bshrc`、`bshShellNotice` 只对主会话有效、
最多 8 个会话。

### 合成器：补 `wl_data_device_manager`，窗口才收得到键鼠

**为什么必须补 —— 不是为了剪贴板**。GDK 对 `wl_seat` 是**延迟处理**的：

    else if (strcmp (interface, "wl_seat") == 0) {
      static const char *required_device_manager_globals[] = {
        "wl_compositor", "wl_data_device_manager", NULL };
      closure->base.required_globals = required_device_manager_globals;

也就是说 **registry 里没有这个全局，GDK 就永不建 `GdkSeat`**。补它之前的症状是 GTK3
窗口能建、能渲染、主循环也在跑，但完全不能交互，日志里
`Gdk-CRITICAL: gdk_seat_get_keyboard: assertion 'GDK_IS_SEAT (seat)' failed`，而
WAYLAND_DEBUG 的 trace 里 `global(7,"wl_seat",8)` 收到了却**从来没有对应的 bind**。
Qt 没有这个前置条件，所以 qtwl-demo 一直有输入 —— 这个缺口是拿 GTK3 当探针才暴露的。

实现按 weston 的语义，只做选区这一半：`set_selection` 给**除供方自己以外**的每个 device
发 `data_offer` → 逐个 `offer(mime)` → `selection`，旧供方收到 `cancelled`；`receive`
把 fd **原样**转给供方的 `wl_data_source.send`（协议定的就是收方建管道、把可写端交上来）；
**后连上来的客户端也能拿到当前选区**（否则"先复制、后开窗"的程序粘不上）；三种对象的
生命周期都收尾（供方销毁 → 收方 `selection(nil)` 且那批 offer 变无害 no-op）。**拖放不
做**：`start_drag` 回一个 `cancelled`（协议里"这次拖拽被拒"就是这么表达的）—— V1 合成器
没有"跨窗口拖动手势"这个输入源，与其半做不如明确不做。

两个踩点：**每个 request 都必须有处理函数，哪怕是空的** —— libwayland 分派时**直接调用**
接口表里的函数指针，留 NULL 就是一进这个 request 就崩（另外
`wl_data_offer.accept` 的参数顺序是 `(serial, mime_type)`，与 `receive` 的
`(mime_type, fd)` 不一样）；**服务端发起建对象时 `wl_resource_create(..., id=0)`** 让
libwayland 自己分配，传别的号会撞客户端自己的 id 空间。

同一批还做了可观测性（都是被"hilog 对 60fps 的高频日志会丢样本"逼出来的）：

- **渲染统计落文件**（`$SYSROOT/render-stats.txt`），连 EGL surface 的真实尺寸
  （`eglQuerySurface`）一起 —— 之前拿"hilog 里没有 X"当"没发生"，白追了好几轮；
  resizeRenderer 只改 `glViewport` 用的 width_/height_、没重建 surface，尺寸错配要靠
  这个才看得出来。
- **只在拿到新帧时才重绘 + swap**：原来无条件 60fps（每帧上传 3.84MB 纹理 + 全屏 draw
  + swap），旧窗口的循环会一直烧 EGL/CPU，新窗口再来一个就供不上帧。
- 新增 `crash_trace.cpp`：guest 崩溃时把现场（pc/lr/fpwalk + 模块表）落下来 —— 没有
  调试器、hilog 又丢样本，这是唯一能拿到"崩在哪"的通道。toplevel 首帧/commit/frame
  日志与 frame callback 记账也一起补上。

### GTK3 探针：五个坑，其中一个"cairo 必须共享"

为回答"我们的合成器能不能承载一个真实 GUI 工具链"，`scripts/build_gtk.sh`（deps|gtk|
probe|pack|all）只编 **wayland 后端** —— 这台设备完全没有 X11/XWayland，而 GTK3 的
wayland 后端本来就用 wl_shm（dmabuf 是 GTK4 才默认）。依赖能复用的一律复用，只补 8 层：
wayland-protocols → fribidi → harfbuzz → pango → gdk-pixbuf → atk → libepoxy → gtk+3。
产物是 `gtkprobe.tar`（34MB，探针 + 21 个 .so）。

沿途五个坑，都留在脚本注释里：

1. **wayland-protocols 的 meson 要 build-time 的 wayland-scanner**，交叉模式下它去目标
   sysroot 找，那里只有库。它是纯数据包，按**宿主原生**编。
2. **`fontconfig.pc` 把 expat 写在 `Requires.private`**（动态库的写法），而我们是静态
   fontconfig → `XML_*` 链不上，报错却是 pango 的
   `cairo-ft does not have the required FontConfig support`（误导性很强）。静态库就该写
   `Requires`。
3. **cairo 缺 gobject**（当初 `-Dglib=disabled` 编的），按完全相同口径重编、只多开
   `-Dglib=enabled`。
4. **glib 的 build tool 被换成了目标架构的**：meson 的 gnome 模块先查 machine file 的
   `[binaries]`，查不到才退到 `glib-2.0.pc` 的 `bindir` —— 那是目标的 bin，于是去跑
   aarch64 的 glib-compile-resources，宿主上直接
   `aarch64-binfmt-P: Could not open '/lib/ld-musl-aarch64.so.1'`。在 machine file 里把
   四个工具指到宿主那份。
5. **cairo 必须是共享库**（真正的功能性问题）：静态链进去时 `libgtk-3.so` /
   `libgdk-3.so` / `libpangocairo-1.0.so` **各带一份 cairo 及其全局缓存**，GTK 把一个
   副本创建的对象交给另一个副本用，画窗口那一步直接
   `Assertion failed: !"reached"`（`cairo-hash.c`）→ abort。取证是
   `libgdk-3.so.0` 的 NEEDED 里**没有** libcairo，可它崩在 cairo 的源码行上 —— cairo 就
   是编在它里面的。改成共享后只有 `libcairo.so.2` 含 cairo 代码。

另外一条环境上的：合成器发的 keymap 用 `include "pc+us+inet(evdev)"`，**include 解析
需要 `<sysroot>/usr/share/x11/xkb`**，而 xkb 现在是 pkg 包 —— 跑探针前先
`pkg install xkb`（不装，GTK 第一轮就崩在这）。

实测：协议 trace 里 GTK3 完整走通 registry → `create_surface` → `get_xdg_surface` →
`get_toplevel` → `set_title` → 我们回 `configure` → `ack_configure` →
`create_buffer(472,349)`；探针打出 `GDK 后端=GdkWaylandDisplay，窗口已建`、无 crash。

### shim 家族重整

- **`crash_reporter.c` 从 `compat_shim.c` 拆出来**：原来它长在 compat 里，而 compat 只编
  进 musl 那份 ⇒ 只有 musl guest 崩了才有 pc/lr/fpwalk，**glibc guest**（VS Code 的
  Electron）静默退出时什么都拿不到。拆开后两份都编。
- **`netif_shim.c` / `latecrash_shim.c` 并入**（原来是在宿主手工编、当独立 preload 用）：
  `netif` 是 `getifaddrs` 兜底 —— 沙箱不给 NETLINK raw socket，Electron 的
  `os.networkInterfaces()` 会抛 EACCES 到 VS Code main 的 `startup()` 上（后续还会用它
  挑"非内部、MAC 非全零"的网卡做 machineId）；假表给 lo + eth0，eth0 带真 MAC（libuv
  是从 AF_PACKET 那条取 phys_addr 的）。`latecrash` 是**迟到安装**的致命信号处理器：
  Chromium 在 main 里 sigaction 覆盖别人，而 LD_PRELOAD 的 constructor 跑在它之前 ⇒
  constructor 只起一个 detached 线程，每 500ms 重装一次、连装 20 次（覆盖 0~10s）。
  它默认**不启用**，要 `BSH_LATECRASH=1`（否则会抢走别人对 SIGSEGV 的处理）。
- **`fs_shim` 新增 `kPathMap`（路径映射表）**：有些程序把系统路径**硬编码**在代码里，
  而 guest 的 `/` 是只读 app 根。头一项是 `/usr/share/X11/xkb` → `$SYSROOT/usr/share/x11/xkb`
  —— libxkbcommon 把 include path 硬编码成前者，实测**不认** `XKB_CONFIG_ROOT`；目录不在
  就 `failed to add default include path`，随后在 `xkb_context_include_path_*` 里踩空 →
  **SIGSEGV(139)，进程约 3 秒就死**。挂在 `resolve_simlinks()` 开头（stat/realpath/open/
  access/fopen 的公共入口），边界判断防 `/usr/share/X11/xkbevil` 误伤。
  同批还有 `xkbpath_shim.c` 作为**对照实现**留在仓库（已被 kPathMap 取代，且不能加进
  `build_shim.sh` —— 它拦的入口与 fs_shim 完全重叠）。
- **`BSH_SHIM_LINK_STRICT=1`**：release 构建下沙箱把 `link(2)` 一并拒了，`link_or_copy()`
  为此有层复制兜底。对"临时文件 → 终名"那族用法（node 的原子写、dsh 的会话持久化）够用，
  但有一类调用方会**核对 link 的语义** —— 最典型是 git 的本地克隆：
  `copy_or_link_directory()` 在 link() **成功返回**之后还 lstat 比 st_mode/st_ino/st_dev，
  发现不是同一个 inode 就 `fatal: hardlink different from source at …`。设了这个变量就
  不做兜底，把内核的原始 errno 原样返回（pkg 的 git 包在四个启动器里都设了）。
  不设时行为一字不动。

### 大栈 fork 线程；`LD_LIBRARY_PATH` 的插入顺序

两条都是"Electron 起来 ~6 秒后静默退出"挖出来的：

- **`ctrl_socket` 的 AcceptLoop、bshutil 的 accept、shell 的 MasterReader 这三条线程不但
  跑协议，还要 `fork`** —— 而 fork 只保留调用线程，子进程（elfloader 装载 guest、命令 so
  就地跑）吃的就是这条线程的栈。musl 默认 128KB 对 Electron 那种 guest 直接不够。新增
  `common/bsh_thread.h` 显式设栈（`std::thread` 换成 pthread + `pthread_attr_setstacksize`）。
- **`EnvPrependList` 是往链表头插，所以后插的排最前**，原写法"先 guest 目录、后 bundle"
  的结果是 bundle 反倒压在前面，**与注释写的意图相反**。代价实测过一次：`code`
  （glibc 的 Electron）本该用自己闭包里的 `usr/lib/vscode/libglib-2.0.so.0`（NEEDED
  `libc.so.6`），却被塞进 bundle 里那份 **musl** 的 `libglib-2.0.so.0`（NEEDED `libc`）
  ⇒ GLib 线程池在 glibc 进程里跑 musl 代码，pool-spawner 线程空指针 SIGSEGV（FAR=0x18）。
  改成：bundle 先插（兜底）、guest 目录后插（优先）。

同批 `build_glibc.sh` 把 glibc 的**分家库**与 C++ 运行时装进 bundle libs
（libm/libpthread/libdl/librt/libutil/libresolv/libanl/libnsl + libgcc_s/libstdc++）。
**为什么必须有**：Ubuntu 的 .deb 里拿不到这几件（它们的真身是发行版 libc6，而我们刻意
不用 —— 会和自编这份 libc.so.6 对不上，GLIBC_PRIVATE 的符号集与内部结构都绑版本）。
可 `libm.so.6` 是**独立**共享库（glibc 2.34 只把 libpthread/libdl/librt 合进 libc，没合
libm），VS Code 那套闭包里有 53 个 ELF NEEDED 它。所以从**自编构建树**里取（与 libc.so.6
同源），`cp -L` 展开软链。

### VS Code 出窗口：闭包、启动器、本体必须与依赖同目录

- `scripts/pack_vscode.sh` 把官方 arm64 tarball + Ubuntu noble arm64 的 deb 依赖闭包打成
  一棵 `usr/` 树（fetch/debs/closure/pack 四阶段）：种子包包 Depends 闭包再沿 NEEDED 补，
  共 **161 个 deb / 113 个 .so**；缺的运行时数据（`share/mime`、`share/icons`、
  `gschemas.compiled`、gdk-pixbuf loaders）在宿主上现场生成或由启动器运行时生成。
- 两个探针把黑屏的第一层根因钉死：
  - `gdkprobe.c` —— gdk-pixbuf 选 loader 不是靠魔数嗅探，而是 `g_content_type_guess()`
    猜 mime → 按 mime 找模块；闭包里没有 shared-mime-info ⇒ 猜成
    `application/octet-stream` ⇒ `Unrecognized image file format` ⇒ GTK 连自带兜底图标都
    加载不了 ⇒ `Bail out!` ⇒ abort。
  - `shmprobe.c` —— 共享内存（memfd_create/shm_open/MAP_SHARED）能不能用，用来排除
    "Mojo/共享内存建不出来"这条假设（实测全 OK）。
- **本体必须与依赖同目录**：apt 装出来的本体落在 `usr/share/code`（deb 的原生路径），
  依赖由 `--flatten` 平铺在 `usr/lib/vscode` —— 分离时（`LD_LIBRARY_PATH` 两个都给了）
  `code` 起来就是静默 SIGSEGV(139)，日志停在 `Failed to initialize drm render node
  handle` 之后什么都没有。根因与 ohos-sdk-prune 那个坑同源：guest 的 `/proc/self/exe`
  指向宿主 appspawn，ld.so 与 Electron 算出来的 `$ORIGIN` 是错的，光靠 `LD_LIBRARY_PATH`
  不够。所以启动器里加一段：本体不在时用 tar 管道把它铺过去（软链会被沙箱拒）。

### code-server 从 HAP 挪进 pkg

它解包后 **640MB 出头**（大头是自带 node 96MB + 两个 Copilot 扩展各 96MB 的
`runtime.node`），跟应用本身没关系，属于"想用才装"。删掉 `shell.cpp` 里那条 UnpackRes
与 rawfile 里的 tar 之后，**HAP 从 458MB 降到 233MB**（`tablet-default-signed.hap`
= 233,762,066 B）。

顺手挖出一个 toybox 的坑：**`UnpackRes` 认 `.tar.gz` 不能交给 tar 自己去猜**。toybox 的
tar 认了 gzip 魔数后会 `xpopen_both()` **vfork** 一个子进程跑 `zcat`/`gzip -d`（见
`toys/posix/tar.c` 的 "autodetect compression type"），而 vfork 的子进程与父进程**共享
地址空间**、父进程被挂起 —— 子进程在 exec 之前除 `_exit` 外什么都不该做。而我们的 exec
委托在子进程里要 socket、要收发，等于拿 tar 的内存当草稿纸。后果是 tar 一声不响什么都
没解出来（实测 code-server 那个 214MB 的 .tar.gz 就这样，同一批 `.tar` 全正常），加上
`UnpackRes` 的 stdio 接的是 /dev/null，连报错都看不见。改成两步：`gzip -d` 经 procmgr
**正常 fork**，解完 tar 拿到的就是纯 tar。

`scripts/pack_codeserver.sh` 的装配有三处非默认：glibc 运行时闭包（放
`usr/lib/code-server/lib` 与 node 同层，好让 procmgr 加进 `LD_LIBRARY_PATH` 的"guest
自己所在目录"能找到）、把上游 12 个 `node_modules/.bin/*` 软链展开成真文件并补 0755
（`bsh_tar.c` 只认普通文件/目录，任何软链都会破坏安装）、tar + `zstd -19`。自检要先落一份
清单文件再查 —— `zstd -dc | tar -t | grep -q` 在 pipefail 下会被 SIGPIPE 判失败（本仓库
反复踩过）。

### pkg 新增 git 包（2.56.0）

`pkg install git` 后设备上直接能 `git clone https://…`。包 3.5MB（解包 17MB，46 个文件）。

几个非默认的 make 变量与理由：`NO_REGEX=NeedsStartEnd`（musl 的 regex.h 没有
`REG_STARTEND`，git 会 `#error` 让你显式选）、`NO_RUST=YesPlease`（2.54 起有一部分 Rust
重写）、`SKIP_DASHED_BUILT_INS`（内建命令同进程派发，不装那 100 多个副本）、
`NO_INSTALL_HARDLINKS`（pkg 的 bsh_tar.c 只认普通文件与目录）、`-U_FORTIFY_SOURCE=0`
（OHOS 的 sys/select.h 把 `FD_SET` 展开成 `__fd_chk`，bundle 那份 vanilla musl 没这个
符号）、LDFLAGS 里写 `/lib/ld-musl-aarch64.so.1`（procmgr 按 PT_INTERP 的 basename 去
bundle libs 找 loader）。

**为什么必须动态链接的 musl，而第三方库反过来必须静态**：静态 guest 吃不到 LD_PRELOAD
的 shim，git 内部所有 exec（传输助手、hook、editor、ssh）会直接打到内核 → 资源根 noexec
→ EACCES；而多一个 guest `.so` 就多一处"装到设备上才发现加载不了"的风险。
`pthread_cancel_stub.c` 是必需的：musl 只声明不实现 `pthread_setcancelstate`/
`setcanceltype`（OHOS 的 pthread.h 是从 glibc 抄的门面，libc.so 里没这两个符号），
`NO_PTHREADS` 能绕开但会把索引/`git grep -j` 的多线程一起关掉 —— 返回 0 不是假实现，
musl 里压根没有"取消"。

`usr/bin/` 下是**四个启动器脚本**（git / git-upload-pack / git-receive-pack /
git-upload-archive）而不是二进制：`GIT_EXEC_PATH`、`GIT_TEMPLATE_DIR`、`GIT_SSL_CAINFO`
都只有运行期才知道路径，编进二进制的是构建前缀 `/usr/...`，跟装在资源根下的实际位置对
不上。

**两个只有回到真设备才暴露的缺口**：① `git-upload-pack` 得在 **PATH** 上（不是
`GIT_EXEC_PATH`）—— 本地 clone 的传输是 `/bin/sh -c 'git-upload-pack …'` 起的，由 shell
按 PATH 找名字；顺带查明 git 2.56 的 clone 里 `transport_get_remote_bundle_uri()` 是
**无条件**调的，所以连本地 clone 也会起这个进程。② 补上 ① 之后才露出来的
`link(2)` 语义问题（见上文 `BSH_SHIM_LINK_STRICT`）—— 教训是**两个是各自独立的缺口，
别把先出现的那个当成全部**。

### apt：从发行版镜像装 `.deb`

`apt` 与 `pkg` **共用 `libpkg.so`**（第三个入口 `apt_main`），但打交道的对象完全不同：
pkg 装我们自己在 bsh.y1yan.com 上发的包，apt 装**发行版原生 deb** —— 依赖关系得从发行版
的 Packages 索引里现查。子命令：install / remove / update / search / info / source。

六个新模块：`bsh_deb.c`（ar 归档解析 —— 设备上没有 ar，toybox 也没有）、
`bsh_pkgindex.c`（Packages.gz 下载 / RFC822 解析 / 二分查找，7 万条 ≈ 3.4MB 条目数组）、
`bsh_depends.c`（Depends 语法 + DFS 求解 + dpkg 版本比较 + noble 的 t64 回退）、
`bsh_gzip.c`、`bsh_xz.c`（从 toybox 的 xzcat.c 提取的 xz-embedded）、`apt_main.c`。
另给基础设施改了三处：`bsh_tar` 改成 hooks 接口（on_member / on_link / skip，pkg 只传
第一个、行为不变）、`bsh_zstd` 加区间解压（.deb 的 ar 成员夹在文件中间）、`bsh_http`
跟随 3xx（微软的 `update.code.visualstudio.com` 就是个 302）。CA 从 1 张加到 4 张，每张
都是实际要用到的：ISRG Root X1（自建源）、DigiCert Global Root G2（微软下载站与 CDN）、
GlobalSign Root R46（aliyun）、ISRG Root X2（ustc）—— 换源撞上
`X509 - Certificate verification failed` 就是缺对应那家的根。

命令表登记 `apt`（与 pkg 共用 `libpkg.so` —— mbedTLS / bsh_http / bsh_tar / bsh_zstd /
bsh_json 都已经在里面了，另建 so 等于把它们再编一遍），并补上早先批次留下的 `zstd`
（只做解压；用途是把官方 .deb 里的 `data.tar.zst` 解成 `.tar` —— 设备上没有 ar / python3，
toybox 也没有 zstd）。README 补了「apt」一节：用法、环境变量表、索引规模、三条纪律、
t64 回退、`--write-list`、换源与四家国内源实测表、两层路径兜底，以及"本体必须与依赖同
目录"这条硬约束。

**三条从实战来的纪律**（写在 `apt_main.c` 文件头）：

1. **系统库不装**（libc6 / libgcc-s1 / libstdc++6 … 由我们自编的 glibc 提供；从 deb 装
   一份不配套的进来，ld.so 与 libc 的 TLS/内部 ABI 会对不上，实测
   `glib-compile-schemas` 在 `____strtod_l_internal` 里 SIGSEGV）。
2. **软链要代偿**（沙箱禁 symlink(2)：库软链复制成真文件，命令软链生成 sh 包装脚本）。
   其中**命令 wrapper 必须保住 `argv[0]`** —— deb 里的命令软链是**内核级的改名 exec**：
   `git-upload-pack -> git` 跑起来 `argv[0]` 就是 `git-upload-pack`，git 靠这个 basename
   分发子命令（dashed built-in）。普通 wrapper 把这条路走断的症状是
   `git: '/data/…/gtest/.git' is not a git command`。改用 `exec -a "${0##*/}"`
   （guest 的 sh 是 mksh，支持这个扩展）。同类程序还有 busybox/toybox/dropbear ——
   **凡按 argv[0] 分发的中招**。（写这段注释时注意：那个"删到最后一个斜杠"的参数展开含
   "星号紧挨斜杠"的序列，原样敲进 C 注释会**提前结束注释**，实测踩过。）
3. **`--flatten DIR`**（把 `usr/lib/**/*.so*` 额外拷一份，"本体必须与依赖同目录"要用）。

另外 `bsh_xz.c` 那 2800 行里修掉 **5 处字符符号 bug** —— toybox 那份 xzcat 的配置项是
`default n`、**从来没被编译过**，所以一路都是"能编译、一跑就错"：`get_unaligned_le32`
的符号扩展（CRC 永远对不上）、`xz_crc32/64` 查表拿 `*buf` 当负下标、`struct xz_buf` 的
`char *in/out`、range decoder 的 `const char *in`（**所有 LZMA 压缩块都解错**，只有
"未压缩块"的小文件碰不到）、`dict_get` 返回 `char`（literal 概率表下标飞出数组，直接
SEGV）。

`apt install` 的"目标已存在就不覆盖"后来补了 `--overwrite`：否则改完 wrapper 逻辑再重装，
链上去的还是旧 wrapper（实测代偿数为 0，白改）。缺依赖时也从"只报个数"改成**打出包名**
（ZCode 的 control 就漏写了 `libgbm1` / `libasound`）。

实测：一条 `apt install --flatten $V <VS Code 官方 deb 的 URL>` 装完 **201 个包**（含
216MB 本体），平铺 372 个库后 `code` 出窗口；`code-server_4.140.0_arm64.deb` **12 秒**
装完 7135 个文件。索引规模：main 1.7MB → 5977 条，universe 19MB → 63665 条。四家镜像各
下一次 main 索引：ports.ubuntu.com 4s / 清华 2s / aliyun 13s / ustc 2s。
镜像默认值 `BSH_APT_MIRROR` 写进 `$HOME/.bshrc`（`apt source <url>` 优先级更高，写
`$SYSROOT/pkgs/apt-source`）；**必须是 https** —— 内置 HTTP 客户端走 mbedTLS，明文
`http://` 会被判成 "URL 不合法"。

### 路径兜底：guest 里没有真正的根文件系统

apt 装的 deb 常带"绝对路径启动器"（`#!/usr/bin/env sh` + `exec /usr/lib/xxx/bin/xxx`），
而 guest 的 `/` 是只读 app 根，`/usr/lib/…` 在宿主上并不存在。**两层配合**才跑得起来：

- `fs_shim.c` 的 `kPathMap` 加 `{ "/usr", "usr" }` 兜底（放具体项之后）。这一步**不能
  省**：mksh 在执行 exec 之前会自己 stat 一次路径，映不过去就只报
  `inaccessible or not found`，**连 execve 都到不了** —— 所以只在 procmgr 那层做回退
  是没用的（第一版就是这么白试的）。
- `procmgr` 的 `Resolve()` 加绝对路径回退：宿主上确实没有该文件时试 `$SYSROOT + path`，
  只在 access 失败时才回退。附带好处是脚本里 `cd "$(dirname "$0")"` 拿到的是正确路径
  （code-server 的 `bin/code-server` 正是靠 `$0` 推导 ROOT）。

另外记一条容易混的：**`bin/` 与 `usr/bin/` 是两个不同的落点** ——
`rawfile/programs/` 下的"命令启动器"一律落 `$SYSROOT/bin`（`InstallPrograms`），`usr/bin`
是 apt/pkg 装出来的**真实程序**的位置。`$SYSROOT/bin` 在 PATH 里排在前面（实测
`python/bin : bin : llvm/bin : home : bin : usr/bin`），所以**同名的启动器会遮蔽 deb 自带
的那份** —— code-server.sh 正是这种情况，原稿 `$EXE` 从头到尾没被赋值，导致不管装没装
都只打"未就绪"指引。

### 三个新启动器：`git` / `code` / `zcode`

都是同一套思路：仓库里按"看得出是什么"存 `xxx.sh`，`shell.cpp` 的 `kRenames` 让它在设备
上落到用户要敲的名字（不改名会落成 `$SYSROOT/bin/xxx.sh`，敲命令找不到）。

- **`git.sh`** —— apt 装出来的 git 缺 `LD_LIBRARY_PATH`：deb 把库放在
  `usr/lib/aarch64-linux-gnu`，而 procmgr 给 guest 的只有"guest 自己所在目录"，症状是
  `error while loading shared libraries: libpcre2-8.so.0`。另加 `GIT_EXEC_PATH`（实测在
  `usr/lib/git-core`，不是编进去的 `usr/libexec/git-core` —— 后者是空目录）、
  `GIT_TEMPLATE_DIR`，以及三级兜底的 CA bundle（设备上没装 ca-certificates）。
- **`code.sh`** —— 除环境变量外还要现场造两样 dpkg trigger 才会生成的东西：
  `gschemas.compiled`（GTK 初始化读不到就 abort）与 gdk-pixbuf 的 `loaders.cache`
  （不设 `GDK_PIXBUF_MODULE_FILE` 时它会去读编译进去的默认路径，那条错误路径上
  `g_error_new_literal(NULL)` → GLib 断言 → **SIGSEGV**）。
- **`zcode.sh`** —— ZCode（Electron 41 / Chrome 146，`/opt/ZCode` 布局）与 `code.sh` 同构，
  但它比 code 多一份必要：**deb 不装 `/usr/bin/zcode`**（postinst 用
  update-alternatives 建软链，沙箱不支持软链），这根链子只能自带。

**ZCode 那一轮挖出的环境事实值得单独记**：它起不来时给的是
`Fatal process out of memory: Failed to reserve virtual memory for CodeRange`（rc=133），
而真实原因与内存无关 —— **没有 writable-code-memory 权限时，`mprotect` 加 `PROT_EXEC`
一律 EINVAL**（连不带 `PROT_BTI` 的也不成；`R|W` 却 ok），V8 拿不到可执行代码窗口就报
这句话。补上 `module.json5` 里那两条 kernel 权限
（`ALLOW_WRITABLE_CODE_MEMORY` / `DISABLE_CODE_MEMORY_PROTECTION`，且签名 profile 的
ACL 里要有）之后 `mprotect(R|W|X)` 立刻转 ok、窗口就出来了。
排查过程里的两个方法也记一下：**同类猜测要先量一遍**（写了个探针把"512M/1G/4G/64G
PROT_NONE mmap、各种 hint、`MAP_FIXED_NOREPLACE`、各保护位组合"逐条打出来，一步就把
"大块 mmap 不行"证伪）；以及**`kill -0 $!` 在这个环境里判不了存活** —— exec 是委托给
procmgr 的，启动器最后那句 `exec` 会 fork 新进程、原 sh 立即退出（差点因此得出"第二次
启动必然失败"的错误结论；真原因是那个实例的主进程 comm 是 `ZCode` 大写、我的脚本只匹配
小写 `zcode`，没杀干净）。

### 其它

- **`switch_version.sh` 收窄成三件事**：改 bundleName/label、用快照的 requestPermissions
  覆盖权限、把该用哪套签名打出来。**不再同步 `libs/arm64-v8a/` 与 `rawfile/tools/`**
  —— 那两处是构建产物，内容该由各自的 `build_*.sh` 决定、去留该由 `.gitignore` 决定；
  让"切版本"顺带 rsync 整目录（还带 `--delete`）等于把两件事绑死。权限与 label 都是
  **就地改那一段/那一行**（快照是 10-01 拷的，那时模块还叫 entry，整份覆盖会把模块名、
  abilities、设备类型一起带跑）。另加两道一致性检查（都对不上就装上也白装）：profile 的
  `bundle-name` 与配置的 bundleName 是否一致、配置要的 `kernel.*` 受限权限是否在 profile
  的 `allowed-acls` 里。
- **`build/pack_deploy.sh`**：一条命令跑完一轮（重打 HAP → 核对包里的 rawfile 与本地
  一致 → 签名 → 装机 → 启动 → 轮询 `$HOME/autorun.log` 里的 `===end===`）。那道核对是
  被"hvigor 增量构建 + 后台构建时改了 autorun"白跑好几轮逼出来的。
- **`build_toybox.sh` 修重跑覆盖失败**：上次构建留下的 `toybox` 产物是 **0555**，
  `cp -a` 覆盖会被内核拒掉 —— 于是"重跑一次就挂，得先手动 `rm -rf build/toybox-src`"。
- **新增 `trace_shim.c`**（并入两份 guest shim）：只记**失败**的系统调用，要
  `BSH_TRACE_SYS=1` 才启用 —— 日志侧（`--v=1`/定向 vmodule）穷尽之后换的这个维度，最后
  正是靠它把 Chromium 的崩溃现场从"什么都看不到"变成一条条可读的失败调用。

### 版本号

`0.7.0 → 0.8.0`（versionCode `1000004 → 1000005`）。

---

## 0.7.0 · 2026-10-05

从 0.6.0 到这里跨了 10-02 ~ 10-05。这一轮的主线是**从"一个能跑应用的包"变成"一套能自己扩展、
自己装东西的系统"**：应用拆成共享 HAR + 两个薄 entry（手机/平板各拿各的权限），命令集从编译期
表变成磁盘上可读的文件，加了一个包管理器把"按需下载"的东西搬出 HAP（两轮削下来 **366 MiB → 约
171 MiB**，各自的数字见后文），并且让**官方发行的二进制**（kimi-code、SDK 的 cmake、node 原生
扩展）真的在设备上跑起来。

### 分包：entry 拆成共享 HAR + 两个薄 entry

- **为什么非拆不可**：**权限只能按模块给**。`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`
  （JIT 必需）手机上拿不到、平板/2in1 才给，而 `module.json5` 是每模块一份 —— 「同一个应用按设备
  给不同能力」就必须有多个 entry 模块。结构照搬 HiSH 的 feature/product。
- 拆成三步走，每步单独拎出来看更清楚：`f68721d` **纯移动**（138 个文件 100% rename，逐字节相同；
  这个提交单独**不可构建**，此刻还不是 HAR）；`73eb492` 真正改成 HAR（hvigorfile 换 `harTasks`、
  页面组件的 `@Entry` 上移到 product 侧薄页面 —— `loadContent('pages/X')` 只在 entry 模块内解析路由、
  `WaymonyService.startAbility` 补 `moduleName`）；`5155475` 让 40 多个脚本与文档跟上路径。
- `73eb492` 与 `19a6144` 必须成对看：前者包能打出来但装上用不了（native 资源根还写死着 `.../haps/entry/files`）。
- 首次构建前要先 `ohpm install` —— 两个 entry 用本地 `file:` 依赖引 HAR，漏了就是
  `Dependency bsh_main not found`。

**资源根从编译期常量改成运行期取值**（`19a6144`）：设备侧路径是
`/data/storage/el2/base/haps/<模块名>/files`，**挂在模块名下**，模块名一改、所有编译期写死的
副本就全指错。改成 `common/bsh_paths.h` 的 `bsh_set_sysroot()`/`bsh_sysroot()` 一对访问器，
getter 以环境变量 `BSH_SYSROOT` 为准，Ability 把 `context.filesDir` 传进来。踩到的坑：getter 不能
直接把 `getenv` 的指针甩出去 —— 调用方紧接着 `setenv("BSH_SYSROOT", bsh_sysroot(), 1)` 是"环境变量
给自己赋值"，`setenv` 释放旧值后指针当场悬空，**实测症状是 PATH 里冒出 `<资源根>/fonts.conf/usr/bin`**；
现在先拷进静态缓冲再返回。另外 `fonts.conf` 必须**在解包之后**重写（fontconfig 的字体目录只能在
文件里写，没有环境变量可覆盖，tar 里那份是打包时的绝对路径）—— 不重写就是所有窗口文字变方块。

### 命令集数据化：`#BSHSO` 启动器文件

`<资源根>/bin/<命令名>` 下现在是一个 4 行文本文件：

```
#BSHSO
/data/storage/el1/bundle/libs/arm64/libtoybox.so
bsh_toybox_main
2                     ← 2 = int(*)(int,char**)；3 = 多一个 envp
```

- **为什么**：`exec_shim.c` 原来在客户端自己做裸名判据 / PATH 搜索 / ELF·脚本·启动器判型 /
  basename 回退，跟 procmgr 的规则两套、迟早不同步。真实症状：`toybox timeout 90 ./x` 里那层
  timeout 用 `execvp` 起子进程，客户端那份 `path_search` 只认 ELF、跳过了空占位文件，命中系统
  真实文件，最后报 **`cannot read /bin/sh or ldso ld-musl-aarch64.so.1`，rc=127**。
- 改完 `exec_shim.c` **只归一、不分类**，把"要跑什么"原样交给 procmgr（唯一例外是 clang 用
  `/proc/self/exe -cc1` 起自己 —— 沙箱里那条路径指向宿主 appspawn，得翻译成命令名）。
  `cmd_make_placeholders` 与 `$HOME/.applets` 空占位一起删掉，`SearchPath` 改成认得 ELF、`#!`
  脚本和 `#BSHSO` 三种；启动器的格式错会报"第 N 行"且**不静默回退**。
- 实测：`which ls` → `<资源根>/bin/ls`；**mksh 里跑表里没有的手写启动器也通** —— 证明判型确实
  搬到 procmgr 去了。

### pkg 包管理器：把"按需下载"的东西从 HAP 里搬走

新增 `pkg` 命令（`list / info / install / remove / source`），安装根就是资源根，装包 = 下载 →
sha256 校验 → `tar -C <资源根> -x`，装完记进 `<资源根>/pkgs/installed.json`，`remove` 按记录逐个删。
默认源 `https://bsh.y1yan.com/`。

- HTTPS 走 mbedTLS（在它的 CMakeLists 里直接编成 `bsh_mbedtls` 静态库）；**内建信任锚 ISRG Root X1**
  —— 沙箱读不到系统 CA（`/etc/ssl/certs` Permission denied）。HTTP/1.0 是为了避开 chunked。
- `.tar.zst` 支持：只编 zstd 的解压半边（不编 compress/dictBuilder/legacy/多线程，
  `ZSTD_LEGACY_SUPPORT=0`、`ZSTD_DISABLE_ASM`），先解成 `.tar` 再交给自带的 `bsh_tar`；
  后者**只认普通文件与目录**（不认软链 —— 这条约束后面反复出现）。
- 文件清单从固定 512 项改成动态数组：原来会让 5 万文件的包"装得上、删不干净"。
- 缓存只认环境变量 `BSH_PKG_CACHE`，默认 `<用户可见的 Download>/com.yiyan.bettersh/.pkg-cache`
  —— 因为 `deploy_hap.sh` 装 HAP 前 `bm uninstall` 会**清空资源根**，每个几百 MB 的包都要重下；
  可用性判据是"建目录 + 真写一个探针文件"而不是只看 `access()`。
- **`ohos-sdk-prune`**（`scripts/pack_ohos_sdk_prune.sh`）：把 SDK 裁到能给 pkg 发。
  1788 MiB 的 zip → 只打 `sdk/default/openharmony` 子树 597 MiB → 再裁掉 lldb 全家、非本机目标的
  clang-rt/libc++、docs 等 → **242 MiB**。为"能发出去"做的三件事：① 去软链（`bsh_tar` 不认），
  别名展开成真副本靠 `--long=27` 去重；② 给 aarch64 clang 补 glibc ABI 闭包 —— 且**必须与 clang
  同目录**放，`$ORIGIN` 在沙箱不成立（guest 的 `/proc/self/exe` 是宿主 appspawn），实测放
  `native/llvm/lib` 会 `libpthread.so.0: cannot open`，能用的只有 `LD_LIBRARY_PATH`；③ 打包前
  自检每个可执行文件的 NEEDED 都在本树里。
- **`weston-terminal` 从"命令 so"改成"guest 可执行"**：`dlopen` 进主进程用 OHOS libc 那套
  （`libwestterm.so`）换成 PIE + `/lib/ld-musl-aarch64.so.1` + `rpath=$ORIGIN/../lib`，按 FHS 摆成
  `usr/bin` + `usr/lib`，xkb 与 weston-data 一起移出 HAP 变成三个包。依赖目录必须排在 bundle libs
  **之前**，否则 `-lfontconfig` 那些会被解析成应用里 OHOS 编出来的动态库、进 guest 就加载失败。
- 顺带：`libclangbsh.so` / `liblld.so` 与 `clang-res.tar` / `sysroot.tar` 从 HAP 里删掉，编 aarch64
  改走上面那个 pkg。**HAP 366.6 MiB → 200.8 MiB。**


### guest 启动栈：两组"一律崩 / 一律不生效"的修

这两条都是**整个 guest 侧一起坏**，症状又都很误导，值得单独记。

- **release 构建下 aarch64 guest 一律 SIGSEGV**：沙箱里宿主 `/proc/self/auxv` 只有
  `PAGESZ / SECURE / RANDOM / HWCAP / HWCAP2` 几项，而原来的 auxv 构造是"照抄宿主、只改写已有项"，
  于是 `AT_PHDR / AT_PHNUM / AT_PHENT / AT_ENTRY` **永远补不上**。musl 的 static-PIE 靠它们定位程序头
  再找 `_DYNAMIC` 做自举重定位，拿不到就算出垃圾指针 —— 第一条指令就死，`fault addr=0x220`、
  PC 落在 `__dls2` 的重定位循环里。修法与 `AT_BASE` 同一套"缺什么补什么"。
- **musl guest 下 `LD_PRELOAD` / 整套 shim 完全不生效**：同一个 aarch64-musl-dynamic guest
  **24 过 / 6 挂**，挂的正好是 shim 管的每一档（软链、硬链、pty、exec），报的都是内核层 errno。
  环境变量在、文件在、shim 符号全能解析，就是不生效。根因在 musl `__dls3` 的一句启发式：

  ```c
  libc.secure = ((aux[0]&0x7800)!=0x7800 || aux[AT_UID]!=aux[AT_EUID]
                 || aux[AT_GID]!=aux[AT_EGID] || aux[AT_SECURE]);
  if (!libc.secure) { env_path = getenv("LD_LIBRARY_PATH"); env_preload = getenv("LD_PRELOAD"); }
  ```

  `aux[0]` 是"哪些类型出现过"的位图，`0x7800` 恰是 `AT_UID/AT_EUID/AT_GID/AT_EGID` 四位；宿主 auxv
  缺这四项 → 位图凑不齐 → 判 secure；而本机 LSM 又把 appspawn 标成 secureexec（宿主 auxv 里
  `AT_SECURE=1`）。musl 的 `load_preload()` 对预载失败**不报错不打印**，于是查了两天只想问"为什么没生效"。
  glibc 不吃这套启发式 —— 这个"半边好半边坏"一度把排查方向带偏。修：缺的身份项按本进程
  `getuid()/geteuid()/getgid()/getegid()` 补上，`AT_SECURE` 对 guest **强制写 0**（同 uid、同一套
  env，没有它要防的跨权限边界）。同一档 **24/6 → 29/1**。

**崩溃取证三处**（`d6fad4a`）：查上面第一条时发现"guest rc=139 且一行日志都没有"另有原因 ——
① 给 `SIGSEGV/SIGBUS/SIGILL/SIGABRT` 注册时复用了给 `SIGSYS` 准备的 `sigaction`、只改了 `sa_flags`，
`sa_sigaction` 一直是 `OnSigSys`，**`OnSigFault` 一次都没跑过**；② elfloader 跳进 guest 前
`sigfillset` 屏蔽所有信号，而同步信号被屏蔽时内核直接按默认动作杀进程，handler 拿不到现场；
③ `UnmapLowAnonRegions()` 会把 `libentry` `.bss` 里那块 64 KB 静态备用栈连带 `munmap`，内核
`get_sigframe` 失败 → 照旧 rc=139。现在 `ChildRunElf` 里重挂四个信号（`mmap` 一块新的备用栈），
从屏蔽集里 `sigdelset` 掉同步故障信号，`OnSigFault` 同时写 fd 2 与 `<资源根>/elf-fault.log`。
退出日志也从 `code=…` 补成 `code=… signaled=… sig=…` —— 以前"被信号打死"和"自己退非零码"
在日志里长得一样。

### box64：补丁集重构，并让它的 guest 也用上 shim

- **补丁集重构**（`ddb0e5a`）：6334 行的单体 `patch_box64.sh` 拆成 `scripts/box64-ohos/`
  的 `files/`（我们自己新加的文件，按源码树镜像、构建时整份覆盖）+ `patches/`（对上游的就地修改，
  一条一个 patch）+ `vendor/`（musl-fts/musl-obstack 源码留档，构建不再联网 clone）。
  `--no-reset` 的幂等改用标记文件 —— 逐条 `patch -R --dry-run` 在这个系列里判不准
  （**35 条里 11 条**因"同一文件被后续补丁再改"而失败）。删掉 wine/PE 那组（A/B 实测对 x86_64
  Linux ELF 零影响，6 份日志归一化后逐字节一致）与从未生效的 `patch_85`（锚点字符串写错、
  一直静默跳过）。等价性：参照树与候选树从同一 pristine commit 出发 `git diff` 为空。
- **guest 用上 fs/tty/pty shim**：box64 的 guest 走它自己的 wrapped-libc 层（`my_*`）与 syscall
  分发，既不能用符号插入也不能用 `-Wl,--wrap=`（wrap 只改写本 so 自己**的**引用）。改成
  `-DBSH_SHIM_BOX64` 编进 `libbox64.so`、由 `my_*` 显式调用，入口按模块加前缀（不加会 `duplicate symbol`）。
  具体修：软链模拟（`my_symlink` 原来直接 `return 0` 不落盘，正是 testprogs 里三条 FAIL 的来源）、
  `isatty/tcgetattr/tcsetattr/ioctl` 走 shim、用户态 socketpair 假 pts（沙箱三层都打不开真
  `/dev/ptmx`，实测 EACCES）、`uname` 报 `"Linux"`。
- **禁掉 box64 对 guest 镜像的"文件可执行映射"**：上游 `AllocLoadElfMemory()` 对每个 PT_LOAD 先试
  从文件 mmap（PF_X 段带 `PROT_EXEC`），正是沙箱 seccomp 确认闸拦的动作 —— **症状是每加载一个
  guest 就弹一次"是否运行 …"、不点干等 30 秒**（被拒后 box64 的兜底路径照跑，所以一直没被当成故障）。
  强制走兜底后同一份自检 **306 秒 → 7 秒**。
- **spawn 的 procmgr sock 一直静默退化**（`2124f60`）：默认值写死成 `.../haps/entry/files/.procmgr.sock`
  （模块名与文件名双重过期），更根本的是 `PROTO_VER` 发 2 而 procmgr 的 `kProtoVer` 是 1，
  **每次都被 `proto_ver_mismatch` 拒掉** —— 因为 sock 失败是静默退化到 fork，这个 bug 一直被盖着。
  改完实测：`[box64-spawn] strategy=sock ×4 → [spawn-sock] sync spawn ok`（改前全是
  `sock failed, falling back to fork`），两个动态 x86 组合从"打完汇总后崩"变成干净退出。

### `.bshrc`：会话环境搬出 C++

- 原来 `shell.cpp` 里一口气 `setenv` 十几条（`TERM`/`VIMRUNTIME`/`PYTHONHOME`/`QT_*`/`PATH`…），
  用户既看不见也改不了。现在搬进 `$HOME/.bshrc`，每次会话执行一遍，C++ 只留"语义上只读"的四个。
- 文件由 `WriteBshrc()` **函数生成**（理由同 `fonts.conf`：默认值引用**当前**资源根），但它是用户会改
  的文件，所以只重写 `>>> BetterSH managed >>>` / `<<< BetterSH managed <<<` 之间的托管块，
  块外原样保留；整份删掉下次会话自动重建。
- **执行时机被两个硬依赖夹出来**：**晚于** `StartControlSocket`（rc 里可能跑外部命令，要经 procmgr）、
  **早于** `initResource`（那里解包起的是裸名 `tar`，由 procmgr 按 PATH 找 `$SYSROOT/bin/tar`，
  而 PATH 现在归 `.bshrc` 管 —— 顺序反了第一次装机就解不开包）。
- 有意接受的语义变化：`SHELL`/`XKB_CONFIG_ROOT`/`BSH_PKG_CACHE` 原来是 `setenv(...,0)`
  （外部已设就不盖），rc 文件里没有这种写法，变成"文件说了算"。
- 宿主单测 **81 PASS / 0 FAIL**（新增 11 条：注释/CRLF/空行/行尾 `#` 不算注释/追加保留用户行/幂等/换块/…）。

### 设备侧构建链：让 `pip install` / `npm install` 现场编得出东西

这一块全部集中在 `.bshrc` 的几行环境与几个包装脚本上，每条背后都是一个具体的死法：

- **`pip` 成为一条命令**：命令表一条只能描述"so + 入口符号 + 参数个数"，而 pip 的标准起法是
  `python -m pip`，所以加了个薄入口 `bsh_pip_main` 把 argv 拼成 `["python","-m","pip",…]`。
- **`_ssl`/`_hashlib` 静态链 OpenSSL 3.0.22**：libpython.so 是 procmgr dlopen 进来的，它再 dlopen
  的 .so 必须落可映射执行位置，而资源根 noexec —— 所以只能静态链，且必须
  `-Wl,--exclude-libs,libssl.a`（否则 libcrypto 符号进动态符号表、与宿主 openssl 撞名），
  还得 `no-module`（OpenSSL 3.x 的 provider 默认可为动态模块，guest 没有 DSO 加载能力）。
- **`MAKEFLAGS=SHELL=$SYSROOT/bin/sh`**：GNU make **从不从环境取 SHELL**（手册原话 "Unlike most
  variables, the variable SHELL is never set from the environment"），默认写死 `/bin/sh`，
  而沙箱 `/bin` 是系统的、不可访问 —— 任何 make 都死在起 recipe shell：`make: /bin/sh: Permission denied`。
  MAKEFLAGS 里的变量赋值等价命令行定义，会传给子 make 且优先级高于 makefile 的 `SHELL :=`。
- **同名 `clang` / `clang++` 包装**：SDK 的 clang 默认 target 是 `aarch64-unknown-linux-gnu`
  而不是 ohos，裸跑连 `stdio.h` 都找不到；只补 `--sysroot` 又卡在 musl 的 `bits/alltypes.h` ——
  **`--target` 与 `--sysroot` 必须一起给**。所有包装再加 `-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0`。
- **`CC` 这类变量只能放不含空格的路径**：`.bshrc` 由基础 shell 执行，它对 `export X="a b"` 只取第一个词
  （实测 `CC` 变成光秃秃的 clang 路径、`--target/--sysroot` 全丢），所以参数写进生成的包装脚本里。
- **给我们的 musl 补 `__fd_chk`**：OHOS 的 `sys/select.h` **无条件**把 `FD_SET`/`FD_CLR` 展开成
  `__fd_chk(fd)`，而 bundle 里那份 `ld-musl-aarch64.so.1` 是 vanilla 1.2.2、没这个符号。
  动态链接不查未定义符号 ⇒ 编译链接都过、**运行期才炸**：
  `Error relocating make: __fd_chk: symbol not found`。用 SDK 头文件编出来的任何东西都会踩。
- **`devtools` 从静态改动态**：静态 guest 没有 PT_INTERP ⇒ procmgr"按 PT_INTERP 挑 shim 预载"
  那段直接跳过 ⇒ make 里根本没 shim ⇒ 它内部的 `execvp("/bin/sh")` 直接打到内核。
  **这条对所有 guest 都成立：要 shim 就别静态链。**
- **`npm_config_nodedir=$SYSROOT/node-headers`**：node-gyp 把环境里的 `npm_config_*` 当命令行选项，
  等价 `node-gyp --nodedir=<…>`，不必联网下 8.7 MB headers。

### 进程内装载器（`elf_dl`）：让 noexec 资源根里的 `.so` 真的能被加载

资源根是 noexec，系统加载器在 `mmap` 那步就被拒（文件明明在，`ls`/`stat`/`read` 都正常）——
所以 pip 装进 site-packages 的 C 扩展只能走我们自己的装载器。为此补了四件事：

- **`dlopen` 兜底**：`libpython.so` 上 `--wrap=dlopen/dlsym/dlclose`，先试真的、失败才读文件交给
  `elf_dlopen_mem()`。**只给 libpython 加，不动通用清单。** 已知语义差别照实记：不区分
  `RTLD_LOCAL`/`RTLD_GLOBAL`、`dlclose` 不真卸、`DT_FINI*` 不跑。
- **弱符号 + `DT_NEEDED` 预载 + 构造函数**：`crtbeginS.o` 的 `__register_frame_info` 在设备上
  没有任何库导出也不被调用，却被当成强符号判失败；`resolve_sym` 兜底只看"已加载"对象，
  于是 `NEEDED libc++_shared.so` 的 `__cxa_*` / `_Unwind_Resume` 全没人提供；还有 `DT_INIT` /
  `DT_INIT_ARRAY` 没跑（numpy 的 `_multiarray_umath` 带 2 个 init_array 项，不跑则 import "成功"、
  一用就崩）。
- **首选符号解析器（宿主作用域优先）**：应用自己链了鸿蒙的 `libace_napi.z.so`（导出 190 个 `napi_*`），
  `libnode.so` 也导出 145 个，而 `dlsym(RTLD_DEFAULT, …)` 先命中先加载的那个。症状：
  `napi_get_version -> 0 ver=8`（应为 9）、`napi_create_function -> 10`（10 是
  `napi_pending_exception`）、`create_function: code=10 msg="An exception is blocking"`、
  `require ok, keys= []`。⚠ 这个钩子**必须定义在匿名 namespace 之外** —— 第一版写在里面，
  `-O2` 当死代码删掉，宿主留下 `U elf_dl_set_prefer_sym`，**整个 libnode.so dlopen 不进来**（node 全废），
  而编译链接期一声不响。
- **真 TLS（PT_TLS / TLSDESC）**：`@napi-rs/uuid-linux-arm64-musl`（Rust 预编译）带
  `R_AARCH64_TLSDESC` 重定位与 `PT_TLS`，报 `unsupported JMPREL reloc type 1031`。
  python 那批没踩到是因为 OHOS clang 走 EMUTLS（`__emutls_get_address` + `__emutls_v.*`，无 PT_TLS）。
  ⚠⚠ **TLSDESC 的 resolver 除 x0 外不许改任何寄存器**（不在普通 C ABI 里）—— 编译器会把线程指针
  缓存在**临时**寄存器里跨 resolver 调用继续用：

  ```
  12284: mrs  x11, TPIDR_EL0     ; 缓存 TP
  12298: blr  x1                 ; 调 resolver
  1229c: str  x8, [x11, x0]      ; 还在用那个 x11
  ```

  C 体里要调 `pthread_getspecific/calloc/fprintf`，按 AAPCS64 会把 x1..x18 与 v0-v7/v16-v31 糊掉，
  第二次访问就用被污染的基址崩。所以入口写成汇编外壳 `elfloader/tlsdesc.S`（与 `guest_switch.S`
  同待遇）：存 → 调 C 体 → 原样恢复。⚠ 凡链 `elf_dl.o` 的脚本（`build_node.sh` / `build_python.sh`）
  都必须一起链 `tlsdesc.o`，落下就是未定义符号、整个 so dlopen 不进来，而链接期不报错。

### exec 委托两段式，以及为它让路的一串 procmgr 修

- **两段式**（原来"目标跑完才返回"，改成"建好就回、退出码第二段取"）：`Popen(['cat'], stdin=PIPE)`
  直接卡死在构造里 —— CPython 靠 error pipe 判断孩子起来了，那根 fd 标了 CLOEXEC、
  父进程**读到 EOF 才算成功**；我们的委托不是真 exec，于是父进程卡读、孩子等父进程喂 stdin。
  现在委托成功（fd 已通过 SCM_RIGHTS 交出）就立刻扫 `/proc/self/fd` 把带 `FD_CLOEXEC` 的关掉，
  模拟"内核在 exec 成功时干的事"。
- **失败语义统一**：命令 so 侧原来委托失败即 `_exit(127)`，而真 `execve` 应返回 -1 + errno ——
  CPython subprocess 做 PATH 搜索时**只对 ENOENT 继续试下一个候选**，所以 `pip install` 崩在
  `uname -rs`（rc 127）：第一个候选 `$HOME/uname` 被 `_exit(127)` 掉后就再没机会试到
  `$SYSROOT/bin/uname`。
- **裸名 PATH 查找要用调用方的 PATH**：`npm error code ENOENT … syscall: 'spawn node-gyp'`，
  而 `node-gyp` 就在调用方 PATH 上（npm 会前插两个目录）。根因是 procmgr 读的是**自己**的
  `environ`，而调用方在 `req.env` 里换了 PATH。
- **`/bin/sh` 这类标准路径落命令表**：gyp 的 Makefile、autotools、meson 都把 `SHELL` 写死 `/bin/sh`，
  而设备上 `/bin` 是系统的、不可访问 —— 要么 EACCES，要么内核 ENOEXEC 后把我们的 `#BSHSO`
  启动器**当 shell 脚本逐行解释**，症状是启动器的三个字段被当命令跑：
  `printf[2]: …/libtoybox.so: can't execute` / `printf[3]: bsh_toybox_main: inaccessible`。
- **exec 的目标路径先解开"用户态软链"**：`npm install` 任何带 install 脚本的包都失败
  （`node_modules/.bin/node-gyp-build: cannot exec: … not found`，code **126**）—— 那些 `.bin/*`
  是 npm 建的软链、被 fs_shim 表示成 `<name>.BSH_SYMLINK`，做 PATH 查找的 shell 看得见它，
  而 procmgr 没有 fs_shim、按真路径 `stat` 得 ENOENT。⚠ 这个调用用**弱引用**声明 —— qemu 那个 so
  只链 `exec_shim`、不链 `fs_shim`，强引用会变未定义符号、整个 so dlopen 不进来。
- **LD_PRELOAD 逐项筛**：调用方自己已是 elfloader 起的 guest 时，继承下来的 shim 与按目标
  `PT_INTERP` 新加的那份会冲突（clang 是 glibc 的 ELF、继承下来的却是 musl 那份
  → glibc 的 ld.so 去预载 musl 的 .so → SIGSEGV）。注入时把 `libbshguest-{musl,glibc}.so` 一律滤掉。
- **并发上限 32 → 512**：两段式之后等待连接在整个目标运行期都开着，"并发进程数"直接等于
  "占用连接数"，numpy 的 meson 构建按核数并发起编译、32 一下就满，症状
  `cannot exec: too_many_clients`。顺手修 **waitpid 的 EINTR**：`WaiterOnlyMain` 原来是
  `if (waitpid(...) > 0)`，被信号打断时 status 不动、code 留成 -1，上层当成"委托失败"、
  命令**无声终止**（高并发编 120 个文件时复现，日志 `wait-exit pid=… code=-1`）。

### 非 PIE 的动态程序现在也走解释器（kimi-code 由此跑通）

- `procmgr` 的 `ElfReadInterp()` 只认 `ET_DYN`，于是 **`ET_EXEC` + `PT_INTERP`**（关掉 PIE 编出来的
  官方发行二进制：kimi-code 的 arm64 独立包、SDK 的 cmake）被判成"静态 guest"：`ChildRunElf` 走
  `elf_run_file`，**直接跳 `_start` 而不跑动态链接器**，GOT 全是 0 —— 一进去就是
  `[bsh] FAULT sig=11 addr=0x0 pc=0x0`。`elf_run_dyn_inproc()` 里还有第二道同样的门槛（`!m.dyn`）。
  两处一起放开：内核遇到 `ET_EXEC` + `PT_INTERP` 本来就是先起解释器、再把 `AT_ENTRY` 交给它。
- exit 桩的条件从 `!dyn` 收紧成 `!dyn && !has_interp` —— 动态主镜像的 `exit` 归解释器管，不能按
  静态 guest 去改它 `exit` 那 4 个字节。
- 实测：kimi-code 2.1.1 的 `kimi-code-linux-arm64`（188MB，内含 Node 24 的 SEA）在设备上
  `./kimi --version` → `2.1.1`，`./kimi --help` → 完整 52 行。`testprogs` 新增
  `aarch64-glibc-dynamic-nopie` 一格专门盯这条路径（宿主机 31/31，设备端 31 块 pass 29 fail 1，
  与另两个动态组合一字不差）。

### 系统 bin 目录里"认不得"的命令改交 exec

- `/bin`、`/usr/bin`… 这 9 个前缀下 basename 命中命令表仍走我们自己的 so；**认不得**的以前落到
  elfloader，而那些文件大多是**系统 toybox 的符号链接**（`/bin/timeout`、`/bin/od` → `/system/bin/toybox`），
  要的是**系统那份** `ld-musl` —— 交给 elfloader 会"装载成功、一进 guest 就崩"：落点固定在
  `ld.so+0x62534`、`pc=0`、rc=139 外加一串 `[crash]`。同一个文件让系统 shell 跑完全正常
  （实测 `/bin/timeout 3 echo hi` → rc=0），所以这类应该交给内核 `execve`；`ChildRunExec` 本来就
  "exec 失败退回 elfloader"，行为不倒退。
- 排查时踩过一个坑：前几轮把 kimi / node 的"崩溃"记到了它们头上，其实是命令前缀里的 `timeout`
  先崩 —— `timeout 5 echo hi` 单跑就能复现 rc=139。

### 命令表补 `timeout`；toybox 补 `awk` / `tr` / `stty` / `clear`

- `timeout` 必须用我们自己那份：系统 `timeout` 会 `fork+exec` 子命令，而它 exec 到的是
  `$SYSROOT/bin` 下那些 `#BSHSO` 启动器（纯文本），内核直接 `ENOEXEC` —— 实测
  `timeout 3 echo hi` → `timeout: exec echo: Exec format error`（rc=126）。走我们的 toybox 则在进程内
  分发、子命令经 exec shim 交给 procmgr。
- `awk` / `tr` / `stty` 一直登记在命令表里、但 toybox 的 defconfig 没开，运行时得到
  `toybox: Unknown command xxx`；`scripts/build_toybox.sh` 的开清单补上这三个（那个循环的注释本来
  就写着"命令表里注册的 applet 必须在 .config 打开"）。
- `testprogs` 从 8 格加到 9 格，`run_testprogs_host.sh` 与 `autorun-all.sh` 第 8 节跟着更新；
  自检脚本里那个"组合名尾部的 `-nopie` 不参与 static/dynamic 替换"的推导也一并修好。
- **`clear` 补 `ESC[3J`**：基础 shell 的 `clear` 是 `shell.cpp` 里硬编码的 `ESC[H ESC[2J ESC[3J`，
  而 mksh 走 toybox 那条路只发 `ESC[H ESC[2J` —— 于是同一个界面里，bsh 的 `clear` 清干净了，
  mksh 的 `clear` 只是把内容顶上去、往回滚还能看见。给 toybox 打补丁让它也多发一个 `ESC[3J`
  （清回滚缓冲），两边行为就一致了。补丁只打在 `build/` 的源码副本上，submodule 保持干净。

### Node.js 18.20.1 → 22.19.0：为了让 agent 类 CLI 能跑

起因是那句"kimi-code 和 deepseek-harness 能不能在我们的项目上跑起来"。结论：
**两个的 CLI 面都跑起来了**（`--version`/`--help`/`doctor`/`-p`、以及 dsh-tui 的
`--version` 与"连不上服务端"的正常报错）—— 为此换了一次运行时；**交互 TUI 当时是崩的，
后来定位并修掉了**（见本节末尾"交互 TUI 的两个崩溃"）。两者的 engines 都写死 `>=22.19`（kimi-code 是
`>=22.19.0`，`@deepseek-harness-tui/dsh-tui` 是 `^22.19 || >=24`，它依赖的 ink 7 也要 `>=22`），
而且一开头就用 ES2024 的 `v` 正则标志（V8 11 起）—— Node 18 上**连解析都过不去**：
`SyntaxError: Invalid regular expression flags`。

- 版本定在 **v22.19.0**：两个工具声明的下界就是它。先试过直接上 **v24.21.0**，编不动，
  卡在工具链而不是代码：V8 13.6 用了 C++20 的"可省略 `typename`"（P0634R3，见
  `objects.h` / `base/template-meta-programming/list.h`），而 OHOS SDK 自带的 clang 15
  不实现这条规则（`error: missing 'typename' prior to dependent type name …`）；
  换宿主机的 clang 18 也不行 —— 它跟 SDK 那份 libc++ 15 的头不兼容
  （`error: reference to unresolved using declaration`）。要上 24 得整套换到更新的 OHOS SDK
  （clang 18+ 与配套 libc++/sysroot），那会顺带换掉 `libc++_shared.so` 的 ABI 与 sysroot，
  和项目里其余按旧 SDK 编出来的产物不是一个世界 —— 留作后续单独立项。
  V8 12.4 恰好没碰这两处（它的 `vector.h` 里还写着 "TODO(v8): Use make_unique_for_overwrite
  once we allow C++20"），clang 15 编得动。
- **新增三个补丁**（`scripts/node-ohos/patches/`）：
  - `0003-make-unique-for-overwrite-cxx20.patch` —— 给 V8 13.6 准备的（22.19 用不上，
    留着不亏：它只在 `__OHOS__` 下换成等价的 `new T[]`）。
  - `0004-smallvector-avoid-std-pair.patch` —— `base::SmallVector<std::pair<const PhiOp*,
    const OpIndex>, 16>` 顶上那条 `ASSERT_TRIVIALLY_COPYABLE` 过不去。根因不是 libc++ 而是
    **成员上的 `const`**：带 const 的成员会让隐式拷贝赋值变成删除，`clang` 的
    `__is_trivially_copyable` 就此判 false（实测同一个结构体去掉 const 就为 true；
    gcc 13 判 true，clang 15 与 18 都判 false）。全树只有这一处，就地换成一个平凡的小结构体。
  - `0005-zlib-crc32-clang15-target-attr.patch` —— 新版 zlib 把 ARM CRC 写成
    `target("arch=armv8-a+aes+crc")`（clang 16+ 才认的拼法），clang 15 报
    `unknown architecture … 'target' attribute ignored`，属性一被忽略，`__builtin_arm_crc32b`
    就没有 crc 特性可用，后端直接 `fatal error: Cannot select: intrinsic
    %llvm.aarch64.crc32b`。Node 18 那份 zlib 用的正是老写法 `target("aes,crc")`，
    所以同一套工具链上一直没暴露。
- **`--with-intl=small-icu` → `full-icu`**（最费周折的一处）：small-icu 的 `\p{L}` 是够用的，
  但**缺断词那一档数据**，于是 V8 12.4 的 `new Intl.Segmenter()` 不是抛异常而是**直接段错误**：
  ```
  node -e 'new Intl.Segmenter()'    # rc=139
  ```
  而 kimi-code 的 bundle **顶层**就在用它（`Intl.Segmenter` 出现 12 次），于是
  `kimi --version` 一片 139、连一行输出都没有。排这一步踩的坑：`timeout` 那次误判（见上）
  让最初的"kimi/node 崩了"全成了假象；后来靠"宿主机上同一份 bundle 用官方 node 22.19 跑
  `--version` 正常"把范围锁到我们这侧，再用逐个 `Intl.*` 的探针一刀切到 `Segmenter`。
  代价：ICU 数据 ~3MB → ~30MB，`libnode.so` 72MB(v18) → **136MB**。
- 顺带修的两处工程问题：
  - `build_node.sh` 里重链用的目标名**写死了 `lib/libnode.so.108`**，而那个号跟着
    `NODE_MODULE_VERSION` 走（18→108、22→127、24→137），一升级就找不到 ninja 里的 build 语句
    —— 改成从构建产物现取。`node_relink.py` 的文档串同步。
  - `make.log` 原来是**追加**写，`tail` 出来的是上一次（甚至上一个 node 版本）的 FAILED 段，
    实测因此把 Node 18 遗留的 `-latomic` / `libnode.so.108` 当成 Node 24 的失败查了一轮；
    改成覆盖写。
  - `build_hap.sh` 的"半成品 so"自查用子串匹配 `__wrap_|__real_`，被 C++ mangling 里的
    libc++ 内部类型 `__wrap_iter` 命中（`_ZNSt4__n1…insertENS_11__wrap_iterIPKcEEc`），
    libnode.so 因此被判成半成品、整包打不出来；改成只认**以 `__wrap_`/`__real_` 开头**的符号。
- 设备实测（`3QC0225617000597`，debug-jit 签名）：`node -v` → v22.19.0、`npm -v` → 10.9.3；
  `Intl.Segmenter` 正常（en/zh 都能分词）；`npm i @moonshot-ai/kimi-code` 成功，
  `node dist/main.mjs --version` → **2.1.1**、`--help` → 完整 52 行；
  `npm i dsh-tui` 成功，`node bin/tui.js --version` → **0.2.19**（非 TTY 模式报
  `fetch failed` 是预期的 —— 它要连 127.0.0.1:3080 上的 DSH 服务端）。
- **交互 TUI 一开始是崩的，后来定位并修掉了**。当时的现象是 rc=139、**零输出**（连版本横幅都
  不打），已排除 TERM（xterm/dumb/空）、V8 JIT 与快照（`--jitless`/`--no-node-snapshot`/`--no-lazy`）、
  ICU（21 个 `Intl.*`/`TextDecoder` 用例全过，含 gbk/shift_jis）、配置缺失（补最小 `config.toml`
  后照崩）、`-Wl,-Bsymbolic-functions`；node 自己的 `--report-on-fatalerror` 也来不及产出报告。
  根因有两个，都不在崩溃现场本身：
  1. **rc=139 —— `process.title` 触发的一次跨堆 memset**。libuv 的 `uv_setup_args()`
     （`deps/uv/src/unix/proctitle.c`）把 `process.title` 的可写容量算成
     `argv[argc-1]+strlen+1-argv[0]`，前提是 **argv 各字符串在内存里首尾相接**；而我们用
     `std::vector<std::string>` 拼 argv、每个字符串各自一次堆分配，那个差值就成了两个无关堆地址
     之差（可以几 MB），于是 `uv_set_process_title()` 里
     `memcpy(pt->str,title,len); memset(pt->str+len,0,cap-len)` 变成**以 argv[0]（"node"，一个
     5 字节堆块）为起点、跨越整个堆的清零**，直到撞上未映射页才 SIGSEGV。修：
     `scripts/node-ohos/bsh_node_entry.cc` 把 argv 拼进**一整块连续内存**。这个 bug 的指纹很特别
     —— 崩点五花八门、崩在 musl 的 memcpy/memset 里、多线程同时崩，而 `--max-old-space-size=64`
     时清零能在已映射区里跑完，就只表现为**干净的 OOM**（rc=134）而不是段错误。
     设备实测：`process.title='kimi-code'` 由 rc=139 → rc=0；超长 title 被安全截断到 57 字节
     （= 参数块字节数 − 1，正好印证 cap 机制）。
  2. **rc=159 —— 沙箱对 `io_uring_setup`(425) 判 `SECCOMP_RET_TRAP`，投出的 SIGSYS 没人接**。
     libuv 初始化 io_uring 后端时裸调 `syscall(__NR_io_uring_setup, …)`，而 procmgr 那个把
     TRAP 降级成 ENOSYS 的 `OnSigSys` **在 node 进程里被 V8 顶掉了**：
     `v8::base::debug::EnableInProcessStackDumping()` 用
     `sa_flags = SA_RESETHAND | SA_SIGINFO | SA_ONSTACK` 装 SIGSYS —— **带 SA_RESETHAND**，
     于是第一次之后 SIGSYS 复位成 `SIG_DFL`，再撞一次就按默认动作 core dump 打死。修：
     `shim/fs_shim.c` 的 `syscall()` 包装里让 425 直接判 ENOSYS（libuv 那边是
     `ringfd = uv__io_uring_setup(…); if (ringfd == -1) return;`，干净回退到 epoll/线程池）——
     **从源头不产生 SIGSYS，不再依赖任何 handler 是否还在**。
     这个号码是靠**内核日志**找到的（`hdc shell "hilog -t kmsg"` 里的 `hmsecpt`/`coredump`：
     `sig=0 … syscall=425 … code=0x30000`）—— 因为 `ptrace` 在沙箱里是 `EACCES`（不是 KILL），
     而逐号探针（参数全 0）测不出任何被杀掉的号（规则不按号走）。设备实测：修前 TUI 3/3 rc=159、
     内核 hmsecpt 每次探测一条；修后 3/3 正常渲染（1789 字节 ANSI），hmsecpt 与 coredump 均归零。
  细节与排除清单见 README 的"kimi-code 交互 TUI 的两个崩溃"一节。
- **`link()` 加复制兜底**：鸿蒙只在 **debug 应用**下给 `link(2)`，release 构建（本项目自测用的
  就是 release 模式 + debug-jit 签名）一律 `EACCES`。而硬链接在工具链里用得不少：node 的原子写
  就是 `link(tmp,final)+unlink(tmp)`，npm/git 也有硬链接优化 —— 实测 `@deepseek-ai/dsh` 的会话
  持久化就死在这（`EACCES … link '…session.v4.jsonl.zstd.<hash>.tmp' -> '…session.v4.jsonl.zstd'`）。
  `shim/fs_shim.c` 新增 `link_or_copy()`：**只在真 `linkat` 失败时**才退化成复制（源是普通文件就
  复制内容+模式；源是符号链接就 `readlink`+`symlinkat` 连**链接本身**复制，符合 link(2) 语义）。
  debug 构建/普通环境下列都走不到，行为一字不变。设备实测：`fs.linkSync` 两边都在、内容一致、
  `st_nlink=1`（走了兜底），硬链接软链得到的仍是软链。
- **`node-headers` 包一并重出并传服务器**：升 node 会换掉 `NODE_MODULE_VERSION`
  （18 → 115、22 → 127），而 pkg 里那份 headers 还是 18.20.1 的，设备侧 node-gyp 编出来的
  `.node` 会因 ABI 不匹配加载失败。做法是取 nodejs.org 的 `node-v22.19.0-headers.tar.gz`，
  把 `include/` 放进 `node-headers/` 打包成 `node-headers.tar.zst`（2910 个成员，
  574906 字节，sha256 `7d63f3a6…`），传服务器并改 `index.json` 的 version/size/sha256
  （旧索引已备份）。实测：`pkg info node-headers` → 22.19.0；装上后 headers 里的
  `node_module_version: 127` 与设备 `process.versions.modules = 127` 一致；
  `npm install --build-from-source bufferutil` 在设备上编出 `bufferutil.node`（15256 字节）
  并成功 `require` + 调用 —— 当初那条现场编译链在 Node 22 下完整恢复。

### 瘦身：去掉科学栈

numpy / matplotlib / Pillow / contourpy / kiwisolver 从包里拿掉（约 **41 MB**：28 个平铺 C
扩展 + 6 个 tar），**HAP 210.6 MB → 170.7 MB**。它们只对"在设备上跑 matplotlib"有意义。

踩到的坑值得记：删包时必须同时删 `initResource()` 里那条解包，而且 numpy 那条是 `fail +=`
**不是** `warning +=` —— tar 没了却留着它，`fail` 就永远非 0、`.res-unpacked` 标记永远写不上，
于是**每次会话都全量重解一遍**。原地留了说明（为什么拿掉、怎么加回来、以及 `numpy.tar` 里那个
`sitecustomize.py` 必须一起加回来）。

没动的公共依赖：`libpng16/libjpeg/libfreetype/libfontconfig/libexpat` 是 **Qt 与 weston-terminal**
的依赖（matplotlib/PIL 只是搭车），删了会把终端窗口字体和 Qt 应用一起搞坏。

### 发布与签名

- `sign_hap.py` 支持按名字选 `signingConfig`（不传仍取第一条 = DevEco debug 材料，旧调用不受影响）。
- 新增 `scripts/build_release.sh`。**App Pack 的重打顺序是踩出来的**：hvigor 打出的 `.app` 内层 hap
  未签名，只签外层会 `Verify Hap failed, signature not found`，所以必须是"先签 hap → 用它重打
  `.app` → 再签 `.app`"，且重打时 `--replace-pack-info` 必须显式给 **false**（默认 true 会重压 hap
  并丢签名块）。另带 bundleName/profile 一致性检查与 p7b `not-after` 有效期检查。
- 修 `build_release.sh` 在 `pipefail` 下的误杀：profile 里字段不一定都有（debug 类型没有
  `app-distribution-type`），空 `grep` 会让管道失败、`set -e` 当场退出；产物名也带上配置名，
  release 与 debug-jit 不再互相覆盖。
- 新增 `scripts/build_test.sh` = 设备自测固定入口（release 构建模式 + `debug-jit` 签名 + 部署 + 拉起）。
  顺带把签名对沙箱的影响定死了：**同一个 guest，debug 构建 30 过 / 0 挂，release 构建 29 过 / 1 挂**，
  差的正是硬链接那一档（非 debug 应用不给 `link(2)`）；真 `release` signingConfig 签的包 hdc 直接
  装不上（`code:9568322 signature verification failed due to not trusted app source`）。
- **图标**：源 SVG 与 `scripts/make_icon.sh` 入库（原来是一次性命令转出来的，源文件和脚本都没留）；
  底板改成满幅正方形、圆角交给系统遮罩 —— 前景自带 `rx=56` 与系统遮罩弧度不同，缝里会露出
  `background.png`。`foreground.png` 12304 → 6703 字节。

### 自检脚本自己的五个 bug

起因是全量回归跑出 **PASS=54 FAIL=7**，其中 5 个是**脚本没跟上代码**，全是"不报错、只是安静地
不干活"那类：

- 第 8 节查 `$HOME/testprogs`，而 testprogs 早搬到资源根 → 一直报"目录不存在"并**静默跳过整档
  ABI 组合**，从没在设备上真跑过；
- 同节的判据 `grep 'total='` —— 汇总行格式是 `blocks=N pass=N fail=N skip=N`，`total=` 这个字段
  根本不存在，于是每个组合都被判"未跑完"；
- clang 缺失记 `[FAIL]` —— clang/lld 已移出 HAP（改由 pkg 装），"没装"不是编译链坏了，改 `[INFO] 跳过`；
- `wait_autorun.sh` 只认旧版结束标记，**永远等不到**；
- `build_weston_terminal.sh` 里 `sed '#define BSH_SYSROOT'` 取资源根，而该宏已改名
  `BSH_SYSROOT_DEFAULT` → 取不到值直接退出，**脚本是坏的**。

修完 **PASS=59 FAIL=2**（剩下两个是已记录的 box64 静态档崩在 `[signal]`）。

### 顺带记下的两组数据

**qemu 下编 C++ 三方库的代价**（16 核 WSL2，两边都是 OHOS LLVM 15.0.4、同一源码/参数/目标）：

| 库 | 宿主交叉编译 | qemu-aarch64 下 | 倍率 |
|---|---|---|---|
| tinyxml2（1 个小 TU） | 0.59s | 9.29s | 15.7× |
| jsoncpp（3 个大 TU） | 4.30s | 62.85s | 14.6× |
| fmt（2 个模板重的 TU） | 2.92s | 48.00s | 16.5× |
| Catch2（2 万行单 TU） | 10.47s | 125.53s | 12.0× |
| **合计** | **18.3s** | **245.7s** | **13.5×（差 ≈3min47s）** |

踩坑记录：**别用 qemu-i386 测这套** —— 那个交叉工具链是 i386 宿主二进制，宿主内核本就原生跑
i386，而 qemu-user 会把 guest 的 `execve` 转给宿主内核，真正干活的 `cc1plus` 压根没进模拟器
（Catch2 单 TU 只"慢" 1%，`/proc/<pid>/exe` 一看就露馅）。

**设备端 testprogs 逐组合**（release + debug-jit）：`aarch64-musl-dynamic 29/1`（硬链接，release
应用的既定限制）、`aarch64-musl-static 22/7`（静态 guest 吃不到 LD_PRELOAD shim，已知不支持）、
`x86_64-{musl,glibc}-dynamic` 与 box64 显式档各有已知失败项；宿主侧 8 组合 0 FAIL。

### 两个工具包：`hdc` 与 `haptools`

- **`hdc` 单独成包**：原来它跟签名材料一起塞在 `rawfile` 的 `bshsign-tools.tar` 里，而那份
  631 MB 的大头是**预编译的 dev HAP** —— dev 改成设备侧自己构建之后就不需要了，剩下的
  hdc 本体 + `.so` 闭包只有几 MB。三条约束照旧：不能有软链（pkg 的 `bsh_tar.c` 只认普通文件/目录）、
  只收 SONAME 形态的真文件、不带 `ld-linux-aarch64.so.1` 与 `libc.so.6`（由应用 bundle 里那份
  打过"不做文件映射"补丁的 glibc 提供）。
- **`haptools`**：hvigor 打 HAP 走的是 `java -jar hap-sign-tool.jar sign-app …` 与
  `java -jar app_packing_tool.jar --mode hap …`，而沙箱没有 JVM。这两个仓库都自带**同源的 C++
  实现**，编成静态 musl 可执行文件后不需要 jit 也能跑。另加一个 `java` 转发壳（**动态** musl ——
  本项目的 exec 委托/tty/软链 shim 只走 `LD_PRELOAD` 符号插入，静态 guest 吃不到）：
  收到 `-jar <已知 jar>` 就把 `-jar` 之后的参数 `execv` 给同目录的原生工具。
  打包工具只在**首参缺失或以 `-` 开头**时补一个 `pack` —— 上游 `commandMap_` 是
  `help`/`pack`/`unpack`，调用者自己写了真子命令就透传，否则 `help` 会被改写成 `pack help`。
  两个 C++ 工具统一 strip（原型只 strip 了其中一个，签名工具因此带 11 MB 调试符号）。
  验证：三个产物的 readelf、qemu 下用 debug-jit 证书对最小 HAP 跑通 `sign-app` → `verify-app`、
  javawrap 四条转发路径实测。

### `bshutil rawfile`：看、取 hap 里打包的资源

- `bshutil rawfile list` 递归列出全部 rawfile（路径 + 字节数 + 合计），
  `bshutil rawfile get <名> <目标>` 把其中一个拷到磁盘。
- 这两条只能在**服务端**实现：rawfile 的入口 `NativeResourceManager` 是 Ability 从 ArkTS 侧
  初始化进来的**进程级单例**，命令 so 在子进程里够不着。访问口收在 `common/bsh_rawfile.{h,cpp}`，
  `shell.cpp` 的 `UnpackRes`/`CopyRawFile` 与这两个子命令走同一份实现。
- `list` 用 `OpenRawDir` 递归 + `IsRawDir` 分辨目录；`GetRawFileName` 返回的是"相对根"还是
  "相对本目录"在实现间不一致，所以拼路径时归一了一次，两种语义都能走通。
- **相对路径按谁的 cwd 解析**是这里的唯一难点：服务端跑在主进程里，它的 cwd 是应用启动目录，
  跟用户在终端里 `cd` 到哪没关系。所以协议加了一行 `CWD <调用方当前目录>`（照抄 `bsh_client.c`
  的做法），客户端 `getcwd` 失败就整行不写、相对路径会被明确拒掉而不是悄悄落到错的地方。
- 顺带修正 `ParseExec` 上一句错注释：值里不能有换行，但**空白是安全的**（解析取"第一个空格之后
  的全部"），带空格的路径本来就能传。

### 首屏说明：`readme.py` / `licenses.py`

横幅从两句静态文字改成指向 `python readme.py`，那两份脚本落到**家目录**（会话起来就在这儿）。
`readme.py` 分章节带 ANSI 颜色，两个开关约定：**输出不是终端就自动关**（重定向时不会把转义序列
写进文件）、`NO_COLOR` 强制关。`licenses.py` 从空壳写成完整清单，分「宽松 / copyleft / pkg 按需
下载 / 默认不构建」四组 —— 应用里既用了 MIT/BSD，也用了 GPL/LGPL（qemu 静态、glibc/glib/glibintl
动态），分发时必须带上许可声明；每条都对着仓库里实际的 LICENSE 文件核过，并且**刻意不写版本号**
（许可不随版本变，版本列只会腐烂）。

修掉一个会上线崩的 bug：`sgr()` 里 `";".join(codes)` 不接受 int，而调用处写的是 `sgr(0)`
→ **真实终端下 `python readme.py` 直接 TypeError**。没被发现是因为 autorun 的输出是重定向的、
`isatty()` 为假，颜色分支压根没执行 —— 补了一个"把 stdout 换成 `isatty()=True` 的假对象"的
测试才照出来。

顺带探到两个环境事实：**多行 `python -c '…'` 在这套 shell 里传不过去**（argv 走行式协议，
值里不能有换行）；**guest 里开不出 pty**（`pty.openpty()` → `OSError: out of pty devices`）。

### 版本号

`0.6.0 → 0.7.0`（versionCode `1000003 → 1000004`）。

---

## 0.6.0 · 2026-10-02

从 0.5.0 到这里跨了 09-28 ~ 10-02。主线是**命令 so 家族扩容**（node / OpenJDK / zip）与
**guest 运行时自编**（glibc、musl 各一份"不做文件映射"的加载器），中间把 guest 与命令 so 的沙箱
适配收进同一个 shim 家族；收尾是**设备内自举** —— 在 BetterSH 里构建、签名、安装、打开它自己。

### 命令 so 又添三员：node / OpenJDK / zip

- **Node.js 18.20.1**（V8 与 OHOS 官方 jsvm 同版本）以 `--shared` 编出 libnode.so、再重链补 C 入口
  与 exec 委托，不 exec、不落地可执行文件，走 toybox/python/vim 同一条路。构建链三个坑：gyp 把宿主
  工具链也交叉掉（torque 之类"先在宿主上跑一遍"的工具被编成 aarch64、链完立刻被内核拒）→ 显式给
  `CC_host/CXX_host`，用 SDK 自带那份 clang（15 能过 V8 10.2；system clang 18 撞
  `-Wenum-constexpr-conversion`）；gyp 在交叉构建下给 1012 个产物声明了两次路径（ninja 直接拒载）
  → `ninja_dedup.py` 只留 `.host` 那份；node.gyp 无条件 `-latomic` 而 OHOS sysroot 没有 → 从
  aarch64 musl 借一份放进私有 `-L`。两个上游补丁：V8 拿可执行内存要过鸿蒙 JitFort ACL，在
  mmap/mprotect(PROT_EXEC) 前后夹 `prctl('jit', …)`（判据必须用编译器内建 `__linux__` ——
  `V8_OS_LINUX` 在那一行之前还没 include、会静默取 0，整段补丁变空操作）；`GetExecPath()` 在
  `__OHOS__` 下改用 argv[0]（我们跑的是 dlopen 进宿主进程的 so，内核眼里的 `/proc/self/exe` 是
  宿主 appspawn，npm 的 lifecycle 起 node 必失败）。
- **OpenJDK 21**（对齐 jdk21u 21.0.5）的形态被两条约束定死：沙箱没有真 exec，`bin/java` 起不来、
  只能 dlopen libjvm.so；而 `$HOME` 是 noexec，.so 放那儿 dlopen 会被拒。于是分两段交付 —— 26 个
  .so 平铺进 bundle libs（随 HAP），`lib/modules`/`conf/`/tzdb.dat 等数据由应用解到 `$HOME/jdk21`。
  入口不走 `JLI_Launch`（它在 musl 上会先摆好 LD_LIBRARY_PATH 再 execv 自己重跑一遍），改自己走
  JNI Invocation API、把 `bin/java` 的语义重做一个等价子集。三处 OHOS 接头：接 OHOS 的 sigchain
  （鸿蒙 DFX 崩溃处理器优先级高于 sigaction，不接会在 HotSpot 装上 handler 之前被截获 init 期的
  SIGSEGV，进程直接被杀、只报一句 `-117`）；退出码用 HotSpot 给嵌入者的 `exit` 钩子接回来（JVM
  内部 exit() 会丢成 0，而预编的 libjvm.so 在符号表里抢不过更早加载的 libc）；
  `SUN_BOOT_LIBRARY_PATH`/`java.library.path` 都要指 bundle libs（否则 Unable to load jimage
  library）。`java`/`javac`/`jar` 共用一个 libjdk.so，后两个只是把主类换成 javac/jar 的 Main；
  真机验收 16/16（javac 语法错=1、System.exit(7)=7、无主类=1、非法 VM 选项=1）。
- **zip/unzip** 用 Info-ZIP（toybox 没有这两个 applet；纯 C、自带 deflate/inflate、BSD 风格许可）。
  两个独立 so —— zip 与 unzip 是两套互不相干的代码库，硬合成只会撞符号；so 名带 `cmd` 后缀是为躲
  libzip.so（那个名字被 JDK 的 java.util.zip 原生库占着）。坑：OHOS 的 ctype.h 把 `isprint` 定义成
  **宏**（恒按 ASCII 判），unzip 据此误判"这个 libc 的 isprint 是 locale 感知的"，于是 `fnfilter()`
  把非 ASCII 全换成 `?` —— 宏是编译期内联的、加 shim 遮蔽不了，只能 `-DNO_WORKING_ISPRINT`。真机
  自检 PASS=55 FAIL=0（其中 zip/unzip 22 条）：打包→列表→解包逐字节一致、与
  `python3 -m zipfile` 双向交叉验证、中文名 UTF-8 往返、退出码 9/10/12 精确透传。明确不做：
  zip64/多卷/加密/`zip -T`。

### guest 运行时自编：两份"不做文件映射"的加载器

- 沙箱那道闸拦的不只是 execve，还有 **file-backed 的可执行映射**：动态 glibc guest 一启动就弹
  "是否运行 xxx"确认框（拒绝后 `failed to map segment from shared object`），而 glibc 的 ld.so
  干的正是 `mmap(…, PROT_EXEC, MAP_FIXED, fd, 0)`；那个确认框还会把**整个应用进程**冻住。解法与
  elfloader 一致：匿名 `PROT_NONE` 预留 → `pread` 读入 → `mprotect` 给最终权限，全程没有带 fd 的
  mmap（补丁 0001）；补丁 0002 把 rseq 注册变 no-op（沙箱对 `rseq(293)` 直接 SIGSYS）。编 glibc
  只能用宿主的 `aarch64-linux-gnu-gcc 13`：OHOS clang 15/18 都编不了 glibc 2.39（configure 要求
  `__GNUC__>=6`、`bits/floatn-common.h` 无条件要 `_Float32/_Float64`）。
- musl 那边是同一个病：aarch64 musl 动态 guest 的 dlopen / DT_NEEDED 必然失败，而 glibc 动态 guest
  的 dlopen 是好的。改 `ldso/dynlink.c` 的 `map_library()` 走同一套匿名装载（musl 的 libc.so 本身
  就是它的动态链接器，改动点集中在这一个文件）。验证：strace 前后带 fd 的 mmap **2 → 0**、
  `pread64` 0 → 3；设备侧 dlopen 由 FAIL 转 PASS。取舍：用 release 1.2.2（比工具链那份少
  `pthread_getname_np`/`qsort_r` 两个动态符号，仓库内 guest 源码没用到；不换 git 快照是为了保住
  "release + 钉 sha256"）。
- **两份 loader 的门都写反了**：HarmonyOS 的 W^X 只在 `prctl(0x6a6974 /* 'jit' */, 0, 0)` —— 值
  **0** 才是开门 —— 而两份补丁里都写成了 `(…, 0, 1)`，等于从没开过门。glibc 侧症状是
  `cannot change memory protections`（设备侧动态 hdc 起不来 rc=127）；musl 侧更隐蔽：任何运行期
  加载的 .so 都在 `set_prot()` 失败，而 musl 的 `load_preload()` 对预载失败是**静默跳过**（不看
  返回值、不打印），表现为"明明设了 LD_PRELOAD 却完全没生效"。修完两条 aarch64 动态 guest 的
  `/proc/self/exe` 自测从 musl 0/8 变成 8/8。
- musl 1.2.2 还缺一批"1.2.4 起才有、而 Qt/libc++ 会引用"的符号（`backtrace*`、
  `pthread_getname_np/setname_np`、`renameat2`、`pthread_cond_clockwait`、`arc4random*`、
  `qsort_r`）—— 少了就是链接期 `symbol not found`；同一份 compat shim 顺带装了 guest 侧崩溃报告器
  （用 dladdr 说出 pc/lr 落在哪个 .so 的哪个偏移）。另外补 DT_RELR：OHOS 系统库的相对重定位全在
  RELR 表里，而 1.2.2 的 loader 只认 DT_REL/DT_RELA，`.init_array` 的构造函数指针没被重定位、
  一调用就跳野地址（现象是 `pc == fault == 0xa0e4` 这种"模块内偏移当运行期地址"的小地址，崩在
  `do_init_fini` 的 blr）。坑：`1 << DT_RELR` 里 1 是 int，`1<<36` 是 UB、GCC 折成 0、整个分支被当
  死代码删掉，症状极像"补丁没生效"，必须写 `1UL`。
- glibc 补丁 0003：动态 glibc guest 一进 `pthread_create` 就整只被 SIGSYS 杀掉
  （`rc=159=128+31`）—— 沙箱的 seccomp 对没放行的号是**直接 SIGSYS**、不是返回 ENOSYS，glibc 2.39
  期待的"ENOSYS → 回退 clone"永远不发生，改成让 `__clone3` 一进来就返回 `-1/ENOSYS`。★真正的改点
  是 `sysdeps/unix/sysv/linux/aarch64/clone3.S`，**不是**同目录那个 `/* An empty placeholder. */`
  的 clone3.c —— arch sysdep 目录优先级更高，它根本不参与编译，只改 .c 会"改了却毫无变化"。
  已知边界：静态链接的 aarch64-glibc 组合仍会发 clone3（它嵌的是宿主交叉 gcc 自带的 glibc）。
- guest 运行时统一从 **bundle libs** 取（删掉"guest 同目录"与 `$HOME/guests` 两个来源）：运行时
  必须在**签名包内**，否则"文件映射成可执行"过不了那道闸；既然只有这一个合法去处，多摆几个搜索
  路径只会带来"同名库版本不一致"的隐患。`GLIBC_TUNABLES=glibc.pthread.rseq=0` 不能删 —— 自编
  运行时不需要它，但静态 glibc guest 与自带 libc 的动态 guest 仍靠它躲沙箱对 rseq 的 SIGSYS。

### 8 种 ABI 的验收矩阵：先在本地跑通，再上设备

- 设备那一圈很贵（重打 HAP ~1 分钟 + 部署 ~1 分钟 + 自检），而**测试程序本身**的毛病（写错的断言、
  越界、把返回值当 errno……）不该拿设备去撞 → `run_testprogs_host.sh` 在开发机上把 8 个组合跑成
  0 FAIL（x86_64 原生、aarch64 走 qemu-user）。三个必须知道的点：x86_64 musl 两只的 PT_INTERP
  本机没有（也不往 /lib 塞东西）→ 在本目录重新链一份、把解释器指到工具链绝对路径；aarch64 必须用
  `QEMU_LD_PREFIX` 而不是命令行 `-L`（嵌套 exec 是内核按 binfmt 重新拉起 qemu，命令行参数传不下去，
  用 -L 会让 exec 那几条全报找不到解释器）；用 `script(1)` 给一路真 pty（否则 0/1/2 全是
  /dev/null + 日志文件，"会话是不是终端"那项没有可验对象、只能 SKIP —— 那是脚本自己造成的空档）。
  两个当场踩到的坑：`scripts/env.sh` 自带 `set -e`，而测试程序正常退出码是 42 → 第一条跑完脚本就
  以 42"成功"退出、8 个组合只跑了 1 个还不显异常（source 完立刻 `set +e`）；产物过期（源码比产物新
  要重编，否则拿旧二进制当新结论）。
- 用例扩到 32 块，三条设计约束（改测试时别破坏）：① **程序不知道自己在哪执行**，判定只下在
  "能不能做到"这类与执行者无关的事上，与环境有关的**事实**只照原样打印（如
  `FACT guest-file-exec-mappings=<n>`），判不判由外层决定 —— 早先试过用环境变量告诉程序"你在本地"，
  那是让程序先知道答案再判卷，同一个现象在三种环境下会给出三种结论；② **有副作用的验证一律放进
  fork 的子进程**（真实案例：glibc 动态那只在 pthread 被 SIGSYS 打死，rc=159 什么都没留下）；
  ③ **绝不用"探测已打印"换一个 PASS**，没有可验对象就记 `[SKIP]`。
- `autorun-all.sh`（786 行）入库：日常那版精简自检启动时自动跑，这一份**不自动跑**、要跑自己在
  终端里 `sh $HOME/autorun-all.sh`。它是整套"无人值守验证"的方法论落点（很多坑是靠它抓到的），
  之前一直是未跟踪的本地文件、丢了就没了。

### shim 家族：软链 / 软 tty / 假 pts / exec 委托

- guest 是"别人的二进制、只能预载"（LD_PRELOAD），命令 so 侧则是"链接期编进去"，所以把这四件事
  做成同一批源码、编成同一个 .so：`fs_shim.c` 做符号链接的用户态模拟 —— 沙箱拒绝 `symlink(2)`
  （三层、所有可写目录 errno=13，硬链接反而可以），于是 `foo -> /target` 表示成普通文件
  `foo.BSH_SYMLINK`（内容就是目标串），把 libc 里碰路径的入口拦下来翻译；`tty_shim.c` 软 tty
  （termios/winsize 的真相在主进程、经 control socket 读写，内部兜底一律走裸 syscall）；
  `pty_shim.c` 假 pts（`open("/dev/ptmx")` → socketpair，沙箱三层都拿不到真 ptmx）；
  `exec_shim.c` exec 委托。`open` 两个模块都要接管，一个 .so 只能一份定义 → 各让一步
  （`-DBSH_SHIM_MERGED_OPEN`）、由 `open_shim.c` 提供唯一入口，且**先问 tty 钩子再做软链解析**
  （`/dev/tty` 在沙箱里根本打不开，先让 tty 接住才不会掉进 fs 那套"路径不存在"的判断）。
- **命令 so 不能用 `RTLD_NEXT`**：它是主进程 dlopen 进来的、排在全局搜索序**末尾**，"下一个"之后
  没有对象，`dlsym` 返回 NULL、每个入口都退化成 ENOSYS（实测把 fs_shim 原样编进 libtoybox 后每个
  文件操作都报 `Function not implemented`）。改用 `-Wl,--wrap=`：链接期把该 so 自己对符号的引用改
  写成 `__wrap_<名>`，真实现是链接器生成的 `__real_<名>`，与搜索序无关。规矩是**所有命令 so 都链
  同一套 shim、清单只有一份**（`scripts/shim-wrap-flags.sh`）—— 一个没人定义的 `--wrap` 不是静默
  失效而是 **dlopen 直接失败**，而 glibc 专属名字（`open64`/`…_chk`/`__xstat`）不能 wrap（musl
  分支没定义它们，libvim.so 上会留 11 个未定义）。判据必须是
  `nm -D -u <so> | grep -E '__wrap_|__real_'` **都为空**：`build_hap.sh` 打包前统一查这一条，是被
  自己坑出来的 —— 改脚本时缩进没对上，zip/unzip/sshcore/python 四个产物的清单根本没进链接行，
  编译期零提示，只有 dlopen 时才报 `__real_lstat: symbol not found`。这一套也让 `ln -s` 在命令里
  能用了（`toybox ln -s` 之前失败），`ls --color=auto`、node/npm 的彩色输出、clang 的彩色诊断也
  认得出终端了（`isatty` 被接管）。
- **`/proc/self/exe` 替身**：guest 由 elfloader 在**宿主进程**里装载，内核给的 `/proc/self/exe` 是
  宿主 appspawn，凡是"读它再 exec 自己"的程序在沙箱里都活不下来。procmgr 把 guest 的真实绝对路径
  放进 `BSH_GUEST_EXE`，fs_shim 加一层虚拟路径：readlink 直接返回它，stat/open/openat/access/
  realpath 在 `resolve_simlinks()` 顶部把 `/proc/self/exe`（含子路径）换成它；`lstat` 与
  `unlink/rename/link` 刻意**不换** —— 真 procfs 对这条魔法链接给的形状本来就对，换掉反而失真
  （第一版合成过一份 stat，dev/ino 变成本体文件的、和真 Linux 不一致，撤了），也顺带避免了
  "unlink /proc/self/exe 把 guest 自己的镜像删掉"。排查开关 `BSH_SHIM_TRACE=1` 定下两个坑：替身
  第一版返回了指向局部数组的指针（use-after-return），glibc 下侥幸能用、musl 下栈一被覆盖就"不
  匹配"（症状是"glibc guest 全过、musl guest 一条不生效"）。验证：两只 aarch64 动态 guest 的
  `/proc/self/exe` 自测各 8/8。
- 命令 so 侧另有两处"看不见 / 认错平台"：node 看不见 shim 的模拟软链 —— libuv 的 `statx` 直发
  syscall（绕过 libc 的 stat/lstat）、libc 的 `scandir` 又绕过我们 wrap 的 `readdir`，于是 node 侧
  `existsSync` 为真、`lstat` 却 ENOENT，hvigor 报 "dependency that is not installed"；修法是
  fs_shim 补 `__wrap_syscall`（statx→ENOSYS，逼 libuv 走回退）与 `scandir`。另一处是 `uname`：
  设备上 `uname(2)` 的 sysname 就是 "HarmonyOS"，任何"看 uname 判宿主 OS"的工具都认错 —— hvigor
  的 `isLinux()`（= node 的 `os.type()`）为假就转而去找 `.dylib`，`@CompileResource` 死在
  "Failed to load the library …dylib"；新增 `os_shim.c` 的 `__wrap_uname` 只把 sysname 改成
  "Linux"（release/version/machine 原样保留 —— 那些是这台机器的实情，改了反而误导），
  `BSH_UNAME_REAL=1` 可看真值。

### procmgr 与 exec 委托：环境、退出码、裸名与 #! 脚本

- 委托出来的进程是 **procmgr** fork 的，环境本来只继承 procmgr 自己那份 → `FOO=1 cmd`、
  `export FOO=1; cmd` 的变量到不了子进程（查 shim 为什么没生效时 `BSH_TTY_STDIO=1 ./guest` 一直
  不生效，卡了半天才发现就是这条）。客户端补发 `ENV k=v` 行（服务端早就有解析与 ApplyEnv，只是
  客户端没发）；`bsh_exec.c` 的 `__wrap_execve` 原来写着 `(void)envp;` —— execve 第三个参数就是
  调用方要的那份环境（`FOO=1 cmd` 的变量正在它里面，不在 mksh 自己的 environ 里）。上限 1024 条 /
  单条 4096 字节。
- guest 调 libc `exit()` 时退出码整段丢成 0（`sh -c 'exit 7'` → 0，而 `os._exit(7)` → 7）：命令 so
  跑在 procmgr fork 出来的子进程里，而宿主主进程在 fork 之前就注册了一堆 atexit（ArkTS/NAPI 的
  收尾），guest 一调 exit(n) 这些 handler 就跑起来、最后以 0 收场。加 `__wrap_exit`（先
  `fflush(NULL)` 再 `_Exit(code)` —— 直接 `_Exit` 会丢掉还在 stdio 缓冲里的输出）。副作用提醒：
  退出码本来就非 0 的命令（如 dropbear 的 ssh 无参数时打 usage 并 exit(1)）修好后会先"看起来失败"
  一次。
- 裸名优先走命令表：`resolve_target` 原来先 `path_search`，而它只认 ELF、必然跳过
  `$HOME/.applets/<名字>` 那些空占位文件，于是命中 PATH 上的同名真实文件（`/bin/sh`、
  `/data/service/hnp/bin/fastfetch`），最后由 elfloader 去装系统的动态 musl 二进制并报 rc=127；
  改成先看 `.applets/<名字>` 在不在。procmgr 侧则是：路径落在系统 bin 目录且 basename 命中命令表
  时改按命令表起（起因是 node 的 `child_process` 默认起 `/bin/sh -c`，沙箱里 `/bin` 是系统 toybox
  的符号链接林，node 侧只报 spawn ENOENT）。认不得 basename 就照原路走。
- hnp 装的应用（`/data/service/hnp/`）是系统装好应用的公有挂载点，允许直接 exec、自带解释器与依赖
  → 该树下的真 ELF 优先直接 `execve`（范围取整棵树：hnp 的 bin 里是包装脚本，真身与它的库在同级的
  `<pkg>.org/` 里）。`#!` 脚本也不再被当"不能跑的文件"：按 `#!` 里的解释器名查命令表
  （`#!/bin/sh` → sh → libmksh.so），argv 重组成 `[解释器名, (解释器参数,) 脚本路径, 原参数…]`。
  设备实测 hnp 那套的 java/javac、node/npm、fastfetch、python3.12 全部通过；顺带给命令表补了
  `readlink`/`dirname`/`basename`/`realpath`/`printf`（hnp 的包装脚本要用
  `bindir=$(dirname $(readlink -f $0))`）。

### 目录布局分两层：BSH_SYSROOT 与 $HOME

- 原来 `$HOME` 就是应用数据目录 `files/`，"运行时资源"与"用户的家"混在同一层（`ls` 一眼二十来项）。
  现在分成两层、路径只在 `common/bsh_paths.h` 一处定义：`files/` 是资源根 `BSH_SYSROOT`
  （initResource 解包落点，三个 unix socket 与 `bsh-ws.bin` 也留这层 —— 它们是应用基础设施），
  `files/home/` 才是 `$HOME`（只放用户的东西：`.applets/`、`.ssh/`、`bettersh.conf`、日志、样张），
  资源类环境变量（`VIMRUNTIME`/`PYTHONHOME`/`XKB_CONFIG_ROOT`/`FONTCONFIG_*`…）指向资源根。
- 两处踩到的：必须先 `mkdir($HOME)` 再 `chdir` —— `$HOME` 是新目录、而建它的是它后面的
  initResource，原来能用只是碰巧 `files/` 已存在，否则 chdir 静默失败、cwd 停在旧目录；权限上资源根
  保留 0755，否则 hdc 的 shell 用户读不了日志（宿主 `wait_autorun.sh` 就是这么读的）。那个头文件里
  还列了"另有一份副本、改布局必须同步"的十来个地方：`build_llvm.sh` 编进 so 的
  `-resource-dir`/`--sysroot`（没有环境变量后门，要重编）、fonts.tar 里写死的 `<dir>`（是文件内容，
  `FONTCONFIG_FILE` 改不了它，要重打 tar）、box64 的 sock 默认值、`wait_autorun.sh` 的路径……

### bsh 自带行编辑器

- bsh 原来只有"行尾打字 + 退格"：方向键被当控制字符静默丢掉（连"收到过 ESC"都看不出来）、TAB 被当
  普通字符塞进行里、`$VAR` 原样打印。补齐三件事，拆成三个**纯逻辑 + 依赖注入**因而能宿主单测的
  模块：`lineedit.cpp`（ESC/CSI 状态机、UTF-8 续字节攒齐才入行、宽字符按显示列数回退、
  Ctrl+A/E/U/K/W/C）；`lexer.cpp`（分词 + `$NAME`/`${NAME}`/`$?` 展开，**和引号/转义同一遍扫描**
  —— "单引号内不展开""未定义展开成空串"都取决于当前在哪种引号里、上一个是不是转义，拆成两遍就没
  法判）；`complete.cpp`（TAB 补全：命令位补内建 + `.applets`，唯一命中直接补完、多候选先补公共
  前缀、再按一次 TAB 才列清单）。这几条只有**交互终端**才走得到：前台有子进程时本循环不 poll，
  字节归 vim/mksh。
- 判据：宿主单测 70 条断言全过；设备侧（uitest 注入按键，判据是文件系统副作用、不看屏幕）该轮
  autorun 9/9。坑：`ESC[3~`（Delete）的参数是**字符** `'3'`，早先写成 `param == 3`
  （0x33 vs 3）永远不成立 —— 是单测抓出来的，不是设备上先暴露。刻意不做（写进已知限制）：
  `!!`/`!n`/`^old^new`、glob、`$(…)`/反引号、`~` 展开；历史只在内存里、重开即清空。

### bshutil：从内建命令到常驻服务

- bshutil 原来只是 bsh 的 builtin（跑在宿主进程里、改的就是主进程那份内存），mksh 里根本没这个
  命令；但**只挂进命令表也不行** —— 命令 so 是 procmgr fork 出来的子进程，`bsh_cfg` 改的是子进程
  那份拷贝、`ui_bus` 的 tsfn 在子进程里无效，`set exit-hint off` 会"成功"却毫无效果、`keys show`
  这类要通知界面的子命令必然失败。于是拆成两半：`bsh_util_server` 是常驻主进程的线程（监听
  `$HOME/bshutil.sock`，串行处理，里面调用**原来的** `bshutil_exec(argc, argv, out_fd)` —— 逻辑
  一行没改，只是 out_fd 换成连接本身，输出由此流回客户端）；`programs/bshutil/` 是命令 so（客户端）。
- 协议极简：一帧 = 4 字节大端长度 + 文本（请求 EXEC / ARGC n / ARG i <值> / END），应答 = 原始输出
  字节 + 4 字节大端退出码 + 末尾 shutdown(SHUT_WR)。★客户端接收端必须是**滑动窗口**（手上只留最后
  4 字节），写成"先把 4 字节攒满再说"会把**流开头**的 4 字节当成退出码扣住，每条命令输出都少开头
  4 个字符（实测 usage 首行的 `bshutil —` 变成 `til —`）。配套：`bsh_cfg` 的 5 个标量改
  `std::atomic`（服务端线程写、shell 线程每次都读）；串行服务端三道防死等（连接级超时收 5s / 发
  10s、写 socket 一律 MSG_NOSIGNAL、服务端线程单独 pthread_sigmask 屏蔽 SIGPIPE）；command_map
  加一行后 `.applets/bshutil` 占位自动生成，mksh 里也能用。设备实测（autorun 跑在 mksh 里）10 条
  全过，`keys show` 三次都 [ok] —— 同时证明服务端确实在主进程。

### westterm 与 Qt：库跟着可执行文件走

- westterm 一个低级但致命的 bug：某次给构建脚本加 tty_shim 时，把第一个数组 `PROTO_SOURCES=(`
  顺手改名成 `SOURCES=(`，而下面还有另一个真的 `SOURCES=(`，于是 8 个 wayland 协议 .c
  （xdg-shell / viewporter / relative-pointer / pointer-constraints / tablet / color-management /
  single-pixel-buffer / text-cursor-position）**再没参与过编译**。链接是"所有源码一次 clang 调用"，
  少几个 .c 只是少几个定义、链接器不报错，而 `wl_*` 核心接口由 libwayland-client 提供、看起来一切
  正常；只有 `wp_color_manager_v1_interface` 这类**协议数据符号**没人提供 —— 数据符号是加载期就
  必须解析的（musl 报 `relocating failed: symbol not found`），整个 libwestterm.so 起不来、设备上
  `westerm` 敲下去毫无反应。改回名字即可。
- Qt 改成随**应用目录**走：`build_qtwl_demo.sh` 两种模式 —— `so`（旧路：平铺进 bundle libs + 命令
  表）与 `app`（新路：PIE 可执行文件 + NEEDED 闭包里的 Qt 库 + QPA/shell-integration 插件 + 8 个顶
  掉 OHOS 同名系统库的桩库，strip 550MB→90MB 后打成平铺 tar `qtapp.tar`，由 elfloader 以 guest
  方式跑）。命令表默认不再挂 `qtwl-demo`（要用旧路再把那行放回来；新路在终端里跑显式路径
  `./qtwl-demo`，裸名会先命中命令表）。顺带修掉 app 模式桩库生成器一个真 bug：原来用 sed 机械
  生成、写出来的是坏 C，而编译错误又被 `| head -3` 吞了 —— 3 个机器生成的桩库一直在用更早那次成功
  编译的旧产物。
- 新路必须补两处，都是"库跟可执行文件放一块"在 elfloader 下要的：`rpath` 表达不了这个意图 —— musl
  对"内核映射的"主程序用 `/proc/self/exe` 推 `$ORIGIN`，而那个 exe 是宿主 appspawn、
  `-Wl,-rpath,'$ORIGIN'` 等于白写，所以 procmgr 按路径跑 guest 时把**它自己的目录**也加进
  `LD_LIBRARY_PATH`（放 bundle libs 之前）；shell 的 `QT_PLUGIN_PATH` 前置 `<sysroot>/qtapp` 与
  `<sysroot>/qtapp/plugins-probe`（wayland graphics-integration 那三个插件带类别子目录形状，只能
  靠显式路径平扫进去），bundle libs 留最后兜底。设备实测（默认环境、不覆盖任何路径）
  `cd <sysroot>/qtapp && ./qtwl-demo` 起窗成功、无 "No such file"/"symbol not found"。

### jit 与沙箱的门：三种情况、qemu 兜底

- 启动期能力探测（fork/exec/jit）只留启动这一次（删掉按需重探），要重探就重开会话；新增
  `node-jitless` 配置项（auto|on|off），导出成环境变量 `BSH_NODE_JITLESS` —— "宿主 → 命令 so"的
  既有通道（BSH_TTY_STDIO / BSH_WL_FD 同理），策略在宿主、机制在 so。Resolve 原来只按 `e_machine`
  分流（aarch64 → elfloader、x86_64 → box64），而这两条都要可写可执行内存：把 jit 门关掉后 elfloader
  报 `mprotect(PROT_EXEC) failed: Invalid argument`、box64 报 "cannot allocate … for bridge"，两条
  路都起不来。改成先看 `Capabilities().jit`：不通就把两者都交给 qemu-user（TCI，走
  kSoMain/dlopen，**不需要可执行页** —— 无 jit 设备上唯一活得下来的路）。设备实测（把 prctl 临时
  wrap 成 no-op 模拟"两道门都没有"）：6 种组合全部经 qemu 跑通；去掉 wrap 后跑 autorun-all
  PASS=52 FAIL=3（3 条全是 java）。
- qemu 需要 guest 运行期：它按 guest 的 PT_INTERP 找解释器（box64 不需要，它自带 libc 垫片），缺了
  直接 `Could not open '/lib/ld-musl-x86_64.so.1'`。会话启动把解释器/库拷进 `<sysroot>/qemu-root/`
  再导出 `QEMU_LD_PREFIX`；**用拷贝不用软链**（这个沙箱里 `symlink()` 一律 EPERM），总共不到 3MB。
  名单里 x86_64 glibc 那对（宿主 glibc，临时占位）进包时改名 `libc-x86_64.so.6` —— 包里同时有
  aarch64 的 libc.so.6，同名会撞。
- jit 的三种情况（① 有 kernel 权限 ② 无权限但允许 prctl 门 ③ 两道门都没有）与当前能力写进文档：
  逐项写清 caps 判定、aarch64/x86_64 guest 各走哪条路、node 会不会自动 `--jitless`、java 能不能起
  （②③ 都不可用，标 TODO 并指向"给 HotSpot 打 prctl 夹层"的改进方向）。相应地 `java`/`javac`/`jar`
  **暂停注册**：留着它们，命令表会把 java 当"可用命令"、跑出来的错也指不到真因（实测报
  `Failed to mark memory page as executable`）；要恢复的门槛是"java 能在无 jit 场景跑起来"
  （OpenJDK Zero 变体，或把 jit 权限加回来）。

### 崩溃取证：SIGSYS / SIGSEGV 的日志与信号栈

- **SIGSYS**：沙箱的 seccomp 对不在白名单的调用不给 errno、直接 SIGSYS（外部只看到 rc=159），一点
  线索都没有；而 `siginfo` 里其实带着 `si_syscall`/`si_call_addr`，装个 `SA_SIGINFO` 处理函数打
  一行就够 —— 就是这行把 hdc 的 rc=159 定到 `io_uring_setup(425)`（hdc 静态链进去的 libuv 在 loop
  初始化时探的），**与 `/proc/self/exe` 无关**（一度记在它头上，`shim/README` 里已更正）。处理函数
  **只记录、不重发**：`SECCOMP_RET_TRAP` 型只要 handler 正常返回，那次调用就以 `-ENOSYS` 交回
  guest，libuv 于是退回 epoll、glibc 的 rseq/clone3 退回老路径 —— 正是真实 Linux（内核不支持该
  调用）下的行为。实测 hdc `list targets` 从 rc=159 变成 rc=0。日志默认静默、`BSH_SIGSYS_TRACE=1`
  才打（避免"每次运行都有"刷屏），但**降级是功能不是日志**，关打印不关降级。
- **elfloader 侧**：guest 崩在坏栈上时（爆栈、或 sp 指向没映射的地方），原来的 fault handler 会在
  坏栈上二次故障、内核直接静默 SIGKILL —— 现象就是"进程 rc=139 却一行日志都没有"。现在 handler
  用自己的 64KB 栈（sigaltstack + SA_ONSTACK），并把 SIGILL 也接住（`a_crash()` 之类是非法指令）。
- **OnSigFault**（procmgr 的 SIGSEGV/BUS/ILL/ABRT 取证）：除信号/故障地址/PC，还把 PC 落在
  `/proc/self/maps` 的哪一段打出来 —— 用来区分崩在 guest 自己的段、崩在我们 JIT 出来的代码、还是
  压根没映射的地址；配一块 64KB 静态备用栈 + SA_ONSTACK。**状态如实记着：截至 2026-10-01 它一次都
  没被触发过** —— 会触发它的那条路（cmake 在 elfloader 里 SIGSEGV）当时被"套 #! 壳转 qemu"绕开了，
  而那正是自举实际走的路径，所以这段代码只有"编译通过"这一条证据，跑通自举并不构成对它的验证。
  将来真去修 elfloader 那条根因时它才是第一手证据；在那之前别把它的存在当成"崩溃已被处理"（它只
  取证、不改行为，返回后仍按默认动作打死进程）。

### 设备内自举

- 目标：在 BetterSH 里构建、签名、安装、打开它自己。运行时支撑：`BSH_FORCE_QEMU=1` 让 aarch64
  guest 也交给 qemu（某些大号 glibc ET_EXEC —— 实测 SDK 的 cmake，16MB —— 在 elfloader 里一进
  guest 就 SIGSEGV、rc=139，连 `[elf] fault:` 都来不及打，而同一份交给 qemu 解释执行是好的；根因
  待查，自举链路先用它绕过去。hvigor 会把环境变量过滤掉，所以实际是靠给 cmake 套一层 `#!` 壳显式
  转给 qemu）；`ForkChild` 无条件注入 `BSH_CTRL_SOCK`/`BSH_SYSROOT`/`BSH_HOME_DIR`（hvigor 会为
  原生工具长出一条**精简环境**的子进程，不注入的话它 spawn 出来的东西找不到 control socket 与
  sysroot、委托链直接断在那层）；资源解包判据从一个 tar 一个标记改成一个总标记 `.res-unpacked`
  （`bm install -r` 不清应用数据目录，旧标记会一直压着新版资源，而设备侧 uid 2000 的 hdc shell
  删不掉应用私有目录里的文件；空文件 = 本版写的，非空 = 早期"版本串"方案留下的，删掉重解）。
- `@PackageHap` 不是 JS 干的，而是 `java -jar <SDK>/toolchains/lib/app_packing_tool.jar --mode hap …`，
  而沙箱里 JVM 起不来（无 jit 权限 → `Failed to mark memory page as executable`）。
  `/workspace/dev/developtools_packing_tool` 是打包工具的 C++ 实现（jar 只是它的外壳），命令行与
  hvigor 传的**逐字一致**，静态编出来就能顶上：同一份 intermediates，产物 **153 个包内条目与 jar
  版逐一相同**、`unzip -t` 通过，设备侧 `@PackageHap` 243ms —— 打包环节从此不需要 JVM。材料
  （compat 垫片 + 两个必要补丁 + vendored cJSON）放 `build/packing-tool-ohos/`，**先不入库**
  （`build/` 整个被 ignore，与 `build/hapsigntool_cpp/` 同一套放法），等这条路真正落地再连同驱动
  脚本一并入库。两个补丁都是被 musl 逼出来的：libstdc++ 没有吃 `filesystem::path` 的 ifstream 重载
  （`directory_entry→path→string` 是两次用户定义转换，语言上不允许）；`std::locale("en_US.UTF-8")`
  在 musl 上没有 locale 数据、构造即抛，被上层 `catch(...)` 吞成 Param parse error、整个打包卡在
  参数校验。
- **node 换 `--with-intl=small-icu`**：设备内 hvigor 的 `@CompileArkTS` 报 `Invalid regular
  expression: /^[_\p{L}][_0-9\p{L}]*$/: Invalid property name in character class` —— 根因是 V8 在
  `V8_INTL_SUPPORT` 关掉时**不认 Unicode property escape**（`\p{L}`/`\p{Nd}`），而 ArkTS 那条链
  到处在用、光 `\p{}` 就有十几种，改 JS 是打地鼠，只能把能力补上。small-icu 只砍 locale 数据，
  uprops/unorm 这些 Unicode 属性数据是全的、且随源码（不用联网）；代价 libnode.so 59M → 72M
  （HAP 416M → 425M）。实测 `@CompileArkTS` 由此通过。
- **exec 委托在设备内构建链上断过一整轮**，两层原因叠着：① qemu 替 guest 执行 execve 走的是它**自己**
  的 `safe_execve()`（safe_syscall 宏展开出来是裸 syscall），libc 的 execve 压根没被调用，所以给
  `libqemu-*.so` 链的 `--wrap=execve` 完全拦不到；而它 re-exec 用的 `/proc/self/exe` 在沙箱里是
  appspawn、路径本身也是错的。新补丁 0010 把两处换成 libc 的 `execve()`，把"要跑什么"交给沙箱
  委托层，由 procmgr 按 `e_machine` + jit 能力重新判型。② ninja 跑每条命令都走 `/bin/sh -c`，而
  guest 侧 shim 在 `delegate_exec()` 里先 stat 探一下、非 ENOENT 就返回；沙箱里 guest 对 `/bin`
  整个目录没有 search 权限 → `stat("/bin/sh")` 直接 EACCES → 提前返回，procmgr 那条"系统 bin
  目录下的 basename 命中命令表就按命令起"永远轮不到。症状是整条链在第一条命令上全灭，而 ninja
  只报一句 `FAILED: [code=127]`、日志里一个字都没有。修法三处：只有 ENOENT/ENOTDIR 才据实返回；
  realpath 规整过的路径被拒时回退用调用方原样给的路径再试一次；**委托失败必须打一行**（原来是
  静默 `_exit(127)`，就是这一条沉默让 cmake→ninja→clang 卡了整整一轮才定位）。实测设备内
  `@BuildNativeWithCmake` 1m26s、`@BuildNativeWithNinja` 9s，clang/clang++/ld.lld 全 rc=0。
- `QEMU_LD_PREFIX` 在本移植里同时是 guest 的 rootfs 基准（qemu 补丁 0009）：原来指向
  `<sysroot>/qemu-root`，基准之外的一切都会被套前缀 → qemu 下跑 cmake 就算不出自己的 `CMAKE_ROOT`
  （它按 `/proc/self/exe` 反推）。抬到 `<sysroot>` 本身，解释器/库副本放 `<sysroot>/lib`。
- **签名在宿主 native 跑**：宿主签这份 ~625MB 的包 real 3.60s（页缓存热）/5.42s（冷），产物 ~628MB、
  verify-app 通过；换 `qemu-x86_64` 解释执行同一套 java + jar 跑不完 —— JIT 开着约 22s 就
  `uncaught target signal 6 (Aborted)`（产物缺 signing block、校验不过），加 `-Xint` 能走到
  Sign successfully（约 4m40s），但随后写 600MB 产物那一步 25min 仍未落盘。可比的开销倍率只能从
  JVM 启动看：`java -version` native ~0.10s / qemu-x86_64 ~0.77s（≈7.5×）/ qemu + `-Xint` ~0.39s。
  结论：签名在宿主 native 跑。
- **`versions/` 版本快照切换**：同一个工程要同时存在正式包（`com.yiyan.bettersh`，不带 java/JDK
  那套 so）、开发包（`com.yiyan.bettershdev`，带自举用的签名/安装工具）与 lite 包，手抄四件套
  （`arm64-v8a` / `tools` / `module.json5` / `bundleName`）必然漏 —— 漏 module.json5 就会带着另一套
  权限去测，漏 libs 会把实验用的 .so 带进正式包，漏 tools 会让 lite 版里残留 full 版才有的 tar
  （实测 `bshsign-tools.tar` 一个文件 634MB，把 HAP 从 425M 顶到 1.0G）。`scripts/switch_version.sh`
  整目录替换，rsync `-a --delete`（快照是权威，不这么做"切到 lite"只是往 full 上叠、永远瘦不
  下来），并有安全阀：快照里缺任何**已入库**文件（`hello.c`/`plot_demo.py`/`autorun-all.sh`）就
  整体拒绝执行，`-n` 走 dry-run。`versions/` 本身不入库（三份快照合计 2.2G、且都是构建产物），
  快照由开发者本地维护，脚本只负责"应用"。
- 另外两件：jdk21-ohos.tar 暂时移出包（放 `build/unshipped/`）；只移 tar、留着解包那条时，结果是
  fail 恒非 0、总标记永不写入、开发期每次会话都全量重解（多花约 10s，大头是临时件 `hapsign.tar`
  的 631MB），所以现在解包也停了 —— java 期间不可用（本来就是 TODO）。沙箱里 hdc 的身份密钥随包
  下发（每次会话补回 `$HOME/.harmony`，已存在就不覆盖、私钥 0600 —— 清掉数据目录也能恢复同一个
  身份，不用重新授权），三份自举输入（`bettershdev-src.tar`/`bshsign-tools.tar`/`hvigor-cache.tar`，
  前者还含签名私钥 p12）入 gitignore。

### 复制/粘贴改为免剪贴板权限

- 0.5.0 那套要 `ohos.permission.READ_PASTEBOARD`这次照 HiSH（已实证）的做法改成**免权限**：写剪贴板本来就
  不需要权限（复制继续 `createData` + `setDataSync`）；读剪贴板用 ArkUI 的**安全控件 PasteButton**
  —— 用户点它的那一刻系统才临时授予读剪贴板权限，回调拿到 `PasteButtonOnClickResult.SUCCESS` 之后
  才 `getData()`。于是既不声明权限，也没有 `requestPermissionsFromUser` 那一段。
- 实现上，右键菜单从网页里的 DOM 菜单搬到 ArkUI（`@Builder ctxMenu()`：一个「复制」MenuItem + 一个
  PasteButton）；网页侧只留"取选区"（`window.termGetSelection`）与"把文本送进终端"
  （`window.termPaste`，仍走 xterm 自己的 `term.paste()`，保住 bracketed paste 语义），不再碰系统
  剪贴板。两种模式：`menu` = 右键弹菜单；`smart` = 有选区直接复制，无选区调 `ctxSmartPaste` 粘贴，
  有权限情况下保持右键直接复制粘贴语义。

---

## 0.5.0 · 2026-09-27

一天内从 0.4.0 走到这里，主题是 **x86_64 guest** 和 **跨进程的 cwd**。

### box64 真正跑通

- 补上两个前提才跑得起来：命令 so 的加载从 `RTLD_LOCAL` 改为 `RTLD_NOW|RTLD_GLOBAL`
  —— box64 的补丁把 `box64lib` 置成 NULL，它解析包装符号走
  `dlsym(RTLD_DEFAULT, "my_…")`，只搜**全局**作用域，于是 RTLD_LOCAL 下每个 `my_*` 都
  返回 NULL、重定位全败（症状是「Warning, function my_xxx not found」刷屏后 SIGSEGV）；
  以及子进程开头先 `UnmapLowAnonRegions()`，并把它从"只清 `[anon:*]`"放宽到"无名映射
  也清" —— 低 4GB 里最大的占用者是一行**无名**的 ≈512MB ArkTS 堆预留，正盖着非 PIE
  ET_EXEC 要的固定基址 `0x400000`，原来只认 `[anon:` 前缀所以漏掉它。
- **不用再记前缀**：`procmgr` 读 ELF 的 `e_machine` 自己挑执行者 —— `AARCH64` 给
  elfloader，`x86_64`/`i386` 给 box64，所以 `./x86_64-xxx` 与 `./aarch64-xxx` 都是直接跑，
  `box64 ./xxx` 这种显式写法也仍然有效。认不出的架构仍交 elfloader 去报 `bad ELF header`。
- 验收件：六个组合（x86_64 的 glibc/musl × 静态/动态，加两个 aarch64 作对照）由
  `scripts/build_testprogs.sh` 编出，随包解到 `$HOME/testprogs`。两个 dynamic 组合
  14/14 全过；两个 static 组合跑完 13 项后停在 `signal` 用例（box64 对静态 guest 的
  信号路由问题，**已知未解**）。i386 也路由到 box64（走它的 BOX32），但那条路验得少。
- 另加 `scripts/build_ohos_stubs.sh`：给 OHOS 上不存在、而 box64 仍会去 `dlopen` 的系统库
  造空 stub（`libresolv.so`/`.so.2`）。脚本里有硬检查 —— 同名库若已存在就报错，避免把
  真正的系统库遮蔽掉。

### 终端里的复制/粘贴

- `bshutil set right-click menu|smart`：`menu` 弹菜单（里面有"复制/粘贴"），`smart` 像
  Windows —— 有选中就把选中内容放进剪贴板，没有就直接粘贴。改完立即生效，不用重开会话。
- 菜单画在页面里（HTML）而不是 ArkUI 菜单，这两条是被 API 逼出来的：能 `copy()`/`paste()`
  的 `WebContextMenuResult` **只在 `onContextMenuShow` 回调内有效**，而菜单项是回调之后
  才被点的；ArkUI 的 `bindContextMenu` 绑上就"右键必弹"，没有"这次不弹"的口子，而 smart
  模式恰恰不能弹。
- 粘贴走 xterm 自己的 `term.paste()`：它会做 `\r\n → \r` 归一，并在前台程序开了 bracketed
  paste（`DECSET 2004`，如 vim）时自动包 `\x1b[200~ … \x1b[201~`；自己拼字符串会丢掉这层语义。
- 抑制 ArkWeb 自带菜单用了两层：页面在 `contextmenu` 的 capture 阶段
  `preventDefault`+`stopPropagation`，Web 组件上再挂 `onContextMenuShow → true`。
- 剪贴板：**写不需要权限，读需要 `ohos.permission.READ_PASTEBOARD`** —— 受限权限
  （`system_basic` + 用户授权）。因此它同时牵动三处：`module.json5` 里声明（`user_grant`
  权限必须带 `reason`/`usedScene`，否则 hvigor 直接报 00303218）、`string.json` 里那条
  reason 文案、以及**签名 profile 的 `allowed-acls`**（缺了它整个 HAP 装不上）。首次粘贴
  会向用户申请一次，被拒则提示并放弃。

### 跨进程的 cwd（一对同源 bug）

- 现象：`sh` 之后 `cd` 到别的目录，`pwd` 对、但 `ls` 还列原来的目录；`./prog` 报
  `not executable`。两半互补，缺一不可：
  1. `Resolve()` 里判断"文件在不在"的相对路径原来按 **procmgr 自己**的 cwd 解析 ——
     mini shell 与 procmgr **在同一进程**，它的 `cd` 顺带改了 procmgr 的 cwd，所以外层
     一直好使；mksh 是另一个进程，它的 `cd` 碰不到 procmgr，于是同一个 `./prog` 被判成
     `not executable`。改成去开头的 `./` 后与 `req.cwd` 拼成绝对路径。
  2. 委托请求原来**不带 `CWD`** —— 子进程是 procmgr fork 的，不带就继承 procmgr 的 cwd
     （`pwd` 是 shell 内建所以看着对，`ls` 是另一个进程所以看错）。客户端补上这一行；
     服务端本来就支持。
- 顺带记下一个工程坑：`bsh_client.c`/`bsh_exec.c` 的 `.o` 被**各命令 so 分别烤一份**
  （mksh / llvm / dropbear 三个构建脚本），改了这两个文件只跑 `build_hap` 不够 —— 漏编
  哪个，那个命令就还是旧行为（实测只重编 `libentry.so`，于是 `sh` 里毫无变化）。

---

## 0.4.0 · 2026-09-11 ~ 2026-09-27

跨度最长的一个版本。主干是"把命令 so 的体系做扎实"（进程创建收敛、tty 解耦），
外加 Python 科学栈，以及两条跨 ISA 的后备执行路径。

### 进程创建收敛到 procmgr（架构转折）

- **全工程只剩一处 fork**：命令表命中 → dlopen 对应 so 调入口符号；否则按路径/ELF 探测交
  elfloader。进程表、前台 pid、fd 继承都收进 procmgr，对外只暴露 `$HOME/bsh-ctrl.sock`
  （4 字节长度前缀 + 文本行帧；fd 走 `SCM_RIGHTS` —— 新进程由主进程 fork，fd 不靠继承）。
  `shell/command_map.*`、`shell/bsh_exec.c` 随之迁进 `procmgr/`。
- **tty 能力拆两半**：fd 身份表留在本地 `tty_shim.c`（fd 号只在进程内有意义），共享的
  termios/winsize/前台 pgrp 只在主进程一份，命令 so 经 `CMD TTY` 读写。
  结果是**7 个命令 so 对 `libentry` 的依赖归零**，解掉了"编任何命令 so 都得先跑一遍
  build_hap"的鸡生蛋。
- `bshutil` 内置命令（`conf` / `set exit-hint|elf-hint|win-scale` / `keys` / `picker` /
  `proclist` / `kill`）+ native↔ArkTS 的 `ui_bus`（单向通知 / 带回执的请求）。
- **启动期能力探测**（fork/exec/jit）：fork 的判据用**管道**而不是 `waitpid` —— ArkWeb 系
  进程自带 SIGCHLD 收割者会先收走子进程，`waitpid` 返回 `ECHILD` 是探测方法的假阴性；
  jit 依次试五条路，其中两条是 `prctl('jit')` 系列，正是 elfloader 走的那条（两台设备实测
  都只有它过）。

### westterm 与"随机黑屏"

- 迁 weston-terminal 为 `libwestterm.so`。沙箱里没有真 pty，`forkpty` 用 socketpair 模拟。
- **黑屏根因**：westterm 依赖的 cairo/fontconfig/xkbcommon 等库在 fork 前后会抢低位 fd，
  同一个 fd 号在父进程是 socketpair、在子进程成了管道 → slave 没人持着 → master 立刻
  EPOLLHUP → weston 静默退出。修法：fork 前把 slave 复制到高位 fd（`F_DUPFD_CLOEXEC`）。
  顺带修 `read` 包装：master 是 `O_NONBLOCK`，把 `EAGAIN` 当读错误会让 weston 退出。

### Wayland 输入延迟

- 事件循环原来把阻塞的 `wl_event_loop_dispatch(loop, 50)` 整个罩在 mutex 里、解锁即重抢，
  等锁实测 47–1737ms。改成锁外 `poll(20ms)` + 持锁非阻塞 `dispatch(loop, 0)`，按键到上屏
  从 30–1765ms 降到 **13–30ms**（地板是渲染线程 16.7ms 的节拍）。

### Python 科学栈

- **CPython 3.12** → `libpython.so`：模块全静态内置（RTLD_LOCAL dlopen 下 `lib-dynload`
  解析不到 `Py*` 符号）、入口用 `Py_BytesMain`、stdlib 裁剪后解到 `$HOME/python`，
  `PYTHONHOME` 与 configure 前缀一致（不依赖 `argv[0]`）。
- **numpy 2.5.3**：受"`$HOME` 是 noexec、bundle `libs/<abi>` 只收平铺 `.so`"约束，扩展改名
  平铺 + `sitecustomize.py` 的 meta path finder 兜底导入。
- **PyQt6 6.11 / matplotlib 全栈**：按"能不能放 `$HOME`"分工 —— 纯 Python 包落
  `$HOME`，C 扩展平铺进 bundle libs；扩展显式记 `NEEDED libpython.so`（RTLD_LOCAL 下必须）。
- **Qt6 wayland 栈 + qtwl-demo**：库与插件必须平铺（HAP 里没有 `platforms/` 这类子目录），
  带 7 个 ohos-extra 依赖并做**依赖闭包自检**，构建期就报错而不是等设备上炸。

### SSH（dropbear）

- `libsshcore.so` 一个 so 覆盖 ssh/scp/ssh-keygen/dropbear 等五个程序（按 `argv[0]` 分发）。
  三处沙箱适配：补 `getpass()`（ohos libc 没有）；遮蔽 `getpwuid/getpwnam`
  （`/etc/passwd` 里没有当前 uid 的条目）与 `seteuid/setegid`（沙箱下会被不可捕获地强杀）；
  服务端会话 pty 改 socketpair、`pass_on_env` 默认置 1。
- 顺带补齐软 tty 缺的两段行规程：**ICRNL**（前端 Enter 发的是 CR，只等 `\n` 的程序会永远等）
  与 **SIGWINCH**（前端尺寸变化要转发给前台，vim 重排、ssh 发 window-change 都靠它）。

### elfloader / 编译链

- **静态 guest 的退出冲刷**：`exit` 入口原来被改写成 `b _Exit`，而 `_Exit` 不冲刷 stdio，
  缓冲里的输出随进程消失（实测只出一行）。改在镜像后 mmap 一页小桩：存退出码 → 调冲刷 →
  还原退出码 → 跳 `_Exit`。冲刷入口优先 musl 的 `__stdio_exit`，退 `fflush(NULL)` ——
  设备端自建 musl 的 `libc.a` 符号不全（实测没有 `fflush` 但有 `__stdio_exit`），
  只试一个会静默退回老行为。
- **clang 默认改 `-static-pie`**：`-static` 产出 ET_EXEC，要落在固定基址（约 `0x200000`），
  而宿主进程里那块可能已被占、ET_EXEC 又搬不动，loader 报 `reserve fixed image range …
  File exists`。static PIE 是 ET_DYN，任意地址映射、由 musl 的 `rcrt1.o` 自重定位。
  sysroot 相应补 `rcrt1.o` 与 PIC 的 `crtbeginS.o`/`crtendS.o`。

### 两条跨 ISA 的后备执行路径

- **qemu-user（TCI + 动态 .so）**：`libqemu-{aarch64,x86_64}.so` 走 dlopen + C 入口，
  **不需要可写可执行内存**，是"exec 被挡、`prctl('jit')` 也不给"的设备上唯一可行的路径。
- **box64（x86_64→ARM64 动态翻译）**：源码由脚本 clone 后打约 40 条补丁；入口包装必须显式
  `visibility("default")`（box64 的 CMakeLists 有全局 `-fvisibility=hidden`，漏了就 dlsym 不到）。
  当时只到"能编出来"，真正跑通是 0.5.0 的事。

---

## 0.3.0 · 2026-09-07 ~ 2026-09-10

首个标注版本，含此前的初始开发。核心是确立"**每个命令 = 一个导出 `main` 的 so，shell 按
命令表 dlopen**"这个模型，以及让终端真的能用起来。

### 应用外壳与 UI

- xterm.js 前端 + 终端页面：Web 载 `term/index.html`，按键经 `javaScriptProxy hbridge.input`。
- 虚拟键栏（ESC/FN/TAB/CTRL + PGUP/方向/设置；CTRL+a–z 转 `\x01..\x1a`；FN 切 F1–F12；
  2in1 默认隐藏）+ 设置面板（字号、光标闪烁）、深色模式去白边。

### 会话与命令体系

- **软 pty**：沙箱里没有真 pty，用 socketpair 模拟 termios + winsize，输出侧做 ONLCR。
- **命令表**：纯 C 只读表（`command_map`），未命中则按路径交 elfloader。
- **exec 委托**：命令 so 里的 `execvp/execv/execve/posix_spawn` 经 `--wrap` 改为向宿主下单，
  保住 fork+wait 语义（这样 mksh、cc1、scp 这些"内部再起程序"的用法才成立）。
- `$HOME/.applets` 里放命令名占位并前置 PATH（否则 mksh 里 `vim` 直接 not found）。

### 命令 so 移植

- **toybox**（`libtoybox.so`，multicall 一个 so 覆盖几十个 applet）、**clang/lld**
  （两阶段构建，宿主 tblgen + musl 交叉；内置头打成 tar 随包）、**vim**（连带自建 ncurses
  widec 与 xterm-256color terminfo；软 tty 注册表让 vim 以为在真 tty 上）、
  **fastfetch**、**mksh**。

### 终端内编译链

- 打包 musl sysroot（头 + `crt*.o` + `libc.a`/`libgcc*.a`），clang 入口默认注入
  `--sysroot=$HOME/musl -static -fuse-ld=lld`，于是终端里 `clang a.c -o a` 免参数即可。

### elfloader

- 移植 in-process 加载器：把 aarch64 ELF 的段映射到新内存、在自制栈上跳转执行，不做 `exec`；
  用 `prctl('jit', …)` 包裹 `mprotect(PROT_EXEC)` 适配 HarmonyOS 的 W^X。

### Wayland

- 内嵌 compositor（`WaylandServer`）+ 客户端 SDK；`wldemo` 冒烟客户端与
  `AppRunnerAbility`/`ClientWindow` 窗口接线。

### 工程

- `build_hap.sh` / `sign_hap.sh` / `deploy_hap.sh` 一键链；本地配置（`build-profile.json5`、
  `scripts/env.sh`）不进仓库，改用 `.example` 模板分发；宿主 ABI 只保留 arm64-v8a。
- 首版 README（能力、架构分层、构建步骤、so 移植配方、已知限制）。
