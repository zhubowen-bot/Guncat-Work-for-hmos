#!/usr/bin/env python3
"""静态检查随包 `.so` 的依赖闭合性 —— 专门堵住"qemu 能跑、真机加载失败"这类盲区。

背景（真机实测踩到的三个坑）：
1. **soname 对不上**：`PIL/_imaging.so` 的 DT_NEEDED 写的是 `libz.so.1`，而我们只发了 `libz.so`，
   设备上直接 `Error loading shared library libz.so.1`。qemu 验证时 Alpine rootfs 里正好有
   `libz.so.1`，把问题遮住了。
2. **扩展缺 DT_NEEDED libpython**：lxml/regex/scipy/PIL 等是 setuptools/meson 直接链的，
   没有 `-lpython3.12`；设备上解不到 `PyErr_NoMemory` 这类符号（真机报 symbol not found）。
3. **链进了 glibc**：Fortran 目标的链接走了 gfortran 驱动，DT_NEEDED 变成 `libc.so.6`/`libm.so.6`，
   musl 上根本不存在这些名字。

这三类都不需要设备就能查出来 —— 本脚本扫一遍 `entry/libs/arm64-v8a` 即可：
- 每条 DT_NEEDED 要么能在 libs 里找到同名文件，要么在"系统提供"白名单里（libc.so/libm.so…）；
- 每个"Python 扩展"（导出 `PyInit_*` 的 .so）必须有 DT_NEEDED `libpython3.12.so`；
- 不允许出现 glibc 专有 soname（libc.so.6 / libm.so.6 / ld-linux-*）。

用法:
    python3 tooling/python/check-sonames.py            # 只报告
    python3 tooling/python/check-sonames.py --strict   # 有问题返回 1（打包门槛用）
"""

from __future__ import annotations

import os
import pathlib
import re
import shutil
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
LIBS = ROOT / "entry/libs/arm64-v8a"

# 设备系统(musl)本来就会提供的名字, 不要求随包
SYSTEM_PROVIDED = {"libc.so", "libm.so", "libdl.so", "libpthread.so", "librt.so",
                   "libutil.so", "libresolv.so", "libstdc++.so", "libgcc_s.so.1"}
# 明确禁止: glibc 专有 soname, 在 OHOS 上不存在
FORBIDDEN = {"libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2", "librt.so.1"}

PY_INIT = re.compile(rb"PyInit_[A-Za-z0-9_]+")


LLVM_CANDIDATES = [
    "/opt/ohos-cmdline/command-line-tools/sdk/default/openharmony/native/llvm/bin/llvm-readelf",
    "/usr/lib/llvm-15/bin/llvm-readelf",
    "llvm-readelf",
]


def _readelf_bin() -> str | None:
    """找 llvm-readelf。Windows 的 SDK 里带 .exe 后缀，不能只拼无后缀名。"""
    env = os.environ.get("GUNCAT_LLVM_BIN")
    search = ([env] if env else []) + [
        os.path.dirname(p) for p in LLVM_CANDIDATES if os.path.dirname(p)
    ]
    for directory in search:
        for name in ("llvm-readelf", "llvm-readelf.exe"):
            candidate = os.path.join(directory, name)
            if os.path.isfile(candidate):
                return candidate
    return shutil.which("llvm-readelf") or shutil.which("llvm-readelf.exe")


def readelf(path: pathlib.Path, dyn: bool = True) -> str:
    binary = _readelf_bin()
    if binary is None:
        return ""
    cmd = [binary]
    if dyn:
        cmd.append("-d")
    cmd.append(str(path))
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False).stdout
    except FileNotFoundError:
        return ""


def needed(path: pathlib.Path) -> list[str]:
    out = readelf(path)
    return re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", out)


def has_py_init(path: pathlib.Path) -> bool:
    try:
        data = path.read_bytes()
    except OSError:
        return False
    return bool(PY_INIT.search(data))


def main() -> int:
    strict = "--strict" in sys.argv
    if not LIBS.is_dir():
        print("找不到 %s" % LIBS)
        return 2 if strict else 0
    if _readelf_bin() is None:
        print("找不到 llvm-readelf：请把它加入 PATH，或设 GUNCAT_LLVM_BIN 指向其目录")
        print("（Windows 的 DevEco SDK 里是 ...\\native\\llvm\\bin\\llvm-readelf.exe）")
        return 2

    shipped = {p.name for p in LIBS.iterdir() if p.is_file()}
    problems = []
    checked = 0

    for so in sorted(LIBS.rglob("*.so*")):
        if not so.is_file() or ".so." in so.name and so.name.startswith("lib"):
            pass
        checked += 1
        deps = needed(so)
        rel = so.relative_to(LIBS)
        for dep in deps:
            if dep in FORBIDDEN:
                problems.append("%s 依赖 glibc 专有的 %s（设备上不存在）" % (rel, dep))
                continue
            if dep in shipped or dep in SYSTEM_PROVIDED:
                continue
            # 包内同级目录里的 .so（scipy/special/libsf_error_state.so 这类）由 $ORIGIN 满足
            if (so.parent / dep).is_file():
                continue
            problems.append("%s 需要 %s，但 libs 里没有同名文件" % (rel, dep))
        # libpython 本身当然不需要 DT_NEEDED 自己
        is_libpython = so.name.startswith("libpython")
        if not is_libpython and has_py_init(so) and "libpython3.12.so" not in deps:
            problems.append("%s 是 Python 扩展但没有 DT_NEEDED libpython3.12.so" % rel)

    print("检查 %d 个 .so，随包库 %d 个" % (checked, len(shipped)))
    if not problems:
        print("依赖闭合，无 glibc 泄漏")
        return 0
    print("发现 %d 个问题:" % len(problems))
    for item in problems[:40]:
        print("  -", item)
    if len(problems) > 40:
        print("  ... 其余 %d 条省略" % (len(problems) - 40))
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
