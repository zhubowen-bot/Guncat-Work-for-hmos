---
name: prompt-engineering
description: Advanced expert in prompt engineering, custom instructions design, and prompt optimization for AI agents
display_name: "prompt-engineering"
display_name_en: "prompt-engineering"
description_zh: "Advanced expert in prompt engineering, custom instructions design, and prompt optimization for AI agents"
description_en: "Advanced expert in prompt engineering, custom instructions design, and prompt optimization for AI agents"
visibility: "public"
---

# Prompt Engineering Expert Skill

This skill equips Claude with deep expertise in prompt engineering, custom instructions design, and prompt optimization. It provides comprehensive guidance on crafting effective AI prompts, designing agent instructions, and iteratively improving prompt performance.

## Capabilities

- **Prompt Writing Best Practices**: Expert guidance on clear, direct prompts with proper structure and formatting
- **Custom Instructions Design**: Creating effective system prompts and custom instructions for AI agents
- **Prompt Optimization**: Analyzing, refining, and improving existing prompts for better performance
- **Advanced Techniques**: Chain-of-thought prompting, few-shot examples, XML tags, role-based prompting
- **Evaluation & Testing**: Developing test cases and success criteria for prompt evaluation
- **Anti-patterns Recognition**: Identifying and correcting common prompt engineering mistakes
- **Context Management**: Optimizing token usage and context window management
- **Multimodal Prompting**: Guidance on vision, embeddings, and file-based prompts

## Use Cases

- Refining vague or ineffective prompts
- Creating specialized system prompts for specific domains
- Designing custom instructions for AI agents and skills
- Optimizing prompts for consistency and reliability
- Teaching prompt engineering best practices
- Debugging prompt performance issues
- Creating prompt templates for reusable workflows


> 本项目加载方式：本文件为原始 SKILL 概览；完整方法在 `reference/BEST_PRACTICES.md`、`TECHNIQUES.md`、`TROUBLESHOOTING.md`、`EXAMPLES.md` 等，按需加载。

---

> 本项目交付定制：优化后的 Prompt/系统提示词用 `write_file` 输出 `.md`；需要 Word 时先 `load_skill("docx")` 再用 `write_docx`；Prompt 清单/评估用例表可用 `load_skill("xlsx")` + `write_xlsx`（场景/目标 Prompt/变量/测试用例/通过标准）。原文能力与参考文件结构全部保留。
