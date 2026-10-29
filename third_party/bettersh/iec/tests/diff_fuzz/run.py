#!/usr/bin/env python3
# run.py — diff 属性/边界对拍：自写 cmd_diff.c（后端 git diff --no-index）与直接运行
# `git diff --no-index` 逐字节比较。
#
# 纯 Python 标准库；在 x86_64 Linux（含 WSL）上把 cmd_diff.c 编成普通可执行文件直接
# 跑，不连设备、不需要 HarmonyOS SDK、不访问网络。
#
#   python3 run.py                 # 100 对随机文件 + 选项/路径/边界/大文件
#   python3 run.py --pairs 20      # 少跑几对（排查用）
#   python3 run.py --keep          # 保留临时目录
#
# 环境变量：
#   DIFF_FUZZ_SRC   待测源码（默认 ../../scripts/optional/cmd_diff.c）
#   CC              宿主 C 编译器（默认 cc）
#
# 退出码：0 = 全部 PASS；1 = 存在差异/失败；2 = 编译/环境错误；3 = 找不到 git（SKIP）。
import argparse
import hashlib
import os
import random
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
IEC_ROOT = HERE.parents[1]
DEFAULT_SRC = IEC_ROOT / "scripts" / "optional" / "cmd_diff.c"

# 单条命令的超时（秒）。8MB 那一组给得宽一些。
TIMEOUT = 60
BIG_TIMEOUT = 180

ENV = dict(
    os.environ,
    LC_ALL="C",
    LANG="C",
    TZ="UTC",
    GIT_PAGER="cat",
    GIT_TERMINAL_PROMPT="0",
    GIT_CONFIG_NOSYSTEM="1",
    GIT_ATTR_NOSYSTEM="1",
)


def die(msg, code=2):
    print("diff_fuzz: " + msg, file=sys.stderr)
    return code


# ------------------------------------------------------------------ 编译


def build(src, workdir):
    """把 cmd_diff.c 编成宿主可执行文件（入口 iec_diff_main）。"""
    cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc")
    if not cc:
        return None, "找不到 C 编译器（cc/gcc）"
    if not src.is_file():
        return None, "源码不存在: %s" % src
    wrap = workdir / "wrap.c"
    wrap.write_text(
        "#include <stdio.h>\n"
        "extern int iec_diff_main(int, char**);\n"
        "int main(int argc, char** argv) { return iec_diff_main(argc, argv); }\n",
        encoding="ascii",
    )
    binary = workdir / "diff_ours"
    cmd = [
        cc, "-std=gnu11", "-O1", "-g", "-Wall", "-Wextra",
        "-D_GNU_SOURCE", str(src), str(wrap), "-o", str(binary),
    ]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        return None, "编译失败:\n%s" % proc.stderr.decode("utf-8", "replace")
    return str(binary), None


# ------------------------------------------------------------------ 运行


class Run:
    __slots__ = ("rc", "out", "err", "timed_out")

    def __init__(self, rc, out, err, timed_out=False):
        self.rc = rc
        self.out = out
        self.err = err
        self.timed_out = timed_out

    def key(self):
        return (self.rc, self.out, self.err)


def run(exe, args, cwd, timeout=TIMEOUT, env=None):
    try:
        p = subprocess.run(
            [exe] + list(args), stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=str(cwd), env=env or ENV, timeout=timeout,
        )
        return Run(p.returncode, p.stdout, p.stderr)
    except subprocess.TimeoutExpired:
        return Run(124, b"", b"<timeout>", True)


# ------------------------------------------------------------------ 报告


def preview(data, limit=600):
    if isinstance(data, str):
        data = data.encode("utf-8", "replace")
    if len(data) > limit:
        return repr(data[:limit]) + " …（共 %d 字节）" % len(data)
    return repr(data)


