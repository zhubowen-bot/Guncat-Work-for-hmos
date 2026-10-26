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

### numpy：已打通（2026-10，2.1.3）

完整脚本见 [`build-numpy-ohos.sh`](../../tooling/python/build-numpy-ohos.sh)。关键三步：

1. **让 meson 能内省目标解释器**：numpy 2.x 的 `meson.build` 要跑 `python -c "import sysconfig"`。
   OHOS SDK 的 sysroot 不含运行时加载器，交叉编出的 aarch64 python 在 x86 上跑不起来 ——
   所以准备一份 Alpine minirootfs（`alpine-aarch64`）当 `-L`，用 `qemu-user` 跑我们的目标 python，
   再包成 wrapper 写进 cross file 的 `[binaries] python` / `cython`。
2. **用 numpy 自带的 vendored meson（1.5.2）**：系统 meson 缺 numpy 的 `features` 模块
   （`meson_cpu/meson.build` 里 `import('features')`），会报 `Module "features" does not exist`。
3. **目标 python 的 pkg-config**：`python-3.12.pc`（含 `Libs/Cflags`）+ `PKG_CONFIG_LIBDIR`，
   否则 meson 报 `Python dependency not found`。

产物落 `entry/libs/arm64-v8a/numpy/`（14MB，已 strip、已删 tests/f2py），
另外带 `libc++_shared.so`（`numpy.fft` 的 pocketfft 是 C++）。
启动器会把 libDir 并进 `PYTHONPATH`，所以 `import numpy` 直接可用；`NEEDED` 是
`libpython3.12.so` + `libc.so`，与其它扩展同一条加载路径。

为什么放在 libs 而不是 site-packages：**设备上只有应用 lib 目录里的 `.so` 能被 dlopen**，
numpy 的 `_multiarray_umath.so` 等必须在包里跟随包目录，而包目录又必须在可加载的树下。

验证（qemu + Alpine rootfs，与设备同 ABI）：
`np.arange(12).reshape(3,4)` 求和 66、`@` 矩阵乘、`np.fft.fft([0,1,2,3]) = [6,-2,-2,-2]`、
`np.linalg.det([[1,2],[3,4]]) = -2`、`polyfit`、`histogram`、`default_rng` 全部正确。

## 3. 已验证可用（2026-10）

纯 Python 21 个：requests / urllib3 / certifi / idna / charset-normalizer / python-dateutil /
pytz / jinja2 / MarkupSafe / PyYAML / openpyxl / et_xmlfile / xlrd / beautifulsoup4 / soupsieve /
pypdf / markdown / tabulate / tqdm / packaging / six。

C 扩展：`_ssl`/`_hashlib`（OpenSSL 3）、`_sqlite3`、`_bz2`、`_lzma`、`zlib`、`_json`、
`_csv`、`math`、`struct`、`array` 等 56 个（见 `entry/libs/arm64-v8a/*.cpython-312-*.so`）。
