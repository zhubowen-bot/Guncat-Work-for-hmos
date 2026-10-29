# JIT 受限权限申请材料（AGC）

> **历史文档**：7.0.1 起 shell 已改为 IEC 原生执行核（命令是 HarmonyOS `.so`，不经虚拟机、
> 不需要 JIT），本文的 QEMU/JIT 申请材料不再适用于当前实现，保留作为归档。

> 用途：向 AppGallery Connect 申请 `ohos.permission.kernel.ALLOW_USE_JITFORT_INTERFACE`（自研引擎 JIT），
> 用于把 `shell` 工具的 QEMU 从 **TCI 解释执行** 切到 **TCG 即时编译**。
> 申请入口与流程见官方《[申请使用受限权限](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/declare-permissions-in-acl)》；
> JSVM 场景的官方说明见《[JSVM-API 申请 JIT 权限指导](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/jsvm-apply-jit-profile)》。

**申请前务必确认**：未获批就把它写进 `module.json5` 的 `requestPermissions` 会导致**应用安装失败**
（官方原文：「如果未申请相应的权限证书，但在配置文件中声明此权限，会导致应用安装失败」）。
所以代码里要按"运行期探测 + 无权限自动回退"来写，而不是编译期硬声明。

---

## 1. 表单「申请理由」（短版，可直接粘贴，约 450 字）

> 应用名称：Guncat Work　包名：com.bowenapp.guncatai（测试包 com.bowenapp.guncataibeta）
> 申请权限：ohos.permission.kernel.ALLOW_USE_JITFORT_INTERFACE

```
我们的应用是端侧 AI 客户端，内置「shell 工具」：在同一 APK 内以 QEMU 全系统虚拟机运行
Alpine Linux，让 AI 在设备本地完成批量文件处理（CSV/Excel/PDF 清洗、重命名、打包）与
Python 脚本计算，数据不上传云端。该虚拟机目前以 TCG 解释执行（TCI）运行，冷启动与命令
执行耗时明显，影响可用性。我们希望启用 QEMU 自带的 TCG 即时编译（JIT）后端，把客户机
指令翻译为宿主机器码执行，以获得可用的交互速度。
JIT 的输入仅来自随包分发的只读 Linux 镜像与用户本机工作区文件，不含任何网络下载的可执行
代码；QEMU 以模板化翻译生成宿主代码，客户机内存访问全部经过其软件 MMU 校验，不会直接
跳转执行客户机字节；生成的代码写入 MAP_FORT 内存，我们将通过 JITFort 接口写入并遵循 W^X
（不申请可写可执行内存）。若权限未获批、或系统处于坚盾守护模式，应用自动回退到解释执行
路径，功能不缺失、不降级为不可用。
```

---

## 2. 详细技术说明（长文本 / 附件正文）

### 2.1 业务场景

- 应用定位：**端侧** AI 客户端（ArkTS/ArkUI 原生），对话与工具执行都在设备完成；模型 API 只接收文本与用户明确发送的附件。
- `shell` 工具（本项目第 46 个内置工具）让 AI 在本地真 Linux 环境里执行命令，典型用法：
  - 批量清洗/转换表格（`sed`/`awk`/`jq`/`python3` 处理 CSV、JSON、XLSX 导出中间数据）；
  - 批量重命名、分类归档、打包压缩（`find`/`tar`/`gzip`）；
  - 对 PDF/Office 抽出的文本做去重、比对、统计；
  - 运行用户或模型编写的小段 Python 脚本做计算。
- **为什么要本地跑**：这类任务的数据是用户的私人文档。放到云端处理意味着上传原始数据、消耗流量与隐私预算；本地执行是产品在隐私上的核心卖点。
- 现状：虚拟机用 QEMU 10.2 的 **TCG 解释器（TCI）**构建（`--enable-tcg-interpreter`），完全不生成机器码，因此**不需要任何受限权限**——这是我们的默认路径，也是回退路径。

### 2.2 为什么必须是 JIT（不可替代性）

1. **解释执行的开销是数量级差异**。TCI 对每条客户机指令都要走一次解释循环；TCG JIT 把基本块翻译成宿主机器码后直接执行。同一个 Alpine 引导流程，在解释模式下我们把**引导超时放到 180 秒**才够稳；常规命令（解压、`apk add`、Python 启动）也明显拖慢，用户体验接近不可用。
2. **没有更便宜的替代方案**：
   - 预编译/`qemu-user` 静态翻译不适用——运行的是完整 Linux 用户态，需要系统调用、设备、文件的完整语义；
   - 把负载搬到云端违背产品定位（隐私）；
   - 用 ArkTS/TS 重写 shell 与 coreutils 只能覆盖极小子集，且无法运行 `python3`/`apk` 生态。
3. **JIT 不改变安全模型**：仍然运行在同一应用进程、同一个沙箱内，只是把"逐条解释"换成"翻译成宿主指令再执行"。

### 2.3 技术实现与安全边界

