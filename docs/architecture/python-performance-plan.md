# 性能问题分析与方案（Python / shell 工具）

> 触发：实机自检发现 VM 内 Python/awk/sh 比原生慢 2–3 个数量级（详见第 1 节）。
> 结论：**这不是"缺 CPython JIT"的问题，而是"CPU 指令被逐条仿真"的问题**；
> 在拿不到 TCG JIT 权限的前提下，唯一能把 Python 拉回可用区间的手段是
> **把解释器编译成 HarmonyOS 原生 .so（AOT），在应用进程内直接跑，不再仿真**。

---

## 0. 一句话结论

| 事实 | 含义 |
| --- | --- |
| TCI 的惩罚发生在**指令仿真层**，与语言无关 | 换语言（JS/Go/Rust）、换 CPython 版本都无效 |
| 同一台机器上 **TCI 比 JIT 慢 5–23×**（本次实测） | 即使拿到 JIT 权限，手机上的 Python 仍会比原生慢 1–1.5 个数量级 |
| **JIT 当前拿不到** | 不要再把 JIT 当作方案前提；要“真快”只能走原生解释器 |
| VM 里已有 Python 3.12 + pip + jq | 兼容性/生态不缺，缺的是**执行速度** |

---

## 1. 实测数据

### 1.1 实机（鸿蒙手机，TCI 解释执行）—— 你提供的自检结果

| 场景 | 实测 | 单次开销 | 原生量级估算 | 倍率 |
| --- | --- | --- | --- | --- |
| CPython 字节码循环 200k | 9.842 s | 49.2 µs/次 | ~0.009 s | ≈1100× |
| CPython C 层 `sum(range(200k))` | 1.652 s | 8.3 µs/元素 | ~0.004 s | ≈410× |
| CPython C 层 `sum(range(2M))` | 16.836 s | 8.4 µs/元素 | ~0.04 s | ≈420× |
| `python3` 启动并打印 | 3.14 s | — | ~0.03 s | ≈100× |
| busybox `awk` 200k 循环 | 42.75 s | 214 µs/次 | ~0.02 s | ≈2100× |
| `sh` 内建算术 1000 次 | 0.71 s | 710 µs/次 | ~0.003 s | ≈240× |
| 200k 行 `yes/head/wc` 管道 | 9.97 s | 50 µs/行 | ~0.05 s | ≈200× |

**读法**：TCI 的吞吐约 5–10 MIPS。CPython 跑一次 200k 空循环大约是 1 亿条客户机指令，
按 10 MIPS 就是 10 秒 —— 与实测吻合。awk/sh/python 同处一个量级，说明惩罚在指令层，
不在解释器层。

### 1.2 TCI vs JIT 对照（本次新增，同一台 x86 主机、同一镜像、同一套参数）

用 [`tooling/linux-vm/bench.sh`](tooling/linux-vm/bench.sh) 跑：
`LABEL=jit`（宿主 Debian QEMU 10.2.1，TCG JIT）与 `NET=0 QEMU=…/build-tci/qemu-system-aarch64 LABEL=tci`
（上游 QEMU 10.2.0 + `--enable-tcg-interpreter`）。计时在**客人内部**用 `/proc/uptime` 完成，
不含宿主轮询开销。

| 负载 | JIT | TCI | TCI/JIT |
| --- | --- | --- | --- |
| `python3 -c pass`（启动） | 0.460 s | 2.500 s | **5.4×** |
| `python3 -S -c pass` | 0.150 s | 1.270 s | **8.5×** |
| CPython 循环 200k | 0.370 s | 4.450 s | **12.0×** |
| `sum(range(200000))` | 0.250 s | 3.020 s | **12.1×** |
| 导入 json/re/collections/decimal | 0.500 s | 3.680 s | **7.4×** |
| awk 200k 循环 | 1.250 s | 27.150 s | **21.7×** |
| sh 算术 1000 次 | 0.020 s | 0.460 s | **23.0×** |
| 200k 行管道 | 0.110 s | 1.740 s | **15.8×** |
| 写 50MB（dd） | 0.110 s | 1.870 s | **17.0×** |
| tar 50MB | 0.160 s | 2.920 s | **18.3×** |

三条可用的结论：

1. **CPU 密集负载恒定慢 12–23×**；启动/导入这类"解析 + 少量计算"只慢 5–8×；
2. **I/O 也不是免费**：`dd` 写 50MB 慢 17×——客人内核的 ext4/page cache 同样被仿真，
   只有真正落到宿主的部分（9p、qcow2 写）才是原生的；
3. 按此倍率推算：**即便 JIT 到手**，手机上 `py_loop` 也只是 9.8s → 约 0.8s，
   仍是原生的 40–90 倍。**"拿到 JIT 就能让 Python 好用"是错觉。**

---

## 2. 三个假设的复核

