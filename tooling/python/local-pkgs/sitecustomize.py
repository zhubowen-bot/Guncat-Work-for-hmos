"""让"纯 Python 包在数据目录、C 扩展在应用 lib 目录"这两半能合起来用。

背景: HarmonyOS 上只有应用的 `libs/` 目录里的 `.so` 能被 dlopen, 而 hvigor 打包时**只保留**
`libs/` 里的 `.so`、丢掉 `.py`。于是 numpy / pandas 这类"C 扩展与 .py 混在同一个包"的库,
只能拆成两半: `.py` 放数据目录(zip 解出来), `.so` 留在 `libs/`。

默认的 import 机制找不到这种"跨目录的包": Python 在数据目录里找到 `numpy/__init__.py` 后,
`numpy.__path__` 就只有数据目录, 子模块 `numpy._core._multiarray_umath` 的 `.so` 在 libs 里,
于是 ImportError。

这里的兜底: 把应用 lib 目录里的同名子树也纳入扩展模块的搜索路径 —— 只对
"父包已经加载、但 .so 不在父包目录"的情况生效, 不影响普通导入。
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import sys


def _looks_like_libdir(path: str) -> bool:
    try:
        names = os.listdir(path)
    except OSError:
        return False
    if "libpython3.12.so" in names:
        return True
    return any(n.endswith(".cpython-312-aarch64-linux-gnu.so") for n in names)


def _find_libdir() -> str:
    """找出应用 lib 目录: 里面既有 libpython3.12.so / 扩展模块, 又有 numpy/pandas 的 .so 子树。"""
    candidates = [e for e in sys.path if e and os.path.isdir(e) and _looks_like_libdir(e)]
    for entry in candidates:
        if os.path.isdir(os.path.join(entry, "numpy")) or os.path.isdir(os.path.join(entry, "pandas")):
            return entry
    return candidates[0] if candidates else ""


_LIBDIR = _find_libdir()
if _LIBDIR and _LIBDIR not in sys.path:
    sys.path.append(_LIBDIR)


class _LibsExtensionFinder:
    """按完整模块名在 lib 目录里找扩展模块(PathFinder 失败后的兜底)。"""

    @staticmethod
    def find_spec(fullname, path=None, target=None):
        if not _LIBDIR or not path:
            return None
        parts = fullname.split(".")
        base = os.path.join(_LIBDIR, *parts)
        for suffix in importlib.machinery.EXTENSION_SUFFIXES:
            candidate = base + suffix
            if os.path.isfile(candidate):
                loader = importlib.machinery.ExtensionFileLoader(fullname, candidate)
                return importlib.util.spec_from_file_location(fullname, candidate, loader=loader)
        return None

    @staticmethod
    def invalidate_caches():
        return None


if _LIBDIR:
    # 放在 sys.meta_path 末尾: 只有常规查找失败时才轮到它
    if not any(getattr(f, "__name__", "") == "_LibsExtensionFinder" for f in sys.meta_path):
        sys.meta_path.append(_LibsExtensionFinder())
