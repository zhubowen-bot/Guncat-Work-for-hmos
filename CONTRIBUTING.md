# 参与贡献

感谢你有兴趣参与。Guncat Work 是一个**端侧优先**的 HarmonyOS AI 客户端：模块化 Agent Loop 内核、三协议流式对话、47 个内置工具、32 个技能，以及在设备本地直出 PPT / Word / Excel 的生成器。

这个仓库对"改动是否可靠"的要求比较高——它做的事情（Agent 循环、文档生成、界面渲染）出错时很难靠肉眼发现，所以下面这套验证流程不是形式主义，**每一层都在拦真实发生过的事故**。

欢迎提交 Issue 和 Pull Request。

---

## 环境要求

- **DevEco Studio 6.0.1** 或兼容版本
- **HarmonyOS SDK API 24**（6.1.1）
- **HarmonyOS 手机真机**（模拟器上 Preview Kit / Share Kit / CoreSpeechKit 等行为不一致）
- **Node.js ≥ 22.6**（harness 依赖原生 TypeScript strip；CI 用 Node 24）
- **Python 3.11+**，跑 Office 生成器验证时需 `python-docx`、`openpyxl`、`python-pptx`、`Pillow`

---

## 三层验证：为什么一层都不能省

### 第 1 层 · 纯逻辑单测（改 `common/` 必跑）

```bash
cd test/guncat-harness
node setup.mjs        # 把 entry/src/main/ets 下的纯逻辑模块移植为 Node 可运行的 .ts
node test-core.mjs    # 当前 754 项
```

覆盖 `PathMatcher` / `DiffUtil` / `EditCore` / `FileSearchCore` / `ToolRegistry` / `PromptBuilder` / `LoopDecisions` / `SSEProtocolAdapter` / `GuncatUiLang` 等纯逻辑，以及**大量提示词断言**；shell 工具结果正文拼装（`ShellResultFormat`：状态行/超时/信号/dropped/二进制/截断）也在这一层逐字回归。

### 第 2 层 · 服务层类型检查

```bash
cd test/guncat-harness
node check-setup.mjs                                              # 移植 + @kit.* 桩 → check/
npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json
```

### 第 2 层补充 · 源码级护栏（改 `views/` 下界面代码时看这条）

```bash
node test/guncat-harness/check-ui-copy.mjs
```

有些界面纪律**编译得过、单测也测不到**，漏了只表现为"真机上某块字没反应"。这类纪律用源码扫描守住：

- **`check-ui-copy.mjs`**：交互界面（`GuncatUiView.ets`）里每个**内容型** `Text` 都必须挂 `.copyOption(CopyOptions.LocalDevice)`（长按弹出文本选择菜单，可选中复制/全选），否则报错。**交互控件标签**（按钮 / 选项卡 / 单选多选药丸 / 下拉项 / 标签选项 / 折叠触发器 / 追问胶囊 / 行内动作 / 序号圆点）**必须豁免**——它们的整块区域就是点击热区，挂上选择能力会跟自己的点击事件抢手势——豁免的写法是行尾 `// copy-off: 原因`（原因不能为空）。新增组件时漏挂 `copyOption`，这条会立刻变红。

### 一键检查（本地 / CI 复用）

上面各层分散成多条命令，提交前建议直接跑一键入口：

```bash
bash scripts/check-all.sh          # 全量
bash scripts/check-all.sh --fast   # 跳过 soname / py_runner / IEC 命令集 / hexdump 属性对拍 / IEC exec 压测
bash scripts/check-all.sh --list   # 只看检查项清单
```

按顺序执行 17 项：纯逻辑单测（754 项）、服务层 `tsc`、界面文案可复制护栏、
Markdown 相对链接、随包许可、共享库 soname、`py_runner` 宿主协议、
IEC 命令集宿主测试、IEC hexdump 属性对拍（200 组随机输入）、IEC nc 属性/边界、
IEC diff 属性/边界对拍、mksh 64 位算术回归、toybox applet 解析交叉验证、
IEC 原生代码宿主回归、IEC exec 会话压测、存在时才跑的 `tools/check-iec-libs.py`，
以及 CA bundle 可用性（curl/python/git 真握手）。

- IEC 原生代码宿主回归对应
  `third_party/bettersh/iec/scripts/test_iec_native_host.sh`：在宿主编出
  `iec_server`，直接钉住 `ResolveKind` 的路由分类、cwd 无搜索权限必须拒绝、
  NCP 平台级拒绝分类，以及 fs shim 的绝对路径映射；不需要设备或 OHOS SDK。

- 单项失败不会中断后续项；每项打印 `==> 名称` 与耗时，末尾给出
  `SUMMARY: PASS=n FAIL=n SKIP=n`，有 FAIL 时整体非零退出。
- `--fast` 跳过的项计入 `SKIP`（不是失败）。
- 缺 Node / Python / 编译器、找不到 DevEco SDK 等环境依赖时会明确打印
  `跳过: 原因` 并继续，不会因缺依赖崩掉。
