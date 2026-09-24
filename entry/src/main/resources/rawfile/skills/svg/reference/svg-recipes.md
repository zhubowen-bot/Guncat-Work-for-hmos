# SVG 配方（可直接套用的模板）

所有模板均带 `xmlns` + `width/height` + `viewBox` + `<title>`（实机栅格引擎要求根元素显式 width/height——缺了工具会自动补，但按模板写可一次成功）。按用途挑模板，改坐标/颜色/文案后经 write_svg 生成，view_image 确认。颜色用示例占位，放进 PPT 时换成主题色。

## 1. 描边图标（24 网格，通用骨架）

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 24 24" fill="none"
     stroke="#333F50" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <title>图标名</title>
  <path d="主路径"/>
  <circle cx="12" cy="12" r="9"/>   <!-- 按需组合基础形状 -->
</svg>
```

常用 path 片段（24 网格）：勾 `M5 13l4 4L19 7`；叉 `M6 6l12 12M18 6L6 18`；加号 `M12 5v14M5 12h14`；
右箭头 `M5 12h14M13 6l6 6-6 6`；文档 `M6 3h9l4 4v14H6z`。

## 2. 填充图标（强调/品牌色变体）

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 24 24">
  <title>星标</title>
  <path fill="#0A7AFF" d="M12 2l2.9 6.2 6.6.8-4.9 4.6 1.3 6.6L12 17l-5.9 3.2 1.3-6.6L2.5 9l6.6-.8z"/>
</svg>
```

## 3. 横向流程图（3 节点，改文案复用）

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="480" height="140" viewBox="0 0 480 140">
  <title>三步流程</title>
  <rect x="20"  y="40" width="120" height="60" rx="10" fill="#F2F6FC" stroke="#0A7AFF" stroke-width="2"/>
  <rect x="180" y="40" width="120" height="60" rx="10" fill="#F2F6FC" stroke="#0A7AFF" stroke-width="2"/>
  <rect x="340" y="40" width="120" height="60" rx="10" fill="#0A7AFF"/>
  <path d="M140 70h32M172 70l-8-5v10z" fill="#6B7280" stroke="#6B7280" stroke-width="2"/>
  <path d="M300 70h32M332 70l-8-5v10z" fill="#6B7280" stroke="#6B7280" stroke-width="2"/>
  <text x="80"  y="75" text-anchor="middle" font-family="sans-serif" font-size="14" fill="#333F50">采集</text>
  <text x="240" y="75" text-anchor="middle" font-family="sans-serif" font-size="14" fill="#333F50">清洗</text>
  <text x="400" y="75" text-anchor="middle" font-family="sans-serif" font-size="14" fill="#FFFFFF">分析</text>
</svg>
```

加节点：视框宽 = 160 + 160×n，节点 x = 20 + 160×i，箭头链随之平移。

## 4. 纵向层级/架构图

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="360" height="300" viewBox="0 0 360 300">
  <title>层级架构</title>
  <rect x="90" y="20" width="180" height="56" rx="10" fill="#0A7AFF"/>
  <rect x="30" y="150" width="140" height="56" rx="10" fill="#F2F6FC" stroke="#0A7AFF" stroke-width="2"/>
  <rect x="190" y="150" width="140" height="56" rx="10" fill="#F2F6FC" stroke="#0A7AFF" stroke-width="2"/>
  <path d="M180 76v30M180 106L100 148M180 106l80 42" fill="none" stroke="#9AA3AF" stroke-width="2"/>
  <text x="180" y="53" text-anchor="middle" font-family="sans-serif" font-size="15" fill="#FFFFFF">应用层</text>
  <text x="100" y="183" text-anchor="middle" font-family="sans-serif" font-size="14" fill="#333F50">服务 A</text>
  <text x="260" y="183" text-anchor="middle" font-family="sans-serif" font-size="14" fill="#333F50">服务 B</text>
</svg>
```

