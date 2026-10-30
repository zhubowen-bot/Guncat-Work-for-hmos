#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nc 属性 / 边界测试。

由 run.sh 编译好宿主版 nc 后调用：python3 run.py <nc 可执行文件>

所有网络都是 127.0.0.1 回环；每个用例都有独立超时（signal.setitimer），
任何断言失败都会让脚本以非零码退出。记录实际行为的地方（并发第二个连接）
只做弱断言，避免依赖内核 backlog 的具体时序。
"""

import os
import queue
import random
import signal
import socket
import subprocess
import sys
import threading
import time

NC = sys.argv[1] if len(sys.argv) > 1 else "nc"
PASS = 0
FAIL = 0
PROCS = set()
SOCKS = []

CHUNK = 65536


class CaseTimeout(Exception):
    pass


def _alarm(_sig, _frame):
    raise CaseTimeout()


signal.signal(signal.SIGALRM, _alarm)


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


def retry_connect(port, timeout=3.0):
    """连到可能还没 bind 好的监听端；成功返回 socket。"""
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        try:
            s.connect(("127.0.0.1", port))
            return s
        except OSError as e:
            last = e
            s.close()
            time.sleep(0.01)
    raise AssertionError("连接 127.0.0.1:%d 失败: %s" % (port, last))


def recv_all(sock, timeout=5.0):
    sock.settimeout(timeout)
    out = bytearray()
    while True:
        b = sock.recv(CHUNK)
        if not b:
            return bytes(out)
        out += b


def run_proc(args, data=None, timeout=10.0):
    """跑一个子进程；data=None 时 stdin 接 /dev/null，否则写入 pipe 并关闭。"""
    p = subprocess.Popen(
        args,
        stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    PROCS.add(p)
    try:
        out, err = p.communicate(data, timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
        raise AssertionError("进程超时 %.1fs: %s (stderr=%r)" % (timeout, args, err[:200]))
    finally:
        PROCS.discard(p)
    return p.returncode, out, err


def wait_proc(p, timeout=10.0):
    """等待自己管理 stdin 的监听端；返回 (rc, stdout, stderr)。"""
    try:
        p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        raise AssertionError("监听端超时 %.1fs 未退出" % timeout)
    out = p.stdout.read() if p.stdout else b""
    err = p.stderr.read() if p.stderr else b""
    return p.returncode, out, err


def client_retry(port, data, timeout=10.0, extra=()):
    """nc 客户端在监听端尚未 bind 好时重试；只对 Connection refused 重试。"""
    last = (None, b"", b"")
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        rc, out, err = run_proc(
            [NC, "-w", "4"] + list(extra) + ["127.0.0.1", str(port)], data, timeout
        )
        last = (rc, out, err)
        if rc == 0 or b"Connection refused" not in err:
            return last
        time.sleep(0.02)
    return last


class EchoServer:
    """流式回显：读线程持续收，主线程原样发回；覆盖双向同时有数据。"""

    def __init__(self):
        self.ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        SOCKS.append(self.ls)
        self.ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.ls.bind(("127.0.0.1", 0))
        self.port = self.ls.getsockname()[1]
        self.ls.listen(1)
        self.ls.settimeout(30)
        self.received = 0
        self.error = None
        self.t = threading.Thread(target=self._run, daemon=True)
        self.t.start()

    def _run(self):
        c = None
        try:
            c, _ = self.ls.accept()
            self.ls.close()
            c.settimeout(30)

            q = queue.Queue()

            def reader():
                try:
                    while True:
                        b = c.recv(CHUNK)
                        if not b:
                            break
                        self.received += len(b)
                        q.put(b)
                except Exception as e:  # noqa: BLE001 - 记录后交给主测试断言
                    if self.error is None:
                        self.error = e
                finally:
                    q.put(None)

            rt = threading.Thread(target=reader, daemon=True)
            rt.start()
            while True:
                b = q.get()
                if b is None:
                    break
                c.sendall(b)
            rt.join(5)
            c.shutdown(socket.SHUT_WR)
        except Exception as e:  # noqa: BLE001
            if self.error is None:
                self.error = e
        finally:
            if c is not None:
                try:
                    c.close()
                except OSError:
                    pass

    def wait(self, timeout=30.0):
        self.t.join(timeout)
        if self.t.is_alive():
            raise AssertionError("回显端 %.1fs 内未结束" % timeout)
        if self.error is not None:
            raise AssertionError("回显端错误: %s" % self.error)


def cleanup_procs():
    for p in list(PROCS):
        try:
            if p.poll() is None:
                p.kill()
        except OSError:
            pass
    PROCS.clear()
    for s in SOCKS:
        try:
            s.close()
        except OSError:
            pass
    SOCKS.clear()


def run_case(name, fn, timeout):
    global PASS, FAIL
    start = time.monotonic()
    signal.setitimer(signal.ITIMER_REAL, timeout)
    try:
        fn()
        PASS += 1
        print("ok    %s (%.2fs)" % (name, time.monotonic() - start))
    except CaseTimeout:
        FAIL += 1
        print("FAIL  %s：超时 >%.1fs" % (name, timeout), file=sys.stderr)
    except AssertionError as e:
        FAIL += 1
        print("FAIL  %s：%s" % (name, e), file=sys.stderr)
    except Exception as e:  # noqa: BLE001
        FAIL += 1
        print("FAIL  %s：%s: %s" % (name, type(e).__name__, e), file=sys.stderr)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        cleanup_procs()


# ------------------------------------------------------------------ 用例


def case_10mb():
    data = bytes(range(256)) * (10 * 1024 * 1024 // 256)
    assert len(data) == 10 * 1024 * 1024
    srv = EchoServer()
    rc, out, err = run_proc(
        [NC, "-w", "30", "127.0.0.1", str(srv.port)], data, timeout=60
    )
    srv.wait(30)
    assert rc == 0, "nc 退出码 %d，stderr=%r" % (rc, err[:300])
    assert len(out) == len(data), "回显长度 %d != %d（截断）" % (len(out), len(data))
    assert out == data, "回显内容与发送的 10MB 不一致"
    assert srv.received == len(data), "监听端收到 %d != %d" % (srv.received, len(data))


def case_concurrency():
    port = free_port()
    accepted = []
    srv_err = []

    def serve():
        ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        SOCKS.append(ls)
        ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        ls.bind(("127.0.0.1", port))
        ls.listen(1)
        ls.settimeout(10)
        try:
            c, _ = ls.accept()
            accepted.append(True)
            ls.close()  # 只服务第一个；第二个留在 backlog 里由内核处理
            # 读干净第一个连接（客户端会先发一行再 FIN），否则 close 时
            # 内核会因未读数据回 RST，第一个客户端也会失败，测不出并发语义。
            c.settimeout(5)
            while c.recv(CHUNK):
                pass
            time.sleep(0.5)
            c.close()
        except Exception as e:  # noqa: BLE001
            srv_err.append(e)
        finally:
            try:
                ls.close()
            except OSError:
                pass

    t = threading.Thread(target=serve, daemon=True)
    t.start()
    time.sleep(0.1)

    def start_one():
        return subprocess.Popen(
            [NC, "-w", "2", "127.0.0.1", str(port)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    procs = [start_one(), start_one()]
    for p in procs:
        PROCS.add(p)
    results = []
    for p in procs:
        try:
            out, err = p.communicate(b"x\n", timeout=5)
            results.append((p.returncode, out, err))
        except subprocess.TimeoutExpired:
            p.kill()
            out, err = p.communicate()
            results.append(("timeout", out, err))
        finally:
            PROCS.discard(p)

    t.join(5)
    assert not t.is_alive(), "监听端线程未结束"
    assert accepted, "监听端一个连接都没接住"
    assert not srv_err, "监听端异常: %s" % srv_err[0]

    successes = sum(1 for rc, _, _ in results if rc == 0)
    detail = ", ".join(
        "client%d rc=%s stderr=%r" % (i + 1, rc, err[:80])
        for i, (rc, _, err) in enumerate(results)
    )
    # 内核 backlog 的时序不属于本命令的契约：只要求至少一个成功、没有卡死
    # （-w 2 + 5s 上限），并记录第二个连接实际是被拒还是排队。
    assert successes >= 1, "两个客户端都没有成功: %s" % detail
    assert "timeout" not in [rc for rc, _, _ in results], "客户端挂死: %s" % detail
    print("    并发实际行为: %s（%d/2 成功）" % (detail, successes))


def case_half_close_listen():
    """裸 socket 客户端 shutdown(SHUT_WR)，nc 监听端稍后仍把 stdin 数据发过来。"""
    port = free_port()
    payload = b"LATE-FROM-LISTENER\n"
    # 需要延迟写 stdin，不能用 start_listen 的 /dev/null。
    p = subprocess.Popen(
        [NC, "-l", "-p", str(port)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    PROCS.add(p)
    c = retry_connect(port)
    write_err = None
    try:
        c.shutdown(socket.SHUT_WR)
        time.sleep(0.5)
        try:
            p.stdin.write(payload)
            p.stdin.close()
        except OSError as e:
            write_err = e
        got = recv_all(c, 5)
    finally:
        c.close()
    rc, _, err = wait_proc(p, 5)
    PROCS.discard(p)
    assert got == payload, (
        "半关闭后收到 %r（期望 %r，迟到数据被丢弃；写 stdin 错误=%r）"
        % (got, payload, write_err)
    )
    assert rc == 0, "nc 监听端退出码 %d，stderr=%r" % (rc, err[:300])


def case_half_close_client():
    """nc 客户端 stdin 先 EOF，裸 socket 对端随后发数据，客户端仍要收到。"""
    port = free_port()
    payload = b"LATE-FROM-PEER\n"
    ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    SOCKS.append(ls)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", port))
    ls.listen(1)
    ls.settimeout(10)
    peer_err = []

    def peer():
        try:
            c, _ = ls.accept()
            ls.close()
            recv_all(c, 5)  # 读到 nc 的 EOF（客户端 stdin 已关）
            time.sleep(0.5)
            c.sendall(payload)
            c.close()
        except Exception as e:  # noqa: BLE001
            peer_err.append(e)
        finally:
            try:
                ls.close()
            except OSError:
                pass

    t = threading.Thread(target=peer, daemon=True)
    t.start()
    time.sleep(0.05)
    rc, out, err = run_proc(
        [NC, "-w", "4", "127.0.0.1", str(port)], None, timeout=10
    )
    t.join(5)
    assert not peer_err, "对端异常: %s" % peer_err[0]
    assert rc == 0, "nc 退出码 %d，stderr=%r" % (rc, err[:300])
    assert out == payload, "收到 %r（期望 %r）" % (out, payload)


def case_timeout():
    # a) 只 accept 不回数据：-w 1 应约 1s 返回，不挂死
    port = free_port()
    ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    SOCKS.append(ls)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", port))
    ls.listen(1)
    ls.settimeout(10)
    held = []

    def accept_silent():
        try:
            c, _ = ls.accept()
            held.append(c)
            time.sleep(3)
            c.close()
        except Exception:  # noqa: BLE001
            pass
        finally:
            try:
                ls.close()
            except OSError:
                pass

    t = threading.Thread(target=accept_silent, daemon=True)
    t.start()
    time.sleep(0.05)
    start = time.monotonic()
    rc, _, err = run_proc(
        [NC, "-w", "1", "127.0.0.1", str(port)], None, timeout=5
    )
    elapsed = time.monotonic() - start
    t.join(5)
    assert rc == 0, "静默监听端下 nc 退出码 %d，stderr=%r" % (rc, err[:200])
    assert 0.5 <= elapsed <= 1.5, "-w 1 实际 %.2fs（期望 1s±0.5s）" % elapsed

    # b) 连接被拒：<0.5s 失败、非零退出、stderr 有信息
    dead = free_port()
    start = time.monotonic()
    rc, out, err = run_proc([NC, "-w", "1", "127.0.0.1", str(dead)], None, timeout=5)
    elapsed = time.monotonic() - start
    assert rc != 0, "连接被拒却退出 0"
    assert err, "连接被拒但 stderr 为空"
    assert elapsed < 0.5, "连接被拒耗时 %.2fs（期望 <0.5s）" % elapsed
    assert not out, "连接被拒却往 stdout 写了数据"


def case_port_reuse():
    port = free_port()
    for i in range(20):
        p = subprocess.Popen(
            [NC, "-l", "-p", str(port)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        PROCS.add(p)
        try:
            c = retry_connect(port, 3)
            c.close()
            rc, _, err = wait_proc(p, 5)
        finally:
            PROCS.discard(p)
        assert rc == 0, "第 %d 次监听退出码 %d，stderr=%r" % (i + 1, rc, err[:200])
        assert b"Address already in use" not in err, (
            "第 %d 次监听出现端口占用: %r" % (i + 1, err)
        )


def case_positional_and_usage():
    # a) -l PORT 与 -l -p PORT 等价
    for form in (["-l"], ["-l", "-p"]):
        port = free_port()
        p = subprocess.Popen(
            [NC] + form + [str(port)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        PROCS.add(p)
        try:
            p.stdin.write(b"from-server\n")
            p.stdin.close()
            rc_c, out_c, err_c = client_retry(port, b"from-client\n")
            rc_s, out_s, err_s = wait_proc(p, 10)
        finally:
            PROCS.discard(p)
        label = " ".join(form)
        assert rc_s == 0, "%s：监听端退出码 %d，stderr=%r" % (label, rc_s, err_s[:200])
        assert rc_c == 0, "%s：客户端退出码 %d，stderr=%r" % (label, rc_c, err_c[:200])
        assert out_c == b"from-server\n", "%s：客户端收到 %r" % (label, out_c)
        assert out_s == b"from-client\n", "%s：监听端收到 %r" % (label, out_s)

    # b) usage 错误路径：非零退出 + stderr 有 usage
    for args in (
        [],
        ["-l"],
        ["127.0.0.1"],
        ["-x"],
        ["--bogus"],
        ["127.0.0.1", "1", "2"],
        ["-p"],
        ["-w"],
    ):
        rc, out, err = run_proc([NC] + args, None, timeout=5)
        assert rc != 0, "参数 %r 退出码为 0" % (args,)
        assert b"usage" in err.lower(), "参数 %r 的 stderr 没有 usage: %r" % (args, err[:200])
        assert not out, "参数 %r 的 stdout 非空: %r" % (args, out[:100])


def case_binary():
    rng = random.Random(0x4E43)  # "NC"
    size = 1024 * 1024
    # getrandbits 在 Python 3.8 也有；randbytes 要 3.9+。
    data = bytearray(rng.getrandbits(8 * size).to_bytes(size, "little"))
    # 明确塞进 0x00 / 0xFF 与全部 256 种字节，避免“随机但恰好没有”
    data[0:2] = b"\x00\xff"
    data[1024:1280] = bytes(range(256))
    data = bytes(data)
    srv = EchoServer()
    rc, out, err = run_proc(
        [NC, "-w", "20", "127.0.0.1", str(srv.port)], data, timeout=40
    )
    srv.wait(20)
    assert rc == 0, "nc 退出码 %d，stderr=%r" % (rc, err[:300])
    assert out == data, "1MB 二进制往返不一致（收到 %d 字节）" % len(out)
    assert srv.received == len(data), "监听端收到 %d != %d" % (srv.received, len(data))


def case_sigterm():
    port = free_port()
    p = subprocess.Popen(
        [NC, "-l", "-p", str(port)],
        stdin=subprocess.PIPE,  # 保持打开，避免 stdin EOF 让 relay 提前结束
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    PROCS.add(p)
    c = retry_connect(port)
    try:
        c.sendall(b"A" * (256 * 1024))
        time.sleep(0.1)
        p.send_signal(signal.SIGTERM)
        rc, _, err = wait_proc(p, 5)
    finally:
        PROCS.discard(p)
        c.close()
    assert rc != 0, "SIGTERM 后 nc 退出码为 0"
    assert b"Address already in use" not in err, "退出时 stderr 报端口占用: %r" % err

    # 端口必须能立刻重新 bind（SO_REUSEADDR）
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", port))
    finally:
        s.close()


CASES = [
    ("10MB 双向传输逐字节一致", case_10mb, 90),
    ("并发两个客户端（弱断言 + 记录实际行为）", case_concurrency, 20),
    ("半关闭：监听端在客户端 SHUT_WR 后仍投递 stdin", case_half_close_listen, 20),
    ("半关闭：客户端 stdin EOF 后仍收到对端迟到数据", case_half_close_client, 20),
    ("-w 1 空闲超时与连接被拒", case_timeout, 20),
    ("端口复用：同一端口连续监听 20 次", case_port_reuse, 60),
    ("-l 位置端口 / -p 等价与 usage 错误路径", case_positional_and_usage, 40),
    ("二进制安全：1MB 随机数据（含 0x00/0xFF）", case_binary, 60),
    ("SIGTERM 中断传输且不占端口", case_sigterm, 20),
]


def main():
    print("== nc_fuzz 属性 / 边界测试 ==")
    print("nc: %s" % NC)
    for name, fn, timeout in CASES:
        run_case(name, fn, timeout)
    print()
    print("== 结果: PASS=%d FAIL=%d ==" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
