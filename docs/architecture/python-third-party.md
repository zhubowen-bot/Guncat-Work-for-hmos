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

### pandas：已打通（2026-10，2.2.3）

脚本 [`build-pandas-ohos.sh`](../../tooling/python/build-pandas-ohos.sh)。比 numpy 多两步：

1. **pandas 的 `__init__` 链上会 `import ctypes`** —— 我们的 CPython 当初因为缺 libffi 把
   `_ctypes` 关了。脚本先交叉编 libffi 3.4.6，再手工编出 `_ctypes` 扩展（六个 .c，链 `-lffi -lpython3.12`）。
   顺带把 `ctypes` 本身补回来了：`ctypes.CDLL('libm.so').sqrt(9)` 可用。
2. **Cython 的 `cimport numpy` 找不到 pxd** —— 把 numpy 的 `.pxd` 树复制到 pandas 源码根的
   `numpy/` 下（Cython 会搜当前目录）；host 侧 cython 也能解析。

产物：`entry/libs/arm64-v8a/pandas/`（34MB，已 strip、已删 tests）+ `_ctypes...so` + `libffi.so.8`。
运行时依赖 numpy（已有）与 pytz/dateutil/tzdata（site-packages.zip / 标准库 zip 里都有）。

验证（qemu + Alpine rootfs）：
`pd.DataFrame({'city':['a','b','a','b'],'amt':[1.5,2.5,3,4]}).groupby('city')['amt'].sum()`
→ `{'a': 4.5, 'b': 6.5}`；带时区的 `pd.date_range(..., tz='Asia/Shanghai')` 正常输出 `+08:00`。

## 2.5 C 扩展包的双层布局（重要）

**hvigor 打包时只保留 `libs/` 里的 `.so`**，同一目录下的 `.py` 会被丢掉。所以 numpy / pandas
这种"C 扩展和 Python 代码混在同一个包里"的库必须拆两层：

| 位置 | 内容 | 为什么 |
| --- | --- | --- |
| `rawfile/python/extras.zip` → 解到 `filesDir/python/lib/python3.12/extras/` | 包的**全部 .py/数据** | 设备上只有数据目录能放可写文件、能被 zipimport/普通 import 读到 |
| `entry/libs/arm64-v8a/<pkg>/…so` | 扩展模块 | **只有应用 lib 目录里的 .so 能被 dlopen** |

两层要能"合起来"成为一个包，靠 `extras.zip` 里的 `sitecustomize.py`：它把应用 lib 目录里的
同名子树接进扩展模块搜索路径（`sys.meta_path` 末尾的兜底 finder），只在"父包已加载、但 .so
不在父包目录"时生效。`PYTHONPATH` 顺序必须是 `stdlib.zip : site-packages.zip : extras : libs`
—— extras 要在 libs 之前，否则 `import numpy` 会命中 libs 里那个只有 `.so` 的空壳目录。

验证方式（模拟真机布局）：把 extras.zip 解到临时目录、libs 里只留 `.so`，用 qemu 跑目标 python：

```
numpy 2.1.3 | sum 66 | fft [6.0,-2.0,-2.0,-2.0]
pandas 2.2.3 | groupby {1: 3.0, 2: 3.0}
```

### Pillow：已打通（2026-10，11.0.0）

脚本 [`build-pillow-ohos.sh`](../../tooling/python/build-pillow-ohos.sh)。依赖链：
zlib（已有）→ libpng 1.6.44 → libjpeg-turbo 3.0.4（cmake，`WITH_SIMD=OFF`，无 nasm 也可编）。

两个必须知道的点：

1. **`--disable-platform-guessing` 是必须的**：Pillow 的 `setup.py` 默认会把 host 的
   `/usr/include`、`/usr/lib`、`/lib` 塞进编译/链接命令，交叉编译时会把 glibc 头和 x86 库拖进来，
   表现为 `bits/libc-header-start.h not found` 或 `--fix-cortex-a53-843419 is only supported on
   AArch64 targets`（这个报错其实是 host 的 `-L/usr/lib/x86_64-linux-gnu` 引起的）。
2. **`setup.py` 要在目标 python 里跑**（qemu 下），这样 ABI 后缀才是 `cpython-312-aarch64`；
   编译器仍由 `CC`/`LDSHARED` 指向 host 的交叉 clang。

产物：`entry/libs/arm64-v8a/PIL/*.so`（1MB）+ `libjpeg.so.62` + `libpng16.so.16`；
`.py` 部分进 `extras.zip`。支持 PNG/JPEG 读写、resize、滤镜，并与 numpy 互转
（`np.array(img)` / `Image.fromarray`）。

验证（qemu + 模拟真机布局）：新建 32×32 图 → 存 PNG（102 字节）→ 读回 → `np.array` 得到
`(32,32,3) uint8`；JPEG 保存、resize、BLUR 滤镜均正常。

### matplotlib：已打通（2026-10，3.9.2）

脚本 [`build-matplotlib-ohos.sh`](../../tooling/python/build-matplotlib-ohos.sh)。整条依赖链：
zlib/libpng（Pillow 那套）→ **freetype 2.13.3** → **qhull 8.0.2** → **kiwisolver 1.4.7** +
**contourpy 1.3.1** → matplotlib。

关键点：

