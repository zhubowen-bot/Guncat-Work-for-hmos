# xlsx-harness: Excel 生成器/导入器离线验证环境

在 PC（Node + Python）上验证 `entry/src/main/ets/export/` 的 Excel 管线，不依赖 DevEco/真机。
原理：XlsxModel/XlsxBuilder/XmlUtil/CsvParser/Constants 是无 HarmonyOS API 依赖的纯逻辑 ArkTS，
复制为 `.ts` 后 Node 原生运行（strip-types）；ZipWriter 仅依赖 `util.TextEncoder`，用 `arkts-shim` 桩替换；
XlsxImporter 依赖 `@kit` 的 fileIo/zlib，用 `kit-shim`（Node fs）+ `harness-unzip`（zip 解包）替换。

## 全量验证

```bash
node setup.mjs                     # 移植 export/* + common/* → gen/*.ts
node test-build.mjs                # 多表/公式/格式/列宽/冻结 + markdown 路径 + 编辑算子 + 外来导入 + 负例
python validate.py gen\out_all.xlsx gen\out_md.xlsx gen\out_edit.xlsx
                                   # zip/XML well-formed/关系一致/openpyxl/表头加粗/公式/数字格式/冻结窗格/列宽
python deep-check.py gen\out_all.xlsx gen\out_md.xlsx gen\out_edit.xlsx
                                   # 内嵌 workbook.json 往返 + 逐格核验(含公式)
```

`test-build.mjs` 内已包含两段 Node 侧断言：
- **无损往返**：`XlsxImporter.import(gen/out_all.xlsx)` 走内嵌 `docProps/workbook.json` 还原，与源 Workbook 深度一致；
- **外来导入**：手工组装的「外来 xlsx」（无内嵌源，含共享字符串/数字/公式/两表）近似导入，
  表顺序、共享字符串、数字、公式 `=SUM(B2:B3)` 全部还原。

服务层（WorkFileService/WorkSkillService/WorkToolRunner/XlsxImporter 等）类型检查复用 pptx-harness：
`node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json`（pptx-harness 的 setup/check-setup
已包含对 XlsxModel/XlsxBuilder/XlsxImporter 的移植；若 npm 缓存被系统拒绝，加 `--cache <workspace>\test\.npm-cache`）。

视觉自检（本机装了 Excel/WPS 时，人工打开 gen/out_all.xlsx 检查表头底纹、金额格式、公式联动、冻结窗格）。

## 修改生成器后的回归顺序

`setup.mjs → test-build.mjs → validate.py → deep-check.py`（pptx-harness 的 check-setup + tsc 做类型检查）。
gen/ 为生成物，可随时删除重建。
