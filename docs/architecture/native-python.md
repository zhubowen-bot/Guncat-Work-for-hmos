# 原生 Python（run_python）与跨域桥（npy）

> 起因：实机测量发现，VM（QEMU TCI 解释执行）里的 Python / awk / sh 比原生慢 **2~3 个数量级**。
> 同一台机器上的对照实验（[`bench.sh`](../../tooling/linux-vm/bench.sh)）显示 TCI 比 JIT 慢 5–23×，
> 说明惩罚在**指令仿真层**，与语言无关。既然 JIT 权限拿不到，就换一条路：**把解释器编译成
> HarmonyOS 原生 `.so`，在应用进程内直接跑**（AOT），彻底绕开仿真。

---

## 1. 两个东西，一个解释器

| 能力 | 谁在跑 | 用在哪 |
| --- | --- | --- |
| `run_python` 工具 | 应用进程内的 CPython 3.12（`libpython3.12.so`） | AI 直接写 Python 算/处理数据 —— 默认路径 |
| `npy` 命令（VM 内） | **同一个**原生解释器（经 9p 通道转发） | 已经在 shell 管道里，需要中间插一段 Python |

两者共用同一个工作区目录（`filesDir/workspaces/<会话>`），所以文件互通，不需要拷贝。

## 2. 目录与数据交换

```
宿主(ArkTS/Native)                          VM(Alpine, QEMU TCI)
  filesDir/workspaces/<会话>  ──virtio-9p──►  /mnt/workspaces/<会话>
        ▲                                        │ bind mount
        │                                        ▼
        │                                    /workspace   ← 两边同一批 inode
  PythonService.run(code)                        │
        │                                        ├─ python3 …（VM 内的，慢）
        └────────────────────────────────────────┴─ npy …（转发到宿主，原生速度）
```

* `run_python` 的 `workDir` 直接就是工作区绝对路径，脚本里写 `open("data/a.csv")` 与 `read_file("data/a.csv")` 是同一份文件。
* `npy` 的 cwd 由它自己解析成**相对 `/workspace`** 的路径传给宿主，宿主拼回同一份目录。

## 3. npy 的协议（复用 shell 的命令通道）

```
VM:  npy [-c 代码 | 脚本.py] [参数…]
      └─ 写 ipc/<会话>/call/<id>/{code,argv,cwd,timeout,stdin,ready}
宿主: LinuxShellService.waitGuest 在等外层任务的同时轮询 call/：
      └─ PythonService.exec() → 写 ipc/<会话>/out/<id>/{stdout,stderr,code,done}
VM:  shim 读回结果 → 打印 stdout/stderr → exit <code>
```

要点：

* **嵌套而非阻塞**：宿主在等 shell 任务时顺手服务 `npy`，不需要第二个线程或新协议。
* **ready 最后写**、**done 最后写**：两边都以这两个标记判断"请求/结果完整"。
* **路径翻译**：`cwd` 说相对路径；`/workspace/...` 的绝对路径不跨域（原生侧看不到 VM 的根）。
* **超时**：客人侧 `NPY_TIMEOUT`（默认 30s）兜等待，宿主侧按 `timeout` 文件给解释器超时。

实测（宿主 JIT，端到端含 9p 往返）：单次 `npy -c 'pass'` 约 **134 ms**；同样的事在 VM 里
`python3 -c pass` 是 **3.1 s**（≈23×）。

## 4. 原生 CPython 的构建

```bash
TOOL_HOME=/opt/ohos-cmdline/command-line-tools \
BUILD_PYTHON=/opt/py312/bin/python3.12 \
bash tooling/python/build-cpython-ohos.sh
```

产物（已在仓库里，HAP 直接打包）：

| 产物 | 位置 | 大小 |
| --- | --- | --- |
| `libpython3.12.so` | `entry/libs/arm64-v8a/` | 5.8 MB |
| `python312.zip`（纯 Python 标准库，**不压缩存储**） | `entry/src/main/resources/rawfile/python/` | 9.6 MB |
| 51 个 C 扩展（`_json.cpython-312-aarch64-linux-gnu.so` 等） | `entry/libs/arm64-v8a/` | 3.5 MB |
| `libz.so`（zlib 1.3.1，供 `zlib`/`binascii` 扩展链接） | 同上 | 90 KB |

