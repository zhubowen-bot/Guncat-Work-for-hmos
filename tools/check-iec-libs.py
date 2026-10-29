#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-iec-libs.py — IEC 随包 .so 的静态一致性检查。

背景：这台仓库已经两次出现"源码改了、随包 .so 没重编"（libpycmd 的 SIGPIPE
修复、nc/hexdump/diff 的语义修复）。这类问题编译能过、单测也能过，只有到设备上
才暴露。本脚本把相关不变量变成一条不依赖设备/SDK 的检查：

  1. 从 IecRuntime.ets 解析 (命令 -> so -> 入口符号) 的期望映射；
  2. 每个被引用的 .so 存在、非空、不是符号链接，且工作区字节与 git index 一致
     （防 autocrlf / 过滤器把二进制改坏）；
  3. 用 llvm-nm 校验 .so 确实导出了对应入口（无 llvm 时 SKIP）；
  4. 用 python 解析 ELF 动态段，校验 NEEDED 白名单；
  5. 用 blob 内容比较"源码 -> 产物"的新鲜度：产物那次提交里的源码哈希与工作区
     不同即失败（能抓到"改了源码还没重编"，不会被只改文件模式的提交误报）；
     node 构建耗时大，只警告；
  6. 若本机有已打包的签名 HAP，检查 libs/arm64-v8a 下是否缺 .so。

只依赖 Python 3 标准库与 git；不连设备、不需要 HarmonyOS SDK。
退出码：0 = 通过，1 = 有失败（--strict 时 SKIP 也算失败）。

用法：
    python3 tools/check-iec-libs.py [--strict]
