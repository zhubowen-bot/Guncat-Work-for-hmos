# 人工智能生成合成内容标识说明

> 适用应用：Guncat Work（鸿蒙版）<br>
> 应用包名：`com.bowenapp.guncataibeta`<br>
> 当前版本：`7.3.0`（versionCode 730）<br>
> 更新日期：2026-11-10

本文档用于应用市场上架审核时说明本应用的 AI 生成合成内容标识实现，配套材料包括应用内显式标识截图、导出文件样例和《人工智能生成合成内容标识说明函》。

---

## 1. 应用与服务形态

Guncat Work 是 HarmonyOS 原生 AI 工作台。应用提供对话、工作模式（Agent Loop）和交互模式（Intelligent UI），可以在设备内完成文本生成、表格/文档/演示文稿生成和 SVG 绘图等任务。

**本应用不内置、不代理、不转售任何大模型服务，也不包含第三方模型权重或开发者持有的模型 API Key。** 模型服务由用户在应用设置中自行配置：

- 支持 OpenAI Completions（`/chat/completions`）、OpenAI Responses（`/responses`）和 Anthropic Messages（`/messages`）三种协议；
- 用户填写自己选择的服务商 Base URL、API Key 与模型名；
- 应用可能提供常见服务商的 Base URL 预设或占位提示，但不包含任何可用 API Key，也不代理/中转请求；用户必须自行填写自己的 Key 并遵守所选服务商的条款；
- 请求由用户设备直接发送到用户配置的服务商，不经过开发者服务器；
- 多模态解析同样是可选的用户自配置 API，应用不提供默认密钥或代理。

因此，生成合成内容的模型服务由用户自行选择，开发者不提供该模型服务；应用本身仍按照《人工智能生成合成内容标识办法》对界面展示、复制和导出文件中的 AI 生成内容添加标识。

应用**不提供**以下深度合成能力：合成人声/仿声、人脸生成/替换/操控、姿态操控、沉浸式拟真场景、AI 视频生成。应用不生成或导出音频、视频文件；朗读功能使用 HarmonyOS CoreSpeechKit 系统 TTS 播放 AI 文本，不提供音色克隆/仿声，也不产生可下载的音频文件。

---

## 2. 显式标识

| 场景 | 标识位置 | 标识形式 | 导出/下载时 |
| --- | --- | --- | --- |
| 对话模式回答 | 正文末尾 | `AI生成` 小角标（9fp 浅灰胶囊） | 复制、导出时写入文件 |
| 工作模式最终回答 | 正文末尾 | `AI生成` 小角标 | 复制、导出时写入文件 |
| 交互模式消息 | 消息末尾 | `AI生成` 小角标 | 界面本身可截图保存 |
| 复制纯文本 | 文本末尾 | 追加 `AI生成` | 是 |
| 复制 Markdown | 文本末尾 | 追加 `> AI生成` | 是 |
| 导出 Word | 正文末尾 + 每页页脚 | 8pt 浅灰 `AI生成` | 是 |
| 生成 PowerPoint | 每页左下角 | 8pt 浅灰 `AI生成` | 是 |
| 生成 Excel | 页面布局/打印页脚左下角 | `AI生成` | 是 |
| 生成 SVG | 图片右下角 | `AI生成`，字号为最短边的 5%（下限 12px），白色描边保证可辨 | 是 |
| 工作区打包导出 | 压缩包根目录 | `_AI生成内容标识.txt` 说明文件 | 是 |
| 分享 Markdown/纯文本/SVG/HTML | 临时副本 | 末尾追加或内嵌标识；工作区原文件不变 | 是 |
| 朗读控制条 | 控制条内 | `AI生成` 小角标 | 不生成音频文件 |

说明：

- 显式标识文字同时包含“AI”和“生成”两个要素，符合《标识办法》对文字提示的要求。
- 小角标使用浅灰、9fp，尽量不打断阅读；导出文件中的标识为 8pt 或 5% 最短边字号，保证清晰可辨。
- CSV、JSON 等结构化数据文件为保持可机读性，不在数据行中插入会破坏结构的标识；其 AI 生成属性在应用内角标、产物卡片和打包说明文件中体现。

---

## 3. 隐式标识

### 3.1 Word / PowerPoint / Excel

生成的 `.docx`、`.pptx`、`.xlsx` 文件在 `docProps/custom.xml` 中写入一个名为 `AIGC` 的自定义属性，值为附录 E 规定的 JSON 字符串。每个文件仅保留一份。

示例：

