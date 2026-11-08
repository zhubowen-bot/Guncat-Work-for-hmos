# 沉浸光感（API 26）架构与维护说明

> [← 返回 README](../../README.md)

沉浸光感是 ArkUI 在 **API 26.0.0** 引入的系统视觉能力：沉浸式系统材质（毛玻璃、折射、高光、阴影）+ 沉浸式空间动效（弹层形变、边缘流光、粒子动画）。它不在应用里自绘，而是**由系统按组件接管背景、边框、阴影**；应用只决定「开不开」和「哪些组件用什么材质」。

这份文档说明本应用的接入方式、兼容保护与平台限制。先记住一条边界：**材质只在系统划定的范围内生效**——弹窗类组件 / Toast / 菜单 / Popup / 半模态 / Slider / Toggle / Select 全页面生效；其余组件只在 `Navigation` / `NavDestination` 标题栏或横向 `Tabs` 的底部 TabBar 内生效。本应用已把**顶部公共头部**改成 `Navigation` 的自定义标题栏（`BarStyle.STACK`，内容区延伸至标题栏下方），因此头部背板与其中的按钮可以呈现材质；输入区、侧栏与抽屉仍是内容区的自绘容器，不在生效范围（见第 5 节）。

## 1. 能力开关：应用级 enable

应用的沉浸光感开关在 `entry/src/main/module.json5` 的 module 级 `metadata` 中：

```json5
"metadata": [
  {
    "name": "ohos.arkui.UIMaterial.state",
    "value": "enable"
  }
]
```

- **只对 entry 类型 module 生效**：本仓库只有 `entry` 一个 entry module，配置一次即可；HAR / 三方库里的同名配置不参与。
- **三种取值**：`default`（未配置时的默认值）、`enable`、`disable`。`disable` 会全局关闭，应用级与组件级设置都不生效。
- **低版本系统忽略未知 metadata**：API 26 以下的系统读不到这项能力，不会因为多一个 metadata 而安装失败或崩溃。
- **为什么用 `enable` 而不是 `default`**：`default` 模式下，Dialog / Toast / AlphabetIndexer 等组件只有在**没有主动设置**背景色、背景模糊、阴影时才会默认开启材质；本应用不少浮层自带背景与阴影，`default` 会把材质挡掉。`enable` 模式的优先级高于组件自身的背景色 / 模糊 / 阴影 / 边框，且覆盖的组件更多，适合「统一交给系统接管」。
- **前提是 targetSdkVersion**：开启沉浸光感要求应用的 `targetSdkVersion` 不低于 `26.0.0`（`build-profile.json5` 已从 `6.1.1(24)` 升到 `26.0.0`）；否则配置不生效。`compatibleSdkVersion` 仍为 `6.1.1(24)`，老设备可继续安装，靠第 4 节的 `apiAvailable` 保护。
- **没有用户开关**：效果强弱随系统「设置 → 沉浸光感」与深浅色模式自动调整，应用不提供独立开关，也不按设备写分级分支。

应用级开启后，以下组件/接口默认就有材质，**不需要逐个设置**：

| 类别 | 默认材质样式 |
| --- | --- |
| Toast | `THICK` |
| Dialog（AlertDialog / CustomDialog / ActionSheet / 各类 PickerDialog） | `ULTRA_THICK` |
| 菜单（`bindMenu` / 文本选择菜单等） | `THICK` |
| Select 下拉按钮 | 组件默认样式 |
| Toggle / Slider | 组件默认样式 |
| AlphabetIndexer 提示弹窗 | `THICK`（低算力设备不显示） |

注意三处例外：**Popup、Tips、`bindSheet` 半模态在应用级 `enable` 下不会默认开启**，需要组件级显式传入 `systemMaterial`；Select 的「下拉按钮」与「下拉菜单」由两个独立接口控制（`systemMaterial` / `menuSystemMaterial`），互不影响。

## 2. 统一适配层：`ImmersiveLight.ts`

