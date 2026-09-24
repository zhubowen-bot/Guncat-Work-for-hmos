# pptx-harness: PPT 生成器离线验证环境

在 PC（Node + Python）上验证 `entry/src/main/ets/export/` 的 PPT 管线，不依赖 DevEco/真机。
原理：DeckModel/PptxThemes/PptxCharts/PptxBuilder/XmlUtil 是无 HarmonyOS API 依赖的纯逻辑 ArkTS，
复制为 `.ts` 后 Node 原生运行（strip-types）；ZipWriter 仅依赖 `util.TextEncoder`，用 `arkts-shim` 桩替换。

## 全量验证

```bash
python makepng.py > png.b64        # 生成测试图片(一次即可)
node setup.mjs                     # 移植 export/* + common/CsvParser + common/DataPipeline → gen/*.ts
node test-build.mjs                # 全版式/多主题/outline/edit算子/负例 → gen/out_*.pptx
node test-transform.mjs            # CsvParser(RFC 4180) + DataPipeline(数据管道) 54 项单测
python validate.py gen\out_all.pptx gen\out_dark.pptx gen\out_outline.pptx gen\out_edit.pptx
                                   # zip/XML/关系一致/content-types/python-pptx/内嵌源校验
python deep-check.py               # python-pptx 读图表数据 + 内嵌 deck.json 往返
```

服务层(WorkFileService/WorkSkillService/WorkToolRunner/PptxImage/PptxImporter)类型检查：

```bash
node check-setup.mjs               # 移植 + @kit.* 桩 → check/
npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json
```

视觉自检（本机装了 PowerPoint 时，导出 PNG 后人工/评审检查）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File export-png.ps1 `
  -PptxPath <pptx 绝对路径> -OutDir <输出目录>
```

## 修改生成器后的回归顺序

`setup.mjs → check-setup.mjs + tsc → test-build.mjs → validate.py → deep-check.py`。
gen/ 与 check/ 均为生成物，可随时删除重建。