def first_line_diff(ref_out, our_out):
    ref_lines = ref_out.splitlines(keepends=True)
    our_lines = our_out.splitlines(keepends=True)
    for idx in range(max(len(ref_lines), len(our_lines))):
        a = ref_lines[idx] if idx < len(ref_lines) else "<缺行>".encode()
        b = our_lines[idx] if idx < len(our_lines) else "<缺行>".encode()
        if a != b:
            return "首个差异行: %d\n  ref : %r\n  ours: %r" % (idx + 1, a[:300], b[:300])
    return "输出相同但退出码/状态不同"


class Report:
    def __init__(self):
        self.pass_ = 0
        self.fail = 0
        self.cases = 0
        self.failures = []

    def ok(self, label, n=1):
        self.pass_ += 1
        self.cases += n

    def bad(self, label, detail):
        self.fail += 1
        self.cases += 1
        self.failures.append((label, detail))


def expect_equal(rep, label, ours, ref, show_stderr=True):
    """逐字节比较一次运行结果。"""
    if ours.timed_out:
        rep.bad(label, "本实现超时（%ds）" % TIMEOUT)
        return
    if ours.key() == ref.key():
        rep.ok(label)
        return
    parts = ["退出码: ref=%d ours=%d" % (ref.rc, ours.rc)]
    if ours.out != ref.out:
        parts.append("stdout 不同\n" + first_line_diff(ref.out, ours.out))
        parts.append("  ref stdout : " + preview(ref.out))
        parts.append("  ours stdout: " + preview(ours.out))
    if show_stderr and ours.err != ref.err:
        parts.append("stderr 不同\n  ref : %r\n  ours: %r" % (ref.err[:400], ours.err[:400]))
    rep.bad(label, "\n".join(parts))


def expect_state(rep, label, ours, rc=None, empty_out=None, has_err=None,
                 out_equals=None, err_contains=None):
    """断言一次运行的退出码/输出形态（用于本实现与 git 语义不同的地方）。"""
    problems = []
    if ours.timed_out:
        rep.bad(label, "本实现超时（%ds）" % TIMEOUT)
        return
    if rc is not None and ours.rc != rc:
        problems.append("退出码 %d（应为 %d）" % (ours.rc, rc))
    if empty_out is True and ours.out:
        problems.append("stdout 应为空，实际 %s" % preview(ours.out))
    if empty_out is False and not ours.out:
        problems.append("stdout 不应为空")
    if has_err is True and not ours.err:
        problems.append("stderr 不应为空")
    if has_err is False and ours.err:
        problems.append("stderr 应为空，实际 %r" % ours.err[:300])
    if out_equals is not None and ours.out != out_equals:
        problems.append("stdout 为 %r（应为 %r）" % (ours.out[:300], out_equals))
    if err_contains is not None and err_contains.encode() not in ours.err:
        problems.append("stderr 未包含 %r（实际 %r）" % (err_contains, ours.err[:300]))
    if problems:
        rep.bad(label, "；".join(problems))
    else:
        rep.ok(label)


# ------------------------------------------------------------------ 数据生成

TEXT_CHARS = "abcdefghij klmnopqrstuvwxyz0123456789\t_-./"


def rand_line(rng, n=None):
    n = rng.randint(0, 60) if n is None else n
    return "".join(rng.choice(TEXT_CHARS) for _ in range(n))


def make_text(rng, lines):
    return "".join(rand_line(rng) + "\n" for _ in range(lines)).encode()


