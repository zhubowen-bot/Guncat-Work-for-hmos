# 交互模式 · 能力调度档位提示词（完整导出）

> 这些文件是**运行时真正拼出来的系统提示词**，不是设计稿。重新生成：
> `cd test/guncat-harness && node setup.mjs && node dump-interactive-tiers.mjs`

## 档位一览

| # | 档位 | 移植来源 | 档位主体 | 默认思考 | 工具面 | 字符数 | 全文 |
| ---: | --- | --- | --- | --- | ---: | ---: | --- |
| 1 | 轻简 | —（原交互模式提示词） | — | `low` | 27 | 21,770 | [查看](01-lite.md) |
| 2 | 效率 | `Guncat 3.0-Flash_prompt_ZH_CN` | `interactive-tier-efficiency.md` | `low` | 28 | 47,093 | [查看](02-efficiency.md) |
| 3 | 专家 | `Guncat 3.0-Pro_prompt_ZH_CN` | `interactive-tier-expert.md` | `high` | 29 | 84,708 | [查看](03-expert.md) |
| 4 | 经典 | `Guncat 2.5-lite _prompt` | `interactive-tier-classic.md` | `high` | 28 | 30,233 | [查看](04-classic.md) |
| 5 | 论文转换 | `Guncat Cnvt-Paper_prompt` | `interactive-tier-paper.md` | `low` | 27 | 30,644 | [查看](05-paper.md) |
| 6 | 法律检索 | `Guncat Srch-Law V1.0-prompt` | `interactive-tier-legal.md` | `high` | 29 | 34,882 | [查看](06-legal.md) |
| 7 | 深度研究 | `Guncat Srch-Research-prompt` | `interactive-tier-research.md` | `high` | 29 | 34,705 | [查看](07-research.md) |
| 8 | 信息筛滤 | `Guncat Srch-Sift-prompt` | `interactive-tier-sift.md` | `high` | 28 | 36,601 | [查看](08-sift.md) |
| 9 | LLM评估 | `Guncat Eval-LLM_prompt` | `interactive-tier-eval.md` | `high` | 29 | 61,099 | [查看](09-eval.md) |

## 分层结构（九个档位共用同一套骨架）

| 段 | 内容 | 轻简 | 其余八档 |
| --- | --- | --- | --- |
| ① 档位声明 | 身份 + 第一纪律 + 工具面政策 + 思考政策 + 丰富度口径（唯一的一级标题） | 原 `interactivePrime()`（逐字节复用） | `InteractiveTierPrompt.tierPrime()` 按档生成 |
| ②~⑨ 界面语言契约 | guncat-ui 语法 / 组件清单（库内注册 77、清单可见 75；由 GuncatUiLibrary 生成）/ 丰富度 / 交互闭环 / 流式顺序 / 示例 / 反例 | 原文 | 原文（丰富度数量口径换为「越多越好」） |
| ⑩ 档位主体 | 原聊天引擎提示词的适配版（角色/思维链/工作流/反幻觉/模板/知识库） | 无 | `rawfile/interactive-tier-*.md` |
| ⑪~⑭ 环境底座 | 工作区 / 本档工具面 / 真实数据纪律 / 技能索引 | 素材区口径 | 素材区 + 产出区口径 |
| ⑮ 起手式 | 进入执行的最后一句引导 | 原句 | 档位版 |
| ⑯ 交付形态职责 | 程序之外不写文字 / 往丰富一侧 / 冲突裁决（最后解释权） | 原文 | 档位版 |

> 组装顺序由 `InteractiveTierPrompt.segments()` 单一事实源固定；轻简档的组装结果与旧的四段组装**逐字节一致**（导出脚本里有断言）。分层设计与适配说明见 [提示词适配说明](../interactive-tier-adaptation.md)。