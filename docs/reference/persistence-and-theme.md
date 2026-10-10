# 持久化与主题系统

> [← 返回 README](../../README.md)


应用使用两类本地持久化：

- **对话历史**：JSON 序列化后保存在应用沙箱文件 `filesDir/guncat_conversations.json`，不再受 Preferences 单值 16MB 上限约束；首次升级到该版本会自动从旧 Preferences 迁移历史会话。
- **配置类数据**：使用 `@kit.ArkData` Preferences 保存，包括当前对话、智能体选择、多套 API 配置、深度思考、联网搜索、朗读音色和朗读倍速。
- 应用重启后恢复本地状态。

主题使用 HarmonyOS 资源限定符实现：

- `base/element/color.json` 提供浅色资源。
- `dark/element/color.json` 提供深色资源。
- `EntryAbility.onConfigurationUpdate()` 监听系统主题变化。
- 状态栏、导航栏、Markdown、代码高亮及公式颜色同步切换。