def make_pair(kind, rng):
    """按类别生成确定性的一对 (a, b)。"""
    if kind == "identical":
        data = make_text(rng, rng.randint(1, 40))
        return data, data
    if kind == "whitespace":
        lines = [rand_line(rng, rng.randint(3, 30)).replace(" ", "") for _ in range(8)]
        a = "".join(x + "\n" for x in lines).encode()
        b = "".join("\t " + x.replace(" ", "  ") + " \n" for x in lines).encode()
        return a, b
    if kind == "length":
        return make_text(rng, rng.randint(1, 5)), make_text(rng, rng.randint(30, 90))
    if kind == "binary":
        n = rng.randint(1, 512)
        a = bytes(rng.getrandbits(8) for _ in range(n))
        b = bytearray(a)
        if b:
            b[rng.randrange(len(b))] ^= 0xFF
        else:
            b = bytearray(b"\x00")
        return a, bytes(b)
    if kind == "crlf":
        lines = [rand_line(rng, rng.randint(0, 20)) for _ in range(rng.randint(1, 6))]
        a = "".join(x + "\n" for x in lines).encode()
        b = "".join(x + "\r\n" for x in lines).encode()
        return a, b
    if kind == "no_trailing_nl":
        lines = [rand_line(rng, rng.randint(0, 20)) for _ in range(rng.randint(1, 6))]
        a = ("\n".join(lines)).encode()
        b = ("\n".join(lines) + "\n").encode()
        return a, b
    if kind == "long_line":
        base = "".join(rng.choice(TEXT_CHARS) for _ in range(10 * 1024))
        mid = len(base) // 2
        return base.encode(), (base[:mid] + "X" + base[mid + 1:]).encode()
    if kind == "empty":
        which = rng.randrange(3)
        if which == 0:
            return b"", b""
        if which == 1:
            return b"", make_text(rng, 3)
        return make_text(rng, 3), b""
    if kind == "mixed":
        # 一半相同行、一半改动行，制造多处 hunk
        n = rng.randint(10, 60)
        a_lines = [rand_line(rng) for _ in range(n)]
        b_lines = list(a_lines)
        for _ in range(rng.randint(1, 5)):
            idx = rng.randrange(n)
            b_lines[idx] = rand_line(rng)
        return ("\n".join(a_lines) + "\n").encode(), ("\n".join(b_lines) + "\n").encode()
    raise AssertionError("未知类别 " + kind)


PAIR_KINDS = (
    "identical", "whitespace", "length", "binary", "crlf",
    "no_trailing_nl", "long_line", "empty", "mixed",
)


def make_pairs(count, rng):
    """前 9 对固定覆盖全部类别，其余随机；整体由种子保证可复现。"""
    kinds = list(PAIR_KINDS[:min(count, len(PAIR_KINDS))])
    while len(kinds) < count:
        kinds.append(PAIR_KINDS[len(kinds) % len(PAIR_KINDS)])
    return [(k, make_pair(k, rng)) for k in kinds[:count]]


# ------------------------------------------------------------------ 用例组


def test_pairs(rep, ours, workdir, pairs):
    """1) 100 对文件：与 `git diff --no-index -- a b` 逐字节一致，退出码一致。"""
    print("-- 1) 随机文件对：%d 对，与 git 逐字节对拍" % len(pairs))
    d = workdir / "pairs"
    d.mkdir()
    # git 的退出码只允许 0/1/2（0 相同、1 有差异、2 出错）
    for idx, (kind, (a, b)) in enumerate(pairs):
        pa = d / ("a_%03d" % idx)
        pb = d / ("b_%03d" % idx)
        pa.write_bytes(a)
        pb.write_bytes(b)
        o = run(ours, ["a_%03d" % idx, "b_%03d" % idx], d)
        r = run("git", ["diff", "--no-index", "--",
                        "a_%03d" % idx, "b_%03d" % idx], d)
        label = "pair#%03d[%s]" % (idx, kind)
        expect_equal(rep, label, o, r)
        if r.rc not in (0, 1, 2):
            rep.bad(label + "/退出码-约定", "git 退出码 %d 不在 0/1/2 内" % r.rc)


