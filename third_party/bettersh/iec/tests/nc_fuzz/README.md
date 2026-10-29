# nc_fuzz 属性 / 边界测试

对自写 `iec/scripts/optional/cmd_nc.c` 做**宿主侧属性与边界测试**：在 x86_64 Linux
（含 WSL）上用

```bash
cc -o nc cmd_nc.c wrap.c
```

编成普通可执行文件，只用 `127.0.0.1` 回环跑。**不连设备、不需要 HarmonyOS SDK、
不访问外部网络。**

## 运行

```bash
bash third_party/bettersh/iec/tests/nc_fuzz/run.sh
NC_FUZZ_SRC=<dir> bash .../run.sh   # 指定别的源码目录（例如 git show 出的旧版本）
```

依赖 `cc`、`python3`、`bash`。全部通过退出 0，有失败退出 1；缺少依赖退出 77
（`check-all.sh` 记为 SKIP）。总耗时约 6s（含 `-w 1` 的 1s 等待）。

## 用例

| # | 用例 | 断言 |
| --- | --- | --- |
| 1 | 10MB 双向传输 | 客户端发 10MB，监听端流式原样回显；逐字节相等、长度一致、两端收到/发出的字节数都是 10MB |
| 2 | 并发两个客户端 | 监听端只 accept 一个连接；两个客户端同时连。断言至少一个成功、没有客户端挂死（`-w 2`）、监听端不崩；第二个连接实际是被拒/排队只打印记录，不做强断言 |
| 3 | 半关闭（监听端方向） | 裸 socket 客户端 `shutdown(SHUT_WR)` 后，nc 监听端 0.5s 后才产生的 stdin 数据仍要送达客户端 |
| 4 | 半关闭（客户端方向） | nc 客户端 stdin 先 EOF，裸 socket 对端 0.5s 后才发数据，客户端仍要收到 |
| 5 | `-w 1` 超时 | 对端 accept 后不回数据：1s±0.5s 返回、退出码 0；连接被拒的端口 <0.5s 失败且 stderr 有信息 |
| 6 | 端口复用 | 同一端口连续 `nc -l` 启动/退出 20 次，每次都无 `Address already in use` |
| 7 | 参数解析 | `nc -l PORT` 与 `nc -l -p PORT` 等价；无参数、缺 host/port、`-x`、`--bogus`、额外位置参数、`-p`/`-w` 缺值都返回非零且 stderr 有 `usage` |
| 8 | 二进制安全 | 固定种子随机的 1MB 数据（显式含 `0x00`/`0xFF` 与全部 256 种字节）往返逐字节一致 |
| 9 | 信号中断 | 传输中给 `nc -l` 发 `SIGTERM`：进程退出，端口可立刻重新 bind，无残留占用 |

每个用例由 Python 侧 `signal.setitimer` 单独限时；子进程另有 `subprocess` 超时，
任何一步超时都算 FAIL，不会把整个检查挂死。

## 这套测试修掉的语义 bug

`relay()` 原来把“读到对端 EOF”当成整个转发的结束条件，于是对端
`shutdown(SHUT_WR)` 后即使本端 stdin 还有数据（或稍后才有数据），也会被直接丢弃。
TCP 半关闭本来是两个独立的写方向，现在分别记录 `stdin_open` / `peer_open`：

- stdin EOF：`shutdown(sock, SHUT_WR)`，但仍继续读对端；
- 对端 EOF：停止读 socket，但仍继续把 stdin 写过去；
- 两者都结束才退出。

顺带把 `POLLNVAL` 按 EOF 处理（调用方关掉 stdin 时不再空转）。

用旧版源码跑本套件时，第 3 个用例会失败（客户端只收到空数据），可用来确认测试
确实能抓住这个回归：

```bash
git show HEAD~:third_party/bettersh/iec/scripts/optional/cmd_nc.c > /tmp/old/cmd_nc.c
NC_FUZZ_SRC=/tmp/old bash third_party/bettersh/iec/tests/nc_fuzz/run.sh
```

## 与系统 nc 有意不同的行为

- **对端半关闭后继续发送**：系统 OpenBSD `nc`（含 `-N`）在对端 `shutdown(SHUT_WR)`
  后会立即结束，晚到的 stdin 数据丢弃；本实现会继续投递，直到 stdin 也 EOF 或
  `-w` 空闲超时。这是为了满足“迟到数据不丢”的半关闭语义。
- **stdin 是终端时的收尾**：对端关闭时若 stdin 仍是 tty，本实现直接结束，避免
  `nc host port` 在对端退出后还卡在终端输入上；管道/文件 stdin 则保留上述半关闭
  语义。
- `-v` / `-n` 接受但忽略；`-z` 仅把超时默认成 1s，仍是完整 relay，不做“连上即
  断开”的端口探测。
- 只支持 TCP；没有 UDP / 代理 / TLS。
