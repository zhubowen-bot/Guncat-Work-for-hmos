#!/usr/bin/env python3
"""给仓库里的 .ps1 补 UTF-8 BOM（Windows PowerShell 5.1 不加 BOM 会把中文按 ANSI 解析，
直接报 "The string is missing the terminator"，与真实问题无关）。

用编辑器改完 .ps1 后跑一次：
    python3 tools/fix-ps1-bom.py
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
fixed = 0
for path in ROOT.rglob("*.ps1"):
    if any(part in {".git", "node_modules", "build", "oh_modules"} for part in path.parts):
        continue
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        continue
    path.write_bytes(b"\xef\xbb\xbf" + raw.decode("utf-8").encode("utf-8"))
    print("BOM 已补:", path.relative_to(ROOT))
    fixed += 1
print("完成, 修正 %d 个文件" % fixed)
sys.exit(0)