def test_options(rep, ours, workdir, w, run_ours, run_git):
    """2) 选项翻译：与翻译后的 git 调用逐字节一致，并抽查语义。"""
    print("-- 2) 选项翻译：-u / -U 1 / -U1 / -q / -s / -w / -b / --stat / --color=never / --no-color")
    a, b, same = "a", "b", "same"
    (w / a).write_text("1\n2\n3\n4\n5\n6\n7\n")
    (w / b).write_text("1\n2\nX\n4\n5\n6\n7\n")
    (w / same).write_text("1\n2\n3\n4\n5\n6\n7\n")
    (w / "ws1").write_text("alpha beta\n")
    (w / "ws2").write_text("alpha    beta\n")

    # (标签, 我们的参数, 翻译后应等价的 git 参数)
    # 参照里选项必须写在 `--` 之前——这正是本实现最容易搞错的地方
    # （写成 `git diff --no-index -- -u a b` 会把 -u 当路径，退出码 129）。
    cases = [
        ("-u", ["-u", a, b], ["-u", "--", a, b]),
        ("-U 1 分开写", ["-U", "1", a, b], ["-U1", "--", a, b]),
        ("-U1 紧贴写", ["-U1", a, b], ["-U1", "--", a, b]),
        ("-U 7", ["-U", "7", a, b], ["-U7", "--", a, b]),
        ("-q", ["-q", a, b], ["--quiet", "--", a, b]),
        ("-q 相同", ["-q", a, same], ["--quiet", "--", a, same]),
        ("-w", ["-w", "ws1", "ws2"], ["-w", "--", "ws1", "ws2"]),
        ("-b", ["-b", "ws1", "ws2"], ["-b", "--", "ws1", "ws2"]),
        ("--stat", ["--stat", a, b], ["--stat", "--", a, b]),
        ("--color=never", ["--color=never", a, b], ["--color=never", "--", a, b]),
        ("--no-color", ["--no-color", a, b], ["--no-color", "--", a, b]),
        ("默认无选项", [a, b], ["--", a, b]),
    ]
    for label, our_args, git_args in cases:
        o = run_ours(our_args)
        r = run_git(git_args)
        expect_equal(rep, "选项 " + label, o, r, show_stderr=False)

    # 语义抽查：确认选项真的生效，而不是被当成路径（老 bug 的形态是退出码 129）
    o = run_ours(["-U", "1", a, b])
    if o.rc == 1 and b"@@ -2,3 +2,3 @@" in o.out:
        rep.ok("-U 1 上下文行数真的生效（@@ -2,3 +2,3 @@）")
    else:
        rep.bad("-U 1 语义", "rc=%d out=%s" % (o.rc, preview(o.out)))
    o = run_ours(["-U1", a, b])
    if o.rc == 1 and b"@@ -2,3 +2,3 @@" in o.out:
        rep.ok("-U1 上下文行数真的生效")
    else:
        rep.bad("-U1 语义", "rc=%d out=%s" % (o.rc, preview(o.out)))
    o = run_ours(["--stat", a, b])
    if o.rc == 1 and b"1 file changed" in o.out:
        rep.ok("--stat 真的输出统计格式")
    else:
        rep.bad("--stat 语义", "rc=%d out=%s" % (o.rc, preview(o.out)))
    o = run_ours(["--color=never", a, b])
    if b"\x1b[" not in o.out:
        rep.ok("--color=never 输出无 ANSI 转义")
    else:
        rep.bad("--color=never 语义", "输出含 ANSI 转义")

    # -s 是唯一由本进程处理的选项：相同文件打印 identical（GNU diff 语义），
    # 有差异时不打印、仍走 git 输出 diff。
    o = run_ours(["-s", a, same])
    expect_state(rep, "选项 -s 相同文件", o, rc=0,
                 out_equals=b"Files a and same are identical\n", has_err=False)
    o = run_ours(["-s", a, b])
    r = run_git(["--", a, b])
    expect_equal(rep, "选项 -s 有差异（仍输出 diff）", o, r)

    # -s 与 -w/-b 互动：字节不同但忽略空白后相同。git 后端下拿不到“相同”的判定，
    # 因此只要求不崩、退出码 0、无输出（与 git -w 一致），见 README 已知差异。
    o = run_ours(["-s", "-w", "ws1", "ws2"])
    expect_state(rep, "选项 -s -w 忽略空白后相同（已知差异）", o, rc=0, empty_out=True)


