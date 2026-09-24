# PPT 视觉风格与装饰配方（Visual Styles）

**用途**：新建 PPT 时选定一套视觉风格，并据此生成全册装饰 SVG。本文件是“不要纯色默认模板”的落地目录。

**选择规则**：
1. 先按主题/受众选一个主风格（下表 8 类，可自定义）。
2. 全册只用一个主风格；配色、纹理、勾边、花色、母题全程一致。
3. 每页都必须有装饰：`background.image` 放纹理/图案，或 `custom` 页放 SVG 装饰元素；封面/分节/结尾页同样要有。
4. 禁止裸用 8 套预设的纯色底；至少用 `themeOverride` 把 `primary/accent/bg/surface` 扩成双色以上混搭。

---

## 风格目录

| 风格 | 适合 | 主色板（2~4 色） | 纹理/图案 | 勾边 | 母题/花色 |
|---|---|---|---|---|---|
| **科技赛博** | AI/软件/产品发布/技术分享/路线图 | 深底 `#0B1220` + 青 `#38BDF8` + 品红 `#E879F9` + 白 | 点阵网格、电路线、扫描线、六边形蜂巢 | 细青色描边、断点线 | 发光节点、角标、信号波 |
| **国风古韵** | 文化/国学/节气/非遗/品牌故事 | 宣纸米白 `#F5EFE3` + 墨黑 `#2B2B2B` + 朱红 `#C0392B` + 青绿 `#1F6F5C` | 纸纹、水墨晕染、细密回纹、云纹 | 细墨线、印章红边 | 印章、山水线、回纹、竖排标题 |
| **极简几何** | 咨询/高管汇报/设计提案/通用 | 石墨 `#343A40` + 白/米白 `#F7F5F2` + 一个高饱和强调 `#E8590C` | 细网格、半透明大圆、线条交织 | 单侧粗边/细线 | 圆、三角、方形的克制组合 |
| **杂志编辑** | 城市/文化/人物/品牌长读/回顾 | 暖中性底 `#F2EBDD` + 墨 `#1F1B16` + 品牌高饱和色（如 `#D64545`） | 纸纹、胶片颗粒、大留白、分栏线 | 细 folio 页码线 | 大数字、引号块、图片裁切 |
| **商务专业** | 经营复盘/战略/商业计划/金融 | 藏青 `#0A3D62` + 金/琥珀 `#D4A017` + 浅灰 `#F2F4F7` | 细横线、轻微纹理、几何角标 | 细金线/深蓝线 | 数据条、KPI strip、箭头 |
| **学术论文** | 答辩/研究/学术报告 | 米白 `#FDFCF8` + 深蓝 `#2B4C7E` + 红褐 `#8B3A3A` | 纸张纹理、脚注线、小网格 | 细深蓝线 | 引用块、编号、图表框 |
| **路演冲击** | 发布会/融资/新品 | 深色 `#111111` + 荧光 `#D4FF3F` 或橙红 `#FF4D00` + 白 | 大色块、斜切、扫描、粗颗粒 | 粗荧光描边 | 超大数字、斜切标签、聚光灯 |
| **暖调手作** | 教育/社区/生活方式/轻松分享 | 奶油 `#FFF3E2` + 珊瑚 `#FF7A59` + 鼠尾草 `#8FAE8B` | 手绘虚线、圆点、纸胶带纹理 | 手绘描边 | 圆角贴纸、手绘箭头、涂鸦 |

---

## 通用实现骨架（每页装饰）

无论哪种风格，建议先建立 3 类 SVG 资产并全册复用：

1. **背景纹理** `assets/ppt-decor/<style>-texture.svg`：
   - 尺寸 1280×720，`viewBox="0 0 1280 720"`；
   - 低透明度图案铺满，例如科技网格/国风回纹/极简点阵；
   - 在 Deck 中每页 `"background":{"image":"assets/ppt-decor/<style>-texture.svg","fit":"cover","overlay":0}`。
2. **角标/边饰** `<style>-corner.svg`：
   - 只画左下/右上角装饰，保持中间大面积透明；
   - 内容页 `background` 或 custom 元素复用。
3. **母题图** `<style>-motif.svg`：
   - 全册重复出现一次的元素（如印章、信号波、大圆），用于封面/分节/quote/end。

### 科技赛博示例：背景网格

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720" viewBox="0 0 1280 720">
  <title>科技网格纹理</title>
  <defs>
    <pattern id="grid" width="48" height="48" patternUnits="userSpaceOnUse">
      <path d="M48 0H0V48" fill="none" stroke="#38BDF8" stroke-width="1" opacity="0.16"/>
    </pattern>
    <radialGradient id="glow" cx="80%" cy="20%" r="60%">
      <stop offset="0%" stop-color="#38BDF8" stop-opacity="0.18"/>
      <stop offset="100%" stop-color="#0B1220" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="1280" height="720" fill="#0B1220"/>
  <rect width="1280" height="720" fill="url(#grid)"/>
  <rect width="1280" height="720" fill="url(#glow)"/>
