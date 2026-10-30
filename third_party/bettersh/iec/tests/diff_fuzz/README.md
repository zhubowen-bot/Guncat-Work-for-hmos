# diff_fuzz — diff 属性/边界对拍（100 对随机文件 + 选项/路径/边界/大文件）

在宿主机（x86_64 Linux / WSL）上把 `iec/scripts/optional/cmd_diff.c` 编成普通可执行
文件，与直接运行 `git diff --no-index` **逐字节**比较 stdout / stderr / 退出码。
不连设备、不需要 HarmonyOS SDK、不访问外部网络。

`cmd_diff.c` 本身不做比较，只把参数翻译成 `git diff --no-index <options> -- <a> <b>`；
所以这里的判据是**翻译后的 git 调用**，而不是 GNU diffutils 的文本格式——两边都不是
`git diff` 自己的输出格式差异。

## 运行

```bash
bash third_party/bettersh/iec/tests/diff_fuzz/run.sh
# 或
python3 third_party/bettersh/iec/tests/diff_fuzz/run.py
```

- `--pairs N`：随机文件对数量（默认 100）。
- `--seed N`：随机种子（默认 20261030，保证可复现）。
- `--keep`：保留临时编译目录与输入文件。
- `--max-failures N`：最多打印多少条失败（默认 10）。

退出码：`0` 全部通过；`1` 存在差异/失败；`2` 编译/环境错误；`3` 宿主没有 git
（`run.sh` 把它转成 `77`，`scripts/check-all.sh` 记为 SKIP）。

依赖：`python3`、`cc`、`git`（>= 2.20 的 `--no-index`）。

## 覆盖范围

当前默认参数共 **138 条用例**，全部逐字节对拍（错误类断言退出码/stderr 形态）。

### 1) 随机文件对（100 对）

确定性类别轮转，前 9 对各覆盖一类，其余按种子随机：

| 类别 | 内容 |
| --- | --- |
| `identical` | 完全相同的文本 |
| `whitespace` | 仅空格/制表符不同 |
| `length` | 行数/长度差异很大 |
| `binary` | 含 NUL 的随机二进制 |
| `crlf` | 一边 LF、一边 CRLF |
| `no_trailing_nl` | 无结尾换行 vs 有结尾换行 |
| `long_line` | 单行 10KB，行中间改一个字节 |
| `empty` | 空/空、空/非空、非空/空 |
| `mixed` | 多处 hunk 的文本 |

每对都跑「本实现」与 `git diff --no-index -- a b`，要求 `(rc, stdout, stderr)` 三元组
完全一致；并额外断言 git 的退出码落在 `0/1/2` 内（diff 的约定）。

### 2) 选项翻译（12 条对拍 + 6 条语义断言）

`-u`、`-U 1`（分开写）、`-U1`（紧贴写）、`-U 7`、`-q`（有差异/相同）、`-w`、`-b`、
`--stat`、`--color=never`、`--no-color`、无选项。

参照一律写成 `git diff --no-index <翻译后的选项> -- a b`——**选项必须在 `--` 之前**，
这正是本实现最容易写错的地方（写成 `git diff --no-index -- -u a b` 会把 `-u` 当路径，
退出码 129，选项全部失效）。

除逐字节对拍外，还单独断言选项真的生效（老 bug 的形态是输出/退出码与不加选项时相同）：

- `-U 1` / `-U1` 的 hunk 头必须是 `@@ -2,3 +2,3 @@`（1 行上下文）；
- `--stat` 输出里必须有 `1 file changed`；
- `--color=never` 输出里不能有 ANSI 转义；
- `-q` 有差异时无输出、退出码 1；相同时无输出、退出码 0；
- `-s` 相同文件打印 `Files a and same are identical`、退出码 0；有差异时仍输出 diff。

### 3) 路径边界（8 条）

- 不存在的文件：退出码 2 + stderr（git 只给 1）；
- 目录对目录（有差异 / 内容相同）：与 git 逐字节一致；
- 以 `-` 开头的文件名（用 `--` 保护）；
- 含空格与中文的路径；
- 绝对路径（cwd 在别处）；
- 文件 vs 目录且目录里没有同名文件：退出码 2（git 只给 1）；
- 文件 vs 目录且目录里**有**同名文件：不能被上面的检查误伤，仍照常比较。

### 4) 边界与权限（11 条）

- 同一个文件两次：退出码 0、无输出；
- 文件 vs 系统目录 `/usr`：退出码 2；
- 不可读文件、不可读目录：退出码 2 + `Permission denied`（**以 uid!=0 运行**；
  uid=0 时该两条自动 skip 并打印说明，因为 root 无视权限位）；
- 只有 1 个操作数 / 没有操作数：退出码 2（git 是 129）；
- `-U` 非数字（分开写）、`-Ux`（紧贴写）、`-U` 缺参数：退出码 2（git 是 129）。

### 5) 大文件（2 条）

构造约 8 MiB 的文本对（每行 64 字节 × 13 万行，隔行改动，逼出 MB 级 diff 输出），
要求：