`entry/src/main/ets/common/ImmersiveLight.ts` 是唯一的材质构造入口，解决两个问题：① 各调用点传同一套材质参数；② 把 API 26 接口收在一处做兼容保护。仓库里所有对 `uiMaterial.*` 与 `deviceInfo.apiAvailable('26.0.0')` 的直接调用都集中在这个文件，页面与 ViewModel 只调用它的静态方法；低版本拿到 `undefined` 就按「不设置材质」处理。

| API | 用途 |
| --- | --- |
| `ImmersiveLight.isAvailable()` | 当前设备是否支持沉浸式系统材质（系统 API ≥ 26 且设备能力探测通过） |
| `ImmersiveLight.level()` | 设备材质等级数值：`0` EXQUISITE / `1` GENTLE / `2` SMOOTH，`-1` 表示未探测或不可用 |
| `ImmersiveLight.barMaterial()` | 标题栏 / 浮动工具栏 |
| `ImmersiveLight.controlMaterial()` | 选择、开关、滑条等控件 |
| `ImmersiveLight.menuMaterial()` | 菜单 / 气泡 / 半模态 |
| `ImmersiveLight.dialogMaterial()` | 弹窗（`ULTRA_THICK`） |
| `ImmersiveLight.toastMaterial()` | 即时反馈 Toast（`THICK`） |
| `ImmersiveLight.describe()` | 环境诊断文本（设置 → 终端展示）：应用级开关 / 设备是否支持 / 材质等级 |
| `ImmersiveLight.material(surface)` | 按用途返回 `uiMaterial.Material \| undefined` |

用途到官方材质样式的映射（与官方「组件适配沉浸光感」推荐的厚薄一致）：

| 用途 | 枚举 | 官方样式 | 额外参数 |
| --- | --- | --- | --- |
| 标题栏 / 浮动工具栏 | `BAR` | `ULTRA_THIN` | EXQUISITE 设备叠加 `colorInvert`（自动反色） |
| 控件（选择 / 开关 / 滑条） | `CONTROL` | `ULTRA_THIN` | 非 SMOOTH 设备叠加 `interactive`（按压形变）+ `lightEffect`（点光源流光）；EXQUISITE 再叠加 `colorInvert` |
| 菜单 / 气泡 / 半模态 | `MENU` | `THICK` | — |
| 即时反馈 Toast | `TOAST` | `THICK` | — |
| 弹窗 | `DIALOG` | `ULTRA_THICK` | — |

约定：

- 材质默认自带阴影（`applyShadow: true`），**调用方不要再叠加自定义 `shadow`**；要自定义阴影必须先把 `applyShadow` 置为 `false`，否则两者冲突、重复绘制。
- **不要在设置了材质的组件上再写不透明的 `backgroundColor`、`backgroundBlurStyle`、`borderColor`/`borderWidth`**：材质层在背景层之下，这些属性会把材质盖住（官方 FAQ 的「背景色或背景模糊遮挡材质效果」）。需要透出材质时用 `Color.Transparent` 或干脆不设。
- 不要在同一子树里嵌套材质；不要在视频 / 动图等持续变化的内容上叠材质，也不要在超大区域或大量小区域上反复使用——材质是稀缺视觉资源，官方功耗优化要求控制面积与层数。
- `material()` 返回 `undefined` 表示「设备不支持 / 系统低于 API 26」，调用方**直接不设置 `systemMaterial`** 即可，保留原有背景。**不要**用 `uiMaterial.Material.empty` 冒充降级：`empty` 是「显式关闭该组件的沉浸光感」，会连应用级默认效果一起关掉；`undefined` 才是「恢复组件默认」。

## 3. 设备档位：由系统决定，应用只读

`uiMaterial.MaterialLevel` 有 `EXQUISITE` / `GENTLE` / `SMOOTH` 三档，分别对应高 / 中 / 低算力设备。**材质等级由设备决定且固定，应用只能通过 `uiMaterial.getGlobalMaterialLevel()` 读取，不能指定**；材质强弱还会随系统「沉浸光感」设置与深浅色模式变化，这部分应用无需适配。

应用侧只做两件「额外开销」的判断，不写分级策略：

