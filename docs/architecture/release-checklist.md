# 发版前检查清单（原生 Python 相关）

任何改动到 `entry/libs/arm64-v8a`、`rawfile/python`、`entry/src/main/cpp/python`、
或 `entry/src/main/ets/service/PythonService.ts` 的提交，按下面顺序过一遍。

## 1. 运行库自检（硬门槛）

```bash
powershell -ExecutionPolicy Bypass -File tools/build-check.ps1
```

它依次跑四件事（任一失败即中止，不产出 HAP）：
1. `tooling/docs-check.py --strict` —— 文档相对链接/锚点检查（坏链 `exit 4`）；
2. `tooling/python/check-sonames.py --strict` —— **随包 .so 依赖闭合**：soname 齐全、
   Python 扩展都带 `libpython3.12.so`、无 glibc 泄漏（失败 `exit 6`）；
3. `tooling/license-check.py --strict` —— 随包组件是否都有许可声明（缺失 `exit 5`）；
4. `tooling/python/run-verify-stack.sh` —— **22 项**运行库自检（失败 `exit 3`）。

> 为什么要第 2 道：qemu 验证会被构建机/rootfs 里的同名库遮住（Alpine 自带 `libz.so.1`），
> 真机上才暴露 `libz.so.1` 缺失、扩展缺 `DT_NEEDED libpython` 这类问题。
> 静态扫 soname 不需要设备，能在打包前拦住。

它会在调 hvigor 之前跑 `tooling/python/run-verify-stack.sh`（**按真机布局**组装：
extras 解压到临时目录、libs 只提供 `.so`、qemu 跑目标 python），21 项全过才继续打包。
失败会以 `exit 3` 中止。

单项排查：
```bash
bash tooling/python/run-verify-stack.sh            # 只跑自检
bash tooling/python/build-python-stack.sh verify   # 同上(总入口)
bash tooling/python/build-python-stack.sh mpl      # 只重建某一层
```

## 2. 体积与内容

```bash
# HAP 里必须有这些(缺一个就是布局错了)
#   libs/arm64-v8a/libpython3.12.so
#   libs/arm64-v8a/{numpy,pandas,PIL,matplotlib,lxml,Crypto,regex,psutil,contourpy,kiwisolver}/*.so
#   rawfile/python/{python312.zip,site-packages.zip,extras.zip,cacert.pem,fonts/*.otf}
```

检查：解包 HAP，确认 `rawfile/python/extras.zip` 存在、`libs` 里只有 `.so`（hvigor 会丢掉
libs 里的 `.py`，所以 `.py` 必须在 extras 或 zip 里）。

## 3. 文档与许可

- 新增库 → 更新 `docs/architecture/python-third-party.md` 的「已验证可用」与
  `THIRD_PARTY_NOTICES.md` 对应小节（名称/版本/许可/产物路径）；
- 新增随包资产（字体/模型/数据）→ 在 `docs/legal/` 放许可全文；
- 用户可见的能力变化 → 更新 `docs/architecture/python-capabilities.md`。

## 4. 版本号

改动 `rawfile/python` 下任何文件后**必须**改 `Constants.WORK_PY_RUNTIME_REV`，
否则老用户不会重新解压，仍用旧文件（典型症状：新加的库 import 不到）。

## 5. 提交前

```bash
cd test/guncat-harness && node setup.mjs && node test-core.mjs   # 应全绿(现 543 项)
```
