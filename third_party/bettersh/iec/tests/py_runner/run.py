#!/usr/bin/env python3
"""py_runner / python_entry 宿主侧协议测试（不需要 HarmonyOS 设备）。

被测对象：
  * exec/py_runner.cpp        — 常驻 runner：fork 孙进程、dlopen libpython、回传协议
  * scripts/optional/python_entry.c — 客户端：把 argv/stdin/env 发过去，收回 stdout/stderr/退出码

做法：
  1. 用宿主自己的 libpython 覆盖编译期常量 IEC_PY_LIBPYTHON（同一份源码，不改逻辑）；
  2. 用临时目录覆盖 FAKE_SYSROOT，socket 就落成 <临时目录>/py-runner.sock；
  3. 客户端用 python_entry.c + client_main.c 编译，socket 路径由 IEC_PY_SOCK 覆盖；
  4. 这里逐项断言退出码、stdout/stderr 分离、二进制、并发、SIGKILL、大输出与错误路径。

用法：
    python3 run.py                 # 自动找 libpython、编译、跑全部用例
    python3 run.py --libpython /path/to/libpython3.12.so
    python3 run.py --keep          # 保留临时目录，便于看编译产物
退出码：全部通过为 0，任何一项失败（或环境不满足）为非 0。
"""

import argparse
import glob
import os
import re
import shutil
import signal
import socket as socketlib
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
IEC_ROOT = os.path.dirname(os.path.dirname(HERE))  # .../iec
PY_RUNNER_SRC = os.path.join(IEC_ROOT, "exec", "py_runner.cpp")
PY_CLIENT_SRC = os.path.join(IEC_ROOT, "scripts", "optional", "python_entry.c")
HARNESS_SRC = os.path.join(HERE, "harness.c")
CLIENT_MAIN_SRC = os.path.join(HERE, "client_main.c")

SLEEP_MARKER = "PYRUNNER_HOST_TEST_SLEEP_30"

TESTS = []


