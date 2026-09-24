# 插件目录

本目录下维护插件 manifest 与加载清单：

- `plugin_list.json`：声明要加载的插件 manifest 文件名（字符串数组）
- 其余 `*.json`：每个文件是一个完整插件 manifest

应用启动时 `PluginHotLoader.loadAll()` 读取 `plugin_list.json`，逐个解析并注册到 `ToolRegistry`。

`plugin_list.json` 示例：

```json
["my_plugin.json"]
```

`my_plugin.json` 示例：

```json
{
  "id": "my_plugin",
  "version": "1",
  "permissions": [],
  "category": "plugin",
  "tools": [
    {
      "name": "my_tool",
      "description": "示例插件工具",
      "parameters": { "type": "object", "properties": {} },
      "readOnly": true,
      "mutating": false,
      "timeoutMs": 5000,
      "maxRetries": 1
    }
  ],
  "skills": []
}
```

工具实现仍需在 `WorkToolRunner.executeInner()` 中按名称分发；未实现的分发层会返回“未知工具”。