| 环节 | 做法 |
| --- | --- |
| 引擎 | QEMU 10.2 源码（同一份代码，仅构建开关不同）：JIT 版 `--enable-tcg`，解释版 `--enable-tcg-interpreter`；两个 `.so` 同包分发 |
| 代码来源 | 只有两类：① 随 APK 打包的只读 Alpine 根文件系统镜像与 Linux 内核；② 用户在应用沙箱工作区内的文件。**没有任何运行期下载的可执行代码** |
| 生成物性质 | QEMU 的 TCG 后端按**固定模板**把客户机指令翻译成宿主导机器码，并把客户机内存访问改写成经过 QEMU 软件 MMU（softmmu）的访存；**不会把客户机字节直接跳过去执行**，也不是"通用 `eval` 机器码" |
| 代码缓存 | 只通过 MAP_FORT 内存分配，只用 JITFort 接口写入生成代码；写完后置为只读/可执行（W^X），不复用可写页 |
| 权限最小化 | 只申请 `ALLOW_USE_JITFORT_INTERFACE` 一项；**不申请** `ALLOW_EXECUTABLE_FORT_MEMORY`（那是系统 JSVM 专用），也不申请其它受限权限 |
| 完整性 | 两个 QEMU `.so` 随 HAP 签名分发，运行期校验文件存在与哈希后再 `dlopen` |

### 2.4 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| JIT 被滥用为注入通道 | 只有 QEMU 自己的翻译器写入代码缓存；应用不暴露"任意代码 → 可执行页"的接口；JS 侧（`run_js`）仍使用系统 JSVM 且**不开 JIT** |
| 恶意工作区文件 | 与普通 shell 同等风险：命令本身受模型能力与用户可见的工具调用记录约束；VM 只能看到本会话工作区（virtio-9p + bind mount），破坏面是应用沙箱内的文件 |
| 坚盾守护模式 | 系统开启时全局禁用 JIT：应用探测失败即回退 TCI，不崩溃、不降级 |
| 权限未获批 | 商用包不声明该权限，默认走 TCI；批准后带新 profile 重打包才启用 JIT |
| 电量/发热 | 空闲 10 分钟自动关机；JIT 只在用户显式打开"性能模式"时启用（可加设置项） |

### 2.5 用户可控与可观测

- 设置页展示"Linux VM 加速：JIT（需系统授权）/ 解释执行"的当前状态；
- AI 的每次 shell 调用都有工具调用记录（命令、退出码、耗时），用户可审计；
- 关闭 shell 工具即不启动虚拟机。

---

## 3. AGC 表单字段对照

| 表单字段 | 填写 |
| --- | --- |
| 权限名称 | `ohos.permission.kernel.ALLOW_USE_JITFORT_INTERFACE` |
| 起始版本 | API 8 起可用（当前 targetSdkVersion 24） |
| 使用场景 | 应用自研的虚拟机内代码生成（QEMU TCG），用于本地 Linux 命令执行 |
| 申请理由 | 见上文第 1 节短版 |
| 是否可回退 | 是：无权限/坚盾模式自动回退 TCI 解释执行 |
| 涉及数据 | 仅设备本地应用沙箱文件与随包镜像，不涉及网络下发代码 |

---

## 4. 如果改走 JSVM 那条路（另一个权限）

只有当你希望**让 `run_js`（系统 JSVM 沙箱）本身开 JIT** 时，才申请 `ALLOW_EXECUTABLE_FORT_MEMORY`，
理由换成：

```
我们的应用内置基于 JSVM-API 的 JS 执行沙箱（run_js），用于让 AI 在设备端完成数值/日期计算、
正则清洗、JSON 重塑与统计汇总。该沙箱是纯计算环境：不联网、不读写文件系统、不支持模块加载，
输入只有用户工作区里的文本与模型生成的脚本，输出为文本或受限写回文件。默认解释执行下，
较长脚本的执行耗时明显；我们希望启用 JSVM 引擎的 JIT 以提升执行效率，申请
ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY。该权限仅用于系统 JS 引擎的即时编译，
不涉及任何网络下发的代码，且坚盾守护模式开启时应用照常以解释方式运行。
```

---

## 5. 建议附上的材料

1. **功能截图**：工作模式里一次 shell 调用的工具卡片（命令 + 退出码 + 耗时），以及 `uname -a` 输出；
2. **架构图**：App 进程 → `libqemu-system-aarch64-*.so` → Alpine 用户态 → 9p 挂载的工作区；
3. **两套构建说明**：`tooling/linux-vm/deps/libqemu/Makefile` 里 `--enable-tcg` 与
   `--enable-tcg-interpreter` 的差异（证明只换开关、不改引擎）；
4. **回退说明**：`LinuxShellService` 中"TCI 优先、JIT 兜底"的加载顺序；
5. **权限清单**：`module.json5` 当前只声明 `INTERNET`、`MICROPHONE`、`KEEP_BACKGROUND_RUNNING`（均为普通权限）。

> 提醒：材料里不要写"提升性能"这类空话，要写清**为什么解释执行不可用、生成代码从哪来、为什么不是注入通道**——
> 审核方关心的正是这三件事。