### 假设一「Python 慢是因为没 JIT」——你的结论对，但注意歧义

CPython 3.13 及之前没有 JIT（3.14 才有实验性 copy-and-patch，官方收益 10–20%），
所以"缺 CPython JIT"确实解释不了 9 秒。这里被禁掉的是 **QEMU 的 TCG（CPU 仿真的 JIT）**，
不是 CPython 的 JIT —— 这也是我上一轮推荐 `ALLOW_USE_JITFORT_INTERFACE`（自研引擎）
而不是 `ALLOW_EXECUTABLE_FORT_MEMORY`（系统 JSVM）的原因。

### 假设二「是 Python 解释执行导致的」——对，而且第 1.2 节给了硬证据

`sum(range(200k))` 的循环体全在 C 里，仍慢 12×；awk 慢 21.7×；sh 慢 23×。
惩罚与上层语言无关，只与"执行了多少客户机指令"相关。

### 假设三「不能生成机器码 / 走 AOT 就能绕开」——**需要修正**

- **VM 里的 Python/busybox 本来就是 AOT 好的原生 ARM 机器码**。慢不是因为它们是字节码，
  而是因为这些 ARM 指令**不能直接在手机上执行**（应用沙箱不允许 exec 沙箱内的 ELF；
  Alpine 的 musl 与 OHOS libc 也不通用），只能由 QEMU 在运行时重新解释。
- 所以"给 VM 做 AOT"没有意义（QEMU 本身不支持 AOT 编译客户机代码）。
  **真正可执行的"绕开仿真"是：把解释器/工具重新编译成 HarmonyOS 原生 `.so`，在应用进程内调用**
  —— 这正是鸿蒙官方的 AOT 路径（C/C++ → NAPI）。这一步能把 100–1000× 的惩罚直接归零。

---

## 3. 方案对比（前提：JIT 拿不到）

| # | 方案 | 预期收益（相对当前 TCI） | 工作量 | 风险 | 保留 | 放弃 |
| --- | --- | --- | --- | --- | --- | --- |
| **A** | **原生 CPython**（交叉编译成 OHOS `.so`，NAPI 调用） | CPU 密集 **≈100–1000×**（回到原生量级） | 2–3 天 | 中：交叉编译/模块裁剪/纯 Python 生态 | 纯 Python + 标准库 + 纯 Python 包；**与工作区目录天然一致** | `apk`、numpy/pandas（除非另编）、真 Linux 语义 |
| B | 原生 MicroPython（~1MB） | ≈原生，但功能子集 | 1 天 | 低 | 轻量脚本 | 标准库兼容性差（decimal/datetime/ssl 缺） |
| C | **VM 内常驻 Python daemon + `-S`** | 启动 3.14s → ≈0；循环仍 1000× | 0.5 天 | 低 | 全家桶（pip/apk/numpy 可用） | CPU 密集仍不可用 |
| D | 原生 busybox 核心工具（sed/awk/grep/tar…） | 100–1000× | 3–5 天 | 中高：**无 fork**，管道要自实现 | 高频文本处理 | 完整 userland、`apk` |
| E | TCI 微优化（computed-goto 分派、`-O3`、换 CPU 模型） | **1.3–2×** | 1–2 天 | 低 | — | 不解决问题 |
| F | 换仿真器（Bochs / unicorn / 各类 JIT 方案） | 更慢，或同样需要 JIT 权限 | — | 高 | — | 不值得 |

> E 的说明：QEMU 的 TCI 主循环是 `for(;;) switch(opc)`（已确认，没有 threaded dispatch）。
> 改成 computed-goto 有 1.3–2× 空间，但 9.8s → 5–7s 仍是**不可用**。

---

## 4. 建议路线

### Phase 0（0.5 天，止损，先做）

1. **VM 内常驻 Python 解释器**：agent 首次执行时拉起一个 `python3 -u -S` 子进程，
   通过 stdin/stdout 喂脚本 + 结束标记，省掉每次 3.14s 的启动与导入。
2. **默认加 `-S`**：实测启动 2.50s → 1.27s（−49%），抑制 `site` 自动导入。
3. **提示词分流**：明确告诉模型"CPU 密集计算用 `run_python`（原生），VM 里的 `python3`
   只做兜底"，避免把 10 万行 CSV 丢进 VM 里循环。

预期：小脚本端到端从 ~3.5s 降到 ~0.1–0.3s；**循环性能不变**。

### Phase 1（2–3 天，核心）

**原生 CPython 工具 `run_python`**：

1. 交叉编译 CPython 3.12（aarch64-linux-ohos，OHOS clang + lld）：
   - `--enable-shared --without-ensurepip`；裁掉 `_ssl`/`_sqlite3`/`_ctypes`/`curses`/`readline`/`tkinter`/`multiprocessing`
   - 标准库打包成 `python312.zip`（只读），`sys.dont_write_bytecode=True`