- 退出码与 git 一致（1）；
- **完整输出**的 SHA-256 相同（不是只看开头）；
- 前 1 MiB 逐字节相同（便于定位首个差异）；
- 输出长度必须 ≥ 1 MiB，防止「输出被截断但前缀相同」蒙混过关。

再用 `-w` 跑一次同一对大文件，确认选项 + 大文件组合也一致。

## 这套测试修掉的 bug

修复前用同样的用例跑旧版 `cmd_diff.c`：**9 条失败**，对应 4 类问题。修复都在
「转发前先挡一遍」的层面，没有自己实现 diff 算法。

### A. 操作数不存在/不可读的退出码不是 2

| 场景 | 修复前 | git 直接跑 | 修复后 |
| --- | --- | --- | --- |
| 文件不可读 | 128（git `fatal: cannot hash`） | 128 | **2** + `diff: x: Permission denied` |
| 目录不可读 | 1（`error: Could not open directory`） | 1 | **2** + `diff: d: Permission denied` |
| 文件 vs 目录（无同名文件） | 1（`error: Could not access 'd/a'`） | 1 | **2** + `diff: d/a: No such file or directory` |

修复：转发前 `stat` 两个操作数；文件/目录混用时先按 diff 的规矩解析成
`<目录>/<文件名>` 再 `stat`；用 `access(R_OK)`（目录还要 `X_OK`）挡掉不可读的。
目录里**有**同名文件时照常转发，不拦——git 本来就能比较。

### B. 操作数不足 2 个时返回 129

`diff a`、`diff` 原来直接把 git 的 usage 和退出码 129 抛给用户；diff 约定是 2。
修复：`npath < 2` 时报 `diff: missing operand after '...'` 并返回 2
（`--help` / `--version` 不需要操作数，豁免）。

### C. `-U` 的上下文长度没校验

`-U x a b`、`-Ux a b` 被原样拼给 git，git 报 `--unified expects a numerical value`
并返回 129；diff 约定是 2。修复：拼之前校验必须是十进制数字，否则
`diff: invalid context length 'x'` + 退出码 2。

### D. 内存泄漏

`args`/`opts`/`paths` 以及 `-U n` 拼出来的字符串在**错误返回**和 `-s` 相同文件
**正常返回**时都没释放。命令 so 常驻在 shell 进程里，每调用一次 diff 就漏一小块。
修复：所有出口走统一 `done:` 收尾释放；`-fsanitize=address` 下已无任何
LeakSanitizer 报告。

## 与 git / GNU diff 的已知差异（不算失败，也不打算改）

本实现的设计就是「转发给 git」，所以下列差异是刻意的，测试里按「当前语义」断言，
不按 git 对拍：

1. **`-s` 的 identical 判定是本进程做的字节比较**：`diff -s -w a b` 当两文件只有
   空白不同时，GNU diff 会打印 `Files a and b are identical`，本实现拿不到这个结论
   （git 的 `-w` 在内部判断，进程外看不到），只会静默退出 0。要修就得自己实现比较
   算法，违反「不自己实现 diff」的约束。
2. **`-s` 对目录**：`diff -s d1 d1` 两边都不打印；GNU 对相同目录也不打印，一致。
   但 `-s` 的 identical 文案只覆盖「两个普通文件」的情形。
3. **`--help` / `--version`**：原样交给 `git diff --no-index`，输出是 git 的 usage 文本、
   退出码 129；GNU diff 会打印自己的帮助并退出 0。
4. **未知选项**（如 `-Q`）：git 返回 129，GNU diff 返回 2。本实现不维护选项白名单，
   无法在不误伤 git 扩展选项的前提下统一成 2。
5. **`-q` 有差异时**：本实现无输出、退出码 1（与 git `--quiet` 一致）；GNU diff 会打印
   `Files a and b differ`。这是「转发给 git」的必然结果，仓库既有用例也按此语义断言。
6. **目录递归里的个别不可读文件**：git 返回 1（`error: ...`），本实现只在**顶层操作数**
   上做权限检查，深层的仍按 git 的退出码透出。

## 连到 check-all.sh

`scripts/check-all.sh` 里新加一项（`--fast` 跳过），并把 `ITEM_NAMES` 的项数从 12 改到
13（`ITEM_FAST_SKIP` 同步加一个 `1`）：

```bash
    ...
    hexdump-fuzz
    diff-fuzz          # 新增
    iec-native-host
    ...
)

    "IEC diff 属性/边界对拍（100 对随机文件 + 选项/路径/权限/8MB）"
```

```bash
check_diff_fuzz() {
    local script="$ROOT/third_party/bettersh/iec/tests/diff_fuzz/run.sh"
    if [[ ! -f "$script" ]]; then
        skip_msg "third_party/bettersh/iec/tests/diff_fuzz/run.sh 不存在"
        return 77
    fi
    command -v bash >/dev/null 2>&1 || { skip_msg "找不到 bash"; return 77; }
    command -v python3 >/dev/null 2>&1 || { skip_msg "找不到 python3"; return 77; }
    command -v cc >/dev/null 2>&1 || { skip_msg "找不到 cc"; return 77; }
    command -v git >/dev/null 2>&1 || { skip_msg "找不到 git"; return 77; }

    bash "$script"
}
```
