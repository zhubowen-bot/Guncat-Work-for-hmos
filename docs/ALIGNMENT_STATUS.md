# 三端实现对照与对齐现状

> 注：7.0.1 起 `shell` 已从 QEMU/Alpine 改为 IEC 原生执行核（命令是 HarmonyOS `.so`，
> 无虚拟机）。本文中关于 shell 后端的对照记录的是 7.0.0 的状态，当前实现见
> [architecture/iec-runtime.md](architecture/iec-runtime.md)。

> 日期：2026-10-28 ｜ 对照：`Guncat-Work-for-pc`(0.2.1)、`Guncat-Work-for-android`(0.2.1)、
> `Guncat-Work-for-hmos`(7.0.0)
> 方法：静态读代码与文档（工具定义、常量表、提示词、服务清单、`git log`、`CHANGELOG`），
> 加 `tsc` / `assembleHap` 编译校验；**未逐条真机复跑**。
> 本文只陈述事实与取舍，不含待办。

## 结论

**功能面一致，实现机制按平台分三套。** 未对齐的项全部是刻意取舍（第八节），没有漏做。

| 层面 | 三端关系 |
| --- | --- |
| 业务内核（Agent Loop、工具面、Office 生成器、数据管道、提示词、交互模式） | 同一套逻辑。电脑版与安卓版共享 `src/core/`；鸿蒙版是它的 ArkTS 原生移植（同名文件、同结构） |
| 执行环境（命令 / 代码 / Python / PDF） | 三套完全不同的实现，见第二、三节 |
| 应用外壳 | Electron / WebView+Java / ArkTS 原生，见第一节 |

---

## 一、应用外壳

| | 电脑版 | 安卓版 | 鸿蒙版 |
| --- | --- | --- | --- |
| 形态 | Electron 38（主进程 + 渲染进程） | Java 外壳 + WebView（SPA） | ArkTS / ArkUI 原生单进程 |
| UI | React 19 + TypeScript | React（同一份 renderer）+ `mobile.css` 断点 | ArkUI 声明式（`.ets`），自绘设计令牌 |
| 业务代码位置 | `src/core/` 跑在主进程 | 同一份 `src/core/` 跑在 **WebView 里** | `entry/src/main/ets/`（`common/ service/ export/ data/ viewmodel/ views/`） |
| 平台桥 | `@kit.*` → Node（`fs` / `net` / `child_process`） | `@kit.*` → 浏览器 API + Java 桥（`window.guncat` / `window.GuncatShell`） | `@kit.*` 真身（CoreFileKit / NetworkKit / PDFKit / ImageKit / CoreSpeechKit…） |
| 文件系统 | 真实磁盘任意目录 | **memfs（IndexedDB）为权威**，命令执行时镜像到应用私有目录 | 应用沙箱真实文件（`filesDir`），无镜像层 |
| 网络 | Node `http` 直连 | WebView `fetch` 受 CORS，必须走本机反向代理（`127.0.0.1:47653`，SSE 逐块 `flush`） | `@kit.NetworkKit` `requestInStream` |
| 进程模型 | 多进程 | WebView 单页面 + Java 侧进程管理 | 单进程 + 原生库（QEMU / CPython / JSVM） |

安卓版把"主进程那一半"（`SessionManager` 及其服务）搬进了 WebView，`window.guncat` 的接口签名与
电脑版 preload 一致，所以 `src/renderer` 不需要平台分支；鸿蒙版则是同一套业务逻辑的**重写移植**，
类名、文件名、提示词、常量名刻意保持同构，便于三端对照。

---

## 二、命令执行（`run_command` / `shell`）——三套完全不同的实现

