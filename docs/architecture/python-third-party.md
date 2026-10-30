# 原生 Python 的三方库扩展

`run_python` 用的是应用进程内的原生 CPython 3.12（见 [native-python.md](native-python.md)）。
三方库分两类，走两条完全不同的路：

| 类型 | 例子 | 做法 | 成本 |
| --- | --- | --- | --- |
| 纯 Python | requests、jinja2、openpyxl、PyYAML、bs4、pypdf、dateutil | 拉轮子解包成 `site-packages.zip`，运行时挂 `PYTHONPATH` | 分钟级 |
| C 扩展 | numpy、pandas、Pillow、lxml、matplotlib、scipy | 交叉编译成 aarch64 的 `.so`，进 `entry/libs/arm64-v8a/` | 半天到数天 |

## 0. 一条命令重建 + 自检

```bash
bash tooling/python/build-python-stack.sh            # 补齐所有缺失的层
FORCE=1 bash tooling/python/build-python-stack.sh mpl # 只重编 matplotlib 相关
bash tooling/python/build-python-stack.sh verify      # 只跑自检
```

阶段：`deps` → `cpython` → `pure` → `numpy` → `pandas` → `pillow` → `mpl` → `lxml` →
`crypto` → `misc` → `extras` → `verify`。每步幂等，产物存在就跳过。

**自检已经是打包的硬门槛**：`tools/build-check.ps1` 在调 hvigor 之前会先跑
`docs-check.py --strict`（文档坏链）与这 24 项，任一失败即中止（`exit 4` / `exit 3`），不产出 HAP。本机没有 WSL/rootfs 时自动跳过并提示；自检默认跳过（约 10 分钟），需要时加 `-Full` 或 `-WithPythonStack`。

自检由 [`verify-python-stack.py`](../../tooling/python/verify-python-stack.py) 完成，
24 项覆盖：标准库（sqlite3/ssl/压缩/hash）、ctypes、numpy（含 fft/det）、pandas（groupby/tz）、
Pillow、matplotlib、qrcode、lxml（xpath/cssselect）、regex（`\p{Han}`）、bs4、PyCryptodome、
docx/pptx/xlsxwriter、sympy、psutil、requests（+ certifi）、openpyxl/yaml/jinja2、reportlab、watchdog、中文字体、scipy。

[`run-verify-stack.sh`](../../tooling/python/run-verify-stack.sh) 会**按真机布局**组装环境：
extras.zip 解到临时目录、libs 只提供 `.so`、`PYTHONPATH=stdlib:site-packages:extras:libs`，
然后用 `qemu-aarch64` 跑目标 python。2026-10-28 的结果：

```
python 3.12.15 | linux
22/22 passed（当时脚本为 22 项，现已扩到 24 项）
```

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

### scipy：已打通（2026-10，1.14.1 + OpenBLAS 0.3.28）

脚本 [`build-scipy-ohos.sh`](../../tooling/python/build-scipy-ohos.sh)。**早先"缺 Fortran 做不了"
的结论是错的**，实际做通的路径：

| 环节 | 做法 |
| --- | --- |
| Fortran 编译器 | `apt-get install gfortran-aarch64-linux-gnu`（GCC 15.2） |
| BLAS/LAPACK | OpenBLAS 0.3.28，`TARGET=ARMV8` + OHOS clang + 交叉 gfortran，产出含 LAPACK 的 `libopenblas.so`（10MB） |
| LAPACK 验证 | qemu 下 `ctypes` 调 `dgesv_`：`info=0`、解正确 |
| scipy 构建 | meson 交叉文件里 `fc` 指向**包装器**：编译走 gfortran、链接走 OHOS clang（避免 DT_NEEDED glibc 版 libgfortran） |
| 运行期替身 | `libgfortran.so.5`(16 个符号)、`libgcc_s.so.1`(libunwind + 自实现 soft-float 转换)、`libmvec.so.1`(标量向量数学) |

验证（qemu，按真机布局）：

```
linalg.solve [1,2] | det 10 | eigvals | lu/cholesky
sparse.spsolve / eigs        integrate.quad=2.0 (∫sin) | odeint e^-1
optimize.minimize [2,-1]     optimize.curve_fit [2,1]
special.erf 0.5205 | gamma 24   stats.norm.ppf 1.96 | ttest p=0.2302
signal.find_peaks / filtfilt    interpolate.interp1d/CubicSpline
spatial.distance 5.0            cluster.vq.kmeans2
```