两个踩过的坑，脚本里已经处理：

1. CPython 的 `config.sub` 不认 `aarch64-linux-ohos` → 用 `--host=aarch64-linux-gnu` +
   编译器包装器把 `--print-multiarch` 对齐成 `aarch64-linux-gnu`（编译目标仍是 OHOS）。
2. 标准库 zip 必须 **`zip -0` 存储**：zipimport 解压依赖 zlib 扩展模块，而它是应用 lib 目录里的 `.so`，
   启动早期加载失败会让解释器起不来。存储模式还省掉每个模块的 inflate，HAP 自身是 zip 会再压一次。

**必须让扩展显式 `DT_NEEDED` libpython**：设备上扩展是 dlopen 加载的，若只 `NEEDED libc.so`，
`PyModuleDef_Init` 这类符号只能去全局作用域找，而鸿蒙上找不到（实机报
`Error relocating … math…so: PyModuleDef_Init: symbol not found`）。构建脚本因此改写
`BLDSHARED` 追加 `-lpython3.12`，并把 libpython 的 SONAME 规范成 `libpython3.12.so`；
加载器会先装 libpython 再直接绑定符号 —— 和 `libqemu` 找 `libslirp.so.0` 是同一条路径。

关掉的扩展：`_ssl`/`_hashlib`（无 OpenSSL）、`_sqlite3`、`_ctypes`（无 libffi）、`_locale`、
`curses`/`readline`/`_tkinter`、`_bz2`/`_lzma`、`_uuid`、`_multiprocessing` 等。
`json`/`csv`/`decimal`/`zlib`/`hashlib`（无 OpenSSL 部分）/`math`/`statistics` 等都可用。

## 5. 运行期布局与释放

首次调用 `run_python`（或 VM 里首次 `npy`）时，把 rawfile 释放到 `filesDir/python/`：

```
filesDir/python/lib/python3.12/python312.zip   ← 标准库（zipimport 直接读）
<应用 lib 目录>/libpython3.12.so                ← 解释器
<应用 lib 目录>/libz.so                         ← zlib
<应用 lib 目录>/*.cpython-312-*.so              ← C 扩展（运行期并进 PYTHONPATH）
```

为什么扩展不放 rawfile 而要放进 `libs/`：**设备上只有应用 lib 目录里的 `.so` 允许 `dlopen`**，
数据目录里的 ELF 会被 linker/沙箱拒绝（QEMU 的 `.so` 一直放在这里也是同一个原因）。
应用 lib 目录的绝对路径不需要写死 —— native 侧用 `dladdr(Py_Initialize)` 反查 libpython 落在哪，
再把它追加进 `PYTHONPATH`。

解释器启动参数（native 侧 `setenv` 后 `Py_Initialize()`）：

```
PYTHONHOME   = filesDir/python
PYTHONPATH   = filesDir/python/lib/python3.12/python312.zip:<应用 lib 目录>
PYTHONUTF8=1  PYTHONDONTWRITEBYTECODE=1  PYTHONNOUSERSITE=1
```

释放由 `filesDir/python/.version`（`versionCode` + `WORK_PY_RUNTIME_REV`）判定，换运行库只需改常量。

## 6. 执行模型与限制

* **单实例、串行**：native 侧有 `g_running` 互斥，ArkTS 侧还有 promise 链；两个调用不会同时进解释器。
* **globals 隔离**：每次执行用全新 dict，但 **import 缓存复用**（第二次起 `import json` 几乎免费）。
* **stdout/stderr 捕获**：Python 层用 `io.StringIO` 换掉 `sys.stdout/sys.stderr`，结束后落盘再读回。
* **超时**：看门狗线程到点调 `PyErr_SetInterrupt()`，纯 Python 循环会在下个字节码边界抛
  `KeyboardInterrupt`；阻塞在 C 调用里的无法中断，按"放弃等待"处理（两次后本会话停用，与 `run_js` 同策略）。
