#!/usr/bin/env python3
# run.py — hexdump 属性对拍：自写 cmd_hexdump.c 与系统 hexdump 逐字节比较。
#
# 纯 Python 标准库；在 x86_64 Linux（含 WSL）上把 cmd_hexdump.c 编成普通可执行
# 文件直接跑，不连设备、不需要 HarmonyOS SDK、不访问网络。
#
#   python3 run.py                 # 200 组随机输入，全部对拍
#   python3 run.py --cases 50      # 少跑几组（排查用）
#   python3 run.py --keep          # 保留临时目录
#
# 环境变量：
#   HEXDUMP_FUZZ_SRC   待测源码（默认 ../../scripts/optional/cmd_hexdump.c）
#   HEXDUMP_FUZZ_REF   系统 hexdump 路径（默认从 PATH 找）
#   CC                 宿主 C 编译器（默认 cc）
#
# 退出码：0 = 全部 PASS（KNOWN-DIFF 不算失败）；1 = 存在未知差异；
#         2 = 编译/环境错误；77 = 宿主没有 hexdump（调用方应记为 SKIP）。
#
# 已知差异（KNOWN-DIFF）只有一类：输入来自 stdin 且 -s 偏移超过输入长度时，
# util-linux 会把最终偏移打印成请求的 skip 值，本实现打印实际读到的字节数
# （跳过时遇到 EOF）。详见 README.md。
import argparse
import concurrent.futures
import itertools
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
IEC_ROOT = HERE.parents[1]
DEFAULT_SRC = IEC_ROOT / "scripts" / "optional" / "cmd_hexdump.c"

MODES = (("-C",), ("-b",), ("-c",), ("-x",), ("-d",), ("-o",))

# 长度必须覆盖任务要求的 0/1/2/15/16/17/255/4096，再补充块边界附近的值。
LENGTHS = (
    0, 1, 2, 3, 7, 15, 16, 17, 18, 31, 32, 33, 47, 48, 49,
    63, 64, 65, 127, 128, 129, 254, 255, 256, 257, 511, 512,
    1000, 1023, 1024, 2047, 2048, 4095, 4096,
)
KINDS = (
    "zeros", "ff", "printable", "control",
    "random", "repeat16", "mixed", "alternating",
)
CONTROL_BYTES = bytes(
    list(range(0x20)) + [0x7f, 0x80, 0x81, 0xfe, 0xff]
)
ENV = dict(os.environ, LC_ALL="C", LANG="C")


def die(msg, code=2):
    print("hexdump_fuzz: " + msg, file=sys.stderr)
    return code