| | 电脑版 `run_command` | 安卓版 `run_command` | 鸿蒙版 `shell` |
| --- | --- | --- | --- |
| 后端 | 宿主系统真进程（Windows `cmd`、macOS/Linux `sh`） | 两条：① 内置 Termux 用户态 `abcd/bin/bash`；② 兜底 `/system/bin/sh`（mksh + toybox） | QEMU **TCI 解释执行**的 Alpine Linux（不生成机器码，**不需要 JIT/可执行内存权限**） |
| 为什么这么选 | 桌面本来就是"能跑命令"的环境 | Android 默认没有 `/bin/sh` 可用、也不允许随便执行私有目录文件（`targetSdk=28` 是硬前提）；内置 Termux 才能给出 bash/python/git | 鸿蒙不允许起子进程；自建 VM 是唯一能给出"真 Linux"的路径 |
| 工作目录 | 工作区（可绑定任意真实目录） | 工作区**镜像目录**（memfs ↔ `filesDir/guncat-data/…/workspaces/<会话>`，单文件 32MB、单次 64MB） | virtio-9p **直连**本会话工作区（不是副本，`cat a.csv` 与 `read_file` 同源） |
| 并发 | 可多进程；后台任务最多 8 个 | 后台任务同电脑版（`job_*`）；进程管理在 Java 侧 | 命令**串行**（单核 TCI，多开只会互拖）；无后台任务 |
| 超时 | 默认 30s、上限 300s，超时杀进程树 | 同电脑版 | 默认 60s、上限 240s；VM 空闲 10 分钟自动关机 |
| 输出 | 环形缓冲 + `.spill/` 落盘 | 环形缓冲（前台 256KB / 后台 512KB），丢弃量如实汇报 | 60KB 截断，全文落 `.spill/` |
| 安全边界 | **`CommandGuard`**：37 条硬禁 + 77 条危险 + 27 条"意图读不出" + 11 条脚本内容 + 11 条命令位 = 163 条；四档审批（ask / ask-risk / auto / full-access）；auto 档交给另一个模型审阅，判不了就退回人工卡；脚本内容、命令位、越界路径、编码载荷都要过判定 | **保留同一套**（内核未改；Termux 只是让"能跑什么"变多，"谁批准"没放宽）；POSIX 越界判定按 Android 真实布局改写 | **不设审批**（刻意）：边界靠 VM——客人只看得到本会话工作区，`rm -rf /` 只毁客人系统 |
| 不可用/限制 | 需要宿主装对应 CLI | 只带 arm64；`pkg install` 的包路径仍写死 `com.termux`，不承诺可直接运行；`targetSdk=28` 不适合上架 | TCI 比 JIT 慢两个数量级，计算密集的活一律建议走 `run_python`；单核 |

一句话概括：**电脑版是"受审的真终端"，安卓版是"内置 Linux 用户态 + 同一套审批"，鸿蒙版是"一次性隔离的整机 VM，因此不设审批"。**

---

## 三、代码与解释器（`run_js` / `run_python`）

| | 电脑版 | 安卓版 | 鸿蒙版 |
| --- | --- | --- | --- |
| `run_js` 引擎 | `node:vm` | Blob Worker（独立线程） | JSVM-API 原生引擎，**每次执行新建 VM + 上下文** |
| 死循环 | `timeout` 可硬中断 | `worker.terminate()` 可终止 | **不可中断**：超时只放弃等待，累计 2 次后本会话停用 `run_js` |
| 隔离 | 无网络/无 fs，文件显式进出 | 同左，另屏蔽 `fetch`/`XHR`/`indexedDB` | 同左（纯计算，文件由 ArkTS 侧预载/落盘） |
| Python | 无专用工具，需要时用 `run_command` 调宿主 python | 内置 Termux **Python 3.14 + pip**，预置三方库（numpy/scipy/pandas/matplotlib/docx/pptx/openpyxl/requests/lxml/sympy…，唯一缺 `regex`——纯 C 扩展无 arm64 包） | **原生 CPython 3.12**：编成 HarmonyOS `.so` 在应用进程内直跑（不经仿真），预置库含 `regex`/`scipy`/`PyCryptodome`；`npy` 桥让 VM 内的 shell 管道也能用上它 |
| Python 的坑（各自处理过） | — | 中文 matplotlib 由 `sitecustomize.py` 挂 audithook 注册系统字体 | 中文靠随包思源黑体；`multiprocessing` 只有 fork 上下文；循环超时靠字节码采样；OOM 会被系统直接杀（工具会给内存提醒） |
| 性能量级 | 宿主原生 | Termux 原生 | Python≈原生（进程内）；shell≈慢两个数量级（TCI） |

---

## 四、Office 与 PDF

| | 电脑版 | 安卓版 | 鸿蒙版 |
| --- | --- | --- | --- |
| Office 生成 | 同一套 `src/core/export/*`（Doc/Workbook/Deck JSON → OOXML） | 同一套（共享 core） | 同一套逻辑的 ArkTS 移植（`DocxBuilder.ets` 等，行数一致） |
| 读回/编辑 | `read_docx`/`edit_docx` 等，无损读回 + 算子式编辑 | 同左 | 同左 |
| PDF 引擎 | `pdfjs-dist` + `@napi-rs/canvas`（原生 `.node`，打包时手工搬入） | `pdfjs-dist`（**fake worker**，避免 WebView module worker 卡死）+ 随包 cmaps/fonts/wasm | `@kit.PDFKit` **系统原生**：`getTextContent()` / `searchKey()` / `getAreaPixelMapWithOptions()` |
| 扫描件转图 | canvas 渲染 | DOM `<canvas>` 渲染 | 原生 PixelMap → JPEG |
| 已知边界 | 加密 PDF 无密码不可读；扫描件无文字层 | 同左（老 WebView 需补 `ReadableStream` 异步迭代器，已补） | 同左 |