</svg>
```

### 国风古韵示例：回纹边饰

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720" viewBox="0 0 1280 720">
  <title>回纹边饰</title>
  <path d="M40 60H140V100H80V140H140V180H40" fill="none" stroke="#C0392B" stroke-width="3" opacity="0.7"/>
  <path d="M1240 660H1140V620H1200V580H1140V540H1240" fill="none" stroke="#C0392B" stroke-width="3" opacity="0.7"/>
  <circle cx="120" cy="620" r="34" fill="none" stroke="#2B2B2B" stroke-width="2" opacity="0.5"/>
  <path d="M120 610l8 16-8 16-8-16z" fill="#C0392B" opacity="0.75"/>
</svg>
```

### 极简几何示例：角标

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720" viewBox="0 0 1280 720">
  <title>极简角标</title>
  <circle cx="1120" cy="160" r="90" fill="none" stroke="#E8590C" stroke-width="2" opacity="0.5"/>
  <circle cx="1120" cy="160" r="46" fill="#E8590C" opacity="0.14"/>
  <line x1="40" y1="680" x2="320" y2="680" stroke="#343A40" stroke-width="3" opacity="0.8"/>
  <line x1="40" y1="688" x2="200" y2="688" stroke="#E8590C" stroke-width="2" opacity="0.6"/>
</svg>
```

> 这些只是起点。AI 生成装饰时可按 svg 技能规范重写，但必须保持：透明底、低干扰、与主题色一致、全册统一母题。

---

## 每页配图（内容性视觉，V3 强制）

**装饰 ≠ 配图。** 装饰是纹理/角标/母题；**配图是“讲内容的图”**：流程图、时间轴、架构图、对比图、简单插画、信息图、数据可视化。每一页除了装饰，**还必须至少有一个内容配图**，不能只有纯文字 + 小图标。

### 文字转图对照（看到哪种内容就画哪种图）

| 页面内容 | 配图类型 | 说明 |
|---|---|---|
| 步骤/流程/因果/机制 | 流程图 | 节点 ≤7，箭头语义一致 |
| 阶段/里程碑/演进 | 时间轴 | 3~6 阶段，标关键节点 |
| 分层/系统/依赖 | 架构图/分层图 | 每层 2~4 节点，层级有含义 |
| 对比（我们 vs 旧方式、A vs B） | 对比图 | 双栏 + 图标/色块 |
| 组织/组件/构成 | 树/网络/关系图 | 分组 + 连线，避免交叉 |
| 概念/抽象观点 | 简单插画 | 用几何+图标表达语义，不写实 |
| 数字/指标 | KPI 卡/数据可视化 | 大数字 + 趋势小图 |
| 比例/转化/预算 | 分配条/漏斗/饼 | 参考 visual-components.md |

### 放置方式（不遮挡正文）

- **图文并排**：`image-text` 版式，`image` 指向配图 SVG（图占一侧 40~55%），另一侧放 3~5 条短要点。
- **自由版面**：`custom` 页用 `elements` 的 image/shape 摆配图 + 文字；坐标 0~1，先做机械越界/重叠检查。
- **背景承载**：封面/分节/quote/end 可用 `background.image` 放大幅配图 + `overlay` 保文字可读。
- **纯要点页禁止只有文字**：把至少一部分要点转成流程图/时间线/示意图；另一部分保留短要点。

### 配图纪律

- 与所选风格一致（配色、描边、圆角、字体同源），全册是一套图，不是每页换一种画风。
- 配图必须讲这页的内容：禁止放与内容无关的“示意图”凑数。
- 图内文字：中文 deck 用中文；短标签 ≤8 字，完整说明放正文/notes。
- 生成后用 `view_image` 预览，确认透明、可读、不抢内容、与主题色一致。

---

## 每页应用规则（强制）

- **内容页**：`background.image` 放纹理或角标；每页再配一个内容配图（`image-text` 或 `custom`），如流程/时间轴/架构/插画。
- **封面/分节/quote/end**：背景纹理 + 母题图，可加 `overlay` 提高文字可读性；封面极简，不塞要点，但可用大幅配图/插画做视觉主体。
- **图表/表格页**：装饰只在背景/边角，不与图表重叠；图表本身保持克制的主题色；图表页本身即“配图”，可不再叠加无关插画。
- **禁止**：同一张装饰图被不假思索地放大模糊；装饰喧宾夺主；每页换风格；纯色底+纯文字；用与内容无关的图凑“配图”。

## 主题映射建议

| 风格 | 建议 base theme | themeOverride 示例 |
|---|---|---|
| 科技赛博 | `midnight` | primary `#38BDF8`、accent `#E879F9`、bg `#0B1220` |
| 国风古韵 | `ivory` | primary `#C0392B`、accent `#1F6F5C`、bg `#F5EFE3` |
| 极简几何 | `graphite` | primary `#343A40`、accent `#E8590C`、bg `#F7F5F2` |
| 杂志编辑 | `sunset` | primary `#D64545`、accent `#1F1B16`、bg `#F2EBDD` |
| 商务专业 | `brand-blue` | primary `#0A3D62`、accent `#D4A017`、bg `#F2F4F7` |
| 学术论文 | `ivory` | primary `#2B4C7E`、accent `#8B3A3A`、bg `#FDFCF8` |
| 路演冲击 | `midnight` | primary `#D4FF3F`、accent `#FF4D00`、bg `#111111` |
| 暖调手作 | `sunset` | primary `#FF7A59`、accent `#8FAE8B`、bg `#FFF3E2` |
