#!/usr/bin/env python3
"""检查「随包第三方库」与「许可声明」是否一一对应（防止发了包却漏了许可）。

用法:
    python3 tooling/license-check.py            # 只报告
    python3 tooling/license-check.py --strict   # 有缺失返回 1（打包门槛用）

检查对象：
1. `entry/libs/arm64-v8a/` 下的每个包目录 / 动态库 —— 必须在 `THIRD_PARTY_NOTICES.md` 里出现名字；
2. `rawfile/python/site-packages.zip` 里的顶层包 —— 同上（排除我们自己的工具）；
3. `THIRD_PARTY_NOTICES.md` 里引用的 `LICENSES/...` 或 `docs/legal/...` 文件必须真实存在。

"出现名字"用的是宽松匹配（忽略大小写、- 与 _），因为许可文档里通常写的是包名而不是目录名。
"""

from __future__ import annotations

import pathlib
import re
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIBS = ROOT / "entry/libs/arm64-v8a"
SITE_ZIP = ROOT / "entry/src/main/resources/rawfile/python/site-packages.zip"
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"

# 我们自己写的/非第三方: 不要求许可条目
OWN = {
    "libpython3.12.so", "libexecinfo_stub.so", "guncat_net.py", "guncat_fonts.py",
    "sitecustomize.py", "cacert.pem", "python312.zip", "site-packages.zip", "extras.zip",
    "libgfortran.so.5", "libgcc_s.so.1", "libmvec.so.1",  # 本项目自写的替身库
}
# 系统/工具链自带, 已在别处声明
SYSTEM_LIBS = {
    "libc.so", "libm.so", "libdl.so", "libz.so", "libssl.so.3", "libcrypto.so.3",
    "libsqlite3.so", "libbz2.so", "liblzma.so.5", "libffi.so.8", "libjpeg.so.62",
    "libpng16.so.16", "libfreetype.so.6", "libqhull_r.so.8", "libxml2.so.2",
    "libxslt.so.1", "libexslt.so.0", "liblzma.so.5", "libc++_shared.so",
}
# 目录名 → 许可文档里的写法（少数对不上的在这里映射）
ALIASES = {
    "PIL": "pillow",
    "Crypto": "pycryptodome",
    "yaml": "pyyaml",
    "docx": "python-docx",
    "pptx": "python-pptx",
    "bs4": "beautifulsoup4",
    "dateutil": "python-dateutil",
    "sklearn": "scikit-learn",
    "matplotlib": "matplotlib",
    "mpl_toolkits": "matplotlib",
    "fontTools": "fonttools",
    "wx": "wxpython",
}


def norm(text: str) -> str:
    return re.sub(r"[-_.\s]", "", text.lower())


def packages_in_libs() -> set[str]:
    names = set()
    if not LIBS.is_dir():
        return names
    for item in LIBS.iterdir():
        if item.is_dir():
            if item.name not in OWN:
                names.add(item.name)
            continue
        # 根目录的 .so: CPython 自带扩展模块(array/math/_ssl...)统一由 CPython 那条许可覆盖,
        # 只有明确属于第三方库的才需要单独声明(在 SYSTEM_LIBS / 通知文档里点名)。
        name = item.name
        if ".cpython-" in name:
            continue
        if name in OWN or name in SYSTEM_LIBS:
            continue
        names.add(name.split(".so")[0])
    return names


def packages_in_site_zip() -> set[str]:
    names = set()
    if not SITE_ZIP.is_file():
        return names
    try:
        with zipfile.ZipFile(SITE_ZIP) as zf:
            for entry in zf.namelist():
                top = entry.split("/")[0]
                if not top or top.startswith("__pycache__"):
                    continue
                if top.endswith((".py", ".pth")):
                    continue
                names.add(top)
    except zipfile.BadZipFile:
        pass
    return names


def main() -> int:
    strict = "--strict" in sys.argv
    notices = NOTICES.read_text(encoding="utf-8", errors="replace")
    haystack = norm(notices)
    problems = []

    candidates = packages_in_libs() | packages_in_site_zip()
    for name in sorted(candidates):
        key = ALIASES.get(name, name)
        if key.endswith(".dist-info") or key.endswith(".data"):
            continue
        if norm(key) in haystack:
            continue
        problems.append("随包但许可文档里找不到: %s" % name)

    for match in re.finditer(r"`((?:LICENSES|docs/legal)/[^`]+)`", notices):
        target = ROOT / match.group(1)
        if not target.is_file():
            problems.append("许可文档引用了不存在的文件: %s" % match.group(1))

    print("检查 %d 个随包组件, 许可文档 %d 字节" % (len(candidates), len(notices)))
    if not problems:
        print("全部有对应声明")
        return 0
    print("发现 %d 个问题:" % len(problems))
    for item in problems:
        print("  -", item)
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
