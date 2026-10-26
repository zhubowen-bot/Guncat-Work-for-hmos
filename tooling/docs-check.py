#!/usr/bin/env python3
"""检查 docs/ 与根目录 Markdown 里的相对链接是否还有效（防文档腐化）。

用法:
    python3 tooling/docs-check.py            # 只报告
    python3 tooling/docs-check.py --strict   # 有坏链就返回 1(进 CI/打包门槛用)

检查两类：
1. `[文字](相对路径)` —— 目标文件必须存在；
2. `[文字](#锚点)` / 同文件锚点 —— 目标标题必须存在（中文标题按 GitHub 规则转 slug）。
外部链接(http/https)与纯锚点不检查网络可达性。
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
HEADING_RE = re.compile(r"^#{1,6}\s+(.*)$", re.M)

SKIP_DIRS = {".git", "node_modules", "build", "oh_modules", ".hvigor", "entry/build"}
# 只检查"我们自己写的"文档: 仓库根 *.md 与 docs/**。
# rawfile/skills/** 是随包技能内容(外部来源), 里面有意留了 {URL} 这类占位符, 不该纳入检查。
CHECK_ROOTS = ("docs",)


def slug(title: str) -> str:
    """GitHub 风格的锚点: 小写、去掉标点、空格转连字符。"""
    text = title.strip().lower()
    text = re.sub(r"[`*_~]", "", text)
    text = re.sub(r"[^\w\u4e00-\u9fff\s-]", "", text)
    text = re.sub(r"\s+", "-", text)
    return text


def markdown_files() -> list[pathlib.Path]:
    files = []
    for path in ROOT.rglob("*.md"):
        rel = path.relative_to(ROOT)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        if len(rel.parts) > 1 and rel.parts[0] not in CHECK_ROOTS:
            continue
        files.append(path)
    return sorted(files)


def strip_code(text: str) -> str:
    """去掉围栏代码块与行内代码: 示例里的 [文字](url) 不是真链接。"""
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    text = re.sub(r"`[^`\n]*`", "", text)
    return text


def loose(text: str) -> str:
    """锚点的宽松形式: 只保留 CJK/字母/数字(GitHub 对中日韩标点的处理与本地不一定一致)。"""
    return re.sub(r"[^0-9a-z\u4e00-\u9fff]", "", text.lower())


def anchors(path: pathlib.Path) -> set[str]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return set()
    return {slug(m.group(1)) for m in HEADING_RE.finditer(text)}


def main() -> int:
    strict = "--strict" in sys.argv
    files = markdown_files()
    broken = []
    checked = 0
    for doc in files:
        text = strip_code(doc.read_text(encoding="utf-8", errors="replace"))
        for raw in LINK_RE.findall(text):
            if raw.startswith(("http://", "https://", "mailto:")):
                continue
            target, _, frag = raw.partition("#")
            checked += 1
            if target:
                dest = (doc.parent / target).resolve()
                if not dest.exists():
                    broken.append((doc.relative_to(ROOT), raw, "文件不存在"))
                    continue
            else:
                dest = doc
            if frag and dest.suffix == ".md":
                if loose(frag) not in {loose(a) for a in anchors(dest)}:
                    broken.append((doc.relative_to(ROOT), raw, "锚点不存在"))

    print("扫描 %d 个 Markdown, 检查 %d 条相对链接" % (len(files), checked))
    if not broken:
        print("全部有效")
        return 0
    print("发现 %d 条问题:" % len(broken))
    for doc, raw, why in broken:
        print("  %s -> %s (%s)" % (doc, raw, why))
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
