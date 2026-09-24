# docx-harness: Word 生成器/导入器离线验证环境

在 PC（Node + Python）上验证 `entry/src/main/ets/export/` 的 Word 管线，不依赖 DevEco/真机。
原理：DocModel/DocxBuilder/MarkdownParser/OmmlConverter/XmlUtil 是无 HarmonyOS API 依赖的纯逻辑 ArkTS，
复制为 `.ts` 后 Node 原生运行（strip-types）；ZipWriter 仅依赖 `util.TextEncoder`，用 `arkts-shim` 桩替换；
DocxImporter 依赖 `@kit` 的 fileIo/zlib，用 `kit-shim`（Node fs）+ `harness-unzip`（zip 解包）替换。

## 全量验证

```bash
python makepng.py > png.b64        # 生成测试图片(一次即可)
node setup.mjs                     # 移植 export/* + common/Constants → gen/*.ts
node test-build.mjs                # 全块类型/markdown 路径/编辑算子/外来导入/负例 → gen/out_*.docx
python validate.py gen\out_all.docx gen\out_md.docx gen\out_edit.docx
                                   # zip/XML well-formed/关系一致/样式字号分级/python-docx/图片嵌入
python deep-check.py gen\out_all.docx gen\out_md.docx gen\out_edit.docx
                                   # 内嵌 doc.json 往返 + 正文/表格/图片/H1 顺序核验
```

`test-build.mjs` 内已包含两段 Node 侧断言：
- **无损往返**：`DocxImporter.import(gen/out_all.docx)` 走内嵌 `docProps/doc.json` 还原，与源 Doc 深度一致；
- **外来导入**：手工组装的「外来 docx」（无内嵌源）近似导入出 heading/paragraph/list/table/image，
  图片抽取到 `gen/imgout/`，src 为 `docx_images/foreign/image1.png`。

服务层（WorkFileService/WorkSkillService/WorkToolRunner/DocxImporter 等）类型检查可复用 pptx-harness：
`node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json`（pptx-harness 的 setup/check-setup
已包含对 DocModel/DocxBuilder/DocxImporter 的移植）。

视觉自检（本机装了 Word/WPS 时，人工打开 gen/out_all.docx 检查封面/标题分级/图片/表格排版）。

## 修改生成器后的回归顺序

`setup.mjs → test-build.mjs → validate.py → deep-check.py`（pptx-harness 的 check-setup + tsc 做类型检查）。
gen/ 为生成物，可随时删除重建。
