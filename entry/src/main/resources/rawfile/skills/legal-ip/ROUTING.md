# 【新增】legal-ip 路由索引

> 本文是主 Skill `legal-ip` 的详细路由索引，原始分支 Skill 正文均未改动；分支 Skill 已物理归入本主 Skill 子目录，`load_skill` 仍用原分支 id。

## 分支清单与触发词

### `law` — 国企法律事务分析

- 触发：企业法律案例/纠纷分析、国企国资监管、股权转让、合同纠纷、合规与责任认定、法律意见书。
- 加载：`load_skill("law")`。
- 注意：法律文书翻译转 `translation`。

### `patent-drafting` — 专利申请文件撰写

- 触发：专利撰写、专利申请、技术交底书、权利要求、说明书、实用新型、发明专利。
- 加载：`load_skill("patent-drafting")`。
- 注意：专利检索/FTO/侵权分析/无效宣告/审查意见答复为相邻业务，不在本分支主流程；混合请求照其正文处理。

### `translation` — 法律翻译

- 触发：翻译法律文书、审校法律英译、起草英文版、制作双语 Word、统一术语。
- 加载：`load_skill("translation")`。
- 注意：非法律文本翻译不使用本分支；医学文献翻译参考其 `medical-*` 文件。

### `marketing-material-review` — 营销素材审核

- 触发：营销素材审核、广告文案合规审查、宣传语合规、广告法审查、促销价格合规、有奖活动规则审查。
- 加载：`load_skill("marketing-material-review")`。
- 注意：营销方案创作转 `content-writing` → `marketing-plan`。

## 交叉引用

| 相邻主 Skill | 何时转出 |
|---|---|
| `content-writing` | 营销方案创作 |
| `academic-publishing` | 学术论文/基金立项 |
| `docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data` | 明确文件格式时直接加载对应分支，不经过主 Skill |
| `research-intelligence` | 深度调研/时效验证补材料 |
| `ai-tooling` | 提示词工程/代码评审 |