- soname 检查默认自动探测 DevEco / OHOS SDK 的 `native/llvm/bin`；也可手动指定
  `GUNCAT_LLVM_BIN=/path/to/native/llvm/bin`。WSL 里若只装了 Windows 版 DevEco，
  脚本会改用 GNU readelf 读取 ELF（Windows 的 `llvm-readelf.exe` 读不了 `/mnt` 路径）。

> 一键入口只覆盖宿主侧检查；第 3 层真实 ArkTS 编译仍需本机 DevEco，见下节。

### 第 3 层 · 真实 ArkTS 编译（**只有编译器才知道的规则**）

```bash
pwsh -File tools/build-check.ps1      # 调用 DevEco 自带的 hvigor，需本机装 DevEco Studio
```

前两层**测不出**这一层才能拦的东西：

- `@Builder` 方法体内不允许声明局部变量（只能写 UI 组件语法）
- 自定义组件的属性名不能与内置属性同名（`size` / `scale`）
- `@Prop` 的 null 需要显式联合类型

harness 只覆盖 `common/**` 与 `service/**` 的纯 TS，**不解析 `.ets`**。历史上这一层一次就拦下过 8 个编译错误。

> CI 能覆盖第 1、2 层和下面的 Office 验证；**第 3 层必须本地跑**——GitHub 托管 runner 上装不了 DevEco Studio + SDK + 签名。

### Office 生成器离线验证（改 `entry/src/main/ets/export/` 下任何文件必跑）

三个生成器各自带一个在 PC 上运行的验证环境，不依赖 DevEco 与真机：

```bash
# Word
cd test/docx-harness && node setup.mjs && node test-build.mjs && \
  python validate.py gen/out_all.docx && python deep-check.py

# Excel
cd test/xlsx-harness && node setup.mjs && node test-build.mjs && \
  python validate.py gen/out_all.xlsx && python deep-check.py

# PowerPoint（生成器最复杂，步骤最多）
cd test/pptx-harness && python makepng.py > png.b64 && node setup.mjs && \
  node test-build.mjs && node test-transform.mjs && node test-csv-glob.mjs && \
  node test-svg.mjs && \
  python validate.py gen/out_all.pptx gen/out_dark.pptx gen/out_outline.pptx gen/out_edit.pptx && \
  python deep-check.py
```

`validate.py` 查 zip / XML 结构 / 关系一致 / content-types，并用 `python-docx` / `openpyxl` / `python-pptx` 真实打开；`deep-check.py` 进一步读图表数据与内嵌的 JSON 中间层，验证**往返一致**。

> 跑完 harness 后，`test/*/gen/` 与 `test/*/check/` 下的生成物会被重写。提交前请回退无关改动：
> `git checkout -- test/`，并删掉多出来的 `gen/out_*.pptx`。

---

## 编码规范

### 一、ArkTS 硬约束（违反即编译不过）

ArkTS 不是 TypeScript 的超集，它砍掉了大量动态特性。**最容易踩的**：

| 不支持 | 改用 |
| --- | --- |
| `any` / `unknown` | 显式指定类型 |
| `var` | `let` |
| 解构赋值、解构变量声明、解构参数 | 临时变量；参数逐个手动命名 |
| 对象字面量直接用作类型声明 | 显式声明 `class` / `interface` |
| 用对象字面量初始化 `any` / `Object` / `object`、带方法的类、带参构造的类、含 `readonly` 字段的类 | 让字面量对应到明确声明的类或接口 |
| 索引签名、`obj["field"]` 动态访问 | 在类里声明字段，用 `obj.field`；数组用下标 |
| 函数表达式、嵌套函数 | 箭头函数（lambda） |
| `Function.apply` / `call` / `bind` | 传统 OOP 的 `this` 语义 |
| 独立函数与静态方法中使用 `this` | `this` 只能出现在实例方法 |
| 全局作用域 / `globalThis` | 显式模块导出与导入 |
| `for...in` 遍历对象 | 数组用普通 `for`；对象布局编译期已知 |
| 生成器函数 | `async` / `await` |
| 构造函数中声明类字段 | 在类声明体内声明 |
| `as const`、条件类型别名、`infer`、交叉类型、映射类型 | 显式类型、继承、常规类 |
| `is` 运算符 | `instanceof`（必要时先 `as` 转换） |
| `typeof` 用于类型标注 | 显式类型声明 |
| `catch` 子句的类型标注 | 省略标注 |
| `#private` | `private` |
| TS 工具类型 | 仅 `Partial` / `Required` / `Readonly` / `Record` 可用 |
| `export =`、`require`、导入断言、UMD、模块名通配符 | 常规 `import` / `export` |
| `Symbol()`（`Symbol.iterator` 除外） | 避免使用 |

另外两条容易忽略的：

- **所有 `import` 必须写在文件最前面**，不能夹在其它语句之间。
- **展开运算符**只允许把数组（或派生自数组的类）展开到 rest 参数或数组字面量中，其余场景手动解包。

