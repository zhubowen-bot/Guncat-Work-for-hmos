# 持久化与主题系统

> [← 返回 README](../../README.md)

应用使用两类本地数据持久化和一套主题资源：

## 对话存档

- **位置**：应用沙箱 `filesDir/guncat_conversations.json`，不受 Preferences 单值 16MB 上限约束；首次升级到该方案时会自动从旧 Preferences 迁移历史会话。
- **合并写**：工具步骤边界会连续触发保存，`StorageManager` 把 800ms 内的请求合并成一次写盘；切后台、停止生成、退出前调用 `flushConversations()` 强制落盘。
- **流式序列化**：逐会话把 `toJson()` 结果直接写入文件，峰值内存与「最大单会话」成正比，不再同时持有全部会话对象图与完整 JSON 字符串。
- **三段式恢复**：写盘顺序为「临时文件 → 旧主文件转 `.bak` → 临时文件改名为主文件」。启动时优先采用可解析的 `.tmp`，主文件损坏则回退 `.bak`；半截或损坏的 `.tmp` 会被清理。
- **落盘瘦身**：附件图片 base64 超过阈值时剥离 `dataUrl` / 缩略图（保留文件名与解析文本）；长任务的 `reasoning` 只保留末尾。

## 配置与用量

- **配置类数据**：使用 `@kit.ArkData` Preferences（`guncat_preferences`）保存，包括当前对话、智能体选择、多套 API 配置、深度思考、联网搜索、朗读音色和朗读倍速。
- **设置自动保存**：设置页把字段修改防抖写入 Preferences，返回或切换配置方案前再同步一次；不再有手动保存按钮。
- **用量账本**：`filesDir/guncat_usage.json`，保存最近 400 天的按日聚合与 8 天小时桶，更早数据只保留「全部」累计值，不保存逐请求明细；5 秒防抖写盘，切后台与退出时 flush，写盘采用 `.tmp` + rename。
- **用量页配置**：汇率、月预算、OpenCode 额度等小配置与 DeepSeek 余额快照存 Preferences（`guncat_usage_settings` / `guncat_usage_balance`），不占用会话存档。
- 应用重启后恢复本地状态。

## 主题

主题使用 HarmonyOS 资源限定符实现：

- `base/element/color.json` 提供浅色资源。
- `dark/element/color.json` 提供深色资源。
- `EntryAbility.onConfigurationUpdate()` 监听系统主题变化。
- 状态栏、导航栏、Markdown、代码高亮及公式颜色同步切换。
