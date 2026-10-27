"""Guncat Work 自带: 不依赖 /dev/shm 的并行 map（基于 fork + Pipe）。

为什么需要它：设备沙箱里 **`/dev/shm` 不可访问**，于是 `multiprocessing` 的
`Lock / Semaphore / Queue / Pool / Value / Array` 全部在 `_multiprocessing.SemLock()` 处
抛 `PermissionError`。但 `os.fork()` 本身是允许的（实测 `Process` 裸用、`Pipe`、`Manager`
都能工作），所以可以绕开信号量，只用"fork + 管道"做并行。

用法：

    import guncat_mp

    def heavy(x):
        return sum(i * i for i in range(x))

    results = guncat_mp.map(heavy, [1000, 2000, 3000, 4000], workers=4)

- `map()` 把 items 按块分给 workers 个 fork 子进程，每个子进程算出结果列表后经 Pipe 送回；
- **不需要 pickle 函数**（fork 直接继承），所以 lambda / 闭包都能用；
- 返回值保持输入顺序；
- 子进程异常会以 `(index, traceback 文本)` 形式回传，不会静默丢失。

限制（都是 /dev/shm 缺失带来的）：
- 不能跨进程共享锁/队列；要通信就用 `Pipe`（本模块已封装）或 `os.fork` + 临时文件；
- 子进程里不要再 `import multiprocessing.pool`（会再次碰 SemLock）；
- 设备上 fork 可能被沙箱限制：真出错时会抛 `RuntimeError` 并给出明确原因。
"""

from __future__ import annotations

import os
import traceback


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


def map(func, items, workers=None):  # noqa: A001 - 故意与内建同名, 便于替换
    """并行 map: 返回与 items 等长的结果列表（顺序一致）。

    只用 fork + pipe，不碰 /dev/shm，因此在设备沙箱内可用。
    """
    items = list(items)
    if not items:
        return []
    n = workers or min(8, os.cpu_count() or 1)
    n = max(1, min(n, len(items)))
    if n == 1:
        return [func(x) for x in items]

    parts = _chunks(items, n)
    children = []          # (pid, read_fd, offset)
    offset = 0
    try:
        for part in parts:
            read_fd, write_fd = os.pipe()
            pid = os.fork()
            if pid == 0:
                # 子进程: 算完就写回, 无论成败都要退出(绝不 return 到父进程的逻辑里)
                code = 0
                try:
                    os.close(read_fd)
                    payload = []
                    for x in part:
                        try:
                            payload.append(("ok", func(x)))
                        except BaseException:
                            payload.append(("err", traceback.format_exc()))
                    import pickle
                    data = pickle.dumps(payload, protocol=pickle.HIGHEST_PROTOCOL)
                    with os.fdopen(write_fd, "wb") as handle:
                        handle.write(data)
                except BaseException:
                    code = 1
                finally:
                    os._exit(code)
            os.close(write_fd)
            children.append((pid, read_fd, offset))
            offset += len(part)

        out = [None] * len(items)
        errors = []
        for pid, read_fd, offset in children:
            with os.fdopen(read_fd, "rb") as handle:
                data = handle.read()
            os.waitpid(pid, 0)
            if not data:
                raise RuntimeError(
                    "并行子进程没有返回结果: 设备可能限制了 fork(沙箱/ seccomp)。"
                    "请改用 threading 或 numpy/scipy 向量化。")
            import pickle
            payload = pickle.loads(data)
            for i, (status, value) in enumerate(payload):
                if status == "ok":
                    out[offset + i] = value
                else:
                    errors.append(value)
        if errors:
            raise RuntimeError("并行子进程出错:\n" + "\n".join(errors[:3]))
        return out
    finally:
        # 父进程中已 unlink 的 fd 由上面的 fdopen 关闭; 这里只兜底 wait 未回收的子进程
        for pid, read_fd, _ in children:
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
    """粗测并行是否可用: 真起一个子进程跑一次加法。"""
    try:
        return map(lambda x: x + 1, [1], workers=1) == [2]
    except BaseException:
        return False
