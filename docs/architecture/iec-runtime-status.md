# IEC 执行核集成：现状、缺口与收尾清单

> 这份文档回答一个问题：**现在到底能用到什么程度，离"完整"还差什么。**
> 只写可验证的事实；每条缺口都带修法与验收标准，不留"以后再説"。

## 0. 一句话结论

`shell` 工具已经从 QEMU/Alpine 换到 IEC 原生执行核，**在真机上跑通了**
（命令、管道、工作区一致性、Python、超时、取消）。但离"完整版"还差三类东西：
**文案与事实不一致**、**超时/并发/二进制的工程边角**、**可选命令集没编**。
下面按优先级列全。

---

## 1. 已经完成且验证过的

### 1.1 执行核（IEC）

| 能力 | 证据 |
| --- | --- |
| 程序化执行 API（管道/stdin/超时/输出上限/作业级取消） | `iec/exec/exec_session.*`；宿主验收 `iec/scripts/test_exec_session.sh` **21 项全过** |
| NAPI 导出（execStart/Poll/Wait/Write/CloseStdin/Terminate/Signal/Release/List/Count） | `iec/platform/ohos/har/.../exec_napi.cpp`，HAR `Index.ets` 已导出 |
| 作业级整树终止（按 `IEC_JOB` 环境变量，不依赖父子关系） | `OP_TERMINATE_JOB` + `onTick` 延迟 SIGKILL；实测取消后 `execList` 无存活项 |
| NCP 失败回落 fork | 真机日志：`native child process refused: start native child failed: 16010004` → `spawned pid 63305` |
| 无 `SO_PEERCRED` 时不再拒绝所有请求 | 改为记录 server pid（本次真机未触发，属于兜底） |
| 启动失败返回具体原因（不再是 `handler failed`） | `onExecute` 的拒绝形状 `[0][errno][text]` |

### 1.2 Guncat 接入

| 能力 | 证据 |
| --- | --- |
| shell 工具走 IEC，QEMU 后端保留可回退 | `HarnessTools.shellBackendHook`；未注入时回退 `LinuxShellService` |
| 工作区同源 | 真机 `pwd` = `<files>/workspaces/<convId>`；用户实测 shell 写的文件 `read_file` 直读一致 |
| 命令环境 | `PATH=<sysroot>/bin:...`、`HOME`、`TMPDIR`；真机 `ls/cat/grep/sed/awk/find/xargs` 可用 |
| Python 共用解释器 | `python3` → `libpython3.12.so`（`Py_BytesMain`）+ `PYTHONHOME/PYTHONPATH`；真机 `3.12.15` |
| 随包命令 so | `libmksh.so` 399,848 B、`libtoybox.so` 734,064 B，`NEEDED` 只有 `libc.so` |
| 构建 | `hvigor assembleHap` 通过；HAP 内含 `libiec_server.so / libmksh.so / libtoybox.so` |
| 真机自检 | `aa start ... --ps iecSelfTest 1` → `[exit 0 · 0.79s]` |

### 1.3 真机实测（用户 + 自检）

- 管道/文本：`tail -n +2 | awk -F, ...` 算对；`sed/grep/find/xargs` 可用；`while` 累加 5050。
- 文件：`mkdir -p`、`printf`、`cat`、中文无乱码；与 `read_file` 字节一致。
- 耗时：单条 0.2–1.4s，冷启动 0.61s（不再有虚拟机长等待）。
- 内存/磁盘：11.6GB 总内存、可用 375MB；磁盘 452G/剩 98G。

---

## 2. 已装但未验证（最新一版）

最后一次构建**已安装**，但因为设备掉线（`hdc` 报 `need connect-key`）没跑自检。这一版修了：

1. launcher 目录**每次启动先清空再重建**（此前旧的 `tar→libbsdtar`、`node→libnode` 会残留）；
2. `hasSo()`：只给实际随包的 `.so` 写 launcher；
3. `tar` 回到 toybox（`newtoys.h` 已确认 `USE_TAR(NEWTOY(tar,...))`，即 tar applet 编进去了）；
4. `seq/stat/cmp/diff/split/sha256sum/base64/xxd` 补进 launcher 列表。

**待验一条命令**（设备回来后，**由你执行**；本文档不授权任何自动连接设备）：

```bash
hdc shell aa force-stop com.bowenapp.guncataibeta
hdc shell aa start -a EntryAbility -b com.bowenapp.guncataibeta --ps iecSelfTest 1
hdc shell hilog -x | grep -A 30 IecSelfTest
```

判据：`--- seq` 下有 1/2/3；`--- tar` 下有 `t.tar` 的 `ls -l` 行；stderr 里没有
`libbsdtar.so`。

---

## 3. 没做的（明确列出，不含糊）

### 3.1 可选命令 so：**一个都没编**

仓库里只有 `libmksh.so`、`libtoybox.so`。下列命令的构建脚本都在
`iec/scripts/optional/`，但**没有执行**：

| 命令 | 脚本 | 现状 | 影响 | 工作量 |
| --- | --- | --- | --- | --- |
| `tar`（libarchive 版） | `build_libarchive.sh` | 未编，回退 toybox tar | toybox tar 不支持 zip，压缩格式少 | 中（libarchive+zlib） |
| `unzip` / `zip` / `cpio` | 同上 + BetterSH `build_zip.sh` | 未编 | 无法解 zip | 中 |
| `git` | `build_git.sh`（需 openssl/curl/pcre2/zlib） | 未编 | 工作区不能 `git clone/commit` | 大（数小时） |
| `ssh/scp` | `build_dropbear.sh` | 未编 | 不能 ssh | 中 |
| `node/npm` | `build_node.sh`（V8） | 未编 | shell 里没有 JS；`run_js` 可替代 | 很大（几十分钟~数小时、产物几十 MB） |
| `python`（IEC 版） | `build_python.sh` | **不需要**：用 Guncat 自带 `libpython3.12.so` | 无 | — |

