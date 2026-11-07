# 发版前检查清单

任何改动到 `entry/libs/arm64-v8a`、`third_party/bettersh/iec`、`rawfile/python`、
`entry/src/main/cpp/python`、`entry/src/main/ets/service/PythonService.ts` 或 shell 运行时的提交，
按下面顺序过一遍。

## 1. 快速门槛（每次发版）

```bash
powershell -ExecutionPolicy Bypass -File tools/build-check.ps1
```

默认只跑**快速门槛**（合起来几秒到 1 分钟）：

0. `test/guncat-harness/check-setup.mjs` + `tsc -p check/tsconfig.json` —— **与 CI 完全一致**的
   服务层类型检查（失败 `exit 7`）。不跑这一步就会出现“本地通过、GitHub 报 TS2339”的来回。
1. `tooling/docs-check.py --strict` —— 文档相对链接/锚点检查（坏链 `exit 4`）；
2. `tooling/python/check-sonames.py --strict` —— **随包 `.so` 依赖闭合**：soname 齐全、
   Python 扩展都带 `libpython3.12.so`、无 glibc 泄漏（失败 `exit 6`）；
3. `tooling/license-check.py --strict` —— 随包组件是否都有许可声明（缺失 `exit 5`）。

`-Full` 或 `-WithPythonStack` 才会在打包前额外跑 **24 项 Python 运行库自检**
（`tooling/python/run-verify-stack.sh`，qemu 用户态约 10 分钟，失败 `exit 3`）。
默认跳过是因为它慢，不是因为它不重要；改过 Python 运行库时必须跑一次。

> 为什么要第 2 道：qemu 验证会被构建机/rootfs 里的同名库遮住（Alpine 自带 `libz.so.1`），
> 真机上才暴露 `libz.so.1` 缺失、扩展缺 `DT_NEEDED libpython` 这类问题。
> 静态扫 soname 不需要设备，能在打包前拦住。
>
> 本机没有 WSL/rootfs 时，docs/soname/license 三项会跳过并提示；这不算通过，只是环境不具备。

## 2. Python 运行库

```bash
bash tooling/python/run-verify-stack.sh            # 24 项，按真机布局在 qemu 里跑
bash tooling/python/build-python-stack.sh verify   # 同上(总入口)
bash tooling/python/build-python-stack.sh mpl      # 只重建某一层
```

**打包门槛**：`tools/build-check.ps1 -Full` 会在调 hvigor 之前跑这 24 项，全过才继续打包。

HAP 里必须有这些（缺一个就是布局错了）：

```text
libs/arm64-v8a/libpython3.12.so
libs/arm64-v8a/{numpy,pandas,PIL,matplotlib,lxml,Crypto,regex,psutil,contourpy,kiwisolver}/*.so
rawfile/python/{python312.zip,site-packages.zip,extras.zip,cacert.pem,fonts/*.otf}
```

检查：解包 HAP，确认 `rawfile/python/extras.zip` 存在、`libs` 里只有 `.so`（hvigor 会丢掉
libs 里的 `.py`，所以 `.py` 必须在 extras 或 zip 里）。

改动 `rawfile/python` 下任何文件后**必须**改 `Constants.WORK_PY_RUNTIME_REV`，
否则老用户不会重新解压，仍用旧文件（典型症状：新加的库 import 不到）。

## 3. 文档与许可

- 新增库 → 更新 `docs/architecture/python-third-party.md` 的「已验证可用」与
  `THIRD_PARTY_NOTICES.md` 对应小节（名称/版本/许可/产物路径）；
- 新增随包资产（字体/模型/数据）→ 在 `docs/legal/` 放许可全文；
- 用户可见的能力变化 → 更新 `docs/features.md`、`docs/guides/usage.md` 与 README（中英）；
- 版本相关 → 同步 `CHANGELOG.md`；三端发布说明与对照文档只在三端仓库齐备且实际同步时处理
  （见 `AGENTS.md` §3.1）；
- 文档改完跑 `python3 tooling/docs-check.py --strict`，坏链会让 CI 失败。

## 4. 版本号与发布物

- `entry/src/main/ets/common/Constants.ts` 的 `APP_VERSION`；
- `AppScope/app.json5` 的 `versionCode` / `versionName`；
- `README.md` / `README_EN.md` 的版本徽章、当前版本行与更新记录表格中的版本范围；
- `entry/src/main/resources/rawfile/玩转应用/index.html` 的 `hero-sub`、首页「新功能体验」
  入口与新版本子页；
- `entry/src/main/resources/rawfile/玩转应用/维护指南.md` 的版本记录；
- `CHANGELOG.md` 的 `## 未发布` 改为 `## X.Y.Z（YYYY-MM-DD）`；
- `docs/guides/device-verification.md` 等文档中的当前版本引用；
- 发布 HAP 必须签名；正式包与 Beta 包的 `bundleName` 以 `AppScope/app.json5` 为准。
- 同步后用旧版本号全仓搜索一遍；历史发布说明与已发布版本的 changelog 小节保持原样。
- `docs/releases/` 与 `docs/ALIGNMENT_STATUS.md` 是三端发布材料，不在单仓库发版清单内；
  只有三端仓库都在上级目录且本次确实三端同步时才处理，规则见 `AGENTS.md` §3.1。

## 5. 提交前

```bash
cd test/guncat-harness && node setup.mjs && node test-core.mjs   # 应全绿（现 760 项）
cd test/usage-harness && npx -y -p typescript@5.5.4 tsc -p tsconfig.json && node out/test/usage-harness/usage-test.js
```

改 Office 生成器时再跑 `test/docx-harness`、`test/xlsx-harness`、`test/pptx-harness`；
跑完回退 `test/*/gen/`、`test/*/check/` 下的生成物，避免把无关产物带进提交。