- `colorInvert`（自动反色）只在 **EXQUISITE 设备 + BAR/CONTROL（ULTRA_THIN）** 上叠加——官方限制是低算力设备不生效、且只有 `THIN` / `ULTRA_THIN` 样式才反色，加在厚材质上是纯开销。
- `interactive` + `lightEffect`（按压形变与光效）只在**非 SMOOTH 设备**的 CONTROL 上叠加，用材质的交互反馈替代控件默认按压态；低算力设备不叠加，避免额外绘制。

> 注意不要和 **hdsMaterial** 混淆：`hdsMaterial.MaterialLevel` 额外有 `ADAPTIVE` 档、允许开发者主动设置；本应用用的是 ArkUI 的 `uiMaterial`，**没有 ADAPTIVE 这个概念**，也不需要写「档位自适应」分支——自适应本来就是系统行为。

能力探测结果会缓存（`probeState` / `deviceLevel`），且**模块加载期不访问 API 26 接口**，第一次取材质时才探测；`getGlobalMaterialLevel()` 读取失败时按 `-1` 处理，只影响「是否叠加反色 / 交互增强」，不影响材质本身。

## 4. 兼容保护：compatible 24 + `apiAvailable('26.0.0')`

`compatibleSdkVersion` 保持 `6.1.1(24)`，意味着 HAP 可以装进 HarmonyOS 6.1.1 老设备；而 `uiMaterial` 是 API 26 接口。按官方《ArkTS API 兼容性保护》要求：

- 所有 API 26 调用必须包在 `if (deviceInfo.apiAvailable('26.0.0'))` 内，**版本号写字符串字面量**；
- 只有 `if` 语句能触发编译期告警消除，**不支持**变量传参、自定义封装、三元表达式，也不支持与 `&&` / `||` / `!` 组合判断；
- 低版本设备上 `apiAvailable` 返回 `false`，代码走降级分支，不会访问新接口。

本应用的做法（`ImmersiveLight.ts`）：

1. `material()` 与 `probe()` 各有一层 `if (deviceInfo.apiAvailable('26.0.0'))` 字面量判断，`uiMaterial` 的构造与探测调用全部在判断内；
2. 探测加 `try/catch`：`isImmersiveMaterialSupported()` 抛错按「不支持」处理，`getGlobalMaterialLevel()` 抛错按 `-1` 处理；
3. 不可用时统一返回 `undefined`，调用方按「无材质」降级，不崩溃、不闪退，老设备界面保持原来的背景、描边与阴影。

维护时不要让新的 API 26 调用绕开这两层判断——包括以后新增的 `systemMaterial` 设置点。

## 5. 平台生效范围：哪些地方有材质

这是本次接入最重要的一条限制，官方原文的口径是：

- **全页面生效**：指定弹窗类组件（AlertDialog、CustomDialog、ActionSheet、各类 PickerDialog、SelectionMenu、AlphabetIndexer 提示弹窗、Text 开启 `copyOption` 后的文本菜单）；指定弹窗类接口（`PromptAction` 的弹窗/Toast、Popup、Tips、Menu、`bindSheet` 半模态）；`Slider` / `Toggle` / `Select`。
- **只在导航容器内生效**：其余组件必须位于 `Navigation` / `NavDestination` 标题栏，或横向 `Tabs` 且 `barPosition` 为 `BarPosition.End` 的底部 TabBar（悬浮样式还要求 `barOverlap: true`、`vertical: false`）。在普通内容区、自绘容器里设置 `systemMaterial` 不生效，日志会打印 `Material inactive: out of scope. Use component in navigation title bar or Tabbar.`

本应用的落地方式：

