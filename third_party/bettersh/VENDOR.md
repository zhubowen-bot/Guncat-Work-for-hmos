# 来源与本地改动

本目录是 **BetterSH** 的 vendored 副本，作为 Guncat 的设备内执行核使用。

- 上游：`https://atomgit.com/qq_35859034/BetterSH.git`
- 上游提交：`27d2440`（2026-10-24）
- 其中 `iec/` 是 BetterSH 的子模块 `https://github.com/panedioic/iec.git`，上游提交 `b1b89fa`
- 拷贝时间：2026-10-29

## 为什么不直接用 submodule

Guncat 需要在这里改运行核（新增 exec 会话 API、作业级取消），改动必须跟着
Guncat 的版本走、和其它模块一起构建。submodule 会让"改一行就要在另一个仓库
提交 + 更新指针"变成常态，且这些改动对上上游没有意义。

## 本地改动（相对上游）

1. `iec/exec/exec_session.{h,cpp}` —— 新增：程序化执行会话（管道、stdin、超时、
   输出上限、作业级取消）。
2. `iec/exec/exec_server.{h,cpp}` —— 新增 `OP_TERMINATE_JOB` / `OP_LIST`、
   进程表里的 `job` 字段、cwd 合法性拒绝、`onTick` 里的延迟 SIGKILL。
3. `iec/common/sock_operation.h`、`iec/exec/exec_types.h` —— 协议与请求结构随之扩展。
4. `iec/platform/ohos/har/` —— 导出 `execStart/execPoll/execWait/...` 的 NAPI 与
   类型声明；CMake 增加 `exec_session.cpp`、`rpc.c`、`sock_client.c`。
5. `iec/tools/exec_session_selftest.cpp`、`iec/scripts/test_exec_session.sh` ——
   宿主侧验收（21 项）。
6. `iec/docs/exec-session.md`、两份 `LICENSE`、`THIRD_PARTY_NOTICES.md`。

## 维护约定

- 上游代码尽量少动；我们的扩展集中在 `exec_session.*` 与 `exec_server.cpp` 的
  新增 handler，升级上游时优先保留这两处。
- 命令 so（`libmksh.so`、`libtoybox.so`、`libpython.so`…）**不在仓库里**，由
  `scripts/build_*.sh` 交叉编译产出到 `feature/bsh_main/libs/arm64-v8a/`。Guncat
  需要它们时，从那里拷到 `entry/libs/arm64-v8a/`（或直接跑脚本把产物指向 entry）。
- 上游文档（`README.md` / `AGENTS.md`）保留原样，作为参考；**Guncat 的集成说明看
  `docs/architecture/iec-runtime.md`**。