三端的 `parse_document` / `search_pdf` / `pdf_to_images` 工具名、参数、返回格式一致，只是后端不同。

---

## 五、工作区与会话数据

| | 电脑版 | 安卓版 | 鸿蒙版 |
| --- | --- | --- | --- |
| 工作区位置 | 真实目录，可**绑定任意文件夹**，也可回退默认沙箱 | `filesDir/guncat-data/files/workspaces/<会话>`（memfs 镜像目标） | `filesDir/workspaces/<会话>`（应用沙箱） |
| 上传/导出 | 系统文件对话框 + 拖拽进窗口 | `<input type=file>`（`onShowFileChooser`）→ canvas/memfs；保存走 MediaStore / 分享面板 | DocumentViewPicker / PhotoViewPicker / CameraPicker；导出走系统保存面板 + Share Kit |
| 预览 | 图片灯箱 / Markdown 渲染 / 代码高亮 / "用默认程序打开" | 行内下载、分享、删除；预览走系统 | Preview Kit 就地预览 + 系统"打开方式" |
| 会话删除 | 删会话同时删工作区（无条件） | 同左（另外 `CommandService.releaseConversation` 收掉后台进程树） | 同左；另加"执行中先停任务、收尾补删"与**启动清扫孤儿**（[workspace-lifecycle.md](architecture/workspace-lifecycle.md)） |
| 会话存储 | `%APPDATA%/Guncat Work` 下 JSON | IndexedDB（memfs + 会话 JSON） | `filesDir/guncat_conversations.json` + Preferences |
| 事件日志 | 有（JSONL） | 有（内核同源） | 有（`filesDir/sessions/<会话>.jsonl`） |

---

## 六、语音、朗读与后台

| | 电脑版 | 安卓版 | 鸿蒙版 |
| --- | --- | --- | --- |
| 朗读 | Web Speech API（系统音色 + 倍速） | Android 系统 TTS（`ttsSpeak` / `ttsStop` 桥） | CoreSpeechKit `textToSpeech`（音色/倍速/可拖动进度 + AVSession 锁屏播放） |
| 语音输入 | 录音 + **服务商转写接口**（`asr_baseUrl`/`asr_apiKey`/`asr_model`，默认 `whisper-1`） | 原生 on-device（API 31+）/ 系统识别；失败回退到录音 + 服务商转写 | CoreSpeechKit `speechRecognizer` + `AudioCapturer`（实时流体上屏） |
| 长任务保活 | 主进程常驻，窗口最小化不影响 | **前台服务**（常驻通知）+ `PARTIAL_WAKE_LOCK` + Wi-Fi 锁 + 电池优化白名单 + 渲染优先心跳 | `backgroundTaskManager` 的 dataTransfer 长时任务（切后台不被挂起） |
| 屏幕 | 不涉及 | `FLAG_KEEP_SCREEN_ON` | `setWindowKeepScreenOn(true)` |
| 凭据 | Electron `safeStorage` 加密（`enc:v1:`）+ 状态上报 | **无保险库，明文**（文档已如实写明） | 明文（Preferences） |

---

## 七、Agent 能力层（三端一致的部分）

- **工具面**：42 个工具定义同名、同参数、同描述（`WorkFileService.toolDefs` + `HarnessTools.toolDefs`）；
  命令/代码/Python 一侧按平台不同（见第二、三节），联网搜索（`local_web_search`）、网页抓取（`web_fetch`）、
  JS（`run_js`）三端都有。鸿蒙版共 47 个工具（42 + `web_fetch`/`run_js`/`local_web_search`/`shell`/`run_python`）。
- **交互模式**：`INTERACTIVE_TOOL_WHITELIST` 27 项逐字相同，三个消费点同走 `toolDefsForMode()`；
  `guncat-ui lang` 解析器、渲染组件库、`interactivePrime()` 纪律段同源。
- **循环**：`WorkLoopStateMachine` / `WorkLoopPlanner` / `LoopDecisions` / `ToolScheduler` / `RepeatDetector` /
  `WorkLoopDriver` 三端同构；有界并行池 4、插话、溢出落盘、粘性 max-tokens、上下文三级压缩一致。