def test_paths(rep, ours, workdir, w, run_ours, run_git):
    """3) 路径：不存在、目录对目录、`-` 开头、空格/中文、绝对路径。"""
    print("-- 3) 路径边界")
    (w / "d1").mkdir(exist_ok=True)
    (w / "d2").mkdir(exist_ok=True)
    (w / "d1" / "f").write_text("one\n")
    (w / "d2" / "f").write_text("two\n")
    (w / "d3").mkdir(exist_ok=True)          # 内容相同
    (w / "d3" / "f").write_text("one\n")

    # 不存在的文件：退出码 2 + stderr（git 只给 1）
    o = run_ours(["-u", "a", "nope"])
    expect_state(rep, "路径 不存在的文件", o, rc=2, empty_out=True,
                 has_err=True, err_contains="No such file")

    # 目录对目录：git 支持，与 git 逐字节一致（有差异 / 相同各一）
    o = run_ours(["d1", "d2"])
    r = run_git(["--", "d1", "d2"])
    expect_equal(rep, "路径 目录对目录（有差异）", o, r)
    o = run_ours(["d1", "d3"])
    r = run_git(["--", "d1", "d3"])
    expect_equal(rep, "路径 目录对目录（相同）", o, r)

    # 文件名以 - 开头，用 -- 保护
    (w / "-dash.txt").write_text("dash\n")
    o = run_ours(["--", "-dash.txt", "a"])
    r = run_git(["--", "-dash.txt", "a"])
    expect_equal(rep, "路径 - 开头的文件名（-- 保护）", o, r)

    # 含空格 / 中文的路径
    name_cn = "含 空格 与中文.txt"
    (w / name_cn).write_text("1\n2\n3\n")
    o = run_ours([name_cn, "a"])
    r = run_git(["--", name_cn, "a"])
    expect_equal(rep, "路径 含空格/中文", o, r)

    # 绝对路径（cwd 在别处）
    absp = str((w / "a").resolve())
    absb = str((w / "b").resolve())
    o = run(ours, [absp, absb], workdir)
    r = run("git", ["diff", "--no-index", "--", absp, absb], workdir)
    expect_equal(rep, "路径 绝对路径", o, r)

    # 文件 vs 目录：目录里没有同名文件 -> 2（git 只给 1）
    o = run_ours(["a", "d2"])
    expect_state(rep, "路径 文件 vs 目录（无同名文件）", o, rc=2,
                 empty_out=True, has_err=True, err_contains="No such file")

    # 目录里恰有同名文件：git 能正常比较，不能被上面的检查拦掉
    (w / "d4").mkdir(exist_ok=True)
    (w / "d4" / "a").write_text("1\n2\n3\n4\n5\n6\n7\n")
    o = run_ours(["a", "d4"])
    r = run_git(["--", "a", "d4"])
    expect_equal(rep, "路径 文件 vs 目录（有同名文件，照常比较）", o, r)


