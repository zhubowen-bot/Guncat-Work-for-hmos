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
| `lib-dynload/*.so`（51 个 C 扩展） | 同上 | 3.7 MB |
| `dynload-list.json`（扩展模块清单） | 同上 | <1 KB |

两个踩过的坑，脚本里已经处理：

1. CPython 的 `config.sub` 不认 `aarch64-linux-ohos` → 用 `--host=aarch64-linux-gnu` +
   编译器包装器把 `--print-multiarch` 对齐成 `aarch64-linux-gnu`（编译目标仍是 OHOS）。
2. 标准库 zip 必须 **`zip -0` 存储**：zipimport 解压依赖 zlib 扩展模块，而它在 `lib-dynload` 里，
   启动早期加载失败会让解释器起不来。存储模式还省掉每个模块的 inflate，HAP 自身是 zip 会再压一次。

关掉的扩展：`_ssl`/`_hashlib`（无 OpenSSL）、`_sqlite3`、`_ctypes`（无 libffi）、`_locale`、
`curses`/`readline`/`_tkinter`、`_bz2`/`_lzma`、`_uuid`、`_multiprocessing` 等。
`json`/`csv`/`decimal`/`zlib`/`hashlib`（无 OpenSSL 部分）/`math`/`statistics` 等都可用。

## 5. 运行期布局与释放

首次调用 `run_python`（或 VM 里首次 `npy`）时，把 rawfile 释放到 `filesDir/python/`：

```
filesDir/python/lib/python3.12/
├── python312.zip        ← 标准库（zipimport 直接读）
└── lib-dynload/*.so     ← C 扩展
```

解释器启动参数（native 侧 `setenv` 后 `Py_Initialize()`）：

```
PYTHONHOME   = filesDir/python
PYTHONPATH   = filesDir/python/lib/python3.12/python312.zip:…/lib-dynload
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

## 7. 验证

| 测试 | 覆盖 | 结果 |
| --- | --- | --- |
| [`npy-test.sh`](../../tooling/linux-vm/npy-test.sh) | guest 脚本覆盖安装、数值、stdin、argv、管道进 jq、退出码、相对路径、子目录、异常、往返开销 | 12 项全过 |
| [`smoke-test.sh`](../../tooling/linux-vm/smoke-test.sh) | VM 引导、9p 一致性、cwd、超时、Python/pip/jq、npy 存在 | 18 项全过 |
| `test/guncat-harness` | 工具目录 47 个、交互模式 27 个、`run_python` 不在子代理工具面 | 521 项全过 |

真机性能数字仍待补（本次只能在宿主用 JIT/TCI 做相对比较）；`run_python` 的绝对值应当接近原生
（手机上 `sum(range(200000))` 预期 < 30 ms，对比 VM 的 1.65 s）。