> 这不是"原项目没有"——脚本齐全，是我这次只编了 shell 必需的两个。见 §5 决策。

### 3.2 QEMU 后端与资产仍在

- `libqemu-system-aarch64-tci.so` 42.7MB、`kernel_aarch64` 13MB、`rootfs_guncat.qcow2` 38.4MB、
  `efi-virtio.rom` 160KB，合计 **约 94MB** 仍在 HAP 里。
- `LinuxShellService` 也完整保留（回退用）。

### 3.3 文档/许可

- `THIRD_PARTY_NOTICES.md`、`LICENSES/`、`AboutPanel.ets` 仍按"QEMU + Linux 内核 + Alpine"
  描述 shell 工具；**没有 IEC/BetterSH 的 MIT 声明**。
- `README.md` 的功能描述仍写"QEMU TCI"。

---

## 4. 已知隐患（不修就会在以后咬人）

| # | 现象 | 后果 | 修法 | 量 |
| --- | --- | --- | --- | --- |
| 1 | `PromptBuilder.ts:82` 仍告诉模型"Alpine，QEMU 解释执行、无 JIT" | 模型会按错误前提用工具（找 apk/seq/虚拟机特性） | 改成原生执行核 + 实际命令面 | S |
| 2 | 工具描述说"git/python/node 以随包为准"，实际 git/node 没有 | 模型试 `git`/`node` 失败，浪费轮次 | 明确列出可用命令，或编出来 | S |
| 3 | 超时后直接 `execRelease(id)`，进程可能还没退 → Release 拒绝 | 会话泄漏（4 线程 + 8MB 缓冲/次） | 超时后等 `exited`（带 2s 上限）再 release；或给引擎加 `ReleaseForce` | S |
| 4 | 并发没有上限 | 并行工具调用多时线程/内存暴涨 | `IecRuntime` 加信号量（如 8 并发），超出排队 | S |
| 5 | 输出按 UTF-8 解码 | `cat` 图片/压缩包会乱码 | 检测非法 UTF-8 → base64 或落 `.spill` 并提示 | M |
| 6 | 应用重启后，上一进程的 job 进程可能残留 | 孤儿进程占内存 | 启动时按旧 job 清理（`execList` + 终止），或记录 pid 文件 | M |
| 7 | `IecRuntime.writeLaunchers()` 每次启动清空 `bin/` | 多进程同时启动有竞态（当前单进程，风险低） | 用版本戳文件，只在版本变化时重建 | S |
| 8 | `tar` 用 toybox 时无 zip 支持 | 用户拿 zip 会失败 | 编 libarchive（§3.1） | M |
| 9 | 设备端没有 CI/回归 | 改动靠手测 | 把 `iecSelfTest` 扩成用例集 + `hdc` 脚本 | M |

---

## 5. 需要拍板的三个决策

1. **QEMU 回退保不保？** 保：安全网，但 HAP 多 94MB；不保：省 94MB，删
   `LinuxShellService` + qemu/kernel/rootfs，风险是原生核在个别机型不工作时没有退路。
2. **命令集编到哪一档？**
   - 最低：现状（toybox+mksh+python）
   - 推荐：+ libarchive（tar/unzip/zip）、+ git
   - 完整：再 + dropbear（ssh/scp）
   - node：建议不编，`run_js` 已覆盖；编它性价比最低。
3. **shell 并发策略**：并行（需加上限）还是回到串行（像旧 LinuxShellService）？
   建议并行 + 8 并发上限——agent 的多工具并行是刚需。

---

## 6. 收尾顺序（P0 → P2）

### P0（不做就不算可用/会误导）

1. 设备重连后跑一次自检，确认 §2 的四项修复。
2. 改 `PromptBuilder.ts`、`AboutPanel.ets`、`Constants.ts` 注释、`HarnessTools` 工具描述。
3. 修超时 release 泄漏 + 加并发上限。
4. `THIRD_PARTY_NOTICES` 补 IEC/BetterSH（MIT）、toybox（0BSD）、mksh（MirOS）；
   `AboutPanel` 同步。

### P1（完整性的主体）

5. 编 libarchive（tar/unzip/zip/cpio），launcher 自动切到 libarchive；
6. 编 git（含 openssl/curl/pcre2/zlib），launcher 注册；
7. 实测 shell 里的 `python3 -c "import numpy, pandas"`（C 扩展平铺 + sitecustomize），
   不通就补 `sitecustomize` 或明确"shell 里的 Python 只保证标准库"；
8. 决定 QEMU 去留并执行（省 94MB 或保留）。

### P2（工程化）

9. 一键构建脚本 `tools/build-iec-runtime.sh`：WSL SDK 路径、clone 源、产物拷贝、校验；
10. vendor 记录补 mksh/toybox 的提交号与构建环境；
11. 二进制输出（base64/spill）与孤儿清理；
12. 把 `iecSelfTest` 扩成真回归用例集（含失败用例）。

---

## 7. 变更记录

```
10d5e81 test(shell): 加 Want 参数触发的真机自检
fb12c20 feat(shell): 补齐 IEC 子进程环境（PATH/HOME/TMPDIR + Python）
cde545f build(shell): 随包 libmksh/libtoybox（IEC shim 版）
c8e15c1 feat(shell): shell 工具接入 IEC 原生执行核
8da2fd0 chore(third_party): vendor BetterSH + IEC 运行核（含 exec 会话 API）
```

未提交（本次盘点后待做）：launcher 清理、`hasSo` 门控、toybox tar 回退、seq 等 applet。