**踩坑清单**（都固化进脚本注释）：

1. 包装器要给 `cython`/`f2py`/`pythran` 加 `-P` —— meson 的 cwd 在 scipy 源码树里，
   不加的话 `import signal` 会命中 `scipy/signal`；
2. numpy 的 `.pxd` 要复制进 build 根，否则 `cimport numpy` 失败（和 pandas 同一个坑）；
3. ARPACK 需要 `-fallow-argument-mismatch`，但 clang 不认，包装器里过滤；
4. glibc `libgcc.a` 里 soft-float 符号是 **hidden visibility**，导出不了 →
   自己实现 `__trunctfdf2`/`__extenddftf2`/`__floatsitf`/`__powidf2`（[`gcc-softfloat-shim.c`](../../tooling/python/gcc-softfloat-shim.c)）；
5. scipy 少数模块 DT_NEEDED `libgfortran.so.5` 与 `libmvec.so.1` —— 用 15KB/50KB 的替身库满足加载。

体积：scipy 30MB(.so) + 33MB(.py, 进 extras) + openblas 10MB ≈ **+73MB**。

## 2.9 真机反馈修复（2026-10-27）

真机自测暴露了三类**只有设备才会显现**的问题 —— 我的 qemu 验证当时被 Alpine rootfs 里的
同名库遮住了。三个根因与修法：

| 症状 | 根因 | 修法 |
| --- | --- | --- |
| `PIL` 报 `Error loading shared library libz.so.1` | 我们只发了 `libz.so`，而 `.so` 的 DT_NEEDED 写的是 `libz.so.1`（soname ≠ 文件名） | 补 `libz.so.1` 实体副本；`libqhull_r.so.8.0` 同理 |
| `lxml`/`regex`/`scipy` 报 `PyErr_NoMemory: symbol not found` | 这些扩展由 setuptools/meson 直接链接，**没有 DT_NEEDED libpython3.12.so**；设备上全局符号作用域不生效 | 全部重新链接并加 `-Wl,--no-as-needed -lpython3.12`（PIL/lxml/regex/psutil/kiwisolver/Crypto/scipy/numpy 共 168 个 `.so`） |
| `scipy` 报 `libc.so.6` 缺失 | `ohos-fc` 包装器在"只链 `.o`"时落到了 gfortran 驱动，DT_NEEDED 变成 glibc 的 `libc.so.6`/`libm.so.6` | 包装器改为**任何链接都走 OHOS clang**，并过滤 meson 传来的 glibc `-L`/`-l`；同时把 `--version` 类查询原样交给 gfortran（否则 meson 误判编译器、传 `-Minform` 这类 g95 参数） |
| `numpy` 无 BLAS（1.4 GFLOPS） | 编 numpy 时 OpenBLAS 还不存在 | 用 `-Dblas=openblas -Dlapack=openblas` 重编，`np.show_config()` 现在报告 `blas: openblas / lapack: openblas` |

**新增静态守卫** [`check-sonames.py`](../../tooling/python/check-sonames.py)：不需要设备就能查出这类问题 ——
扫一遍 `entry/libs` 的每个 `.so`，要求①每条 DT_NEEDED 都能在随包目录或系统白名单里找到；
②凡是 Python 扩展必须带 DT_NEEDED `libpython3.12.so`；③不得出现 glibc 专有 soname。
已作为**打包第 2 道门槛**（`exit 6`）。

### 2.10 OpenBLAS 触发 seccomp 被杀（2026-10-27，真机复现）

真机 6 次闪退的堆栈完全一致，根因不在 Python 层：

```
Reason: Signal:SIGSYS(SYS_SECCOMP) syscall number is 235
#00 ld-musl-aarch64.so.1          ← 进程在这里被内核杀掉
#01 libopenblas.so
#02 libopenblas.so(blas_memory_alloc+432)
#03 libopenblas.so(blas_thread_init+120)
#04 libopenblas.so(gotoblas_init+104)
#05 ld-musl(do_init_fini)         ← dlopen 期间执行 .init
```

- aarch64 上 `syscall 235` = **`mbind`**（NUMA 内存策略），HarmonyOS 的 seccomp 把它判为违规，
  直接 **SIGSYS 终止进程** —— 这不是崩溃，`try/except` 当然无效。