* **没有 fork/exec**：`subprocess`、`os.system`、`multiprocessing` 不可用；要调 Unix 工具请用 `shell`。
* **没有网络**：未编 `_ssl`，`urllib` 的 https 不可用；HTTP 需求走 ArkTS 侧工具。
* **第三方包**：镜像里 `pip` 装的包在 VM 里；原生解释器只有标准库（要 numpy/pandas 需另外交叉编译）。

## 6.1 标准库可用性（实机口径）

| 可用 | 说明 |
| --- | --- |
| 全部**纯 Python** 模块 | `json`/`csv`/`re`/`statistics`/`fractions`/`pathlib`/`argparse`/`logging`/`difflib`/`shutil`/`typing`/`dataclasses`/`textwrap`/`glob`/`traceback`… |
| C 扩展 | `_json` `_csv` `zlib` `binascii` `math` `cmath` `_struct` `array` `_datetime` `_random` `_statistics` `_socket` `select` `mmap` `_decimal` `_elementtree` `pyexpat` `unicodedata` `_md5` `_sha1` `_sha2` `_sha3` `_blake2` `_posixsubprocess` `_queue` `_pickle` `_heapq` `_bisect` `_asyncio` `_contextvars` `fcntl` `termios` `resource` `grp` `syslog` |

`hashlib` 没有 OpenSSL 后端，但会走 `_md5`/`_sha*`/`_blake2` 这些内置实现，`md5`/`sha256` 等**可用**。

| 不可用 | 原因 |
| --- | --- |
| `ctypes` | 未编 libffi |
| `curses` / `readline` / `tkinter` / `multiprocessing` / `_locale` / `dbm.gnu` | 依赖库或 fork，沙箱里用不上 |

> 2026-10 补充：`sqlite3`（SQLite 3.45.3）、`ssl`/`_hashlib`（OpenSSL 3.0.15）、`bz2`（bzip2 1.0.8）、
> `lzma`（xz 5.4.6）已通过 [`build-native-deps.sh`](../../tooling/python/build-native-deps.sh) 交叉编译进来，
> 依赖库随包放在 `entry/libs/arm64-v8a/`（`libssl.so.3` / `libcrypto.so.3` / `libsqlite3.so` / `libbz2.so` / `liblzma.so.5`），
> 扩展通过 `DT_NEEDED` 找它们。`hashlib.pbkdf2_hmac` / `scrypt` 也随之可用。

### 6.2 超时: 为什么不是"发信号打断"

先说结论: **绝不能用信号去打断解释器**。实机做过 7 次对照实验(timeout_ms=1000~1500 对 3~10 秒的任务):

| 现象 | 次数 | 机制 |
| --- | --- | --- |
| 超时被完全忽略, 任务跑满设计时长 | 5 | 应用进程里 SIGINT 的处置是 `SIG_IGN`, 信号直接丢弃 |
| 到点**直接闪退** | 2 | 同一时刻 SIGINT 是 `SIG_DFL`, 信号一到进程就被杀 |

上一版用 `pthread_kill(运行线程, SIGINT)`, 在桌面 Linux 上 100% 成功(POC 验证过), 但在鸿蒙应用进程里
信号处置不由我们掌控 —— 等于把进程生死交给了一个不可控的信号。另外两条路也实测不通:
`PyErr_SetInterrupt()` 只在 CPython 认定的 main thread 上生效(跨线程会被丢弃, 日志里那句
`Signal 2 ignored due to race condition` 就是它), `PyThreadState_SetAsyncExc()` 恒返回 0。

现在的方案是**两层, 全在可控范围内**:

