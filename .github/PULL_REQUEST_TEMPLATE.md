## 改了什么

<!-- 一两句话说清这个 PR 做了什么。关联的 Issue 请写 "Closes #123"。 -->

## 为什么

<!-- 解决什么问题？为什么用这种做法？ -->

## 验证方式

请勾选你实际**跑过**的项（跑不了就说明原因，别勾没跑过的）：

- [ ] 纯逻辑单测：`cd test/guncat-harness && node setup.mjs && node test-core.mjs`
- [ ] 服务层类型检查：`cd test/guncat-harness && node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json`
- [ ] Office 生成器离线验证（改了 `export/` 下任何文件则必跑）：`test/docx-harness` / `test/xlsx-harness` / `test/pptx-harness`
- [ ] 真实 ArkTS 编译：`pwsh -File tools/build-check.ps1`（需本机 DevEco Studio）
- [ ] 真机验证（说明机型与系统版本）

> CI 只能覆盖前两层与 Office 验证；**真实 ArkTS 编译必须本地跑**。ArkUI 有一批只有编译器才知道的规则，
> 详见 [CONTRIBUTING.md](https://github.com/zhubowen-bot/Guncat-Work-for-hmos/blob/main/CONTRIBUTING.md)。

## 影响面

- [ ] 改了 `common/**` 的纯逻辑模块（**改完必须同步 `test/guncat-harness` 的断言**）
- [ ] 改了系统提示词正文（注意：交互模式与工作模式的行为纪律边界有断言守着，别把工作模式的段落拼回交互模式）
- [ ] 改了 `.ets` 视图 / 页面 / 视图模型（**必须跑真实编译**）
- [ ] 改了 `entry/src/main/cpp` 原生层（**必须实机构建**，Node 侧只能做类型级检查）
- [ ] 改了 `rawfile/skills/` 下的技能文档
- [ ] 仅文档 / 注释

## 界面改动

<!-- 有 UI 变化请附改动前后的截图；没有就写"无"。 -->

## 自查

- [ ] 没有引入新的权限或新的网络行为
- [ ] 没有把生成物（`test/*/gen/`、`test/*/check/`）之外的临时文件带进提交
- [ ] 提交信息符合仓库约定（`feat(scope): 中文描述`）