def test_boundary(rep, ours, workdir, w, run_ours, run_git):
    """4) 边界：同一文件、文件 vs 目录、权限不可读。"""
    print("-- 4) 边界与权限")
    # 同一个文件 -> 0，无输出
    o = run_ours(["a", "a"])
    expect_state(rep, "边界 同一个文件", o, rc=0, empty_out=True, has_err=False)

    # 文件 vs 目录（同上，单独的边界断言）
    o = run_ours(["a", "/usr"])
    expect_state(rep, "边界 文件 vs 系统目录", o, rc=2, empty_out=True, has_err=True)

    # 权限不可读：只对非 root 有意义（root 无视权限位）
    if os.geteuid() == 0:
        print("   skip 权限不可读（当前 uid=0，root 无视权限位）")
    else:
        secret = w / "secret.txt"
        secret.write_text("top secret\n")
        secret.chmod(0o000)
        try:
            o = run_ours(["a", "secret.txt"])
            expect_state(rep, "边界 不可读文件", o, rc=2, empty_out=True,
                         has_err=True, err_contains="Permission denied")
            # 不可读目录
            nd = w / "nodir"
            nd.mkdir(exist_ok=True)
            (nd / "f").write_text("x\n")
            nd.chmod(0o000)
            try:
                o = run_ours(["d1", "nodir"])
                expect_state(rep, "边界 不可读目录", o, rc=2, empty_out=True,
                             has_err=True, err_contains="Permission denied")
            finally:
                nd.chmod(0o755)
        finally:
            secret.chmod(0o644)

    # 操作数不足：diff 约定 2（git 是 129）
    o = run_ours(["a"])
    expect_state(rep, "边界 只有 1 个操作数", o, rc=2, has_err=True)
    o = run_ours([])
    expect_state(rep, "边界 没有操作数", o, rc=2, has_err=True)

    # -U 的非法长度：diff 约定 2（git 是 129）
    o = run_ours(["-U", "x", "a", "b"])
    expect_state(rep, "边界 -U 非数字（分开写）", o, rc=2, has_err=True)
    o = run_ours(["-Ux", "a", "b"])
    expect_state(rep, "边界 -U 非数字（紧贴写）", o, rc=2, has_err=True)
    o = run_ours(["-U", "a", "b"])
    expect_state(rep, "边界 -U 缺参数", o, rc=2, has_err=True)


def test_big(rep, ours, workdir, w, run_ours, run_git):
    """5) 大文件：8MB 差异，输出完整、退出码一致。"""
    print("-- 5) 大文件（8MB）")
    big_a = w / "big_a.txt"
    big_b = w / "big_b.txt"
    # 8MB 左右：每行 64 字节 × 130000 行 ≈ 8.1 MiB
    nlines = 130000
    a_blocks = [b"line-%06d-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ\n" % i
                for i in range(nlines)]
    # b 每隔一行改一次：制造大量 hunk，逼出 MB 级输出（否则“完整输出”测不出来）
    b_blocks = []
    for i, blk in enumerate(a_blocks):
        if i % 2 == 0:
            b_blocks.append(b"CHANGED-%06d-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ\n" % i)
        else:
            b_blocks.append(blk)
    a_data = b"".join(a_blocks)
    b_data = b"".join(b_blocks)
    big_a.write_bytes(a_data)
    big_b.write_bytes(b_data)
    size = len(a_data) + len(b_data)
    print("   输入 %.1f MiB（a=%.1f MiB, b=%.1f MiB）"
          % (size / 1048576.0, len(a_data) / 1048576.0, len(b_data) / 1048576.0))

    o = run(ours, ["big_a.txt", "big_b.txt"], w, timeout=BIG_TIMEOUT)
    r = run("git", ["diff", "--no-index", "--", "big_a.txt", "big_b.txt"],
            w, timeout=BIG_TIMEOUT)
    if o.rc != 1 or r.rc != 1:
        rep.bad("大文件 8MB", "退出码 ref=%d ours=%d（都应为 1）" % (r.rc, o.rc))
        return
    if o.timed_out or r.timed_out:
        rep.bad("大文件 8MB", "超时")
        return
    # 完整比较（哈希），再单独核对前 1MB——两者都过才算过
    h_ours = hashlib.sha256(o.out).hexdigest()
    h_ref = hashlib.sha256(r.out).hexdigest()
    first_ours = o.out[: 1 << 20]
    first_ref = r.out[: 1 << 20]
    detail = []
    if h_ours != h_ref:
        detail.append("完整输出哈希不同：ref=%s ours=%s（长度 %d / %d）"
                      % (h_ref[:16], h_ours[:16], len(r.out), len(o.out)))
        detail.append(first_line_diff(r.out, o.out))
    if first_ours != first_ref:
        detail.append("前 1MiB 不同")
    # 大文件输出必须“完整”：长度要明显超过 1MiB，不能被截断
    if len(o.out) < (1 << 20):
        detail.append("输出只有 %d 字节，疑似被截断" % len(o.out))
    if detail:
        rep.bad("大文件 8MB", "；".join(detail))
    else:
        rep.ok("大文件 8MB（完整输出 %d 字节，前 1MiB 逐字节一致）" % len(o.out))

    # 顺带确认大文件仅空白差异时 -w 也一致（走同一条转发路径）
    o2 = run(ours, ["-w", "big_a.txt", "big_b.txt"], w, timeout=BIG_TIMEOUT)
    r2 = run("git", ["diff", "--no-index", "-w", "--", "big_a.txt", "big_b.txt"],
             w, timeout=BIG_TIMEOUT)
    expect_equal(rep, "大文件 -w", o2, r2)