"""

import argparse
import ast
import datetime
import os
import re
import shutil
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

ETS_REL = "entry/src/main/ets/service/IecRuntime.ets"
LIBS_REL = "third_party/bettersh/iec/platform/ohos/har/libs/arm64-v8a"
HAP_REL = "entry/build/default/outputs/default/entry-default-signed.hap"

# libarchive 不在 launcher 映射里（由 native 的 unpackResource 使用），但它同样是
# 随包运行库，必须做文件/blob/NEEDED 检查。
AUX_LIBS = ("libarchive.so.13",)

# NEEDED 白名单。命令 so 都是自包含的，只允许 libc；libnode 因为用 C++ 实现，
# 额外允许随包的 libc++_shared。命中不在表里的 NEEDED 说明链接方式变了
# （例如误链了 target 上不存在的 libm/libpthread），设备上会 dlopen 失败。
DEFAULT_ALLOWED_NEEDED = {"libc.so"}
NEEDED_WHITELIST = {
    "libnode.so": {"libc.so", "libc++_shared.so"},
}

# 源码 -> 产物。时间取最后一次改动该路径的提交时间：源码提交晚于产物提交，
# 说明产物是旧源码编出来的，必须重编。node 的构建脚本/补丁变动只警告：
# 它体积大、重建成本高，而且脚本改动不一定改变产物字节。
FRESHNESS = (
    {
        "product": "libpycmd.so",
        "sources": ("third_party/bettersh/iec/scripts/optional/python_entry.c",),
        "hint": "仓库内没有 libpycmd 的构建脚本；按 python_entry.c 的 IEC 交叉编译"
                "流程重编（入口 iec_python_main），再重新打包 HAP",
        "warn_only": False,
    },
    {
        "product": "libnc.so",
        "sources": ("third_party/bettersh/iec/scripts/optional/cmd_nc.c",),
        "hint": "bash third_party/bettersh/iec/scripts/build_extra_commands.sh",
        "warn_only": False,
    },
    {
        "product": "libhexdump.so",
        "sources": ("third_party/bettersh/iec/scripts/optional/cmd_hexdump.c",),
        "hint": "bash third_party/bettersh/iec/scripts/build_extra_commands.sh",
        "warn_only": False,
    },
    {
        "product": "libdiff.so",
        "sources": ("third_party/bettersh/iec/scripts/optional/cmd_diff.c",),
        "hint": "bash third_party/bettersh/iec/scripts/build_extra_commands.sh",
        "warn_only": False,
    },
    {
        "product": "libnode.so",
        "sources": (
            "third_party/bettersh/iec/scripts/optional/node-ohos",
            "third_party/bettersh/iec/scripts/optional/build_node.sh",
        ),
        "hint": "bash third_party/bettersh/iec/scripts/optional/build_node.sh"
                "（node 体积大，只警告不阻塞）",
        "warn_only": True,
    },
)

SO_NAME_RE = re.compile(r"lib[A-Za-z0-9._+-]*\.so(?:\.[0-9]+)*$")
SYMBOL_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*$")


class Reporter:
    """收集失败/跳过/警告，并按检查项输出简洁报告。"""

    def __init__(self, strict=False):
        self.strict = strict
        self.fails = []
        self.skips = []
        self.warns = []
        self._index = 0
        self._total = 0

    def fail(self, message):
        self.fails.append(message)

    def skip(self, message):
        self.skips.append(message)

    def warn(self, message):
        self.warns.append(message)

    def section(self, title, body, not_applicable=None):
        """执行一个检查项并打印状态；body 返回一行补充说明。"""
        self._index += 1
        f0, s0, w0 = len(self.fails), len(self.skips), len(self.warns)
        detail = body()
        new_f = len(self.fails) - f0
        new_s = len(self.skips) - s0
        new_w = len(self.warns) - w0
        if not_applicable is not None:
            status = "N/A"
            detail = not_applicable
        elif new_f:
            status = "FAIL"
        elif new_s:
            status = "SKIP"
        elif new_w:
            status = "WARN"
        else:
            status = "OK"
        head = "[%d/%d] %s: %s" % (self._index, self._total, title, status)
        if detail:
            head += "（%s）" % detail
        print(head)
        for item in self.fails[f0:]:
            print("       - FAIL: " + item)
        for item in self.skips[s0:]:
            print("       - SKIP: " + item)
        for item in self.warns[w0:]:
            print("       - WARN: " + item)

    def set_total(self, total):
        self._total = total

    def exit_code(self):
        failed = bool(self.fails) or (self.strict and bool(self.skips))
        return 1 if failed else 0

    def summary(self):
        status = "FAIL" if self.exit_code() else "PASS"
        line = "结果: %s（失败 %d，跳过 %d，警告 %d）" % (
            status, len(self.fails), len(self.skips), len(self.warns))
        if self.strict and self.skips:
            line += "；--strict 把 SKIP 计为失败"
        print()
        print(line)


def run_bytes(args, cwd=None):
    """执行命令并返回 (returncode, stdout_bytes, stderr_bytes)。"""
    try:
        proc = subprocess.run(
            args,
            cwd=str(cwd or REPO_ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except OSError as exc:
        return 127, b"", str(exc).encode("utf-8", "replace")


def git(*args):
    return run_bytes(["git", *args])


def git_text(*args):
    code, out, err = git(*args)
    if code != 0:
        return ""
    return out.decode("utf-8", "replace")


def git_ts(paths):
    """路径（文件或目录）最后一次被提交的时间戳；没有历史则返回 None。"""
    code, out, _ = git("log", "-1", "--format=%ct", "--", *paths)
    if code != 0:
        return None
    text = out.decode("ascii", "replace").strip()
    return int(text) if text.isdigit() else None


def git_blob(rev, path):
    """rev 中 path 的 blob hash；该版本没有此文件时返回 None。

    新鲜度用内容比较而不是提交时间：一次只改可执行位/换行的提交也会刷新
    路径的“最后提交时间”，按时间判断会把正常的产物误报成落后。
    """
    code, out, _ = git("rev-parse", "%s:%s" % (rev, path))
    if code != 0:
        return None
    return out.decode("ascii", "replace").strip() or None


def worktree_blob(path):
    """工作区文件的 blob hash（走 git 的过滤器，CRLF 不会造成误报）。"""
    code, out, _ = git("hash-object", "--", path)
    if code != 0:
        return None
    return out.decode("ascii", "replace").strip() or None


def fmt_ts(ts):
    if ts is None:
        return "无提交记录"
    return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


# ---------------------------------------------------------------------------
# 1. 解析 IecRuntime.ets
# ---------------------------------------------------------------------------

def strip_js_comments(text):
    """把 // 与 /* */ 注释替换成空格（保留换行与字符串），避免匹配到注释里的调用。"""
    out = []
    i, n = 0, len(text)
    state = "normal"
    quote = ""
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state == "normal":
            if ch == "/" and nxt == "/":
                out.append("  ")
                i += 2
                state = "line"
            elif ch == "/" and nxt == "*":
                out.append("  ")
                i += 2
                state = "block"
            elif ch in ("'", '"', "`"):
                quote = ch
                out.append(ch)
                i += 1
                state = "string"
            else:
                out.append(ch)
                i += 1
        elif state == "line":
            if ch == "\n":
                out.append(ch)
                state = "normal"
            else:
                out.append(" ")
            i += 1
        elif state == "block":
            if ch == "*" and nxt == "/":
                out.append("  ")
                i += 2
                state = "normal"
            else:
                out.append("\n" if ch == "\n" else " ")
                i += 1
        else:  # string
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == quote:
                state = "normal"
            i += 1
    return "".join(out)