> 完整清单（约 70 条，含每条的理由与替代写法）见 [`docs/harmonyos-default.md`](docs/harmonyos-default.md)。

### 二、HarmonyOS API 与资源

- 优先使用官方 API / UI 组件 / 动画；**任何不确定的语法和 API 都不要猜**，先查华为开发者官方文档。
- 调用前确认 API Level 与设备支持情况、是否需要在文件头 `import`、是否需要在 `module.json5` 中配权限。
- UI 展示引用的常量应定义在 `resources` 里并用 `$r` 引用，不要直接写字面值。
- **新增颜色等资源要同时考虑深色主题**（深色下"看不见按钮"是这个项目踩过的坑）。
- 新增国际化字符串时，每种语言都要补上，避免遗漏。

### 三、ArkUI 的隐性规则

- **不要**在 `@Builder` 方法体内声明局部变量。
- 自定义组件的属性名不能与内置属性同名（`size`、`scale` 等）。
- `@Prop` 的 null 需要显式联合类型。
- 动画优先用声明式 UI + `@State` 驱动；复杂子组件的动画加 `renderGroup(true)`；**动画过程中不要频繁改** `width` / `height` / `padding` / `margin`。
- `ForEach` 的键值不变时 ArkUI 会直接复用子组件、**连 item builder 都不执行**——需要重建时必须把变化编进 key 里。

### 四、本项目的红线

- **提示词边界有断言守着。** 交互模式与工作模式共用同一套循环和工具，但**行为纪律相反**。把工作模式的段落（`# 工作流程` / `四步法` / `交付前自检清单` / `# 输出丰富性原则`）拼回交互模式，`test-core.mjs` 会立刻变红——这是有意设计的守门员，不要为了让某个 case 过关而放宽它。
- **改了 `common/**` 的纯逻辑，要同步补/改 `test/guncat-harness` 的断言。** 这个仓库的习惯是"修一处缺陷，加一组断言"。
- **交互界面里的内容文字必须可长按自由复制。** `GuncatUiView.ets` 里每个展示内容的 `Text` 都要挂 `.copyOption(CopyOptions.LocalDevice)`；只有"整块区域就是点击热区"的控件标签才豁免，且要写清 `// copy-off: 原因`。由 `check-ui-copy.mjs` 守着（见上文「第 2 层补充」）。
- **界面里的数字必须来自真实数据**（文件 / 工具结果 / 用户输入），不要在提示词或代码里编造。
- 运行时只使用应用沙箱（`filesDir/workspaces/`）与系统安全组件；**不要新增存储权限**。
- 改动原生层（`entry/src/main/cpp`）**必须实机构建**，Node 侧只能做类型级检查（原生模块在 Node 侧是桩）。

---

## 改哪块看哪份文档

| 你要改的东西 | 先读 |
| --- | --- |
| Agent Loop、工具系统、技能、`run_js`、图谱生成链路 | [工作模式架构与维护指南](docs/architecture/work-mode.md) |
| 交互模式、`guncat-ui lang` 语言契约、界面渲染 | [交互模式架构](docs/architecture/interactive-mode.md) |
| 目录布局、数据流、核心组件 | [项目结构](docs/architecture/project-structure.md) |
| 客户端功能全貌 | [主要功能](docs/features.md) |
| 版本变更史 | [更新记录](CHANGELOG.md) |
| 待办与规划 | [`docs/BACKLOG.md`](docs/BACKLOG.md) |
| Agent Loop 逐轮改动记录 | [`docs/ITERATION_LOG.md`](docs/ITERATION_LOG.md) |

---

## 提交与 PR 流程

1. Fork 仓库，从 `main` 创建功能分支。
2. 完成修改，跑通上面对应的验证层（PR 模板里有勾选项，**别勾没跑过的**）。
3. 提交，遵循下面的提交信息约定。
4. 发起 Pull Request，说明**改了什么、为什么、怎么验证的**；有 UI 改动请附前后截图。

### 提交信息约定

仓库使用 Conventional Commits，描述用中文：

```
feat(interactive): 界面块被输出上限截断时自动续写
fix(mode): 换挡时深色滑块不再先闪在旧档位 —— 点击即落选中态 + 去掉过渡动画
docs: 拆分 README 为门面 + docs/ 深水区
chore(harness): 同步 ported Constants
```

- 类型：`feat` / `fix` / `docs` / `style` / `refactor` / `chore` / `test`
- `scope` 用模块名（`interactive` / `mode` / `sidebar` / `harness` / `export` 等）
- 描述写清**行为变化**，真机缺陷建议带上根因，例如上面那条 `fix(mode)`。

---

## 行为准则

- 讨论对事不对人；技术分歧用证据（日志、截图、最小复现）说话。
- 提 Issue 前先看一眼[常见问题](docs/guides/faq.md)与现有 Issue。
- 一个人维护的项目，回复可能不快，但每条都会看。