2. NAPI 封装（`entry/src/main/cpp/python/`）：`Py_InitializeFromConfig` + `PyRun_String`，
   stdout/stderr 重定向到缓冲区，异常转可读文本，GIL 下串行执行。
3. 工具面：`run_python(code, files?, timeout_ms?)`，输出截断/`.spill` 复用现有逻辑。
4. 提示词：`run_python` 负责计算与数据加工；`shell` 负责真 Unix 工具（sed/awk/tar/git/apk）。

预期：`sum(range(200000))` < 30ms，`python -c pass` < 100ms，与桌面 CPython 行为一致。

### Phase 2（3–5 天，按需）

原生 busybox 核心工具（`sed`/`awk`/`grep`/`find`/`tar`）作为 OHOS `.so`，
解决"无 fork 的管道/重定向"（进程内管道或临时文件）。只有在 Phase 1 之后仍频繁
撞到 VM 的 I/O/文本处理瓶颈时才做。

---

## 5. 验收指标

| 指标 | 目标 |
| --- | --- |
| `run_python`：`sum(range(200000))` | ≤ 30 ms（当前 VM 1.65 s） |
| `run_python`：解释器启动 | ≤ 100 ms（当前 VM 3.14 s） |
| 端到端：AI 清洗 5 万行 CSV | < 1 s（当前 VM 数十秒） |
| 包体增量 | ≤ +20 MB |
| 回归 | 现有 521 项单测、17 项 guest smoke 全绿 |
| 目录一致性 | `run_python` 打开的就是 `filesDir/workspaces/<会话>`（与 shell/read_file 同一批文件） |

---

## 6. 风险与对策

| 风险 | 对策 |
| --- | --- |
| CPython 交叉编译踩坑（模块裁剪、zip 标准库、`__pycache__` 只读） | 先做 POC：只跑 `sum(range)` 与 `import json` 两个用例，跑通再扩 |
| 无 `fork` → `subprocess`/`multiprocessing` 不可用 | 编译期禁用 + 运行期明确报错 + 提示词约束 |
| `ctypes`/`ssl`/`sqlite3` 缺库 | Phase 1 先不带；按需交叉编译 libffi/OpenSSL/SQLite（各自 0.5–1 天） |
| 用户要 numpy/pandas | 纯 Python 替代（csv/json/statistics）或回退 VM（明确标注会慢） |
| 两套 Python 让模型困惑 | 提示词里只给一条规则：**算/处理 → `run_python`；调 Unix 工具 → `shell`** |
| CPython 与 ArkTS 的线程模型 | 单线程串行 + 现有工具串行队列，不引入并发 |

---

## 7. 可行性探针（已做，结论：可做，剩机械问题）

在 WSL 里用 OHOS 的 clang/lld 直接试了 CPython 3.12.15 的交叉编译配置：

| 尝试 | 结果 |
| --- | --- |
| `--host=aarch64-linux-ohos` | ✗ CPython 自带的 `config.sub` 不认 `*‑ohos` 三元组（`OS 'ohos' not recognized`） |
| `--host=aarch64-linux-gnu` + `CC=aarch64-unknown-linux-ohos-clang` | ✓ 三元组通过、工具链检测正常；只卡在 `--with-build-python` 需要**同版本(3.12)的宿主 python**（本机是 3.14） |

所以剩下的都是机械问题，没有架构级阻碍：

1. 先用同一个 tarball 编一个宿主 CPython 3.12（`--prefix=/opt/py312`，约 5 分钟），
   再 `--with-build-python=/opt/py312/bin/python3.12` 重新 configure；
2. 模块裁剪：`_ssl`/`_sqlite3`/`_ctypes`/`curses`/`readline`/`tkinter`/`multiprocessing` 先全部不编；
3. `make -j` 产出 `libpython3.12.so` + `python312.zip`；
4. NAPI 封装与工具接入（见 Phase 1）。

另外，社区已有可参考的先例（[ohos-python](https://atomgit.com/messar/ohos-python)、
[MicroPython/OpenHarmony](https://atomgit.com/emailofzhangchao/python)、
[ohos-python-release](https://atomgit.com/OpenHarmonyPCDeveloper/ohos-python-release)），
说明这条路在 OpenHarmony 上是被走通过的。

## 8. 复现方式

```bash
# 宿主 JIT 基线
LABEL=jit bash tooling/linux-vm/bench.sh
# 宿主 TCI 基线(需自行编一份 --enable-tcg-interpreter 的宿主 QEMU)
NET=0 LABEL=tci QEMU=/path/to/qemu-system-aarch64 bash tooling/linux-vm/bench.sh
```

实机数据由用户在真机上以同一套负载测得（`bench/tci_vs_native_benchmark.csv`）。