# ------------------------------------------------------------------ 入口


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="自写 diff 与 git diff --no-index 的属性/边界对拍",
    )
    parser.add_argument("--pairs", type=int, default=100,
                        help="随机文件对数量（默认 100）")
    parser.add_argument("--seed", type=int, default=20261030,
                        help="随机种子（默认 20261030）")
    parser.add_argument("--keep", action="store_true",
                        help="保留临时编译/输入目录")
    parser.add_argument("--max-failures", type=int, default=10,
                        help="最多打印多少条失败（默认 10）")
    args = parser.parse_args(argv)

    if not shutil.which("git"):
        print("diff_fuzz: SKIP —— 宿主没有 git")
        return 3
    src = Path(os.environ.get("DIFF_FUZZ_SRC") or DEFAULT_SRC)

    print("== diff_fuzz: 自写 diff 与 git diff --no-index 逐字节对拍 ==")
    print("源码: %s" % src)
    ver = subprocess.run(["git", "--version"], stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE).stdout.decode().strip()
    print("参照: %s" % ver)

    workdir = Path(tempfile.mkdtemp(prefix="diff_fuzz."))
    # 独立的 HOME / git 配置，避免宿主的 diff.algorithm、color.ui、autocrlf 等
    # 影响参照输出，让对拍可复现。
    home = workdir / "home"
    home.mkdir()
    (home / ".gitconfig").write_text("")
    ENV["HOME"] = str(home)
    ENV["GIT_CONFIG_GLOBAL"] = str(home / ".gitconfig")

    try:
        binary, err = build(src, workdir)
        if err:
            return die(err)
        w = workdir / "work"
        w.mkdir()

        rep = Report()
        started = time.time()

        def run_ours(a, cwd=w):
            return run(binary, a, cwd)

        def run_git(git_opts, cwd=w):
            return run("git", ["diff", "--no-index"] + git_opts, cwd)

        rng = random.Random(args.seed)
        pairs = make_pairs(max(1, args.pairs), rng)

        test_pairs(rep, binary, workdir, pairs)
        test_options(rep, binary, workdir, w, run_ours, run_git)
        test_paths(rep, binary, workdir, w, run_ours, run_git)
        test_boundary(rep, binary, workdir, w, run_ours, run_git)
        test_big(rep, binary, workdir, w, run_ours, run_git)

        elapsed = time.time() - started
        print()
        if rep.failures:
            for i, (label, detail) in enumerate(rep.failures[: args.max_failures], 1):
                print("FAIL [%d/%d] %s" % (i, len(rep.failures), label))
                print(detail)
                print()
            if len(rep.failures) > args.max_failures:
                print("… 另有 %d 条未打印" % (len(rep.failures) - args.max_failures))

        print("== 结果: 用例=%d PASS=%d FAIL=%d 用时=%.1fs =="
              % (rep.cases, rep.pass_, rep.fail, elapsed))
        return 1 if rep.fail else 0
    finally:
        if args.keep:
            print("保留临时目录: %s" % workdir)
        else:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