## 5. 信息图卡片（大数字 + 标签，PPT 内容页点缀）

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="300" height="160" viewBox="0 0 300 160">
  <title>关键指标卡片</title>
  <rect x="0" y="0" width="300" height="160" rx="14" fill="#F2F6FC"/>
  <rect x="0" y="0" width="300" height="6" rx="3" fill="#0A7AFF"/>
  <text x="150" y="86" text-anchor="middle" font-family="sans-serif" font-size="48" font-weight="bold" fill="#0A7AFF">+18%</text>
  <text x="150" y="126" text-anchor="middle" font-family="sans-serif" font-size="15" fill="#6B7280">营收同比增速</text>
</svg>
```

## 6. 封面装饰（几何组合，放 PPT cover 的 background/角落；纯装饰可省略 title）

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 200 200">
  <circle cx="150" cy="50" r="80" fill="#0A7AFF" opacity="0.12"/>
  <circle cx="30" cy="170" r="46" fill="#3DBE64" opacity="0.16"/>
  <path d="M0 160 L200 90" stroke="#0A7AFF" stroke-width="3" opacity="0.35"/>
</svg>
```

要点：低透明度大几何 + 一条细线，放在 cover 角落不抢标题。

## 7. 简易趋势示意（sparkline，数据感装饰）

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="320" height="120" viewBox="0 0 320 120">
  <title>趋势示意</title>
  <path d="M10 95 L70 80 L130 86 L190 52 L250 58 L310 22"
        fill="none" stroke="#0A7AFF" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="310" cy="22" r="6" fill="#0A7AFF"/>
</svg>
```

真实数据图表不要用这个——用 ppt 技能的 chart 版式（真坐标轴）。

## 8. 柱状对比图（简单类目对比，数据来自工作区）

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="360" height="240" viewBox="0 0 360 240">
  <title>类目对比</title>
  <line x1="40" y1="200" x2="340" y2="200" stroke="#9AA3AF" stroke-width="2"/>
  <rect x="70"  y="120" width="44" height="80" rx="4" fill="#0A7AFF"/>
  <rect x="158" y="60"  width="44" height="140" rx="4" fill="#3DBE64"/>
  <rect x="246" y="90"  width="44" height="110" rx="4" fill="#E9A23B"/>
  <text x="92"  y="218" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#333F50">线上</text>
  <text x="180" y="218" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#333F50">线下</text>
  <text x="268" y="218" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#333F50">直播</text>
  <text x="92"  y="112" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#333F50">120</text>
  <text x="180" y="52"  text-anchor="middle" font-family="sans-serif" font-size="12" fill="#333F50">220</text>
  <text x="268" y="82"  text-anchor="middle" font-family="sans-serif" font-size="12" fill="#333F50">170</text>
</svg>
```

- 柱高按数据比例换算：`height = value / maxValue * 绘图区高度`；标签写真实数字，禁止编造。
- 类目 ≤7 个；超过就只画 Top 7 或改用 PPT chart 版式。

## 9. 时间轴/里程碑

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="480" height="120" viewBox="0 0 480 120">
  <title>项目里程碑</title>
  <line x1="30" y1="60" x2="450" y2="60" stroke="#9AA3AF" stroke-width="2"/>
  <circle cx="90"  cy="60" r="8" fill="#0A7AFF"/>
  <circle cx="220" cy="60" r="8" fill="#0A7AFF"/>
  <circle cx="350" cy="60" r="8" fill="#0A7AFF"/>
  <text x="90"  y="30" text-anchor="middle" font-family="sans-serif" font-size="13" font-weight="bold" fill="#333F50">Q1</text>
  <text x="90"  y="86" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#6B7280">立项</text>
  <text x="220" y="30" text-anchor="middle" font-family="sans-serif" font-size="13" font-weight="bold" fill="#333F50">Q2</text>
  <text x="220" y="86" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#6B7280">上线</text>
  <text x="350" y="30" text-anchor="middle" font-family="sans-serif" font-size="13" font-weight="bold" fill="#333F50">Q3</text>
  <text x="350" y="86" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#6B7280">复盘</text>
</svg>
```

- 事件 ≤6 个；节点从左到右按时间顺序均匀排列，日期/阶段写真实值。