def split_args(text, open_pos):
    """从 '(' 的位置开始，按顶层逗号切分实参；返回 (args, close_pos)。"""
    args = []
    buf = []
    depth = 0
    quote = ""
    i = open_pos
    while i < len(text):
        ch = text[i]
        if quote:
            buf.append(ch)
            if ch == "\\" and i + 1 < len(text):
                buf.append(text[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = ""
            i += 1
            continue
        if ch in ("'", '"', "`"):
            quote = ch
            buf.append(ch)
        elif ch in "([{":
            depth += 1
            if depth == 1:
                i += 1
                continue
            buf.append(ch)
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                args.append("".join(buf).strip())
                return args, i
            buf.append(ch)
        elif ch == "," and depth == 1:
            args.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
        i += 1
    return args, len(text)


def iter_calls(text, func_name):
    """迭代 func_name(...) 调用，返回 (行号, 起始位置, 实参列表)。"""
    pattern = re.compile(r"(?<![.\w$])" + re.escape(func_name) + r"\s*\(")
    for match in pattern.finditer(text):
        args, _ = split_args(text, match.end() - 1)
        line = text.count("\n", 0, match.start()) + 1
        yield line, match.start(), args


def string_literals(expr):
    """取出表达式里的字符串字面量（支持单/双引号与转义）。"""
    values = []
    pattern = re.compile(r"'((?:\\.|[^'\\])*)'|\"((?:\\.|[^\"\\])*)\"", re.S)
    for match in pattern.finditer(expr):
        raw = match.group(0)
        try:
            value = ast.literal_eval(raw)
        except (ValueError, SyntaxError):
            continue
        if isinstance(value, str):
            values.append(value)
    return values


def so_literal(expr):
    """从实参表达式里找随包 so 文件名（允许 BUNDLE_LIBS + 'x.so'）。"""
    for value in string_literals(expr):
        if SO_NAME_RE.fullmatch(value):
            return value
    return None


def so_like_literals(expr):
    """表达式里看起来像 so、但不是合法纯文件名的字面量（用于报错而不是静默跳过）。"""
    return [value for value in string_literals(expr)
            if ".so" in value or value.endswith(".so")]


def symbol_literal(expr):
    values = string_literals(expr)
    if len(values) == 1 and SYMBOL_RE.fullmatch(values[0]):
        return values[0]
    return None


def loop_names(text, call_start, var):
    """若 call_start 位于 `for (const <var> of ['a','b'])` 内，返回数组里的名字。"""
    pattern = re.compile(
        r"for\s*\(\s*(?:const|let|var)\s+" + re.escape(var) + r"\s+of\s*\[")
    best = None
    for match in pattern.finditer(text, 0, call_start):
        close = find_matching(text, match.end() - 1, "[", "]")
        if close is not None and close < call_start:
            best = (match.end(), close)
    if best is None:
        return None
    names = string_literals(text[best[0]:best[1]])
    return names or None


def find_matching(text, open_pos, open_ch, close_ch):
    depth = 0
    quote = ""
    i = open_pos
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = ""
            i += 1
            continue
        if ch in ("'", '"', "`"):
            quote = ch
        elif ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def parse_launchers(ets_text, reporter):
    """解析 add(...) 与直接 writeSoLauncher(...)，返回 (mappings, add数, 直接调用数)。"""
    text = strip_js_comments(ets_text)
    mappings = []
    add_count = 0
    direct_count = 0

    for line, start, args in iter_calls(text, "add"):
        if len(args) < 3:
            continue  # explicitNames.add(...) 之类的单参数调用；方法调用已被正则排除
        so = so_literal(args[1])
        if so is None:
            bad = so_like_literals(args[1])
            if bad:
                reporter.fail("%s:%d add(...) 的 so 参数 %s 不是 libs/arm64-v8a 下的"
                              "纯文件名" % (ETS_REL, line, bad[0]))
            else:
                reporter.fail("%s:%d add(...) 的 so 参数不是字符串字面量，无法静态校验"
                              % (ETS_REL, line))
            continue
        entry = symbol_literal(args[2])
        if entry is None:
            reporter.fail("%s:%d add(...) 的入口不是字符串字面量，无法静态校验"
                          % (ETS_REL, line))
            continue
        first = args[0].strip()
        literal = string_literals(first)
        names = []
        if re.fullmatch(r"'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"", first):
            names = [literal[0]]
        elif re.fullmatch(r"[A-Za-z_$][\w$]*", first):
            expanded = loop_names(text, start, first)
            names = expanded if expanded else [None]
        elif literal:
            names = [literal[0]]
        else:
            names = [None]
        add_count += 1
        for name in names:
            mappings.append({"name": name, "so": so, "entry": entry, "line": line})

    for line, start, args in iter_calls(text, "writeSoLauncher"):
        if len(args) < 3:
            continue
        so = so_literal(args[1])
        if so is None:
            # add 辅助函数里的 writeSoLauncher(BIN_DIR + name, BUNDLE_LIBS + so, entry)
            # 是通用形参，本就该跳过；但出现路径形式/非纯文件名的 so 字面量要报错。
            bad = so_like_literals(args[1])
            if bad:
                reporter.fail("%s:%d writeSoLauncher(...) 的 so 参数 %s 不是"
                              "libs/arm64-v8a 下的纯文件名" % (ETS_REL, line, bad[0]))
            continue
        entry = symbol_literal(args[2])
        if entry is None:
            reporter.fail("%s:%d writeSoLauncher(...) 的入口不是字符串字面量"
                          % (ETS_REL, line))
            continue
        direct_count += 1
        literal = string_literals(args[0])
        name = literal[0] if len(literal) == 1 else None
        mappings.append({"name": name, "so": so, "entry": entry, "line": line})

    if add_count == 0 and direct_count == 0:
        reporter.fail("%s 里没有解析到任何 add(...) / writeSoLauncher(...)" % ETS_REL)

    # 同名命令只能指向一个 (so, 入口)，否则运行时后写的会覆盖先写的。
    by_name = {}
    for item in mappings:
        name = item["name"]
        if not name:
            continue
        key = (item["so"], item["entry"])
        old = by_name.get(name)
        if old is not None and old[0] != key:
            reporter.fail("命令 %s 同时映射到 %s/%s 与 %s/%s（第 %d 行）"
                          % (name, old[0][0], old[0][1],
                             item["so"], item["entry"], item["line"]))
        by_name[name] = (key, item["line"])

    # 去掉完全重复的记录（直接 writeSoLauncher 与 add 可能有同一 (命令,so,入口)）。
    seen = set()
    unique = []
    for item in mappings:
        key = (item["name"], item["so"], item["entry"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(item)
    return unique, add_count, direct_count


# ---------------------------------------------------------------------------
# 2. 文件、符号链接、工作区/blob 一致性
# ---------------------------------------------------------------------------

def index_entry(rel_path):
    """返回 (mode, blob_sha) 或 None。"""
    code, out, _ = git("ls-files", "-s", "--", rel_path)
    if code != 0:
        return None
    line = out.decode("utf-8", "replace").strip()
    if not line:
        return None
    parts = line.split()
    if len(parts) < 2:
        return None
    return parts[0], parts[1]


def check_lib_files(required_sos, reporter):
    ok = 0
    for so in required_sos:
        path = REPO_ROOT / LIBS_REL / so
        rel = path.relative_to(REPO_ROOT).as_posix()
        if path.is_symlink():
            reporter.fail("%s 是符号链接；随包 .so 必须是普通文件" % rel)
            continue
        if not path.is_file():
            reporter.fail("%s 不存在" % rel)
            continue
        size = path.stat().st_size
        if size <= 0:
            reporter.fail("%s 是空文件" % rel)
            continue

        entry = index_entry(rel)
        if entry is None:
            reporter.fail("%s 不在 git index 里（无法证明随包字节可复现）" % rel)
            continue
        mode, blob_sha = entry
        if mode == "120000":
            reporter.fail("%s 在 git index 里是符号链接（mode 120000）" % rel)
            continue

        code, out, _ = git("cat-file", "-s", blob_sha)
        if code != 0:
            reporter.fail("%s 的 index blob %s 读不出大小" % (rel, blob_sha[:12]))
            continue
        try:
            blob_size = int(out.decode("ascii").strip())
        except ValueError:
            reporter.fail("%s 的 index blob 大小无法解析" % rel)
            continue
        if blob_size != size:
            reporter.fail("%s 工作区大小 %d 与 index blob 大小 %d 不一致"
                          % (rel, size, blob_size))
            continue

        code, out, err = git("hash-object", "--", rel)
        if code != 0:
            reporter.fail("%s 无法计算工作区 blob：%s"
                          % (rel, err.decode("utf-8", "replace").strip()))
            continue
        worktree_sha = out.decode("ascii", "replace").strip()
        if worktree_sha != blob_sha:
            reporter.fail("%s 工作区字节与 index 不一致（index=%s，工作区=%s）；"
                          "常见原因是 autocrlf/过滤器改坏了二进制，请恢复该文件"
                          % (rel, blob_sha[:12], worktree_sha[:12]))
            continue
        ok += 1
    return ok


# ---------------------------------------------------------------------------
# 3. 入口符号（llvm-nm）
# ---------------------------------------------------------------------------

def find_llvm_tool(name):
    """在环境变量、PATH、DevEco SDK 与 Linux llvm 目录里找 llvm 工具。"""
    names = [name, name + ".exe"]
    candidates = []

    env_dir = os.environ.get("GUNCAT_LLVM_BIN", "").strip()
    if env_dir:
        env_path = Path(env_dir)
        if env_path.is_file():
            candidates.append(env_path)
        else:
            candidates.extend(env_path / item for item in names)

    for item in names:
        found = shutil.which(item)
        if found:
            candidates.append(Path(found))

    # DevEco Studio 默认安装位置（Windows / Linux）。
    for root in (
        Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Huawei" / "DevEco Studio",
        Path(os.environ.get("LOCALAPPDATA", "")) / "Huawei" / "DevEco Studio",
        Path.home() / "DevEcoStudio",
        Path("/opt/DevEcoStudio"),
        Path("/opt/huawei/DevEcoStudio"),
    ):
        for sub in (
            "sdk/default/openharmony/native/llvm/bin",
            "sdk/default/hms/native/BiSheng/bin",
        ):
            for item in names:
                candidates.append(root / sub / item)

    # Ubuntu 的 llvm 包可能只装带版本号的二进制。
    for pattern in ("/usr/lib/llvm-*/bin/" + name, "/usr/bin/" + name + "-*"):
        import glob
        candidates.extend(Path(p) for p in glob.glob(pattern))

    seen = set()
    for path in candidates:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        if path.is_file() and os.access(str(path), os.X_OK):
            return path
    return None


def check_entries(required_sos, mappings, reporter):
    nm = find_llvm_tool("llvm-nm")
    if nm is None:
        reporter.skip("未找到 llvm-nm，跳过入口符号校验；"
                      "设置 GUNCAT_LLVM_BIN 或安装 DevEco SDK / llvm 后启用")
        return None
    expected = {}
    for item in mappings:
        expected.setdefault(item["so"], set()).add(item["entry"])
    checked = 0
    for so in required_sos:
        entries = expected.get(so)
        if not entries:
            continue
        path = REPO_ROOT / LIBS_REL / so
        code, out, err = run_bytes([str(nm), "--dynamic", "--defined-only", str(path)])
        if code != 0:
            reporter.fail("llvm-nm 读取 %s 失败：%s"
                          % (so, err.decode("utf-8", "replace").strip()))
            continue
        symbols = set()
        for line in out.decode("utf-8", "replace").splitlines():
            fields = line.split()
            if fields:
                symbols.add(fields[-1])
        for entry in sorted(entries):
            if entry not in symbols:
                reporter.fail("%s 没有导出入口 %s（launcher 指向它会在设备上 dlopen 后"
                              "找不到符号）" % (so, entry))
            else:
                checked += 1
    return "%s，%d 个入口" % (nm.name, checked)


# ---------------------------------------------------------------------------
# 4. NEEDED（纯 python 解析 ELF64 动态段）
# ---------------------------------------------------------------------------

def elf_needed(path):
    """返回 DT_NEEDED 列表；不是可解析的 ELF64 时返回 None。"""
    try:
        data = path.read_bytes()
        if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] not in (1, 2):
            return None
        endian = "<" if data[5] == 1 else ">"
        if len(data) < 0x40:
            return None
        e_phoff = struct.unpack_from(endian + "Q", data, 0x20)[0]
        e_phentsize = struct.unpack_from(endian + "H", data, 0x36)[0]
        e_phnum = struct.unpack_from(endian + "H", data, 0x38)[0]
        loads = []
        dynamic = None
        for i in range(e_phnum):
            off = e_phoff + i * e_phentsize
            if off + 56 > len(data):
                return None
            p_type = struct.unpack_from(endian + "I", data, off)[0]
            p_offset = struct.unpack_from(endian + "Q", data, off + 8)[0]
            p_vaddr = struct.unpack_from(endian + "Q", data, off + 16)[0]
            p_filesz = struct.unpack_from(endian + "Q", data, off + 32)[0]
            if p_type == 1:  # PT_LOAD
                loads.append((p_vaddr, p_offset, p_filesz))
            elif p_type == 2:  # PT_DYNAMIC
                dynamic = (p_offset, p_filesz)
        if dynamic is None:
            return []
        strtab_addr = None
        needed_offsets = []
        offset, size = dynamic
        for i in range(size // 16):
            pos = offset + i * 16
            if pos + 16 > len(data):
                return None
            tag, value = struct.unpack_from(endian + "qQ", data, pos)
            if tag == 0:  # DT_NULL
                break
            if tag == 5:  # DT_STRTAB
                strtab_addr = value
            elif tag == 1:  # DT_NEEDED
                needed_offsets.append(value)
        if strtab_addr is None:
            return []
        strtab_off = None
        for vaddr, file_off, filesz in loads:
            if vaddr <= strtab_addr < vaddr + filesz:
                strtab_off = file_off + (strtab_addr - vaddr)
                break
        if strtab_off is None or strtab_off >= len(data):
            return None
        needed = []
        for name_off in needed_offsets:
            start = strtab_off + name_off
            if start >= len(data):
                return None
            end = data.find(b"\0", start)
            if end < 0:
                return None
            needed.append(data[start:end].decode("utf-8", "replace"))
        return needed
    except (OSError, struct.error):
        return None


def check_needed(required_sos, reporter):
    checked = 0
    for so in required_sos:
        path = REPO_ROOT / LIBS_REL / so
        needed = elf_needed(path)
        if needed is None:
            reporter.fail("%s 不是可解析的 ELF64 共享库，无法校验 NEEDED" % so)
            continue
        allowed = NEEDED_WHITELIST.get(so, DEFAULT_ALLOWED_NEEDED)
        unexpected = sorted(set(needed) - set(allowed))
        if unexpected:
            reporter.fail("%s 的 NEEDED 不在白名单：%s（只允许 %s）"
                          % (so, "、".join(unexpected), "、".join(sorted(allowed))))
            continue
        checked += 1
    return "%d 个 so" % checked


# ---------------------------------------------------------------------------
# 5. 源码新鲜度
# ---------------------------------------------------------------------------

def check_freshness(reporter):
    # 浅克隆里 git log 看不到完整历史，会把正常产物误报成"没有提交记录"。
    # CI 用 fetch-depth: 0 取全历史；本地浅克隆请先 git fetch --unshallow。
    if git_text("rev-parse", "--is-shallow-repository").strip() == "true":
        reporter.skip("当前是浅克隆，git log 看不到完整历史；"
                      "先 git fetch --unshallow 再检查新鲜度")
        return None
    checked = 0
    for item in FRESHNESS:
        product = item["product"]
        product_rel = (Path(LIBS_REL) / product).as_posix()
        product_ts = git_ts((product_rel,))
        if product_ts is None:
            reporter.fail("%s 没有提交记录，无法判断源码新鲜度" % product_rel)
            continue
        product_commit = git_text("log", "-1", "--format=%H", "--", product_rel).strip()
        if not product_commit:
            reporter.fail("%s 没有提交记录，无法判断源码新鲜度" % product_rel)
            continue
        # 内容比较：产物那次提交里的源码 blob 与**工作区**是否相同。这样能抓到
        # “源码改了还没提交/没重编”，也不会被只改文件模式的提交误报。
        stale = []
        for src in item["sources"]:
            current = worktree_blob(src)
            if current is None:
                continue  # 源文件已被删除，无从比较
            if git_blob(product_commit, src) != current:
                stale.append(src)
        checked += 1
        if not stale:
            continue
        source_ts = git_ts(item["sources"])
        message = ("%s 落后于源码（%s 内容有改动%s）；请运行 %s"
                   % (product, "、".join(stale),
                      "，源码最后提交 %s" % fmt_ts(source_ts) if source_ts else "",
                      item["hint"]))
        if item["warn_only"]:
            reporter.warn(message)
        else:
            reporter.fail(message)
    return "%d 个映射" % checked


# ---------------------------------------------------------------------------
# 6. HAP 内容
# ---------------------------------------------------------------------------

def check_hap(required_sos, reporter):
    hap = REPO_ROOT / HAP_REL
    if not hap.is_file():
        return None  # 由调用方显示 N/A；CI 不构建 HAP，不能算失败
    try:
        with zipfile.ZipFile(hap) as archive:
            names = set(archive.namelist())
    except (OSError, zipfile.BadZipFile) as exc:
        reporter.fail("%s 无法作为 HAP（zip）读取：%s" % (HAP_REL, exc))
        return ""
    prefix = "libs/arm64-v8a/"
    present = {name[len(prefix):] for name in names if name.startswith(prefix)}
    if not present:
        reporter.fail("%s 里没有 %s 目录（HAP 可能是旧包或没有打进命令 so）"
                      % (HAP_REL, prefix))
        return ""
    missing = sorted(set(required_sos) - present)
    if missing:
        reporter.fail("%s 缺少 %d 个随包 .so：%s；HAP 已过期，请重新打包"
                      % (HAP_REL, len(missing), "、".join(missing)))
    return "%d 个必需 so" % len(required_sos)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass

    parser = argparse.ArgumentParser(
        description="IEC 随包 .so 静态一致性检查（不需要设备/SDK）")
    parser.add_argument("--strict", action="store_true",
                        help="把 SKIP 也计为失败")
    args = parser.parse_args()

    reporter = Reporter(strict=args.strict)
    reporter.set_total(6)
    print("IEC 随包库一致性检查")
    print("仓库根: %s" % REPO_ROOT)
    print()

    if shutil.which("git") is None:
        print("结果: FAIL（找不到 git，无法校验 blob 与提交时间）")
        return 1

    ets_path = REPO_ROOT / ETS_REL
    try:
        ets_text = ets_path.read_text(encoding="utf-8")
    except OSError as exc:
        print("结果: FAIL（读取 %s 失败：%s）" % (ETS_REL, exc))
        return 1

    state = {}
    reporter.section("命令映射", lambda: _mapping_section(ets_text, state, reporter))
    required_sos = sorted({item["so"] for item in state["mappings"]} | set(AUX_LIBS))
    state["required_sos"] = required_sos

    reporter.section(
        "随包 .so 文件与 blob",
        lambda: _files_section(required_sos, reporter),
    )
    reporter.section(
        "入口符号",
        lambda: check_entries(required_sos, state["mappings"], reporter),
    )
    reporter.section(
        "NEEDED 白名单",
        lambda: check_needed(required_sos, reporter),
    )
    reporter.section(
        "源码新鲜度",
        lambda: check_freshness(reporter),
    )
    reporter.section(
        "HAP 随包内容",
        lambda: check_hap(required_sos, reporter),
        not_applicable=_hap_not_applicable(),
    )

    reporter.summary()
    return reporter.exit_code()


def _mapping_section(ets_text, state, reporter):
    mappings, add_count, direct_count = parse_launchers(ets_text, reporter)
    state["mappings"] = mappings
    unique_sos = sorted({item["so"] for item in mappings})
    names = {item["name"] for item in mappings if item["name"]}
    if not mappings:
        return "未解析到映射"
    return "%d 条 add + %d 条直接 writeSoLauncher，%d 个命令 / %d 个 so" % (
        add_count, direct_count, len(names), len(unique_sos))


def _files_section(required_sos, reporter):
    ok = check_lib_files(required_sos, reporter)
    return "%d/%d 个文件通过" % (ok, len(required_sos))


def _hap_not_applicable():
    hap = REPO_ROOT / HAP_REL
    if not hap.is_file():
        return "未发现已打包 HAP，跳过；CI 不构建 HAP，正常"
    return None


if __name__ == "__main__":
    sys.exit(main())