class Failure(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Failure(msg)


def test(fn):
    TESTS.append(fn)
    return fn


# ── libpython 探测 ────────────────────────────────────────────────────────────


def _is_elf(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def _ldconfig_map():
    """返回 {(主, 次): 路径}；ldconfig 不存在时返回空。"""
    try:
        p = subprocess.run(
            ["ldconfig", "-p"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
    except OSError:
        return {}
    found = {}
    for line in p.stdout.splitlines():
        # 形如：libpython3.12.so.1.0 (libc6,x86-64) => /usr/lib/.../libpython3.12.so.1.0
        m = re.search(r"libpython(\d+)\.(\d+)\.so\S*\s+\([^)]*\)\s+=>\s+(\S+)", line)
        if m:
            found[(int(m.group(1)), int(m.group(2)))] = m.group(3)
    return found


def _from_config():
    """从 python3-config --embed --ldflags 里找 -lpythonX.Y 对应的库。"""
    for exe in ("python3.12-config", "python3-config"):
        try:
            p = subprocess.run(
                [exe, "--embed", "--ldflags"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
            )
        except OSError:
            continue
        if p.returncode != 0:
            continue
        libdirs = re.findall(r"-L(\S+)", p.stdout)
        names = re.findall(r"-l(python\d+\.\d+)", p.stdout)
        for name in names:
            for d in libdirs or [""]:
                hits = sorted(glob.glob(os.path.join(d, "lib%s.so*" % name)))
                for hit in hits:
                    if _is_elf(hit):
                        return hit
    return None


def discover_libpython(explicit):
    if explicit:
        check(os.path.isfile(explicit) and _is_elf(explicit),
              "IEC_PY_LIBPYTHON/--libpython 不是可加载的共享库：%s" % explicit)
        return os.path.abspath(explicit)

    # 优先精确的 3.12（设备上就是 3.12），没有就取版本最高的宿主库。
    versions = _ldconfig_map()
    for ver in sorted(versions, key=lambda v: (v == (3, 12), v), reverse=True):
        if _is_elf(versions[ver]):
            return versions[ver]

    patterns = (
        "/opt/py312/lib/libpython3.12.so*",
        "/usr/lib/*/libpython3.*.so*",
        "/usr/lib/libpython3.*.so*",
        "/usr/local/lib/libpython3.*.so*",
    )
    for pattern in patterns:
        for hit in sorted(glob.glob(pattern)):
            if _is_elf(hit):
                return hit

    from_config = _from_config()
    if from_config:
        return from_config

    raise Failure(
        "找不到宿主的 libpython 共享库。请安装 python3-dev / libpython3.12-dev，"
        "或用 IEC_PY_LIBPYTHON=/path/to/libpython3.12.so 指定。"
    )


# ── 编译 ─────────────────────────────────────────────────────────────────────


def run_cmd(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0:
        raise Failure("命令失败（退出码 %d）：\n  %s\n%s"
                      % (p.returncode, " ".join(cmd), p.stdout))
    return p.stdout


class Context:
    def __init__(self, workdir, libpython):
        self.workdir = workdir
        self.sock = os.path.join(workdir, "py-runner.sock")
        self.libpython = libpython
        self.runner = os.path.join(workdir, "build", "py_runner_host")
        self.client = os.path.join(workdir, "build", "py_client")
        self.proc = None
        self.runner_pid = None
        self.log_path = os.path.join(workdir, "harness.log")
        self._log = None


def build(ctx):
    os.makedirs(os.path.join(ctx.workdir, "build"), exist_ok=True)
    cc = os.environ.get("CC", "cc")
    cxx = os.environ.get("CXX", "c++")
    inc = ["-I", IEC_ROOT, "-I", os.path.join(IEC_ROOT, "common")]
    harness_o = os.path.join(ctx.workdir, "build", "harness.o")
    runner_o = os.path.join(ctx.workdir, "build", "py_runner.o")

    run_cmd([cc, "-std=gnu11", "-D_GNU_SOURCE", "-O1", "-g", "-Wall", "-Wextra"]
            + inc
            + ['-DFAKE_SYSROOT="%s"' % ctx.workdir,
               "-c", HARNESS_SRC, "-o", harness_o])
    run_cmd([cxx, "-std=c++17", "-O1", "-g", "-Wall", "-Wextra"]
            + inc
            + ['-DFAKE_SYSROOT="%s"' % ctx.workdir,
               '-DIEC_PY_LIBPYTHON="%s"' % ctx.libpython,
               "-c", PY_RUNNER_SRC, "-o", runner_o])
    run_cmd([cxx, runner_o, harness_o, "-o", ctx.runner, "-ldl", "-lpthread"])
    run_cmd([cc, "-std=gnu11", "-D_GNU_SOURCE", "-O2", "-Wall", "-Wextra",
             PY_CLIENT_SRC, CLIENT_MAIN_SRC, "-o", ctx.client])


def start_runner(ctx):
    ctx._log = open(ctx.log_path, "wb")
    ctx.proc = subprocess.Popen(
        [ctx.runner],
        stdin=subprocess.DEVNULL,
        stdout=ctx._log,
        stderr=subprocess.STDOUT,
        env=clean_env(),
    )
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if ctx.proc.poll() is not None:
            raise Failure("runner 启动即退出：\n" + read_log(ctx))
        if os.path.exists(ctx.sock):
            ctx.runner_pid = read_runner_pid(ctx)
            time.sleep(0.05)  # 让监听进入 poll 循环
            return
        time.sleep(0.01)
    raise Failure("等待 runner socket 超时：%s" % ctx.sock)


def read_runner_pid(ctx, timeout=5.0):
    """读 harness 落盘的 runner pid，并确认它确实是 harness 的子进程。

    harness 的 cmdline 与 runner/handler/解释器完全一样（fork 后不 exec），
    光靠命令行匹配分不出谁是谁；进程树断言必须有一个确定的 runner pid。
    """
    path = os.path.join(ctx.workdir, "runner.pid")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with open(path, "r") as f:
                text = f.read().strip()
            pid = int(text)
        except (OSError, ValueError):
            time.sleep(0.01)
            continue
        if pid > 0 and _ppid(pid) == ctx.proc.pid:
            return pid
        time.sleep(0.01)
    raise Failure("拿不到 runner pid（%s）：harness 没有写出有效的子进程 pid" % path)


def read_log(ctx):
    try:
        ctx._log.flush()
    except Exception:
        pass
    try:
        with open(ctx.log_path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


# ── 客户端调用 ───────────────────────────────────────────────────────────────


def clean_env():
    """去掉会改变宿主 libpython 搜索路径的变量，保证每次跑的是同一套 stdlib。"""
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONHOME", "PYTHONPATH")}
    env.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    return env


def client_env(ctx, sock=None, extra=None):
    env = clean_env()
    env["IEC_PY_SOCK"] = sock if sock is not None else ctx.sock
    if extra:
        env.update(extra)
    return env


def run_client(ctx, argv, stdin=b"", timeout=30, extra_env=None, sock=None):
    p = subprocess.Popen(
        [ctx.client] + list(argv),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=client_env(ctx, sock=sock, extra=extra_env),
    )
    try:
        out, err = p.communicate(stdin, timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
        raise Failure("客户端超时（>%ss），已杀掉。stdout=%r stderr=%r"
                      % (timeout, out[:200], err[:200]))
    return p.returncode, out, err


def pycode(source):
    return ["python3", "-c", source]


# ── /proc 辅助（清理 + 等进程真的起来） ─────────────────────────────────────


def _all_pids():
    for name in os.listdir("/proc"):
        if name.isdigit():
            yield int(name)


def _cmdline(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            return f.read()
    except OSError:
        return b""


def pids_matching(needle):
    needle = needle.encode() if isinstance(needle, str) else needle
    me = os.getpid()
    return [pid for pid in _all_pids() if pid != me and needle in _cmdline(pid)]


def wait_for_pid_matching(needle, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        hits = pids_matching(needle)
        if hits:
            return hits[0]
        time.sleep(0.02)
    raise Failure("等待进程出现超时：%r" % needle)


def kill_pids(pids, sig=signal.SIGKILL):
    for pid in pids:
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            pass


def _stat_fields(pid):
    """读 /proc/<pid>/stat。comm 里可能有空格和括号，按最后一个 ')' 切。"""
    try:
        with open("/proc/%d/stat" % pid, "rb") as f:
            data = f.read()
    except OSError:
        return None
    rp = data.rfind(b")")
    if rp < 0 or rp + 2 >= len(data):
        return None
    return data[rp + 2:].split()


def _ppid(pid):
    fields = _stat_fields(pid)
    if not fields or len(fields) < 2:
        return None
    try:
        return int(fields[1])
    except ValueError:
        return None


def proc_state(pid):
    """进程状态字符（R/S/D/Z/…）；进程不存在返回 None。"""
    fields = _stat_fields(pid)
    if not fields:
        return None
    try:
        return fields[0].decode("ascii", "replace")[:1]
    except Exception:  # noqa: BLE001 - 极老的 /proc 格式不该让测试脚本崩掉
        return None


def _read_children(pid):
    """读 /proc/<pid>/task/*/children，返回去重后的直接子进程集合。

    比 `ps --ppid` 可靠：runner 是 setsid 出来的，且 handler 会立刻再 fork，
    ps 在采样窗口里可能刚好错过；/proc 的 children 是内核现算的。
    """
    kids = set()
    task_dir = "/proc/%d/task" % pid
    try:
        tids = os.listdir(task_dir)
    except OSError:
        return kids
    for tid in tids:
        try:
            with open(os.path.join(task_dir, tid, "children"), "rb") as f:
                for tok in f.read().split():
                    kids.add(int(tok))
        except (OSError, ValueError):
            pass
    return kids


def live_descendants(pid):
    """pid 名下所有存活后代（不含僵尸、不含 pid 自己），深度优先。"""
    found = []
    stack = list(_read_children(pid))
    seen = set()
    while stack:
        child = stack.pop()
        if child in seen:
            continue
        seen.add(child)
        state = proc_state(child)
        if state is None or state == "Z":
            continue
        found.append(child)
        stack.extend(_read_children(child))
    return found


def wait_live_descendants(pid, at_least, timeout):
    """轮询到存活后代数 >= at_least；超时抛 Failure。"""
    deadline = time.monotonic() + timeout
    last = []
    while time.monotonic() < deadline:
        last = live_descendants(pid)
        if len(last) >= at_least:
            return last
        time.sleep(0.01)
    raise Failure("等待 runner 后代达到 %d 个超时（只有 %d 个）"
                  % (at_least, len(last)))


def wait_descendants_gone(pid, timeout):
    """轮询到存活后代清空；返回超时后仍活着的 pid 列表（空表示干净）。"""
    deadline = time.monotonic() + timeout
    left = live_descendants(pid)
    while left and time.monotonic() < deadline:
        time.sleep(0.02)
        left = live_descendants(pid)
    return left


def fd_count(pid):
    return len(os.listdir("/proc/%d/fd" % pid))


def idle_fd_count(pid, samples=20, interval=0.01):
    """采样取最小值：runner 正 accept 时会短暂多一个 fd，取最小即空闲基线。"""
    best = None
    for _ in range(samples):
        try:
            n = fd_count(pid)
        except OSError:
            return None
        best = n if best is None else min(best, n)
        time.sleep(interval)
    return best


def spawn_clients(ctx, scripts, stdin=subprocess.DEVNULL):
    procs = []
    for script in scripts:
        procs.append(subprocess.Popen(
            [ctx.client] + pycode(script),
            stdin=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=client_env(ctx),
        ))
    return procs


def collect(procs, timeout, what):
    results = []
    for p in procs:
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            out, err = p.communicate()
            raise Failure("%s 超时（>%ss）" % (what, timeout))
        results.append((p.returncode, out, err))
    return results


# ── 用例 ─────────────────────────────────────────────────────────────────────


@test
def t01_exit_code(ctx):
    """sys.exit(7) → 客户端退出码 7，且没有输出。"""
    rc, out, err = run_client(ctx, pycode("import sys; sys.exit(7)"))
    check(rc == 7, "退出码应为 7，实际 %r；stderr=%r" % (rc, err))
    check(out == b"", "stdout 应为空，实际 %r" % out)
    check(err == b"", "stderr 应为空，实际 %r" % err)


@test
def t02_stdout_stderr_split(ctx):
    """stdout / stderr 分别写，客户端重定向后各自完整、不串。"""
    script = (
        "import sys\n"
        "sys.stdout.write('OUT-1\\n')\n"
        "sys.stdout.flush()\n"
        "sys.stderr.write('ERR-1\\n')\n"
        "sys.stderr.flush()\n"
    )
    rc, out, err = run_client(ctx, pycode(script))
    check(rc == 0, "退出码应为 0，实际 %r；stderr=%r" % (rc, err))
    check(out == b"OUT-1\n", "stdout 被串改：%r" % out)
    check(err == b"ERR-1\n", "stderr 被串改：%r" % err)


@test
def t03_binary_stdout(ctx):
    """二进制 stdout：0..255 每个字节都要原样到达。"""
    rc, out, err = run_client(
        ctx, pycode("import sys; sys.stdout.buffer.write(bytes(range(256)))"))
    check(rc == 0, "退出码应为 0，实际 %r；stderr=%r" % (rc, err))
    check(out == bytes(range(256)), "二进制 stdout 不一致（长度 %d）" % len(out))
    check(err == b"", "stderr 应为空，实际 %r" % err)


@test
def t04_binary_stdin(ctx):
    """二进制 stdin：64KB 全字节数据经 runner 往返后逐字节一致。"""
    payload = bytes(range(256)) * 256
    script = "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())"
    rc, out, err = run_client(ctx, pycode(script), stdin=payload)
    check(rc == 0, "退出码应为 0，实际 %r；stderr=%r" % (rc, err))
    check(out == payload, "二进制 stdin 往返不一致（发出 %d，收回 %d）"
          % (len(payload), len(out)))


@test
def t05_concurrent_clients(ctx):
    """两个客户端并发（各 sleep 0.5）→ 总耗时明显短于串行。"""
    def code(tag):
        return (
            "import time, sys\n"
            "time.sleep(0.5)\n"
            "sys.stdout.write('%s\\n')\n" % tag
        )

    procs = []
    started = time.monotonic()
    for tag in ("A", "B"):
        procs.append(subprocess.Popen(
            [ctx.client] + pycode(code(tag)),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=client_env(ctx),
        ))
    results = []
    for p in procs:
        try:
            out, err = p.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            p.kill()
            out, err = p.communicate()
            raise Failure("并发客户端超时")
        results.append((p.returncode, out, err))
    elapsed = time.monotonic() - started

    for tag, (rc, out, err) in zip(("A", "B"), results):
        check(rc == 0, "客户端 %s 退出码应为 0，实际 %r；stderr=%r" % (tag, rc, err))
        check(out == (tag + "\n").encode(), "客户端 %s stdout 不对：%r" % (tag, out))
    # 串行至少要 1.0s；并发只需 ~0.5s + 两次解释器启动。0.85s 留足慢机器余量。
    check(elapsed < 0.85,
          "两个 0.5s 请求总耗时 %.3fs，看起来没有并发服务" % elapsed)


@test
def t06_missing_socket(ctx):
    """socket 不存在 → 客户端退出码 127，stderr 有明确提示。"""
    missing = os.path.join(ctx.workdir, "no-such-runner.sock")
    check(not os.path.exists(missing), "测试用 socket 不应存在：%s" % missing)
    rc, out, err = run_client(ctx, pycode("print('never')"), sock=missing)
    check(rc == 127, "退出码应为 127，实际 %r" % rc)
    check(out == b"", "stdout 应为空，实际 %r" % out)
    check(b"cannot reach the interpreter runner" in err,
          "stderr 缺少连接失败提示：%r" % err)


@test
def t07_argc_zero(ctx):
    """协议层 argc=0：runner 应直接拒绝并关连接，不崩溃，之后仍能服务。"""
    s = socketlib.socket(socketlib.AF_UNIX, socketlib.SOCK_STREAM)
    s.settimeout(5)
    try:
        s.connect(ctx.sock)
        s.sendall(struct.pack("<III", 0, 0, 0))
        try:
            data = s.recv(1)
        except ConnectionResetError:
            data = b""
    finally:
        s.close()
    check(data == b"", "argc=0 时 runner 不应回正常响应，却收到 %r" % data)
    check(ctx.proc.poll() is None, "argc=0 不应影响 runner 进程")

    # 客户端侧同样走一遍：协议错误只能以 127 + stderr 提示收场，不能被 SIGPIPE 打死。
    rc, out, err = run_client(ctx, [], extra_env={"IEC_TEST_ARGC0": "1"})
    check(rc == 127, "argc=0 时客户端退出码应为 127，实际 %r；stderr=%r" % (rc, err))
    check(out == b"", "argc=0 时 stdout 应为空，实际 %r" % out)
    check(err.startswith(b"python3:"), "argc=0 时 stderr 缺少提示：%r" % err)

    # 错误路径之后 runner 仍然健康。
    rc, out, err = run_client(ctx, pycode("print('still-here')"))
    check(rc == 0 and out == b"still-here\n",
          "argc=0 之后 runner 未恢复正常：rc=%r out=%r err=%r" % (rc, out, err))


@test
def t08_large_stdout(ctx):
    """4MB stdout 完整收到（响应头的 u32 长度字段与分块读取都要对）。"""
    size = 4 * 1024 * 1024
    payload = bytes(range(256)) * (size // 256)
    script = "import sys; sys.stdout.buffer.write(bytes(range(256)) * %d)" % (size // 256)
    rc, out, err = run_client(ctx, pycode(script), timeout=60)
    check(rc == 0, "退出码应为 0，实际 %r；stderr=%r" % (rc, err))
    check(len(out) == size, "stdout 长度应为 %d，实际 %d" % (size, len(out)))
    check(out == payload, "4MB stdout 内容不一致")
    check(err == b"", "stderr 应为空，实际 %r" % err)


@test
def t09_client_sigkill(ctx):
    """客户端跑 sleep(30) 时被 SIGKILL → runner 不受影响，新请求正常。"""
    script = "import time\ntime.sleep(30)  # %s" % SLEEP_MARKER
    p = subprocess.Popen(
        [ctx.client] + pycode(script),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=client_env(ctx),
    )
    try:
        # 等 runner 的孙进程真的把 python 跑起来，再杀客户端。
        wait_for_pid_matching(SLEEP_MARKER, timeout=10)
        p.kill()
        p.wait(timeout=5)
        check(p.returncode == -signal.SIGKILL,
              "客户端应死于 SIGKILL，实际退出码 %r" % p.returncode)
        check(ctx.proc.poll() is None, "客户端被 SIGKILL 后 runner 也应活着")

        rc, out, err = run_client(ctx, pycode("import sys; print('alive'); sys.exit(3)"))
        check(rc == 3, "SIGKILL 之后新请求退出码应为 3，实际 %r；stderr=%r" % (rc, err))
        check(out == b"alive\n", "SIGKILL 之后新请求 stdout 不对：%r" % out)
        check(err == b"", "SIGKILL 之后新请求 stderr 应为空：%r" % err)
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
        kill_pids(pids_matching(SLEEP_MARKER))


@test
def t12_client_gone_reaps_interpreter(ctx):
    """客户端被 SIGKILL 后，runner 必须把那个解释器孙进程一起收掉。

    解释器是 runner 的孙进程，不在调用者（shell 作业）的进程组里，job 级 SIGKILL
    打不到它。handler 如果只等 stdout/stderr 的 EOF，调用者死后就会留下一个没人
    能停、一直跑的解释器 —— 设备上表现为超时/取消过的 python3 永远占着 CPU。
    """
    before = set(pids_matching(ctx.runner))
    p = subprocess.Popen(
        [ctx.client] + pycode("import time\ntime.sleep(60)"),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=client_env(ctx),
    )
    try:
        # 等到 handler 与解释器都起来：runner 家族应多出两个进程。
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if len(set(pids_matching(ctx.runner)) - before) >= 2:
                break
            time.sleep(0.02)
        check(len(set(pids_matching(ctx.runner)) - before) >= 2,
              "解释器/处理器没起来：runner 家族只多了 %d 个进程"
              % len(set(pids_matching(ctx.runner)) - before))

        p.kill()
        p.wait(timeout=5)

        # 调用者没了之后，handler 与解释器都应在几秒内消失。
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not (set(pids_matching(ctx.runner)) - before):
                break
            time.sleep(0.05)
        left = set(pids_matching(ctx.runner)) - before
        check(not left,
              "调用者死后 runner 仍留着 %d 个后代进程（解释器没被收掉）" % len(left))
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
        # 只收本次新长出来的 handler/解释器：before 里有 runner 本体，按 ctx.runner
        # 全杀会把常驻 runner 一起杀掉，后面的用例就都连不上它了。
        kill_pids(set(pids_matching(ctx.runner)) - before)


@test
def t10_streaming_stdin_stdout(ctx):
    """边读 stdin 边写 stdout（各 1MB）→ 不能因为两根管道互相等而死锁。

    runner 如果先把 stdin 整块写完再开始读 stdout，这个用例会卡死：
    解释器写完 64KB stdout 后不再读 stdin，而 runner 还堵在写 stdin 上。
    """
    payload = bytes(range(256)) * 4096  # 1 MiB
    script = (
        "import sys\n"
        "while True:\n"
        "    chunk = sys.stdin.buffer.read(65536)\n"
        "    if not chunk:\n"
        "        break\n"
        "    sys.stdout.buffer.write(chunk)\n"
    )
    rc, out, err = run_client(ctx, pycode(script), stdin=payload, timeout=20)
    check(rc == 0, "退出码应为 0，实际 %r；stderr=%r" % (rc, err))
    check(out == payload, "流式往返不一致（发出 %d，收回 %d）" % (len(payload), len(out)))
    check(err == b"", "stderr 应为空，实际 %r" % err)


@test
def t11_large_stdin_early_exit(ctx):
    """stdin 很大但解释器立刻退出 → 仍应拿到真实退出码，而不是被 SIGPIPE 打断。"""
    payload = b"z" * (4 * 1024 * 1024)
    rc, out, err = run_client(ctx, pycode("import sys; sys.exit(0)"),
                              stdin=payload, timeout=20)
    check(rc == 0, "退出码应为 0，实际 %r；stderr=%r" % (rc, err))
    check(out == b"", "stdout 应为空，实际 %r" % out)
    check(err == b"", "stderr 应为空，实际 %r" % err)


# ── 并发 / 生命周期压测 ──────────────────────────────────────────────────────


@test
def t13_eight_concurrent_sleep(ctx):
    """8 个并发客户端各 sleep 0.3s → 总耗时 < 1.2s，输出与退出码各自正确。"""
    count = 8
    started = time.monotonic()
    procs = spawn_clients(ctx, [
        "import time\n"
        "time.sleep(0.3)\n"
        "print(%d)\n" % i
        for i in range(count)
    ])
    results = collect(procs, 30, "8 路并发 sleep")
    elapsed = time.monotonic() - started

    for i, (rc, out, err) in enumerate(results):
        check(rc == 0, "客户端 %d 退出码应为 0，实际 %r；stderr=%r" % (i, rc, err))
        check(out == ("%d\n" % i).encode(),
              "客户端 %d stdout 不对：%r" % (i, out))
        check(err == b"", "客户端 %d stderr 应为空：%r" % (i, err))
    # 串行至少 8 * 0.3 = 2.4s；并发只要 ~0.3s + 8 次解释器启动。
    check(elapsed < 1.2,
          "8 个 0.3s 请求总耗时 %.3fs，runner 没有并发服务（串行需 >2.4s）" % elapsed)


@test
def t14_concurrent_large_stdout(ctx):
    """8 个客户端同时各写 4MB stdout → 8 份都逐字节完整（总量 32MB）。"""
    count = 8
    size = 4 * 1024 * 1024
    payload = bytes(range(256)) * (size // 256)
    script = ("import sys\n"
              "sys.stdout.buffer.write(bytes(range(256)) * %d)\n" % (size // 256))
    procs = spawn_clients(ctx, [script] * count)
    results = collect(procs, 180, "8 路 4MB stdout")

    total = 0
    for i, (rc, out, err) in enumerate(results):
        check(rc == 0, "客户端 %d 退出码应为 0，实际 %r；stderr=%r" % (i, rc, err))
        check(len(out) == size,
              "客户端 %d stdout 长度应为 %d，实际 %d" % (i, size, len(out)))
        check(out == payload, "客户端 %d 的 4MB stdout 内容不一致" % i)
        check(err == b"", "客户端 %d stderr 应为空：%r" % (i, err))
        total += len(out)
    check(total == count * size,
          "8 路输出总量应为 %d，实际 %d" % (count * size, total))


@test
def t15_kill_storm_no_orphans(ctx):
    """8 个 sleep(30) 客户端同时被 SIGKILL → runner 仍服务新请求（rc 7），且不留存活后代。"""
    count = 8
    marker = "PYRUNNER_KILL_STORM_30"
    script = "import time\ntime.sleep(30)  # %s\n" % marker
    procs = spawn_clients(ctx, [script] * count)
    try:
        # 先确认 8 个 handler + 8 个解释器都真的起来了，否则“杀完没后代”是空过。
        wait_live_descendants(ctx.runner_pid, 2 * count, 15)

        for p in procs:
            p.kill()
        for p in procs:
            p.wait(timeout=5)
        check(all(p.returncode == -signal.SIGKILL for p in procs),
              "8 个客户端都应死于 SIGKILL，实际退出码 %r"
              % [p.returncode for p in procs])
        check(ctx.proc.poll() is None, "kill 风暴后 harness 不应退出")

        # runner 不能把被杀的请求留在前台：新请求必须照常拿到真实退出码。
        rc, out, err = run_client(ctx, pycode("import sys; sys.exit(7)"), timeout=10)
        check(rc == 7, "kill 风暴之后新请求退出码应为 7，实际 %r；stderr=%r" % (rc, err))
        check(out == b"", "kill 风暴之后新请求 stdout 应为空：%r" % out)

        left = wait_descendants_gone(ctx.runner_pid, 10)
        check(not left,
              "kill 风暴后 runner 仍留着 %d 个存活后代（handler/解释器泄漏）：%r"
              % (len(left), left))
    finally:
        for p in procs:
            if p.poll() is None:
                p.kill()
                p.wait(timeout=5)
        # 只收后代，runner 本体留给后面的用例。
        kill_pids(wait_descendants_gone(ctx.runner_pid, 0.5))


@test
def t16_kill_then_50_requests(ctx):
    """一个 sleep(30) 客户端被 SIGKILL 后，连续 50 次请求全部正常且总耗时 < 5s。"""
    marker = "PYRUNNER_KILL_ONCE_30"
    p = subprocess.Popen(
        [ctx.client] + pycode("import time\ntime.sleep(30)  # %s\n" % marker),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=client_env(ctx),
    )
    try:
        wait_live_descendants(ctx.runner_pid, 2, 10)
        p.kill()
        p.wait(timeout=5)
        check(p.returncode == -signal.SIGKILL,
              "客户端应死于 SIGKILL，实际退出码 %r" % p.returncode)

        started = time.monotonic()
        for i in range(50):
            rc, out, err = run_client(ctx, pycode("print(1)"), timeout=15)
            check(rc == 0, "第 %d 次请求退出码应为 0，实际 %r；stderr=%r"
                  % (i + 1, rc, err))
            check(out == b"1\n", "第 %d 次请求 stdout 不对：%r" % (i + 1, out))
            check(err == b"", "第 %d 次请求 stderr 应为空：%r" % (i + 1, err))
        elapsed = time.monotonic() - started
        check(elapsed < 5.0,
              "被 SIGKILL 的请求拖慢了 runner：50 次请求耗时 %.3fs（>5s）" % elapsed)
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
        kill_pids(wait_descendants_gone(ctx.runner_pid, 0.5))


@test
def t17_large_stdin_and_stdout(ctx):
    """8MB stdin 与 8MB stdout 同时走 → 客户端完整收发，不死锁、不丢字节。"""
    size = 8 * 1024 * 1024
    payload = bytes(range(256)) * (size // 256)
    script = (
        "import sys\n"
        "while True:\n"
        "    chunk = sys.stdin.buffer.read(65536)\n"
        "    if not chunk:\n"
        "        break\n"
        "    sys.stdout.buffer.write(chunk)\n"
    )
    rc, out, err = run_client(ctx, pycode(script), stdin=payload, timeout=180)
    check(rc == 0, "退出码应为 0，实际 %r；stderr=%r" % (rc, err))
    check(len(out) == size, "stdout 长度应为 %d，实际 %d" % (size, len(out)))
    check(out == payload, "8MB stdin/stdout 往返不一致")
    check(err == b"", "stderr 应为空，实际 %r" % err)


@test
def t18_fd_stable_under_200_requests(ctx):
    """200 次短请求后 harness/runner 的 fd 数不增长（±2），且没有遗留 handler。"""
    def short_request(i):
        rc, out, err = run_client(ctx, pycode("print(1)"), timeout=15)
        check(rc == 0, "第 %d 次请求退出码应为 0，实际 %r；stderr=%r" % (i, rc, err))
        check(out == b"1\n", "第 %d 次请求 stdout 不对：%r" % (i, out))

    # 先跑几次，把 locale/编码等惰性初始化触发的 fd 打开，避免算进增长。
    for i in range(1, 6):
        short_request(i)

    runner_fd0 = idle_fd_count(ctx.runner_pid)
    harness_fd0 = idle_fd_count(ctx.proc.pid)
    check(runner_fd0 is not None and harness_fd0 is not None,
          "读不到 runner/harness 的 fd 目录")

    for i in range(6, 206):
        short_request(i)

    left = wait_descendants_gone(ctx.runner_pid, 5)
    check(not left,
          "200 次请求后仍有 %d 个存活 handler/解释器：%r" % (len(left), left))

    runner_fd1 = idle_fd_count(ctx.runner_pid)
    harness_fd1 = idle_fd_count(ctx.proc.pid)
    check(runner_fd1 is not None and harness_fd1 is not None,
          "读不到 runner/harness 的 fd 目录")
    check(abs(runner_fd1 - runner_fd0) <= 2,
          "runner fd 数从 %d 涨到 %d（>2）" % (runner_fd0, runner_fd1))
    check(abs(harness_fd1 - harness_fd0) <= 2,
          "harness fd 数从 %d 涨到 %d（>2）" % (harness_fd0, harness_fd1))


# ── 入口 ─────────────────────────────────────────────────────────────────────


def cleanup(ctx):
    kill_pids(pids_matching(SLEEP_MARKER))
    if ctx.proc is not None and ctx.proc.poll() is None:
        ctx.proc.terminate()
        try:
            ctx.proc.wait(timeout=7)
        except subprocess.TimeoutExpired:
            ctx.proc.kill()
            ctx.proc.wait(timeout=5)
    # runner 是 harness 的子进程且自己 setsid；正常情况下父进程退出后 5s 内自退。
    # 这里按命令行匹配，把 runner 以及它此刻还挂着的 handler 一起收掉，
    # 避免测试结束后留下常驻进程（容器里父进程不一定被重挂到 PID 1）。
    kill_pids(pids_matching(ctx.runner))
    if ctx._log is not None:
        try:
            ctx._log.close()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description="py_runner 宿主侧协议测试")
    ap.add_argument("--libpython", default=os.environ.get("IEC_PY_LIBPYTHON"),
                    help="宿主 libpython 共享库绝对路径（默认自动探测，优先 3.12）")
    ap.add_argument("--keep", action="store_true", help="失败时也保留临时目录")
    args = ap.parse_args()

    workdir = tempfile.mkdtemp(prefix="py-runner-host-")
    ctx = Context(workdir, None)
    try:
        ctx.libpython = discover_libpython(args.libpython)
        print("py_runner 宿主协议测试")
        print("  libpython : %s" % ctx.libpython)
        print("  工作目录  : %s" % workdir)
        print("  编译 ...")
        build(ctx)
        start_runner(ctx)
        print("  socket    : %s" % ctx.sock)
        print()

        failures = 0
        for fn in TESTS:
            name = "%s %s" % (fn.__name__, (fn.__doc__ or "").strip().splitlines()[0])
            started = time.monotonic()
            try:
                fn(ctx)
            except Failure as e:
                failures += 1
                print("[FAIL] %s\n       %s" % (name, e))
            except Exception as e:  # noqa: BLE001 - 测试脚本要报告而不是崩掉
                failures += 1
                print("[FAIL] %s\n       %s: %s" % (name, type(e).__name__, e))
            else:
                print("[PASS] %s (%.2fs)" % (name, time.monotonic() - started))

        print()
        if failures:
            print("=== %d/%d 项失败 ===" % (failures, len(TESTS)))
            if ctx.proc is not None and ctx.proc.poll() is not None:
                print("runner 日志：\n" + read_log(ctx))
            return 1
        print("=== 全部 %d 项通过 ===" % len(TESTS))
        return 0
    except Failure as e:
        print("[ERROR] %s" % e)
        return 1
    finally:
        if ctx._log is not None or ctx.proc is not None:
            log = read_log(ctx) if ctx._log is not None else ""
            cleanup(ctx)
            if log.strip():
                print("\nrunner/harness 日志：\n" + log)
        if args.keep:
            print("\n临时目录已保留：%s" % workdir)
        else:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
