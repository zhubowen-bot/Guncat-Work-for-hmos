# 【新增】content-writing 路由索引

> 本文是主 Skill `content-writing` 的详细路由索引，原始分支 Skill 正文均未改动；分支 Skill 已物理归入本主 Skill 子目录，`load_skill` 仍用原分支 id。

## 分支清单与触发词

### `khazix-writer` — 公众号长文写作（卡兹克风格）

- 触发：写文章、写稿子、帮我写、续写、扩写、公众号文章、长文、按我的风格写。
- 加载：`load_skill("khazix-writer")`。
- 注意：通用公众号/小红书/短视频创作转 `newmedia-writing`。

### `newmedia-writing` — 新媒体写作（小红书/公众号/短视频）

- 触发：小红书笔记、公众号文章、短视频分镜、爆款文案、种草文、账号定位、内容创作方案。
- 加载：`load_skill("newmedia-writing")`。
- 注意：已有母稿做多平台分发转 `content-rewrite`。

### `content-rewrite` — 多平台内容改写分发

- 触发：一稿多发、多平台分发、内容矩阵、跨平台改写、分发执行包、改成公众号版/短视频版/微博版/小红书版。
- 加载：`load_skill("content-rewrite")`。
- 注意：无素材从零创作转 `newmedia-writing` / `khazix-writer`；论文改写转 `academic-publishing`。

### `humanizer` — 去 AI 味与拟人化改写

- 触发：去 AI 味、AI 味太重、太像 AI 写的、自然一点、像人写的。
- 加载：`load_skill("humanizer")`。
- 注意：学术论文润色转 `academic-publishing` → `paper`。

### `marketing-plan` — 营销策划方案

- 触发：营销方案、营销策划、活动策划、产品上市方案、整合营销、增长转化方案。
- 加载：`load_skill("marketing-plan")`。
- 注意：广告宣传语/海报文案合规审查转 `legal-ip` → `marketing-material-review`。

## 交叉引用

| 相邻主 Skill | 何时转出 |
|---|---|
| `legal-ip` | 营销素材合规审核 |
| `academic-publishing` | 学术论文写作/润色/精读/审稿 |
| `research-intelligence` | 深度调研/舆情/行业研究/用户研究 |
| `docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data` | 明确文件格式时直接加载对应分支，不经过主 Skill |
| `ai-tooling` | 提示词工程/代码评审 |
