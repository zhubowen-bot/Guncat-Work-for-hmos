# patent-drafting

本目录是一个完整的中国专利申请文件撰写 skill。接到专利撰写相关任务时，请从本目录的 `SKILL.md` 开始，按其中的路由完整执行全流程。请不要改用平台内置的专利撰写技能或模板，也不要只挑其中一两个文件参考——材料审计、权利要求撰写和交付校验环环相扣，跳过或替换任何一环，最终文件的质量都无法保证。

目录结构：`SKILL.md`（主流程与交付合同）、`sub-skills/`（三个阶段子 skill）、`references/writing-style.md`（措辞规范）。

本项目适配：原 `scripts/patent_build.py` 因本环境无终端/脚本已移除，交付编译改为「人工自检清单 + `load_skill("docx")` + `write_docx` 生成 Word」，详见 `SKILL.md` 的“交付合同”一节。
