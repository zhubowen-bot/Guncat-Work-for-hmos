"""Guncat Work 自带: 中文字体支持（matplotlib / Pillow 都能直接写中文）。

应用随包带了一份 **Source Han Sans SC**(思源黑体, OFL-1.1, 已按 GB2312 子集化到约 3.4MB),
放在运行目录的 `fonts/` 下。用法：

    import guncat_fonts
    guncat_fonts.use_cjk()                # 注册给 matplotlib 并设为默认字体
    font = guncat_fonts.pillow_font(24)   # Pillow 用的 ImageFont

matplotlib 一旦 import 过 `matplotlib.font_manager`, 本模块会**自动注册**一次,
所以多数情况下你什么都不用做, 直接 `plt.title("中文")` 就能显示。

注意: 子集只覆盖 GB2312(6763 汉字 + 常用符号)。生僻字/扩展 B 区会显示成方块,
那种情况请自带字体: `guncat_fonts.use_cjk("/path/your.ttf")`。
"""

from __future__ import annotations

import os
import sys

FONT_NAME = "SourceHanSansSC-Regular.otf"
_FONT_FAMILY = "Source Han Sans SC"

_cached_path = None
_registered = False


def _candidates():
    seen = []
    env_dir = os.environ.get("GUNCAT_FONT_DIR")
    if env_dir:
        seen.append(env_dir)
    # 运行目录: python312.zip 的同级 fonts/
    for entry in sys.path:
        if not entry:
            continue
        base = os.path.dirname(entry) if os.path.isfile(entry) or entry.endswith(".zip") else entry
        if base:
            seen.append(os.path.join(base, "fonts"))
    # 本模块同级/上级
    here = os.path.dirname(os.path.abspath(__file__))
    seen.append(os.path.join(here, "fonts"))
    seen.append(os.path.join(os.path.dirname(here), "fonts"))
    return seen


def path() -> str | None:
    """返回随包中文字体路径; 找不到返回 None。"""
    global _cached_path
    if _cached_path and os.path.isfile(_cached_path):
        return _cached_path
    for directory in _candidates():
        candidate = os.path.join(directory, FONT_NAME)
        if os.path.isfile(candidate):
            _cached_path = candidate
            return candidate
    return None


def use_cjk(extra_font: str | None = None, family: str | None = None) -> str | None:
    """把随包中文字体注册进 matplotlib 并设为默认。返回实际使用的字体路径。"""
    global _registered
    chosen = path()
    if extra_font:
        chosen = extra_font
    if not chosen or not os.path.isfile(chosen):
        return None
    try:
        from matplotlib import font_manager, rcParams
    except BaseException:
        return chosen
    try:
        font_manager.fontManager.addfont(chosen)
        # 字体真正的 family 名以文件里的 name 表为准(子集化后我们的常量未必对得上),
        # 拿不到才退回常量 —— 名字对不上时 matplotlib 会静默退回 DejaVu, 中文变方块。
        name = family
        if not name:
            try:
                name = font_manager.FontProperties(fname=chosen).get_name()
            except BaseException:
                name = None
            if not name or name.lower() in ("dejavu sans", "sans"):
                name = _FONT_FAMILY
        rcParams["font.family"] = ["sans-serif"]
        rcParams["font.sans-serif"] = [name, "DejaVu Sans"]
        rcParams["axes.unicode_minus"] = False
        _registered = True
    except BaseException:
        pass
    return chosen


def pillow_font(size: int = 20, index: int = 0):
    """Pillow 的 ImageFont 对象(默认用随包中文字体)。"""
    from PIL import ImageFont
    chosen = path()
    if not chosen:
        return ImageFont.load_default()
    return ImageFont.truetype(chosen, size, index=index)


def _install_auto_hook() -> None:
    """matplotlib.font_manager 一被 import 就自动注册中文字体。

    用 sys.addaudithook 监听 'import' 事件 —— 它在 import 完成**之后**触发,
    此时 font_manager 已就绪, 可以安全 addfont。任何异常都吞掉:
    自动失效时用户仍可显式调用 use_cjk()。
    """
    if os.environ.get("GUNCAT_FONT_AUTO", "1") in ("0", "false", "no"):
        return
    if path() is None:
        return

    try:
        import sys as _sys

        def _hook(event, args):
            if event != "import" or not args:
                return
            name = args[0]
            if name in ("matplotlib.font_manager", "matplotlib.pyplot"):
                try:
                    if not _registered:
                        use_cjk()
                except BaseException:
                    pass

        _sys.addaudithook(_hook)
    except BaseException:
        pass


_install_auto_hook()
