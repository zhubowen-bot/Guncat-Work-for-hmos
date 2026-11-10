# AGENTS.md

本文件约定在本仓库工作的 AI 编码代理与自动化助手需要遵守的流程。目标不是把每一步写死，
而是保证每次改动都能落地：**能构建、能追溯、文档一致、版本号不漂移**。

用户当次明确说明的例外优先于本文。没有例外时，按下面的顺序执行。

---

## 0. 仓库速览

- HarmonyOS 原生应用，ArkTS / ArkUI，入口模块是 `entry`。
- 应用代码在 `entry/src/main/ets/`；随包资源在 `entry/src/main/resources/rawfile/`
  （含「玩转应用」、技能文档、智能体提示词）。
- 设备内原生执行核在 `third_party/bettersh/iec/`，作为 `iec` 模块参与构建。
- 测试与离线验证在 `test/`；项目文档在 `docs/`。
- 本地构建门槛是 `tools/build-check.ps1`，它调用本机 DevEco Studio 的 hvigor 打包 HAP。

---

## 1. 开始前

1. 读 `README.md`、`CONTRIBUTING.md` 和本次改动相关的 `docs/` 文档。
2. 跑 `git status --short`，确认工作区里有没有别人的未提交改动。不要覆盖、回退或顺手提交
   与本次任务无关的文件。
3. 判断这次改动是否影响用户可见行为、版本号、发布物或其他文档。影响范围不清楚时，先查
   文档和代码，不要猜。
4. 没有明确要求时，**不升版本号**。

---

## 2. 每次任务的固定流程

1. 实现改动。
2. 同步受影响的文档（见 §5）。
3. 更新 `CHANGELOG.md`（见 §4）。只写用户可见的产品变化；纯文档、注释、测试、构建脚本改动不写。
4. 用本机 DevEco Studio 跑 HAP 构建（见 §6）。**构建不通过不提交。**
5. 跑与改动相关的检查（单元测试、`tsc`、文档链接检查等）。
6. `git diff` 自查：有没有调试代码、生成物、无关格式化、错别字。
7. 提交 git（见 §7）。一个任务至少留下一个可回滚的提交。
8. 汇报：改了什么、构建结果、提交哈希、版本号是否变化、还有哪些没验证。

只读排查、没有产生文件改动的任务，不需要为了“必须提交”造一个空提交。

纯文档改动（只改 Markdown、注释，不涉及应用代码、资源和构建配置）跳过第 4、5 步的
HAP 构建与相关检查，其余步骤照常执行。

---

## 3. 版本号

### 默认规则

- 没有人明确说“发布 x.y.z”“把版本号同步到 x.y.z”时，保持现有版本号不变。
- `CHANGELOG.md` 顶部用 `## 未发布` 收纳当前开发周期的内容，不要自己编一个版本号。
- 不要为了让 changelog 看起来完整而改 `AppScope/app.json5`、`Constants.APP_VERSION` 或
  README 徽章。

### 明确要求升版本时

先确认目标版本号和 versionCode。仓库现有 7.x 的 versionCode 按
`major*100 + minor*10 + patch` 递增（7.2.0 → 720）；如果用户给了明确值，以用户给的为准。
然后同步下面所有位置：

| 位置 | 需要同步的内容 |
| --- | --- |
| `AppScope/app.json5` | `versionName`、`versionCode` |
| `entry/src/main/ets/common/Constants.ts` | `APP_VERSION` |
| `README.md` | 版本徽章、当前应用版本行、更新记录表格中的版本范围 |
| `README_EN.md` | 同上（英文） |
| `entry/src/main/resources/rawfile/玩转应用/index.html` | 首页 `hero-sub`、新功能入口、新版本子页 |
| `entry/src/main/resources/rawfile/玩转应用/维护指南.md` | 版本页记录与本次修订说明 |
| `CHANGELOG.md` | `## 未发布` 改为 `## X.Y.Z（YYYY-MM-DD）` |
| `docs/guides/device-verification.md` | “应用版本 X.Y.Z”等当前版本引用 |
| `docs/architecture/background-keepalive.md` | “适用版本”等与当前版本绑定的说明（仅相关时） |

`docs/releases/` 与 `docs/ALIGNMENT_STATUS.md` 是三端发布材料，**不在单仓库版本同步范围内**。
只有满足 §3.1 的条件时才处理。

