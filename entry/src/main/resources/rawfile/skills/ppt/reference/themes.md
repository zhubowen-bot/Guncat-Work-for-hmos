# 主题系统

`write_pptx` 传 `theme` 参数（或在 deck JSON 顶层写 `"theme"`）；`edit_ppt` 用 `{"op":"set_theme","theme":"…"}` 换肤。未知主题名回退 brand-blue。

> **重要：8 套预设只是色板基座，禁止裸用纯色默认模板。** 新建 PPT 必须：① 按 `reference/visual-styles.md` 选定视觉风格；② 用 `themeOverride` 把主题扩展为至少两色以上混搭；③ 每页用 `background.image` 叠加纹理/图案/勾边。用户给了模板/品牌规范时以用户为准。

## 8 套预设

| id | 名称 | 主色 | 气质 | 适用 |
|---|---|---|---|---|
| brand-blue | 品牌蓝 | #0A7AFF | 清爽商务（默认） | 通用、汇报 |
| midnight | 午夜 | #38BDF8 深底 #0B1220 | 深色科技 | 技术分享、产品发布 |
| forest | 墨绿 | #1E7A55 | 沉稳自然 | 方案、农业/健康 |
| sunset | 暖橙 | #E8590C | 热情活力 | 路演、市场、活动 |
| violet | 雅紫 | #7048E8 | 现代创意 | 设计、品牌 |
| graphite | 石墨 | #343A40 + 红点缀 | 极简克制 | 高管汇报、严肃议题 |
| ivory | 象牙 | #2B4C7E 米白底 | 学术纸感 | 教学、研究、论文答辩 |
| crimson | 绯红 | #C92A2A | 强调有力 | 警示、复盘、动员 |

每套主题包含完整色板：primary（主色/顶栏/项目符号/图表系列1）、accent（强调/图表系列2）、bg（页面底色）、surface（表格隔行/浅卡片）、title/body/sub/faint（四级文字）、series（图表 6 色板）。深色主题（midnight）会自动切换图表坐标与网格配色。

## 自定义主题（多色混搭）

在 deck JSON 顶层用 `themeOverride` 覆盖任意色字段（未给的字段继承所选预设）。**至少覆盖 primary + accent + bg + surface，保证双色以上混搭，避免纯色模板感**：

```json
{"title":"…","theme":"brand-blue",
 "themeOverride":{"primary":"0A3D62","accent":"E8590C","bg":"F7F3EC","surface":"EFE6DA"},
 "slides":[…]}
```

可覆盖字段：primary / accent / bg / surface / title / body / sub / faint（6 位 hex，可带 #）。

使用原则：
- 用户点名主题或指定颜色时才自定义；自己创作时**必须**按 `reference/visual-styles.md` 选风格并扩展色板，不要只给单一主色。
- 全册一个 theme；`edit_ppt` 的 set_theme 可整体换肤（版面结构不变）。
- 深色主题下不要再给 content 页设浅色 background.color，会失去对比。
- **每页视觉**：在 deck 中给页面加 `background.image`（纹理/图案 SVG）与 `background.overlay`（0~0.6 按文字可读性调），让整册呈现纹理/勾边/图案/花色，而不是纯色底。
