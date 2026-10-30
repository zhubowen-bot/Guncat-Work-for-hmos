# py_runner 宿主侧协议测试

验证 `exec/py_runner.cpp`（常驻 runner）与 `scripts/optional/python_entry.c`（客户端）
之间的本机 UDS 协议。**在 x86_64 Linux / WSL 上跑，不需要 HarmonyOS 设备**，也不
依赖应用进程或 IEC launcher。

## 为什么能在宿主跑

- `py_runner.cpp` 里的解释器路径 `kLibPython` 是编译期常量，测试用
  `-DIEC_PY_LIBPYTHON=...` 指到宿主自己的 `libpython3.x.so`；runner 本来就是在
  孙进程里 `dlopen` + `Py_BytesMain`，和设备的差别只有这个路径。
- socket 路径来自 `FAKE_SYSROOT`，测试用 `-DFAKE_SYSROOT=<临时目录>` 覆盖。
- 客户端用 `python_entry.c` + `client_main.c` 直接编，`DEFAULT_SOCK` 由环境变量
  `IEC_PY_SOCK` 覆盖，不需要改源码。
- `harness.c` 只调用 `StartPyRunner()` 然后原地不退，模拟应用主进程活着。

## 运行

```bash
# 在仓库里
bash third_party/bettersh/iec/tests/py_runner/run.sh

# 或者走脚本入口
bash third_party/bettersh/scripts/test_py_runner_host.sh
```

依赖：`gcc`/`g++`（或 `cc`/`c++`）、`python3`、宿主 `libpython3.x` 共享库
（Ubuntu: `libpython3.12-dev` 或 `python3.12-dev`）。自动探测顺序：

1. `IEC_PY_LIBPYTHON` / `--libpython`
2. `ldconfig -p` 里的 `libpython3.12.so`（优先）或版本最高的 `libpython3.*.so`
3. `/opt/py312/lib/libpython3.12.so*`、`/usr/lib/**/libpython3.*.so*`
4. `python3-config --embed --ldflags`

全部通过退出码为 0，任何一项失败为非 0。

## 覆盖的用例

| 用例 | 断言 |
| --- | --- |
| `sys.exit(7)` | 客户端退出码 7，无输出 |
| stdout/stderr 分离 | 两边内容各自完整、不串 |
| 二进制 stdout | `bytes(range(256))` 原样到达 |
| 二进制 stdin | 64KB 全字节数据往返逐字节一致 |
| 两个客户端并发 | 各 sleep 0.5s，总耗时 < 0.85s（串行需 > 1s） |
| socket 不存在 | 客户端 127 + `cannot reach the interpreter runner` |
| 协议 argc=0 | runner 拒绝并关连接、不崩溃，之后仍能服务；客户端 127 + stderr 提示 |
| 4MB stdout | 完整收到（长度与内容都校验） |
| 客户端被 SIGKILL | runner 存活，随后新请求退出码/输出正确 |
| 客户端消失后收掉解释器 | runner 家族多出的 handler/解释器在调用者死后几秒内消失 |
| 流式 stdin→stdout（各 1MB） | 不发生 stdin 写、stdout 读互相等待的死锁 |
| 4MB stdin + 解释器立刻退出 | 仍拿到真实退出码，不被 SIGPIPE 打断 |
| 8 路并发 sleep(0.3s) | 总耗时 < 1.2s（串行需 >2.4s），8 份输出/退出码各自正确 |
| 8 路并发 4MB stdout | 8 份逐字节完整，总量 32MB |
| kill 风暴（8 个 sleep(30) 同时 SIGKILL） | runner 仍能服务新请求（rc 7），且存活后代清空 |
| 单请求 SIGKILL 后连续 50 次请求 | 50 次全部正常，总耗时 < 5s，runner 未被拖死 |
| 8MB stdin + 8MB stdout 同时 | 客户端完整收发，不死锁、不丢字节 |
| 200 次短请求 | harness/runner 的 fd 数增长 ≤2，且无遗留 handler/解释器 |

“流式 stdin→stdout”与“4MB stdin + 解释器立刻退出”是回归用例：它们对应
`py_runner.cpp` 里“先把 stdin 整块写完、再开始读 stdout/stderr”的旧实现会暴露的
两个真实缺陷（死锁、SIGPIPE 打死 handler），修复后保留下来防止回退。“客户端消失
后收掉解释器”是另一条同类回归：解释器不在调用者的作业里，handler 只看管道 EOF
就会留下一个没人能停的进程。

后 6 项是并发 / 生命周期压测。判断“runner 有没有留下后代”不能靠命令行匹配：
harness、runner、handler 与解释器都是 fork 出来的同一条 cmdline（没有 exec），
所以 harness 启动后会把 `StartPyRunner()` 那个子进程的 pid 写进
`<FAKE_SYSROOT>/runner.pid`，`run.py` 用 `/proc/<runner>/task/*/children` 逐层
遍历进程树，只把**非僵尸**后代算作存活。等待一律用轮询 + 期限，不靠 `sleep` 猜。

## 文件

| 文件 | 作用 |
| --- | --- |
| `run.sh` | 薄入口，转调 `run.py` |
| `run.py` | 探测 libpython、编译 runner/客户端、逐项跑用例 |
| `harness.c` | 调 `StartPyRunner()`、把 runner pid 落盘，并保持父进程存活 |
| `client_main.c` | 给 `python_entry.c` 补 `main`，另留 `IEC_TEST_ARGC0` 错误路径开关 |

编译产物与 socket 都在 `mktemp` 出来的临时目录里，默认跑完删除；`--keep` 保留。