- **顶部公共头部已改成 `Navigation` 的自定义标题栏**：`ChatPage` 的主聊天列改为 `Navigation() { 内容 }`，原 `buildHeader()` 通过 `.title({ builder: this.buildHeader, height: 64 }, { barStyle: BarStyle.STACK })` 作为标题栏内容，标题栏背景由 `ImmersiveLight.barMaterial()`（`ULTRA_THIN`）接管，头部里的按钮处在标题栏范围内、同样可呈现材质。`STACK` 样式让内容区延伸到标题栏下方，消息列表顶部留出 `TITLE_BAR_HEIGHT`（64vp）的初始空白，上滑时消息从毛玻璃标题栏下方透出，形成沉浸层次。
- **输入区、侧栏、抽屉仍是内容区的自绘容器**，不在生效范围，给它们设置 `systemMaterial` 也不会显示；本次没有为它们改结构（输入区悬挂在底部、侧栏属于常驻布局，硬套 `Navigation` / 底部 TabBar 会改变现有交互，收益与风险不成比例）。
- 结论：**头部与所有弹层有材质；输入区、侧栏、抽屉没有**。这是平台规则的结果，不是配置写错。

> 关于「强制 EXQUISITE 档」：ArkUI 的 `uiMaterial.MaterialLevel` 由设备算力写死（高算力 EXQUISITE / 中 GENTLE / 低 SMOOTH），应用只能读取、不能指定；能主动设档的只有 HDS 的 `hdsMaterial`（`HdsNavigation` / `HdsTabs` 的 `SystemMaterialParams.materialLevel`）。本应用当前用 ArkUI 路径，档位跟随设备；如果确需强制 EXQUISITE，需把头部换成 HDS 导航标题栏（见第 8 节），且对低算力设备有卡顿/发热风险。

## 6. 接入点与维护约定

**应用级默认生效（无需逐个设置）**：Toast、Dialog、菜单、Select 下拉、Toggle、Slider、文本选择菜单。

**组件级显式设置**（需要统一材质用途、或组件在应用级 `enable` 下默认不开启时）：

| 位置 | 组件 | 材质 |
| --- | --- | --- |
| `ChatPage` 顶部公共头部 | Navigation 自定义标题栏 | `barMaterial()`（ULTRA_THIN，标题栏背景 + 头部按钮） |
| `ChatPage` 应用内 Toast（`showToast`） | 系统 Toast | `toastMaterial()`（THICK） |
| `ChatPage` 工作区弹层（`bindPopup`） | Popup | `menuMaterial()`（THICK） |
| `ChatPage` 模型选择弹层（`bindPopup`） | Popup | `menuMaterial()`（THICK） |
| `ChatPage` 阅读器语音菜单（`bindMenu`） | Menu | `menuMaterial()`（THICK） |
| `ChatViewModel` 的确认弹窗（删除会话 / 清空工作区 / 删除配置，`promptAction.showDialog`） | Dialog | `dialogMaterial()`（ULTRA_THICK） |
| `UsagePage` 的确认弹窗（用量清理，`promptAction.showDialog`） | Dialog | `dialogMaterial()`（ULTRA_THICK） |

`controlMaterial()` 是给后续在 Navigation 标题栏 / 底部 TabBar 内做控件级开启预留的；应用级 `enable` 已覆盖 Select / Toggle / Slider 的默认材质，暂不需要逐个设置。

设置 → 终端页新增「沉浸光感」只读行（`ImmersiveLight.describe()`）：显示「应用级已开启 / 已关闭 / 默认 · 设备支持 / 不支持 · 等级 EXQUISITE / GENTLE / SMOOTH」，用于快速确认「看不到效果」是环境原因还是界面原因。

配套的样式处理也收在接入点：弹层 / 弹窗的内容容器在 `ImmersiveLight.isAvailable()` 为真时把不透明背板背景设为透明、阴影归零，把层次交给系统材质；低版本保持原来的背景与阴影（例如 `WorkspaceBar` 工作区面板与模型选择弹层内容）。

新增浮层时的检查清单：

