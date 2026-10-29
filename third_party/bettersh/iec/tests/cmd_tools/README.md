# cmd_tools 宿主行为测试（nc / hexdump / diff）

对 `iec/scripts/optional/` 下三个自写命令做**宿主侧行为测试**：在 x86_64 Linux
（含 WSL）上把 `cmd_nc.c`、`cmd_hexdump.c`、`cmd_diff.c` 编成普通可执行文件直接跑，
与系统 `hexdump` / `git diff --no-index` 逐字节对拍。**不连设备、不需要 HarmonyOS SDK、
不访问外部网络**（nc 用例只走 127.0.0.1）。

## 运行

```bash
bash third_party/bettersh/iec/tests/cmd_tools/run.sh
```

- `./run.sh --keep` 保留临时编译目录，便于排查。
- 环境变量 `CMD_TOOLS_SRC=<dir>` 可指定别的源码目录（例如 `git show` 出来的旧版本，
  用来确认测试确实能抓住回归）。
- 环境变量 `CMD_TOOLS_NO_HEXDUMP=1` 假装宿主没有 `hexdump`，只跑 `golden/` 期望文本比对。

依赖：`cc`、`git`、`bash`、coreutils（`timeout`/`od`）；系统 `hexdump` 可选。
全部通过退出 0，任何断言失败退出 1，总耗时约 5s（< 20s）。

## 为什么能直接在宿主跑

三个源文件只依赖 libc/POSIX，没有 shim 依赖；它们只导出 `iec_xxx_main`，没有 `main`，
所以测试用 `host_main.c` 加一个转发 `main`，用 `-DENTRY=iec_xxx_main` 指定入口
（与设备侧 `-Dmain=...` 的约定一致）。`cmd_diff.c` 会 `execvp("git", ...)`，因此在宿主
直接调用宿主的 git；用例都 `cd` 到临时目录并把 `HOME`/`GIT_CONFIG_GLOBAL` 指到临时目录，
避免被用户的 git 配置或仓库 `.git` 干扰。

## 覆盖的用例

### hexdump（`golden/` 期望文本 + 系统 hexdump 双重对拍）

| 用例 | 断言 |
| --- | --- |
| `-C 'AB'` | 与系统 `hexdump -C` 逐字节一致（含行尾空格、最终偏移行） |
| `-C` 0x00–0xff | 256 字节二进制全量对拍 |
| `-b / -c / -x / -d / -o` | 各格式与系统对应选项一致；`-c` 覆盖 `\0 \a \b \t \n \v \f \r` 转义 |
| `-C -s 3 -n 5` | 偏移与截断：首行偏移 3、最终偏移 8 |
| 17 字节输入 `-C` / `-x` | 部分行按整行宽度补空格（`-x` 末单元缺的一半按 0 补齐显示） |
| 多文件 `-C` | 偏移与 16 字节分组跨文件连续 |
| 多文件 `-C -n 17` | `-n` 是**整条流**的总长度，不是每个文件各算一次 |
| 32 个 0 字节 `-C` / `-C -v` | 重复整块折叠成 `*`；`-v` 关闭折叠 |
| `-C -s 5` | 文件内偏移 |
| 空输入 | 无任何输出 |
| 不存在的文件 | 退出码 1、stderr 有信息、stdout 为空 |

### diff（与 `git diff --no-index` 对拍）

| 用例 | 断言 |
| --- | --- |
| `diff -u a b` | 输出与 `git diff --no-index -- a b` 一致，退出码 1 |
| 相同内容 | 退出码 0、无输出 |
| 不存在文件 | 退出码 2（git 只给 1）、stderr 有信息 |
| `diff -q` | 有差异退出码 1 且无输出；相同退出码 0 |
| `diff -U 1 a b` | 分开写的一体化上下文参数与 `git -U1` 输出一致 |
| `diff -s` | 相同打印 `Files A and B are identical`；不同仍输出 diff |

### nc（127.0.0.1 回环，全部带 `timeout` 与自定义超时）

| 用例 | 断言 |
| --- | --- |
| `nc -l -p PORT` ↔ `nc 127.0.0.1 PORT` | 双向各收到一行，两端退出码 0 |
| 位置端口 `nc -l PORT` + `nc -p PORT host` | 两种端口写法都能互通 |
| `nc -w 1 127.0.0.1 <关闭端口>` | 4s 内失败（实测约 0.1s），stderr 有信息，不挂死 |
| 客户端 stdin 先 EOF、对端 300ms 后才发数据 | 仍能收到对端数据并退出 0 |
| 监听端 stdin 先 EOF、对端 300ms 后才发数据 | 仍能收到对端数据并退出 0 |
| stdin EOF 传播 | 对端读到 EOF（`peer listen-eof` 打印 `SAW_EOF`） |

后两条“迟到数据”用例用的是 `peer.c`（几十行的裸 socket 对端）：nc 自己构造不出这个时序
（一端 shutdown 写，另一端马上也会结束），必须精确控制先后。

## 文件

| 文件 | 作用 |
| --- | --- |
| `run.sh` | 编译 + 全部用例 + 汇总退出码 |
| `host_main.c` | 转发 `main` 到 `iec_xxx_main` |
| `peer.c` | 测试用裸 socket 对端（probe / listen / connect / *-eof） |
| `gen_golden.sh` | 用系统 hexdump 重新生成 `golden/`（只在需要改用例时跑，依赖 python3） |
| `golden/` | hexdump 期望输出文本（无系统 hexdump 时的唯一判据） |

## 这套测试修掉的语义 bug

- hexdump：`-C` 的字节分组与行宽（每 2 字节一个空格、少一列填充）、`-b/-c/-x/-d/-o`
  的字段宽度与部分行补空格、缺最终偏移行、`-c` 缺 `\0 \a \b \v \f` 转义、
  `-x/-d/-o` 字段宽度是 5 而不是 8、多个文件偏移与分组重新开始、`-n` 按文件重复计算、
  重复整块不折叠。
- diff：选项被放在 `--` 之后，git 把 `-u/-q` 当路径（退出码 129），选项全部失效；
  `-q` 未翻译成 `--quiet`；`-U n` 分开写不支持；不存在文件返回 1 而不是 2；`-s` 未实现。
- nc：stdin EOF 后只要 socket 当时没有可读数据就直接退出，导致对端稍后发来的数据
  全部丢失（`relay()` 的退出条件错误）；`-w` 只设了 SO_RCVTIMEO，连接阶段与空闲等待
  都不受超时约束。
