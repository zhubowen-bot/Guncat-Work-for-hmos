# sitecustomize.py — 让 CPython 能从 bundle 的平铺 libs 目录导入 C 扩展
#
# 背景(细节见 scripts/build_pyqt.sh / build_numpy.sh 的头部说明):
#   * app 数据目录($HOME,site-packages 就在这里)是 **noexec**,扩展 .so 放那儿
#     没法 dlopen;
#   * bundle 的 libs/<abi>/ 是唯一能映射执行的位置,但 hvigor 只收**平铺**的
#     .so(子目录会被丢掉)—— 所以 numpy/_core/_multiarray_umath.so 这种嵌套
#     位置没法原样保留;
#   * 于是约定:模块 a.b.c 的扩展 → <libs>/a__b__c.so。文件名随便,因为 CPython
#     取的是**模块名最后一段**去找 PyInit_c,与文件名无关。
#
# 这个 finder **追加**在 sys.meta_path 末尾:正常的包/模块查找一律优先,只有
# "包目录里找不到该扩展"时才来平铺目录兜底,所以不会遮蔽任何纯 Python 模块。
# libs 目录不存在时直接不安装(宿主机/本地开发不受影响)。
import os
import sys
import importlib.machinery
import importlib.util

# ── pip 的平台 tag 伪装（实验性，默认关）────────────────────────
#
#     export BSH_PIP_FAKE_PLATFORM=manylinux_2_28_aarch64
#
# 之后 pip 与一切走 packaging.tags 的工具都会按这个名字挑 wheel。
#
# 为什么需要：设备真实的平台名是 `harmonyos-HongMeng Kernel 1.13.0-aarch64`
# （规范化后 harmonyos_HongMeng_Kernel_1_13_0_aarch64），PyPI 上根本没有这种轮子；
# 于是 pip 只会退回 sdist 现场构建，而设备上没有编译器。
#
# 为什么这么写就能生效：CPython 的 sysconfig.get_platform() 直接认
# `_PYTHON_HOST_PLATFORM` 这个 cross-build 用的环境变量（它检查的是"在不在"，
# 所以**千万别把它设成空串**），而 packaging.tags 的平台 tag 就是从那儿取的。
# 实测（pip 26.2 的 vendored packaging，sys.platform == 'linux'）：
#     不设                                      → ['harmonyos_HongMeng_Kernel_1_13_0_aarch64']
#     _PYTHON_HOST_PLATFORM=linux-aarch64        → ['linux_aarch64']
#     _PYTHON_HOST_PLATFORM=manylinux_2_28_aarch64 → ['manylinux_2_28_aarch64']
#
# ⚠ 这样装下来的扩展是给 **glibc** 编的，而这里是 musl 的世界。能不能跑取决于
#   elfloader 的进程内装载器怎么解析符号（见 cpp/shim/README.md §9）—— 简单扩展
#   常常能跑，碰 glibc 专属 API 的就完蛋。属于实验开关，设备默认不开。
_fake_platform = os.environ.get("BSH_PIP_FAKE_PLATFORM", "").strip()
if _fake_platform:
    os.environ["_PYTHON_HOST_PLATFORM"] = _fake_platform


# ── 扩展后缀兼容（跟着上面那个开关走）────────────────────────────
#
# 伪装成 musllinux 装下来的 wheel，里面的扩展名是 `…cpython-312-aarch64-linux-musl.so`
# （构建它的那台 python 的 EXT_SUFFIX），而本机 CPython 只认自己的
# `…cpython-312-aarch64-linux-gnu.so` / `.abi3.so` / `.so`。不改的话 import 直接报
# "No module named '…'" —— 文件明明在，只是名字对不上。
#
# 做法：把另一套后缀也加进 EXTENSION_SUFFIXES，并把 FileFinder 的 path hook 换掉。
# 后半句是必须的：**FileFinder 在 bootstrap 时按当时的后缀列表构造并缓存**，
# 光改 EXTENSION_SUFFIXES 影响不到已经存在的 finder。
def _widen_ext_suffixes():
    import sys as _sys
    import importlib.machinery as _m

    machine = os.uname().machine                      # aarch64
    ver = "%d%d" % _sys.version_info[:2]              # 312
    libc = "musl" if "musl" in _fake_platform.lower() else "gnu"
    extra = ".cpython-%s-%s-linux-%s.so" % (ver, machine, libc)

    have = tuple(_m.EXTENSION_SUFFIXES)
    want = tuple(dict.fromkeys(have + (extra,)))
    if want == have:
        return
    _m.EXTENSION_SUFFIXES = want
    hook = _m.FileFinder.path_hook(
        (_m.SourceFileLoader, _m.SOURCE_SUFFIXES),
        (_m.SourcelessFileLoader, _m.BYTECODE_SUFFIXES),
        (_m.ExtensionFileLoader, want),
    )
    # 插到最前：命中就用我们这套后缀，没命中它会抛 ImportError，后面的 hook 照常接管
    _sys.path_hooks.insert(0, hook)
    _sys.path_importer_cache.clear()


if _fake_platform:
    try:
        _widen_ext_suffixes()
    except Exception:
        pass

# 默认与 build_*.sh 交付目录一致;可用环境变量覆盖(便于在宿主机上自测)。
_LIBS_DIR = os.environ.get("BSH_NATIVE_LIBS_DIR", "/data/storage/el1/bundle/libs/arm64")


class _FlatExtensionFinder:
    """把模块名 a.b.c 映射到 <libs>/a__b__c.so。"""

    def find_spec(self, fullname, path=None, target=None):
        flat = os.path.join(_LIBS_DIR, fullname.replace(".", "__") + ".so")
        if not os.path.isfile(flat):
            return None
        return importlib.util.spec_from_file_location(
            fullname, flat,
            loader=importlib.machinery.ExtensionFileLoader(fullname, flat),
        )


def _install():
    if not os.path.isdir(_LIBS_DIR):
        return
    if any(isinstance(f, _FlatExtensionFinder) for f in sys.meta_path):
        return
    sys.meta_path.append(_FlatExtensionFinder())


_install()
