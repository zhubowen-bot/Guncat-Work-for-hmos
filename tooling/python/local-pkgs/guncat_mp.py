"""Guncat Work 自带: 不依赖 /dev/shm 的并行 map（基于 fork + Pipe）。

为什么需要它：设备沙箱里 **`/dev/shm` 不可访问**，于是 `multiprocessing` 的
`Lock / Semaphore / Queue / Pool / Value / Array` 全部在 `_multiprocessing.SemLock()` 处
抛 `PermissionError`。但 `os.fork()` 本身是允许的（实测 `Process` 裸用、`Pipe`、`Manager`
都能工作），所以可以绕开信号量，只用"fork + 管道"做并行。

用法：

    import guncat_mp

    def heavy(x):
        return sum(i * i for i in range(x))

    results = guncat_mp.map(heavy, [3_000_000] * 4, workers=4)

保证与限制（都经真机实测）：

- **函数不需要 pickle**：fork 直接继承内存，lambda / 闭包 / 嵌套函数都能用；
- **结果必须可 pickle**：返回值经 `pickle` 从子进程回传，文件句柄 / socket / lambda
  这类对象会失败（此时报错会明确说"结果不可 pickle"，不会误报成 fork 被限制）；
- **顺序**：返回列表与输入一一对应；
- **单任务要够重才划算**：单次 fork + 管道开销约 60–90ms，所以单个任务少于
  ~100ms（或 ~100 万次简单迭代）时并行是**亏的**，直接串行更快；
  实测 4 个任务各 300 万次迭代 ≈ 2.07x，而 20 万行 CSV 聚合（总耗时 146ms）用并行会慢 4 倍；
- **workers 建议**：默认 `min(8, cpu_count)`；实测甜点在 4–6，超过物理核数会因
  内存带宽竞争反而变慢（12 workers 时降到 1.72x）；
- 子进程里不要再 `import multiprocessing.pool`（会再次碰 SemLock）。
"""

from __future__ import annotations

import os
import pickle
import traceback

_PROBE = None


def _chunks(seq, n):
    """把序列尽量均匀地切成 n 段（保持顺序）。"""
    total = len(seq)
    if total == 0:
        return []
    n = max(1, min(n, total))
    size, extra = divmod(total, n)
    out, start = [], 0
    for i in range(n):
        end = start + size + (1 if i < extra else 0)
        out.append(seq[start:end])
        start = end
    return out


def _run_child(func, part, write_fd):
    """子进程主体: 算完把 (status, value) 列表 pickle 回父进程, 然后退出。

    退出码含义: 0=正常写入, 2=结果不可 pickle(已回传诊断), 1=其它失败(未写入或写入失败)。
    """
    payload = []
    for x in part:
        try:
            payload.append(("ok", func(x)))
        except BaseException:
            payload.append(("err", traceback.format_exc()))

    data = b""
    status = 0
    try:
        data = pickle.dumps(payload, protocol=pickle.HIGHEST_PROTOCOL)
    except BaseException:
        # 结果不可 pickle：回传**纯字符串**诊断（一定可 pickle），否则父进程只能看到空管道，
        # 会误判成"fork 被限制"（这是真实踩过的误报）
        status = 2
        try:
            data = pickle.dumps(
                [("err", "结果不可 pickle（返回值要经 pickle 从子进程回传）:\n"
                         + traceback.format_exc())], protocol=4)
        except BaseException:
            data = b""
    try:
        if data:
            with os.fdopen(write_fd, "wb") as handle:
                handle.write(data)
    except BaseException:
        status = 1
    finally:
        os._exit(status)


def map(func, items, workers=None):  # noqa: A001 - 故意与内建同名, 便于替换
    """并行 map: 返回与 items 等长的结果列表（顺序一致）。

    只用 fork + pipe，不碰 /dev/shm，因此在设备沙箱内可用。
    func 不需要可 pickle；**返回值需要**。
    """
    items = list(items)
    if not items:
        return []
    n = workers or min(8, os.cpu_count() or 1)
    n = max(1, min(n, len(items)))
    if n == 1:
        return [func(x) for x in items]

    parts = _chunks(items, n)
    children = []          # (pid, read_fd, offset, count)
    offset = 0
    try:
        for part in parts:
            read_fd, write_fd = os.pipe()
            try:
                pid = os.fork()
            except OSError as exc:
                os.close(read_fd)
                os.close(write_fd)
                raise RuntimeError(
                    "fork 失败（%s）：设备的沙箱可能禁止创建子进程。"
                    "请改用 threading，或用 numpy/scipy 向量化。" % exc) from exc
            if pid == 0:
                os.close(read_fd)
                _run_child(func, part, write_fd)   # 内部 os._exit，不会返回
            os.close(write_fd)
            children.append((pid, read_fd, offset, len(part)))
            offset += len(part)

        out = [None] * len(items)
        errors = []
        for pid, read_fd, offset, count in children:
            with os.fdopen(read_fd, "rb") as handle:
                data = handle.read()
            _, status = os.waitpid(pid, 0)
            code = os.waitstatus_to_exitcode(status)
            if not data:
                # 空管道有两种原因：子进程被环境杀掉(fork/seccomp)，或 pickling 前就崩了
                if code == 2:
                    raise RuntimeError("并行子进程的结果无法回传（pickle 失败），见上文诊断")
                raise RuntimeError(
                    "并行子进程没有返回结果（退出码 %d）: 设备可能限制了 fork"
                    "（沙箱/seccomp），或子进程被信号终止。请改用 threading"
                    "或 numpy/scipy 向量化。" % code)
            payload = pickle.loads(data)
            for i, (kind, value) in enumerate(payload):
                if kind == "ok":
                    out[offset + i] = value
                else:
                    errors.append(value)
        if errors:
            raise RuntimeError("并行子进程出错:\n" + "\n".join(errors[:3]))
        return out
    finally:
        for pid, read_fd, _offset, _count in children:
            try:
                os.close(read_fd)
            except OSError:
                pass
            try:
                os.waitpid(pid, os.WNOHANG)
            except OSError:
                pass


def cpu_count() -> int:
    """本进程可用的 CPU 数（设备上通常小于物理核数）。"""
    return os.cpu_count() or 1


def available() -> bool:
    """真的起一个子进程验证 fork 是否可用（结果缓存）。

    注意：不能用 `map(..., workers=1)` 来探测 —— 那会走**本地串行分支**，零 fork，
    永远返回 True（实测耗时 0.009ms vs 真 fork 的 62ms，差 7000 倍）。
    """
    global _PROBE
    if _PROBE is not None:
        return _PROBE
    try:
        pid = os.fork()
        if pid == 0:
            os._exit(0)
        _, status = os.waitpid(pid, 0)
        _PROBE = (os.waitstatus_to_exitcode(status) == 0)
    except BaseException:
        _PROBE = False
    return _PROBE