同步完用旧版本号全仓搜索一遍，确认没有遗漏：

```bash
rg -n "<旧版本号>|<旧 versionCode>" --glob '!entry/build/**' --glob '!third_party/**'
```

历史发布说明（`docs/releases/v6.x.md`、`v7.0.0.md` 等）和 `CHANGELOG.md` 里已经发布的旧版本
小节保持原样，不要把历史记录改成新版本号。

### 3.1 三端同步

`docs/releases/`、`docs/ALIGNMENT_STATUS.md` 以及跨平台发布说明描述的是 PC / Android /
HarmonyOS 三端的共同状态，不能根据鸿蒙版单仓库的改动推断。

只有下面条件同时满足时才动这些文档：

1. 上级目录里能找到三个仓库：
   - `../Guncat-Work-for-hmos`
   - `../Guncat-Work-for-android`
   - `../Guncat-Work-for-pc`
2. 本次改动确实在三端都实现或确认过，或者用户明确要求做三端对齐。
3. 已经读过另外两个仓库的当前版本、`CHANGELOG.md`、发布说明和实际功能状态。

缺一个仓库、或只改了鸿蒙版，就不要更新 `docs/releases/` 与 `docs/ALIGNMENT_STATUS.md`；
在汇报里说明“三端文档未动，因为只有当前仓库的改动”。

三端同步时：

- 以三个仓库的实际状态为准，不把鸿蒙版的实现细节直接套到 PC / Android。
- 发布说明里的平台差异、产物表、版本号分别核对；没有实现的功能写“—”，不要补想象。
- `docs/ALIGNMENT_STATUS.md` 的日期、三端版本和差异项按另外两个仓库的当前状态改。
- 改完在三个仓库分别提交；不要在一个仓库的提交里假装三端都改完了。

---

## 4. CHANGELOG

`CHANGELOG.md` 是发布记录，不是工作日志。

### 写什么

- 用户能感知的新功能、行为变化、界面变化、兼容性变化。
- 已发布版本里存在的缺陷，在这次改动中被修复：写清现象和最终修复，不写内部返工过程。
- 用户需要知道的限制、迁移动作、配置变化。
- 影响使用方式的性能 / 稳定性改进。

### 不写什么

- 只改文档、注释、README 措辞、协作约定、模板、测试或构建脚本，没有改变应用行为。
- 本次开发过程中写错、被指出、又改回来的东西。它没有进入任何已发布版本，不属于 changelog。
- “按用户要求”“根据反馈”“AI 修正了……”这类过程描述。
- 纯内部重构、测试补充、构建脚本调整、注释和格式变化，除非它们改变了用户可见行为。
- 文件级流水账、堆栈、逐行实现细节。
- 为了显得丰富而编造的影响或数据。

### 格式

```markdown
## 未发布

### 主题

- **短标题**：做了什么、用户会看到什么变化、有什么边界。
```

- 按主题分组，不按文件分组。
- 一条只讲一件事；标题写行为，不写“优化”“修复若干问题”这种空话。
- 技术细节可以写，但只写帮助理解行为、边界和取舍的部分。
- 发布时把 `## 未发布` 改成 `## X.Y.Z（YYYY-MM-DD）`，不要保留“未发布”字样。

### 判断标准

先问一句：这次改动会不会让用户在使用应用时看到、用到或感受到不同？不会，就不写。文档维
护、流程调整、给代理看的说明都不属于 changelog。

改动只存在于当前未发布版本、且是开发过程中产生的返工，不写。改动修复的是已经在某个已
发布版本里出现的问题，写。

---

## 5. 文档同步

文档是这个仓库交付物的一部分。改代码前先找对应文档，改完后回写；不要等发版再补。

| 改动类型 | 通常需要同步 |
| --- | --- |
| 用户可见功能、设置项、交互变化 | `README.md` / `README_EN.md`、`docs/features.md`、`docs/guides/usage.md`；发版时加「玩转应用」 |
| 架构、运行时、数据流 | `docs/architecture/` 下对应文档 |
| shell / Python / 原生库 | `docs/architecture/release-checklist.md`、`docs/guides/device-verification.md`、相关 Python 文档 |
| 界面截图、示意图 | `docs/images/`；玩转应用配图放 `entry/src/main/resources/rawfile/玩转应用/assets/` |
| 版本号、发布物 | §3 的完整清单 |
| 三端发布说明、三端对照 | `docs/releases/`、`docs/ALIGNMENT_STATUS.md`；只有满足 §3.1 才动 |
| 协作流程 | `CONTRIBUTING.md`、`AGENTS.md`、`docs/architecture/release-checklist.md` |

