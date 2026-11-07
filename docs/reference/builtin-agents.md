# 内置智能体

> [← 返回 README](../../README.md)


智能体通过 `resources/rawfile/agents.json` 和独立 Markdown 提示词文件管理。侧边栏支持独立自定义图标（`icon` 字段指向 `icons/` 目录下以智能体 id 命名的 PNG，未配置回退猫头像），并采用双描述机制：侧边栏展示 `shortDescription` 短描述，新建对话页展示 `description` 完整描述：

窄屏抽屉（`AgentDrawerView`）把智能体分成两节：**「Agent引擎（推荐）」**（工作模式 / 交互模式）和**「聊天引擎」**（4 个通用 + 5 个专家智能体）。**「聊天引擎」默认折叠**，点击标题行才展开，把默认视野留给 Agent 模式与历史对话。

| 智能体      | 类别    | 功能                                                         |
| -------- | ----- | ---------------------------------------------------------- |
| 轻简模式     | 通用智能体 | Guncat 3.1-Flash 基座：系列首个 Flash 独立基座，专为日常聊天与简单知识查询打造的最轻量智能体 |
| 效率模式     | 通用智能体 | Guncat 3.0-Flash 基座：缺口驱动执行带来极速响应，回答详尽度与 Pro 同标准            |
| 专家模式     | 通用智能体 | Guncat 3.0-Pro 基座：最强大的单体化超级智能体，全系专家能力与行业领先的反幻觉体系           |
| 经典模式     | 通用智能体 | 基于 Guncat 2.5-Lite：成熟的轻量级通用智能体，结构化思维链引导高质量长输出              |
| 转换专家-论文  | 改写智能体 | 基于 Guncat Cnvt-Paper：将非论文文体转化为符合学术规范的论文                    |
| 检索专家-法律  | 检索智能体 | 基于 Guncat Srch-Law：国企法律分析，强制多轮检索与结构化法律意见                   |
| 检索专家-研究  | 检索智能体 | 基于 Guncat Srch-Research：跨领域信息检索与多源交叉验证                     |
| 检索专家-筛滤  | 检索智能体 | 基于 Guncat Srch-Sift：官方溯源与 AI 内容过滤                          |
| 评估专家-LLM | 评估智能体 | 基于 Guncat Eval-LLM：最大减少幻觉地评估 LLM 模型的性能                     |
| 交互模式（虚拟） | Agent 模式 | Intelligent UI：同一套 Agent Loop，但回答交付为可操作的原生界面（图表 / 表格 / 卡片 / 表单），调参即时重算、点按钮让助手重算（**侧边栏第一项，也是应用启动落点**） |
| 工作模式（虚拟） | Agent 模式 | Guncat Harness：本地沙箱工作区 + 47 个工具 + 多轮 Agent Loop，自主完成长程任务并产出文件 |

## 与交互模式「能力调度」的对应关系

聊天引擎的九份智能体提示词同时也是交互模式「能力调度」九个档位的**移植来源**（设置 →「能力」→「能力调度」，默认轻简）。两者共用同一份原始提示词文件，但档位读的是独立的适配版 `rawfile/interactive-tier-*.md`（原提示词只做溯源，不直接读）：

| 交互模式档位 | 聊天引擎智能体 | 移植来源（rawfile） | 迁移方式 |
| --- | --- | --- | --- |
| 轻简 | 轻简模式（3.1-Flash） | 原交互模式提示词本身（不是 3.1-Flash） | 逐字节复用，无档位主体 |
| 效率 | 效率模式 | `Guncat 3.0-Flash_prompt_ZH_CN.md` | 主体逐字保留 + 交付形态适配 |
| 专家 | 专家模式 | `Guncat 3.0-Pro_prompt_ZH_CN.md` | 同上 |
| 经典 | 经典模式 | `Guncat 2.5-lite _prompt.md` | 同上 |
| 论文转换 | 转换专家-论文 | `Guncat Cnvt-Paper_prompt.md` | 同上 |
| 法律检索 | 检索专家-法律 | `Guncat Srch-Law V1.0-prompt.md` | 同上 |
| 深度研究 | 检索专家-研究 | `Guncat Srch-Research-prompt.md` | 同上 |
| 信息筛滤 | 检索专家-筛滤 | `Guncat Srch-Sift-prompt.md` | 同上 |
| LLM评估 | 评估专家-LLM | `Guncat Eval-LLM_prompt.md` | 同上 |

迁移规则、逐档适配点与九档组合后的完整提示词见[提示词适配说明](../prompts/interactive-tier-adaptation.md)。

