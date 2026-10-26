# 原生 Python 的三方库扩展

`run_python` 用的是应用进程内的原生 CPython 3.12（见 [native-python.md](native-python.md)）。
三方库分两类，走两条完全不同的路：

| 类型 | 例子 | 做法 | 成本 |
| --- | --- | --- | --- |
| 纯 Python | requests、jinja2、openpyxl、PyYAML、bs4、pypdf、dateutil | 拉轮子解包成 `site-packages.zip`，运行时挂 `PYTHONPATH` | 分钟级 |
| C 扩展 | numpy、pandas、Pillow、lxml、matplotlib、scipy | 交叉编译成 aarch64 的 `.so`，进 `entry/libs/arm64-v8a/` | 半天到数天 |

## 1. 纯 Python 包：`tooling/python/vendor-pure.sh`

```bash
bash tooling/python/vendor-pure.sh              # 默认清单
PKGS="requests jinja2" bash tooling/python/vendor-pure.sh
```

- 用 `pip download --no-deps --only-binary=:all:` 只取**纯 Python 轮子**（`*-none-any.whl`）；
- 只有平台轮子的包（PyYAML、MarkupSafe）改从 sdist 取纯 Python 回退实现；
- 解包到 `entry/src/main/resources/rawfile/python/site-packages.zip`（stored 压缩）；
- 同时生成 `tooling/python/vendor-licenses.md`，内容并入 `THIRD_PARTY_NOTICES.md`。

运行时：`PythonService.pythonPath` 返回 `python312.zip:site-packages.zip`，
`ensureRuntime` 把两个 zip 一起释放到 `filesDir/python/lib/python3.12/`。

## 2. C 扩展：交叉编译

工具链与 CPython 本体一致（`build-cpython-ohos.sh` 里那套 OHOS clang + sysroot）：

```bash
TC=/opt/ohos-cmdline/command-line-tools/sdk/default/openharmony/native
CC=$TC/llvm/bin/aarch64-unknown-linux-ohos-clang
SYSROOT=$TC/sysroot
```

要点（与扩展模块相同的三条铁律）：

1. 产物放 `entry/libs/arm64-v8a/`，**只有这个目录能被 dlopen**；
2. 每个 `.so` 必须带 `DT_NEEDED libpython3.12.so`（否则实机报 `PyModuleDef_Init: symbol not found`）；
3. 依赖库（libz/libssl/libcrypto/libsqlite3/libbz2/liblzma…）也放同一目录，SONAME 即文件名。

### numpy 的现状与下一步

numpy 2.x 用 meson 构建，`meson.build` 需要**目标平台的 python 解释器**做内省
（`import sysconfig` 取头文件/库路径）。交叉编译时 meson 不能在 x86 上执行 aarch64 的
`python3`，因此卡在：

```
meson.build:41:12: ERROR: Python dependency not found
```

已排除：`pkg-config` 缺失、`.pc` 文件名不符（`python3` / `python-3.12` / `*-embed` 都已提供
且 `pkg-config --modversion python-3.12` 正常返回 3.12）。真正缺的是"能在构建机上运行的
目标解释器"。

两条可行路线（按推荐顺序）：

1. **qemu-user + OHOS sysroot**：装 `qemu-user-static`，用
   `qemu-aarch64-static -L $SYSROOT <交叉编译出的 python3> -c "import sysconfig; ..."`
   让 meson 完成内省；把该命令包成 wrapper 写进 cross file 的 `[binaries] python`。
2. **改走 setuptools 路线**：numpy 1.26.x 仍支持 `setup.py`，用
   `_PYTHON_HOST_PLATFORM=linux-aarch64` + `CC/AR/LDSHARED` 交叉，不走 meson 的 Python 依赖发现。

numpy 打通后，pandas（依赖 numpy + Cython 生成的 C）、scipy、matplotlib 才有意义；
Pillow/lxml 与 numpy 无关，可并行推进（依赖 libjpeg-turbo、libpng、freetype、libxml2/libxslt）。

## 3. 已验证可用（2026-10）

纯 Python 21 个：requests / urllib3 / certifi / idna / charset-normalizer / python-dateutil /
pytz / jinja2 / MarkupSafe / PyYAML / openpyxl / et_xmlfile / xlrd / beautifulsoup4 / soupsieve /
pypdf / markdown / tabulate / tqdm / packaging / six。

C 扩展：`_ssl`/`_hashlib`（OpenSSL 3）、`_sqlite3`、`_bz2`、`_lzma`、`zlib`、`_json`、
`_csv`、`math`、`struct`、`array` 等 56 个（见 `entry/libs/arm64-v8a/*.cpython-312-*.so`）。