def make_data(n, kind, rng):
    """按类别生成确定性的 n 字节输入。"""
    if n == 0:
        return b""
    if kind == "zeros":
        return bytes(n)
    if kind == "ff":
        return b"\xff" * n
    if kind == "printable":
        return bytes(0x20 + (i % 95) for i in range(n))
    if kind == "control":
        return bytes(CONTROL_BYTES[i % len(CONTROL_BYTES)] for i in range(n))
    if kind == "repeat16":
        block = random_bytes(rng, 16)
        return (block * (n // 16 + 1))[:n]
    if kind == "mixed":
        third = n // 3
        return b"\x00" * third + b"\xff" * third + \
            bytes(0x20 + (i % 95) for i in range(n - 2 * third))
    if kind == "alternating":
        return (b"\x00\xff" * ((n + 1) // 2))[:n]
    return random_bytes(rng, n)


def random_bytes(rng, n):
    if hasattr(rng, "randbytes"):
        return rng.randbytes(n)
    return bytes(rng.getrandbits(8) for _ in range(n))


def make_cases(count, rng):
    """返回 [(长度, 类别), ...]；前 10 组固定覆盖边界长度与全部类别。"""
    fixed = [
        (0, "zeros"),
        (1, "ff"),
        (2, "printable"),
        (15, "control"),
        (16, "random"),
        (17, "repeat16"),
        (255, "mixed"),
        (4096, "zeros"),
        (4096, "ff"),
        (4096, "printable"),
    ]
    cases = list(fixed[:count])
    while len(cases) < count:
        i = len(cases) - len(fixed)
        cases.append((rng.choice(LENGTHS), KINDS[i % len(KINDS)]))
    return cases


def build(src, workdir):
    """把 cmd_hexdump.c 编成宿主可执行文件（入口 iec_hexdump_main）。"""
    cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc")
    if not cc:
        return None, "找不到 C 编译器（cc/gcc）"
    if not src.is_file():
        return None, "源码不存在: %s" % src
    wrap = workdir / "wrap.c"
    wrap.write_text(
        "#include <stdio.h>\n"
        "extern int iec_hexdump_main(int, char**);\n"
        "int main(int argc, char** argv) { return iec_hexdump_main(argc, argv); }\n",
        encoding="ascii",
    )
    binary = workdir / "hexdump_ours"
    cmd = [
        cc, "-std=gnu11", "-O1", "-g", "-Wall", "-Wextra",
        "-D_GNU_SOURCE", str(src), str(wrap), "-o", str(binary),
    ]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        return None, "编译失败:\n%s" % proc.stderr.decode("utf-8", "replace")
    return str(binary), None


def ref_version(ref):
    for arg in ("--version",):
        try:
            p = subprocess.run(
                [ref, arg], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=ENV, timeout=5,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        text = (p.stdout or p.stderr).decode("utf-8", "replace").strip()
        if p.returncode == 0 and text:
            return text.splitlines()[0]
    return "未知版本"


def run(exe, args, stdin_path=None):
    """跑一次，返回 (rc, stdout, stderr)。stdin_path 为 None 时接 /dev/null。"""
    if stdin_path is not None:
        with open(stdin_path, "rb") as f:
            p = subprocess.run(
                [exe] + args, stdin=f, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, env=ENV, cwd=WORK_CWD,
            )
    else:
        p = subprocess.run(
            [exe] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=ENV, cwd=WORK_CWD,
        )
    return p.returncode, p.stdout, p.stderr


def preview(data, limit=800):
    if len(data) > limit:
        return repr(data[:limit]) + " …（共 %d 字节）" % len(data)
    return repr(data)


def first_line_diff(ref_out, our_out):
    """返回第一处不同的行号（1 起）与上下文，供失败报告定位格式问题。"""
    ref_lines = ref_out.splitlines(keepends=True)
    our_lines = our_out.splitlines(keepends=True)
    for idx, (a, b) in enumerate(itertools.zip_longest(ref_lines, our_lines), 1):
        if a != b:
            lo = max(1, idx - 2)
            ctx_ref = b"".join(ref_lines[lo - 1:idx + 2])
            ctx_our = b"".join(our_lines[lo - 1:idx + 2])
            return (
                "首个差异行: %d\n"
                "  ref 上下文: %r\n"
                "  ours 上下文: %r" % (idx, ctx_ref, ctx_our)
            )
    return "输出相同但退出码/状态不同"


def known_stdin_skip(args, length, ref, ours):
    """判断是否只是 stdin + -s 超过长度时的已知偏移差异。

    只放行「除最终偏移行外完全相同」的情况，避免把真正的格式 bug 误判为
    KNOWN-DIFF。util-linux 在 seek 到 EOF 之后仍把最终偏移写成请求的 skip 值；
    本实现按实际读到的字节数推进偏移（长度为 0 时不打印最终偏移行）。
    """
    if "-s" not in args:
        return False
    skip = int(args[args.index("-s") + 1])
    if skip <= length:
        return False
    ref_rc, ref_out, ref_err = ref
    our_rc, our_out, our_err = ours
    if ref_rc != our_rc or ref_err != our_err:
        return False
    width = 8 if args[0] == "-C" else 7
    want = ("%0*x" % (width, skip)).encode("ascii")
    ref_lines = ref_out.splitlines()
    our_lines = our_out.splitlines()
    if not ref_lines or ref_lines[-1] != want:
        return False
    if our_lines and our_lines[-1] == ("%0*x" % (width, length)).encode("ascii"):
        our_lines = our_lines[:-1]
    # 长度为 0 时本实现没有最终偏移行，ours 为空。
    if length == 0 and our_lines:
        return False
    return our_lines == ref_lines[:-1]


def check_job(job):
    """执行一次对拍，返回 (seq, status, label, detail)。"""
    seq, args, path, length, channel = job
    dash_rejected = False
    if channel == "file":
        ref = run(REF_BIN, args + [path], None)
        ours = run(OUR_BIN, args + [path], None)
    elif channel == "dash":
        # util-linux 不认 BSD 的 "-" 表示 stdin，会把它当文件名打开；因此再跑一遍
        # 「不带 - 的 stdin」作为真正的参照，并单独记录它拒绝 "-" 的事实。
        ref = run(REF_BIN, args + ["-"], path)
        ours = run(OUR_BIN, args + ["-"], path)
        ref_stdin = run(REF_BIN, args, path)
        dash_rejected = (
            ref[0] != 0 and b"hexdump: -:" in ref[2]
            and b"No such file or directory" in ref[2]
        )
        if ref == ours:
            return seq, "pass", "", ""
        if dash_rejected and ours == ref_stdin:
            return seq, "known", "%s %s dash" % (channel, args[0]), ""
        if dash_rejected and known_stdin_skip(args, length, ref_stdin, ours):
            return seq, "known", "%s %s dash-s>len" % (channel, args[0]), ""
        ref = ref_stdin
    else:
        ref = run(REF_BIN, args, path)
        ours = run(OUR_BIN, args, path)

    if ref == ours:
        return seq, "pass", "", ""

    if channel == "stdin" and known_stdin_skip(args, length, ref, ours):
        return seq, "known", "stdin %s -s>len" % args[0], ""

    extra = ""
    if channel == "dash":
        extra = "\n（util-linux 拒绝 \"-\": %r）" % (ref[2][:200],)
    detail = (
        "参数: %s\n输入长度: %d，渠道: %s\n"
        "退出码: ref=%d ours=%d\n%s\n"
        "ref stdout: %s\nours stdout: %s\n"
        "ref stderr: %r\nours stderr: %r%s"
        % (
            " ".join(args) + ("" if channel == "file" else " (%s)" % channel),
            length, channel, ref[0], ours[0],
            first_line_diff(ref[1], ours[1]),
            preview(ref[1]), preview(ours[1]),
            ref[2][:200], ours[2][:200], extra,
        )
    )
    return seq, "fail", "", detail


def option_variants(n):
    """每个格式的必测组合：裸格式、-v、-n(0/1/超长)、-s(0/1/15/超长)。"""
    variants = []
    for mode in MODES:
        variants.append(mode)
        variants.append(mode + ("-v",))
        for length in (0, 1, n + 1):
            variants.append(mode + ("-n", str(length)))
        for off in (0, 1, 15, n + 1):
            variants.append(mode + ("-s", str(off)))
    # -n 与 -s 同时出现（-n 0 曾多打最终偏移行）；状态逻辑与格式无关，
    # 固定挑 -C / -x 两种代表格式，避免组合数爆炸。
    for mode in (("-C",), ("-x",)):
        variants.append(mode + ("-n", "0", "-s", "1"))
        variants.append(mode + ("-n", "0", "-s", str(n + 1)))
        variants.append(mode + ("-n", "1", "-s", "15"))
        variants.append(mode + ("-n", str(n + 1), "-s", "1"))
        variants.append(mode + ("-n", "5", "-s", "15"))
    return variants


def build_jobs(paths, lengths, cases):
    """生成全部对拍任务；返回 jobs 列表。"""
    jobs = []
    seq = 0

    # 1) 每个输入：文件参数 + 全部格式/截断/跳过/折叠组合。
    for idx, n in enumerate(lengths):
        for args in option_variants(n):
            jobs.append((seq, list(args), paths[idx], n, "file"))
            seq += 1

    # 2) 多文件：一条字节流跨文件连续（含 -n/-s/-v 跨越文件边界）。
    for pair in range(len(paths) // 2):
        f1, f2 = paths[2 * pair], paths[2 * pair + 1]
        total = lengths[2 * pair] + lengths[2 * pair + 1]
        modes = (MODES[pair % len(MODES)], MODES[(pair + 3) % len(MODES)])
        for mode in MODES:
            jobs.append((seq, list(mode) + [f1, f2], "", total, "file"))
            seq += 1
        for mode in modes:
            for extra in (
                ("-v", "-n", "17", "-s", "3"),
                ("-n", "0", "-s", "5"),
                ("-s", "15"),
            ):
                jobs.append(
                    (seq, list(mode) + list(extra) + [f1, f2], "", total, "file")
                )
                seq += 1

    # 3) stdin：只挑边界/抽样输入，覆盖 -s 超过长度时的 KNOWN-DIFF。
    stdin_indexes = list(range(min(10, len(paths))))
    stdin_indexes += [i for i in range(10, len(paths), 20)]
    for idx in stdin_indexes:
        n = lengths[idx]
        offs = sorted({1, 15, n + 1})
        for mode in MODES:
            for off in offs:
                jobs.append(
                    (seq, list(mode) + ["-s", str(off)], paths[idx], n, "stdin")
                )
                seq += 1
            jobs.append(
                (seq, list(mode) + ["-n", "5", "-s", "15"], paths[idx], n, "stdin")
            )
            seq += 1

    # 4) "-" 作为 stdin 的文件参数写法（首个非选项）。
    for idx in range(min(3, len(paths))):
        n = lengths[idx]
        for mode in MODES:
            for off in (3, n + 1):
                jobs.append(
                    (seq, list(mode) + ["-s", str(off)], paths[idx], n, "dash")
                )
                seq += 1

    return jobs


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="自写 hexdump 与系统 hexdump 的属性对拍",
    )
    parser.add_argument("--cases", type=int, default=200,
                        help="随机输入组数（默认 200）")
    parser.add_argument("--seed", type=int, default=20261030,
                        help="随机种子（默认 20261030）")
    parser.add_argument("--jobs", type=int, default=0,
                        help="并发进程数（默认 min(16, CPU 数)）")
    parser.add_argument("--max-failures", type=int, default=10,
                        help="最多打印多少个未知差异（默认 10）")
    parser.add_argument("--keep", action="store_true",
                        help="保留临时编译/输入目录")
    args = parser.parse_args(argv)

    global REF_BIN, OUR_BIN, WORK_CWD
    ref = os.environ.get("HEXDUMP_FUZZ_REF") or shutil.which("hexdump")
    if not ref:
        print("hexdump_fuzz: SKIP —— 宿主没有系统 hexdump（util-linux/bsdextrautils）")
        return 77
    REF_BIN = ref
    src = Path(os.environ.get("HEXDUMP_FUZZ_SRC") or DEFAULT_SRC)

    print("== hexdump_fuzz: 自写 hexdump 与系统实现逐字节对拍 ==")
    print("源码: %s" % src)
    print("参照: %s（%s）" % (ref, ref_version(ref)))

    workdir = Path(tempfile.mkdtemp(prefix="hexdump_fuzz."))
    WORK_CWD = str(workdir)
    try:
        binary, err = build(src, workdir)
        if err:
            return die(err)
        OUR_BIN = binary

        rng = random.Random(args.seed)
        cases = make_cases(max(1, args.cases), rng)
        paths, lengths = [], []
        for idx, (n, kind) in enumerate(cases):
            path = workdir / ("in_%03d.bin" % idx)
            path.write_bytes(make_data(n, kind, rng))
            paths.append(str(path))
            lengths.append(n)

        jobs = build_jobs(paths, lengths, cases)
        workers = args.jobs or min(16, os.cpu_count() or 4)
        workers = max(1, workers)
        print("输入: %d 组，对拍任务: %d 次（渠道: 文件参数/stdin/\"-\"，并发 %d）"
              % (len(cases), len(jobs), workers))

        started = time.time()
        statuses = {}
        known = []
        failures = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [pool.submit(check_job, job) for job in jobs]
            for fut in concurrent.futures.as_completed(futures):
                seq, status, label, detail = fut.result()
                statuses[seq] = status
                if status == "known":
                    known.append(label)
                elif status == "fail":
                    failures.append((seq, detail))
        elapsed = time.time() - started

        passed = sum(1 for s in statuses.values() if s == "pass")
        print()
        if failures:
            failures.sort(key=lambda item: item[0])
            for i, (seq, detail) in enumerate(failures[:args.max_failures], 1):
                print("FAIL [%d/%d] 任务 #%d" % (i, len(failures), seq))
                print(detail)
                print()
            if len(failures) > args.max_failures:
                print("… 另有 %d 个未知差异未打印"
                      % (len(failures) - args.max_failures))

        if known:
            stdin_known = [item for item in known if item.startswith("stdin ")]
            dash_known = [item for item in known if item.startswith("dash ")]
            print("KNOWN-DIFF: %d 例" % len(known))
            if stdin_known:
                modes = sorted({item.split()[1] for item in stdin_known})
                print("  A. %d 例：stdin 输入，-s 偏移超过数据长度，格式=%s"
                      "（含 -n/-v 组合）"
                      % (len(stdin_known), " ".join(modes)))
                print("     原因: util-linux 在 EOF 后仍把最终偏移打印为请求的 skip 值；"
                      "本实现打印实际读到的字节数（长度 0 时不打印最终偏移行）。")
            if dash_known:
                modes = sorted({item.split()[1] for item in dash_known})
                print("  B. %d 例：\"-\" 作为 stdin 操作符，格式=%s"
                      % (len(dash_known), " ".join(modes)))
                print("     原因: util-linux 不把 \"-\" 当 stdin，而是当文件名打开并报"
                      " No such file；本实现按 BSD 习惯读 stdin。")

        print("== 结果: 输入=%d 对拍=%d PASS=%d KNOWN-DIFF=%d FAIL=%d 用时=%.1fs =="
              % (len(cases), len(jobs), passed, len(known), len(failures), elapsed))
        if failures:
            return 1
        return 0
    finally:
        if args.keep:
            print("保留临时目录: %s" % workdir)
        else:
            shutil.rmtree(workdir, ignore_errors=True)


REF_BIN = ""
OUR_BIN = ""
WORK_CWD = ""

if __name__ == "__main__":
    sys.exit(main())