1. **freetype 必须用 savannah 的 release 包**：GitHub 的 tarball 会跑 `git submodule` 检查而失败；
   并且要 `--without-brotli`（否则缺 `brotli/decode.h`）。
2. **qhull 自己编**（cmake，CMake ≥4 需 `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`），
   再给个 `qhull.pc`；配置 matplotlib 时加 `-Dsystem-freetype=true -Dsystem-qhull=true`，
   否则 meson 会去下载 subproject。
3. matplotlib 的 `meson.build` 用 `run_command(python3 -m setuptools_scm)` 取版本，
   构建机没有该包时把这一行换成字面版本号最省事。
4. 构建期依赖要装进**目标** python：`cppy`（kiwisolver）、`meson-python`（contourpy）、
   `pybind11`（matplotlib/contourpy 的头文件 + `.pc`）。
5. `mpl_toolkits`（含 mplot3d）要一起打进 extras，否则 3D 投影不可用。

验证（qemu + 模拟真机布局）：`plt.subplots` + `plot`/`bar`/`contour` 存 PNG 均成功
（12KB / 5KB），`matplotlib 3.9.2` 正常报告版本。

### lxml：已打通（2026-10，5.3.0）

脚本 [`build-lxml-ohos.sh`](../../tooling/python/build-lxml-ohos.sh)。依赖 libxml2 2.13.5 + libxslt 1.1.42。

两个关键点：

1. **必须用 PyPI 的 sdist，不能用 GitHub tag**。GitHub 树里只有 `.pyx`，会用构建机的 Cython 现场生成 C；
   Cython 3.3 生成的代码与 lxml 5.3 不兼容，报 `use of undeclared identifier '__pyx_empty_tuple'`。
   PyPI sdist 里带**已生成好的 C**，直接编即可。
2. libxml2/libxslt 是 autotools：GitHub tag 没有 `configure`，先 `autoreconf -fi`；
   `config.sub` 不认 `ohos`，用 `--host=aarch64-linux-gnu` 混过校验（编译器仍是 OHOS clang）。

验证（qemu + 模拟真机布局）：`etree.fromstring` + `xpath('//a/@x')` 正确；
`lxml.html` + `cssselect('p.c')` 正确（cssselect 是纯 Python，已 vendor）。

### 文档 / 办公 / 数学库（2026-10）

| 包 | 作用 | 备注 |
| --- | --- | --- |
| python-docx 1.2.0 | 生成/读取 Word | 依赖 lxml ✔；**模板是真实文件**，必须放 extras |
| python-pptx 1.0.2 | 生成/读取 PPT | 依赖 lxml + Pillow；同样要放 extras |
| XlsxWriter 3.x | 写带格式的 Excel | 与原生 `write_xlsx` 互补（公式/图表/条件格式更全） |
| qrcode | 生成二维码 | 依赖 Pillow 输出 PNG |
| sympy + mpmath | 符号数学（积分/解方程/化简） | 纯 Python，体积较大（约 9MB） |

**重要经验：带数据文件的包不能留在 zip 里。** python-docx 用
`os.path.join(os.path.dirname(docx.__file__), 'templates', 'default.docx')` 定位模板，
certifi 也用文件路径拿 CA 包 —— zipimport 下这些路径是虚拟的，会报
`PackageNotFoundError: ... /site-packages.zip/docx/templates/default.docx`。
所以 `vendor-pure.sh` 现在把它们单独放进 `$WORK/extras-pkgs/`，需要合并进 `extras.zip`
（运行时解成真实文件）。已在 `DATA_PKGS` 里登记：docx、pptx、certifi。

### scipy：暂不集成（2026-10 评估结论）

阻塞点不是 Python 层，而是**工具链缺 Fortran**：

- scipy 的 `linalg` / `sparse` / `optimize` 都依赖 LAPACK，而 LAPACK 是 Fortran 实现；
- OHOS SDK 里没有 gfortran/flang；OpenBLAS 可以 `NOFORTRAN=1` 编，但那只给 BLAS+CBLAS，**没有 LAPACK**；
- 交叉编 gfortran 运行库（libgfortran）再对齐 OHOS libc，是另一个量级的工程。

替代方案与代价：

1. numpy 已覆盖 `linalg`（含 `solve`/`svd`/`eig`，走自带的 lapack_lite）、`fft`、`stats` 的一部分；
2. 需要 scipy 特有功能（稀疏矩阵、优化、信号处理）时，用 numpy 手写或用纯 Python 实现；
3. 若将来非要上：先交叉编译 gfortran（或 flang）→ 编 OpenBLAS with LAPACK → 再编 scipy，
   预计 2–4 天且包体 +40~60MB。当前性价比不成立，暂缓。

## 3. 已验证可用（2026-10）

纯 Python 21 个：requests / urllib3 / certifi / idna / charset-normalizer / python-dateutil /
pytz / jinja2 / MarkupSafe / PyYAML / openpyxl / et_xmlfile / xlrd / beautifulsoup4 / soupsieve /
pypdf / markdown / tabulate / tqdm / packaging / six。

C 扩展：`_ssl`/`_hashlib`（OpenSSL 3）、`_sqlite3`、`_bz2`、`_lzma`、`zlib`、`_json`、
`_csv`、`math`、`struct`、`array` 等 56 个（见 `entry/libs/arm64-v8a/*.cpython-312-*.so`）。