- **子代理**：独立上下文、≤40 步、产出目录隔离（`subagents/sa_*/`）、并发布上限 4。
- **技能与智能体**：`SKILL.md` 40 份、目录结构一致；`agents.json` 逐条一致；`list_skills`/`load_skill` 渐进加载。
- **提示词**：`PromptBuilder` 分块同源；项目指令（`AGENTS.md` 一类）三端都有——电脑版/安卓版**自动注入**快照，
  鸿蒙版**只写纪律、由模型自己读**（手机端省上下文）。
- **编辑守卫**：`FileObservation`（`FS_NOT_OBSERVED` / `FS_STALE_VERSION`，指纹=大小:mtime:开头 8KB FNV-1a）
  三端同规则，鸿蒙版为移植实现。
- **@ 引用**：三端都有；鸿蒙版为 ArkTS 移植（`MentionQuery` + `WorkspaceMentionService`），预算与越界规则一致。

---

## 八、刻意不对齐的清单（现状即最终决定）

| 项 | 电脑版 | 安卓版 | 鸿蒙版 | 取舍理由 |
| --- | --- | --- | --- | --- |
| 命令审批 / `CommandGuard` | 163 条规则 + 四档审批 + 模型审阅 | 同左（完整保留） | **无审批** | VM 隔离：客人只看得到本会话工作区，破坏性命令只毁客人系统。前提是**不把宿主目录挂进 9p**；若将来要挂，这条必须重估 |
| 后台任务 `job_*` | 有（最多 8 个） | 有（进程树递归 kill） | **无** | 内存硬约束（VM 2GB + 原生 Python 常驻 1GB+），系统 OOM 是 SIGKILL、捕不到异常；VM 单核，并发互拖。技术评估留档：[BACKGROUND_JOBS_PLAN.md](BACKGROUND_JOBS_PLAN.md) |
| 凭据加密 | 有（safeStorage） | **无**（明文） | **无**（明文） | 落盘在应用私有目录，正常途径仅本应用可读；三端里只有桌面做了系统保险库 |
| 多会话并行 | 按 `conversationId` 分桶，可同时跑 | 同左 | **单实例循环**：切会话不打断，但在别的会话发送会提示"另一个会话正在执行任务" | 串行换确定性与内存可控；串行也是当前架构的前提 |
| 自定义工作区目录 / 资源管理器显示 / 拖拽导入 / 剪贴板贴图 | 有 | 无 | 无 | 桌面专属系统能力 |
| `run_js` 可中断 | 可（`node:vm` timeout） | 可（Worker terminate） | **不可** | JSVM-API 没有终止执行的接口；用"放弃等待 + 2 次后停用"兜住 |
| Mermaid 规范 | 桌面宽屏（允许 LR/mindmap/gantt，`useMaxWidth:false`） | 同电脑版（宽屏断点） | 手机竖屏（只 TD/时序，节点与分支收紧） | 按渲染宽度分叉，不是能力差异 |
| 子代理工具面 | 含 `run_command` | 含 `run_command` | 排除 `shell` / `run_python` | 子代理的产出目录隔离只重定向"路径参数"，约束不住 shell 的任意重定向 |
| 交互模式命令能力 | 不下发 `run_command` | 同左 | 不下发 `shell` / `run_python` | 同一逻辑：交互模式只给"读素材/算数/核实/出文件"27 个工具 |
| 工具计数口径 | README 记 45 | 未单列 | 记 47 | 是否把 `job_*`、`local_web_search` 算进"内置工具"，非能力差异 |

---

## 九、验证状态

| 端 | 自动化 | 结果 |
| --- | --- | --- |
| 鸿蒙版 | `test/guncat-harness`（纯逻辑 683 项）+ `tsc -p check/tsconfig.json` + `assembleHap` | 683 项全绿、tsc exit 0、BUILD SUCCESSFUL |
| 电脑版 | `scripts/ipc-check.mjs` 等（判定层 + 集成层），CI | 未在本轮重跑 |
| 安卓版 | 浏览器冒烟（无原生桥，走 JS 回退）+ `typecheck` | 未在本轮重跑 |

**验证边界（诚实说明）**：本文的"已对齐"是**代码级**结论——工具定义、常量、提示词、服务清单逐项比对，
加上编译通过；**没有**逐条真机复跑。对行为敏感的项（多图视觉注入、跨会话插话拦截、执行中删会话后目录
回收、大图兜底压缩、@ 引用的光标落点）建议实机各验证一次。