1. **硬截止(AST 注入)**: 执行前用 `ast` 给 `while True` / `while 1` 这类常量真循环的循环体首行插入
   `if __guncat_deadline and __guncat_now() > __guncat_deadline: raise TimeoutError('run_python 超时(ast-deadline)')`。
   纯 Python 层, 不可能伤到进程; 普通循环不注入, 零开销。实测 `while True` 在 1.5 秒时准点抛出。
2. **软超时(宿主侧)**: 宿主等 `timeout_ms + 1.5s` 仍没结束, 就放弃等待并返回"超时(未中断, 任务仍在后台运行)"。
   覆盖 AST 管不到的情况(超长 `for`、阻塞在 C 调用里)。

**覆盖范围(实机验证过的边界)**:

| 写法 | 硬截止 | 行为 |
| --- | --- | --- |
| `while True:` / `while 1:` | ✅ | 到点抛 `TimeoutError('run_python 超时(ast-deadline)')`, 可被用户 `try/except` 接住, 通道保持可用 |
| `while <条件式>:`(如 `while time.time()-t0 < 2:`) | ✅ | 同上 |
| `for i in range(N):` | ❌ | 只能软超时 |

`for` 循环故意不注入逐次检查: 紧凑数值循环每轮只花 ~100ns, 每次都比一次时间会慢 2~3 倍, 不划算 —— 改用提示词/文档
明确要求"`for` 必须自己写死边界", 让写法从一开始就安全。

**熔断策略**: 软超时后, 只要那个任务还在跑, `run_python` 就**直接拒绝**(不排队); 任务一结束(`g_busy` 归零)
自动恢复。连续 3 次软超时(中间没有一次正常完成)才永久停用本会话的 Python, 需要重启应用。

执行本身固定在一个**专属线程**上(第一次调用时创建, 由它 `Py_Initialize`, 之后所有调用都投递给它) ——
解释器的线程态、GIL 记录都绑在初始化它的线程上, NAPI 回调落在别的线程会出各种怪问题。

## 7. 排障信号

`run_python`/`npy` 失败时，返回值里会带**运行库诊断**（native 侧在启动器没写出结果时用最小脚本再探一次）：

```
Python 启动器没有产出结果(rc=-1, 兜底诊断 rc=0)
—— 运行库诊断 ——
mini version=3.12.15 ...
mini prefix=/data/storage/el2/base/files/python
mini path=/data/storage/el2/base/files/python/lib/python3.12/python312.zip
mini path=/data/app/el1/bundle/.../libs/arm64
mini import _json=FAIL ModuleNotFoundError("No module named '_json'")
```

- `import _json=FAIL ... cannot open shared object file` → 扩展模块没随包/没加载（见 §5 的 libs 目录）；
- `import zlib=FAIL ... libz.so` → 少了 `libz.so`；
- 若看到 `rc=0` 且 meta/stdout/diag **全是空的** → 启动器没拿到路径（历史 bug：CPython 在
  `Py_Initialize` 时快照 `os.environ`，native 之后 `setenv` 传路径 Python 侧读不到；现已改成把
  路径直接渲染进启动器源码）；
- 连 `mini` 都没有 → 解释器初始化后就不可用，优先查 `PYTHONHOME` 里的 zip 是否存在。

## 8. 验证

| 测试 | 覆盖 | 结果 |
| --- | --- | --- |
| [`npy-test.sh`](../../tooling/linux-vm/npy-test.sh) | guest 脚本覆盖安装、数值、stdin、argv、管道进 jq、退出码、相对路径、子目录、异常、往返开销 | 12 项全过 |
| [`smoke-test.sh`](../../tooling/linux-vm/smoke-test.sh) | VM 引导、9p 一致性、cwd、超时、Python/pip/jq、npy 存在 | 18 项全过 |
| `test/guncat-harness` | 工具目录 47 个、交互模式 27 个、`run_python` 不在子代理工具面 | 521 项全过 |

真机性能数字仍待补（本次只能在宿主用 JIT/TCI 做相对比较）；`run_python` 的绝对值应当接近原生
（手机上 `sum(range(200000))` 预期 < 30 ms，对比 VM 的 1.65 s）。