- OpenBLAS 的 `driver/others/memory.c` 在 `#ifdef OS_LINUX` 下**无条件**调用 `my_mbind`，
  于是 `import numpy` → dlopen libopenblas → 构造函数 → 被杀。pandas / scipy / matplotlib
  都依赖 numpy，**看起来像"这些库都崩了"，实际是同一个原因**。

修法（已固化进 `build-scipy-ohos.sh` 的 OpenBLAS 步骤）：

1. 给 `common_linux.h` 的 `my_mbind` / `my_set_mempolicy` 增加 `GUNCAT_NO_NUMA_SYSCALLS` 分支，
   编 OpenBLAS 时加 `-DGUNCAT_NO_NUMA_SYSCALLS`（手机没有 NUMA 策略可谈，直接跳过）；
2. 同时加 `NO_AFFINITY=1`，避免 `sched_setaffinity` 之类同样可能被拦的调用。

**教训**：在 OHOS 上，"进程突然消失、没有 Python traceback" 优先去看 cppcrash 的
`Reason: Signal:SIGSYS` —— 大概率是某个 C 库调了被 seccomp 拦的系统调用。

### 2.11 extras 必须是解压后的目录（2026-10-27）

`RawAsset.extract` 只是**拷贝 rawfile 原始字节**，不会解压。之前把 `extras.zip` 拷到
`<stdlib>/extras`，于是 sys.path 上那个路径实际是个 zip 文件，靠 zipimport 勉强能 import `.py`，
但 **docx/pptx 的模板、pandas 的数据文件用 `os.path.exists()` 一律 False**
（真机报 `PackageNotFoundError: .../docx/templates/default.docx`）。

改为：拷贝出 `extras.zip` 后用 `@kit.BasicServicesKit` 的 `zlib.decompressFile` 解到
`<stdlib>/extras` 目录，成功后删除 zip（省 ~77MB 沙箱空间）；并处理旧版本遗留的"同名文件"。

### 2.12 中文字体为何在真机上是 None（2026-10-27 修复）

`guncat_fonts.path()` 在真机返回 `None`、`use_cjk()` 无效，根因是**字体文件从未落地**：
`RawAsset.extract` 用 `fileIo.openSync(..., CREATE)` 写目标文件，而 `<stdlib>/fonts/` 目录
不存在时这一步直接失败，异常被 `catch` 里打成一条 warn 就过去了。

修法：解压前先 `mkdir -p <stdlib>/fonts`；另外 `path()` 增加**系统字库回退**
（真机实测 `/system/fonts/HarmonyOS_Sans_SC.ttf` 等 4 个字体都是 0 缺字，
而 `HYQiHeiL3.ttf` 是子集字体、缺 191 字，已排除）。

### 2.13 multiprocessing（2026-10-27）

`_multiprocessing` 之前没编（`multiprocessing` 能 import 但起不了进程）。现已随包：
用 CPython 源码的 `Modules/_multiprocessing/{multiprocessing,semaphore}.c` 交叉编译，
与 `_posixshmem` 配合，`Pool.map` / `Process.start()` 在 qemu 里实测可用（fork 启动方式）。

配套的 [`guncat_mp.py`](../../tooling/python/local-pkgs/guncat_mp.py) 提供 fork+Pipe 的并行 `map`
（`Pool` 因 `/dev/shm` 不可用）。真机实测：4 进程 2.07x、4 线程 0.10x；
单任务 < 100ms 时并行反亏（fork 开销 60–90ms），结果必须可 pickle。

**设备侧注意**：OHOS 沙箱可能限制 `fork`，若 `Process.start()` 让应用消失，
基本就是被 seccomp/SELinux 拦了（和 OpenBLAS 的 `mbind` 同类）——那种情况用
`threading` + numpy/scipy 向量化替代。自检里已加入 `multiprocessing` 一项（真起进程跑 `Pool.map`）。

## 3. 已验证可用（2026-10）

纯 Python 21 个：requests / urllib3 / certifi / idna / charset-normalizer / python-dateutil /
pytz / jinja2 / MarkupSafe / PyYAML / openpyxl / et_xmlfile / xlrd / beautifulsoup4 / soupsieve /
pypdf / markdown / tabulate / tqdm / packaging / six。

C 扩展：`_ssl`/`_hashlib`（OpenSSL 3）、`_sqlite3`、`_bz2`、`_lzma`、`zlib`、`_json`、
`_csv`、`math`、`struct`、`array` 等 56 个（见 `entry/libs/arm64-v8a/*.cpython-312-*.so`）。