要求：

- 文档里的行为描述必须和代码一致；不要保留“旧版本这样做”的过期段落，除非它明确标注为历史。
- 改术语、入口名、文件名时，用旧词全仓搜索，连同文档、注释、提示词一起改。
- 中文文档用中文；`README_EN.md` 用英文。代码注释沿用仓库现有语言。
- 文档改完跑：

  ```bash
  python tooling/docs-check.py --strict
  ```

  坏链会让 CI 失败。

---

## 6. HAP 构建

CI 不装 DevEco Studio，真实 ArkTS 编译和 HAP 打包必须在本地完成。每次任务只要产生文件改动，
提交前都要跑一次；纯文档改动（只改 Markdown、注释）不需要跑构建和检查。

### 命令

在仓库根目录：

```powershell
powershell -ExecutionPolicy Bypass -File tools/build-check.ps1
```

脚本会：

1. 用 DevEco 自带的 Node / hvigor 准备工具链；
2. 跑服务层 `tsc`；
3. 跑文档链接、随包 `.so`、许可检查（本机有 WSL rootfs 时）；
4. 执行 `assembleHap`。

默认路径是 `C:\Program Files\Huawei\DevEco Studio`。如果本机装在其他位置，先改脚本顶部的
`$deveco`，不要跳过构建。

### 什么时候加 `-Full`

改到 `entry/libs/arm64-v8a`、`third_party/bettersh/iec`、`rawfile/python`、
`entry/src/main/cpp/python`、`PythonService.ts` 或 shell 运行库时，加：

```powershell
powershell -ExecutionPolicy Bypass -File tools/build-check.ps1 -Full
```

`-Full` 会多跑约 10 分钟的 Python 运行库自检。普通 UI / 文档改动不需要。

### 结果

- 以脚本输出为准；成功时应看到 `BUILD SUCCESSFUL`。
- 构建产物在 `entry/build/default/outputs/default/`，常见文件名 `entry-default-unsigned.hap`；
  签名配置生效时以实际输出为准。
- 失败就修，修完重跑；不要在失败状态下提交，也不要把“之前构建过”当成这次通过。
- 本机确实没有 DevEco Studio 时，明确说明哪一步没跑、为什么；不要伪造构建结果。

---

## 7. Git 提交

### 规则

- 每个产生文件改动的任务都要提交；不要把多个无关任务攒在一个提交里。
- 提交前 `git status --short` 和 `git diff --stat`，只 stage 本次相关的文件。
- 工作区里如果有用户未提交的改动，不要擅自 stage、覆盖或回退；在汇报里说明。
- 不提交 `build/`、`entry/build/`、`.hvigor/`、`test/*/gen/`、`test/*/check/` 等生成物。
- 提交信息用 Conventional Commits，描述用中文。

### 类型

`feat` / `fix` / `docs` / `style` / `refactor` / `chore` / `test`

### 示例

```text
docs: 补充 AI 协作流程与任务请求模板
feat(usage): 新增按日聚合的用量热力图
fix(mode): 切换模式时进入目标模式的新建对话
chore(release): 同步 7.3.0 版本号与发布说明
```

提交信息写行为，不写“用户要求”“按指示修改”。需要解释原因时放提交正文，仍然不要写过程
八卦。

---

## 8. 「玩转应用」页面

位置：`entry/src/main/resources/rawfile/玩转应用/`。首页是 `index.html` 里的 `view-home`，
每个子页是一个 `<section class="view" id="view-xxx">`。

### 新增版本页

1. 首页「新功能体验」面板最前面加入口卡，链接到新子页。
2. 新增 `view-0NN` 子页，页名统一为 `Version X.Y 新功能体验`。
3. 配图按 `0NN-1.png`、`0NN-2.png` 顺序命名，放在 `assets/`；轮播图与介绍卡数量、顺序
   一一对应。
4. 首页 `hero-sub` 同步为 `Version X.Y.Z (versionCode_1)`。
5. 更新 `维护指南.md` 的版本记录。
6. 如果这次是升版本，按 §3 把其他版本位置一起改完。