1. 先判断它属于哪一类：**弹窗类接口**（Toast / Dialog / Popup / Tips / Menu / Sheet）还是**普通容器**。普通容器只有放进第 5 节的导航标题栏 / 底部 TabBar 才有材质；不要给输入区、侧栏、抽屉这些自绘容器加。
2. 弹窗类优先用 `ImmersiveLight` 的现成方法，不要在各处手写 `new uiMaterial.ImmersiveMaterial(...)`。
3. 去掉会遮挡材质的 `backgroundColor` / `backgroundBlurStyle` / `shadow`；确实需要自定义阴影时先 `applyShadow: false`。
4. 材质参数一次定好并保持稳定，不要在定时器 / 滚动回调里反复改 `style` / `materialColor`，也不要频繁增删材质区域内的子节点。
5. 需要显式关闭某个组件的默认材质时用 `uiMaterial.Material.empty`，不要传 `undefined`。

## 7. 验证方式

- **API 26+ 真机**：进入聊天页上下滑动，确认消息从顶部毛玻璃标题栏下方透出、标题栏有通透的材质与描边高光；操作中确认 Toast / 确认弹窗 / 菜单 / Select / 开关 / 滑条呈玻璃材质；按压控件看是否有形变与流光；深色模式切换后材质随之变化。
- **档位确认**：设置 → 终端 → 「沉浸光感」行应显示「应用级已开启 · 设备支持 · 等级 EXQUISITE/GENTLE/SMOOTH」。等级由设备决定，高算力设备即 EXQUISITE；若显示「设备不支持」或「系统低于 API 26」，则任何界面都不会有材质。
- **低版本真机（API 24 / HarmonyOS 6.1.1）**：安装、启动、头部、弹层与菜单行为正常，无崩溃、无白屏；界面与升级前一致（无材质，头部保留原背景与阴影）。
- **日志检查**：如果误给输入区 / 抽屉这类内容区容器设置材质，确认日志出现 `Material inactive: out of scope`，说明这是平台限制而不是配置写错。
- **工作区弹层 / 阅读器语音菜单**：确认显式设置的弹层仍可正常交互（材质不吞点击、不改变弹层尺寸）。

## 8. 后续可扩展点

- **强制 EXQUISITE 档（HDS 路径）**：ArkUI 的 `uiMaterial` 只能跟随设备档位；如果产品上要求在所有设备强制 `EXQUISITE`，需要把顶部头部从 ArkUI `Navigation` 换成 `HdsNavigation`，在 `titleBar.style.systemMaterialEffect` 里设 `materialType: IMMERSIVE`、`materialLevel: EXQUISITE`，并用 `hdsMaterial.getSystemMaterialTypes()` 在低端设备上降级到 SMOOTH。代价是头部换成 HDS 标题栏结构（标题/菜单/返回键布局由 HDS 决定），且 `materialLevel: ADAPTIVE` 才是官方推荐值——强制 EXQUISITE 在低算力设备上有卡顿与发热风险。
- **底部 Tabs 悬浮页签**：若以后新增底部导航，可用 `barFloatingStyle` + `systemMaterial` 获得材质，条件是 `barOverlap: true`、`vertical: false`、`barPosition: BarPosition.End`。
- **输入区 / 抽屉 / 半模态面板**：`bindSheet` 半模态在应用级 `enable` 下默认不开材质，可按需显式接入；抽屉与输入区若未来愿意改成 `bindSheet` / Navigation 结构，也能获得材质，但属于交互重构。
- **更多弹窗类组件**：`Tips`、Toast 的 `options.systemMaterial`（本应用已用）、`bindSheet` 可按需接入；`CustomDialog` 的 `customStyle: true` 背板由开发者自绘，暂不支持材质。

## 9. 参考

- 官方文档：[沉浸光感简介](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-overview) · [开启沉浸光感](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-enable) · [组件适配沉浸光感](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-component-adaptation) · [功耗优化](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-constraints) · [常见问题](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-faq) · [uiMaterial API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-uimaterial) · [ArkTS API 兼容性保护](https://developer.huawei.com/consumer/cn/doc/harmonyos-releases/arkts-api-compatibility-warning-elim)
- 仓库内：[能力开关](../../entry/src/main/module.json5) · [材质适配层](../../entry/src/main/ets/common/ImmersiveLight.ts) · [主要功能](../features.md) · `build-profile.json5`（本机签名配置不入库；`build-profile.json5.example` 已是 API 26 配置，复制即用，无需手工改 `targetSdkVersion`）