```json
{
  "AIGC": {
    "Label": "1",
    "ContentProducer": "Guncat Work (com.bowenapp.guncataibeta)",
    "ProduceID": "GW-20261110123045-1a2b3c4d",
    "ReservedCode1": "",
    "ContentPropagator": "Guncat Work (com.bowenapp.guncataibeta)",
    "PropagateID": "GW-20261110123045-1a2b3c4d",
    "ReservedCode2": ""
  }
}
```

字段说明：

- `Label`：`1`，表示属于人工智能生成合成内容；
- `ContentProducer`：生成合成服务提供者名称/编码，使用应用名 + 包名；
- `ProduceID`：本次生成内容的唯一编号（时间 + 随机串）；
- `ContentPropagator` / `PropagateID`：首次写入时与制作者/制作编号一致；
- `ReservedCode1` / `ReservedCode2`：预留字段，当前为空字符串。

文件内同时包含 `[Content_Types].xml` 中 `docProps/custom.xml` 的内容类型声明，以及 `_rels/.rels` 中对应的关系条目，保证 Word、PowerPoint、Excel 能正常打开并读取该属性。

### 3.2 SVG

生成的 `.svg` 文件在根元素后写入：

```xml
<metadata id="aigc-mark">{"AIGC":{...}}</metadata>
```

并在图片右下角绘制 `AI生成` 文字。由 SVG 栅格化得到的 PNG 预览会一并带上该文字标识，并在 PNG 的 `tEXt` 块中写入 `AIGC` 关键字和同一份 JSON。

### 3.3 不含音频/视频

应用不生成音频、视频或虚拟场景文件，因此不涉及音频节奏标识、视频起始画面标识和虚拟场景标识。

---

## 4. 复制、导出与下载范围

| 出口 | 处理 |
| --- | --- |
| 复制回答（纯文本） | 末尾追加 `AI生成` |
| 复制回答（Markdown） | 末尾追加 `> AI生成` |
| 导出 Word | 正文末尾 + 页脚 + `docProps/custom.xml` |
| 生成 Word/PPT/Excel | 生成时写入显式标识 + 隐式标识 |
| 生成 SVG | 生成时写入右下角文字 + `<metadata>` |
| 分享工作区文件 | Markdown/纯文本/HTML/SVG 使用带标识的临时副本；Office/SVG 生成时已带标识；原文件不改动 |
| 导出工作区 ZIP | 包内文本补标识，包根目录附 `_AI生成内容标识.txt` |
| 预览、朗读 | 应用内角标；不产生可下载的音频/视频文件 |

---

## 5. 应用内说明入口

设置 →「系统」→「合规与许可」新增独立页面，包含：

- 「AI 生成内容标识」：说明本应用不内置、不代理大模型服务，以及显式/隐式标识的位置和形式；
- 「第三方组件与许可」：随包原生组件、Python 运行时、界面库及其许可证；
- 「开源许可证全文」：随应用包分发的许可证原文。

该入口用于让用户在使用前了解内容属性，也便于审核人员截图取证。

---

## 6. 审核材料与自检

### 6.1 需要提交的材料

1. 本说明文档；
2. 加盖公章的《人工智能生成合成内容标识说明函》；
3. 应用内显式标识截图（清单见 `上架填报与截图清单.md`）；
4. 导出文件样例：`.docx`、`.pptx`、`.xlsx`、`.svg`、`.png` 各一份；
5. 隐式标识证明：`docProps/custom.xml` 截图，或使用 `tools/check-aigc-mark.py` 的检测输出。

### 6.2 本地自检

```bash
# 检查导出的 Office/SVG/文本文件是否带标识
python tools/check-aigc-mark.py path/to/sample.docx path/to/sample.pptx \
  path/to/sample.xlsx path/to/sample.svg path/to/answer.md
```

生成器回归（仓库内已有离线验证环境）：

```bash
cd test/docx-harness && node setup.mjs && node test-build.mjs && python validate.py gen/out_md.docx
cd test/pptx-harness && node setup.mjs && node test-build.mjs && python validate.py gen/out_all.pptx
cd test/xlsx-harness && node setup.mjs && node test-build.mjs && python validate.py gen/out_all.xlsx
```

---

## 7. 边界与变更

- 本说明描述的是当前 `7.3.0` 的实现。若后续版本内置模型、增加代理服务、增加音频/视频生成或改变导出范围，应同步更新本说明、说明函和审核材料。
- 用户自行配置的模型服务商可能对同一内容有自己的标识；本应用不替代模型服务商的标识义务。
- 应用不向开发者服务器上传对话内容；对话、配置、工作区文件均保存在设备本地，模型请求直接发往用户配置的服务商。