### 标题

- 需要保证不重复的是首页「新功能体验」面板的入口卡标题，比如“看看 Version 6.2 带来哪些新
  体验”“了解 Version 6.3 的重磅功能更新”“探索 Version 7.0 开启的生产力革命”“感受
  Version 7.2 的顺手升级”。新增版本时，入口卡标题要和这些旧入口换一个说法，不要复用同一
  句式或关键词。
- 新增入口卡前，先在 `index.html` 的首页「新功能体验」面板里搜一遍已有标题。
- 功能页内部的卡片标题按本版本的功能写，不要求和旧版本避让；每个版本功能不同，标题自然
  不同，准确、具体即可。
- 入口卡和功能卡都写用户得到什么，不写实现名。比如“换模式，从一条新对话开始”，不要写
  `selectAgentForNewConversation`。

### 文案

- 面向普通用户，不是技术评审。说清楚：能做什么、在哪里用、用起来有什么变化。
- 不堆协议名、类名、文件路径、复杂度、原子提交之类的实现细节。必须提技术名词时，用一句
  人话解释。
- 也不要写成口水话或营销稿：少用“重磅”“来啦”“心心念念”，少用感叹号，不写空泛的
  “体验全面升级”。
- 一张卡 1–3 段，每段 1–3 句；先讲结果，再讲边界。参考 7.0 / 7.2 两页的密度和语气。
- 不编造截图里没有的功能、数字或承诺。

### 配图

- 规格：1000×1330 PNG，浅蓝渐变背景，顶部白色胶囊写 `Version X.Y 新功能体验`，左侧大号
  蓝色序号（01、02…），下方粗体黑色标题、灰色副标题，底部放简洁的界面示意卡。
- 风格参照 `assets/011-*.png` 和 `assets/012-*.png`：同一套配色、字体层级和留白，不混用
  3D 图标、照片或复杂插画。
- 用图像生成工具直接产出，不要等用户截图；图里的中文要检查，出现乱码、错字或多余文字就
  重生成。
- 一张图对应一张卡；增删时图、卡、`alt` 文本一起改，数量必须一致。
- 图片直接放 `assets/`，页面用相对路径引用，不写外链。

---

## 9. 最小需求模板

用户不需要描述完整流程，填 `docs/templates/task-request.md` 即可。没填的项按默认值处理：

- 版本号：不改。
- `CHANGELOG.md`：有用户可见变化才记在 `## 未发布`；纯文档、流程改动不写。
- 是否发布：否。
- HAP 构建、文档同步、git 提交：默认执行。

模板全文：

```markdown
# 任务请求

## 目标

（一句话说明要做什么，以及用户能看到的结果。）

## 版本

- 版本号：不改 / x.y.z
- versionCode：自动 / 指定
- 是否发布：否（保留“未发布”）/ 是

## 验收

- 必须做到：
- 不要出现：

## 参考

- 相关页面 / 截图 / 旧版本：
```

---

## 10. 图标与性能约定

### 图标

- 鸿蒙版图标一律采用 HarmonyOS 系统自带图标。
- 系统图标匹配度确实不高时，可以仿照系统自带图标的风格自行绘制图标，风格与系统图标保持一致。
- 禁止使用 Emoji、纯文本字符等充当图标。

### 性能与内存

- 鸿蒙版开发全过程都要特别注意性能与内存的优化和调度，把性能开销作为每次改动的评估项。
- 本项目对性能的敏感度极高：涉及长上下文处理、工具调用等场景，本身开销就大；且鸿蒙版预留的可用内存和性能余量有限。
- 新增代码前先评估内存占用与计算开销：避免常驻大对象、重复拷贝大文本、不必要的全量刷新或高频定时任务；能流式/分页处理的不要一次性全量加载。

---

## 11. 完成标准

- [ ] 行为已实现，相关测试 / 检查通过。
- [ ] 受影响的文档已同步，`docs-check` 无坏链（纯文档改动可跳过）。
- [ ] 用户可见变化已写入 `CHANGELOG.md`；没有自行升版本。
- [ ] 本机 HAP 构建通过（`BUILD SUCCESSFUL`；纯文档改动可跳过）。
- [ ] 只提交了本次相关文件，提交信息符合约定。
- [ ] 汇报中包含提交哈希、构建结果、版本号状态和未验证项。
