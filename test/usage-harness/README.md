# 用量纯逻辑回归

不依赖 ArkUI / 设备，直接编译并运行：

```powershell
# 使用仓库 test/.npm-cache 里的 tsc（或任意 TypeScript 编译器）
& .\test\.npm-cache\_npx\dbadba31d18877ff\node_modules\.bin\tsc.cmd -p test\usage-harness\tsconfig.json
node test\usage-harness\out\test\usage-harness\usage-test.js
```

覆盖：

- 北京时间切日/跨日/跨小时
- DeepSeek 工作日峰谷边界、周末、法定节假日
- DeepSeek Flash 峰/谷价与缓存命中/未命中/输出分项
- Anthropic / Responses / Completions / OpenCode 四种 usage 口径
- 按日/小时聚合与 JSON 往返
