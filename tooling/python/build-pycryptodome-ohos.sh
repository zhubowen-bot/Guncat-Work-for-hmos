#!/usr/bin/env bash
# Guncat Work: 交叉编译 PyCryptodome（AES / RSA / ECC / SHA3 / HMAC）
#
# 相比 numpy/pandas/matplotlib 简单得多：sdist 自带 C 源码，setuptools 直接编，
# 不需要 BLAS/Fortran，也不依赖第三方 C 库。
#
# 唯一的坑：**PyCryptodome 用 ctypes 按路径加载自己的 .so**（`Crypto/Util/_raw_api.py`
# 里 `load_pycryptodome_raw_lib`），路径由 `Crypto/Util/_file_system.py` 拼出来。
# 设备上 .so 只能放在应用 lib 目录，必须让那个函数也去 libs 找 —— 脚本会就地打补丁，
# 运行时靠 `sitecustomize` 导出的 `GUNCAT_PY_LIBDIR` 环境变量定位。
#
# 用法: bash tooling/python/build-pycryptodome-ohos.sh [版本, 默认 3.21.0]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
VER="${1:-3.21.0}"
WORK="${WORK:-$HOME/ohos-py-crypto}"
NP="${NPWORK:-$HOME/ohos-py-np}"
TC="${TC:-/opt/ohos-cmdline/command-line-tools/sdk/default/openharmony/native}"
CLANG="$TC/llvm/bin/aarch64-unknown-linux-ohos-clang"
STRIP="$TC/llvm/bin/llvm-strip"
LIBS="$PROJ/entry/libs/arm64-v8a"
ROOTFS="$NP/alpine-a64"
PYINC="${PYINC:-/root/cpython-ohos/dest/usr/local/include/python3.12}"
PYLIB="${PYLIB:-/root/cpython-ohos/dest/usr/local/lib}"
EXTRAS="${EXTRAS:-/root/extras}"

mkdir -p "$WORK"
cd "$WORK"
if [ ! -d "pycryptodome-$VER" ]; then
  URL=$(curl -s "https://pypi.org/pypi/pycryptodome/$VER/json" | \
    python3 -c "import sys,json;d=json.load(sys.stdin);print([u['url'] for u in d['urls'] if u['packagetype']=='sdist'][0])")
  curl -sL -o "pcd.tar.gz" "$URL"
  tar xzf pcd.tar.gz
fi
cd "pycryptodome-$VER"

export CC="$CLANG"
export LDSHARED="$CLANG --sysroot=$TC/sysroot -shared -fuse-ld=lld"
export CFLAGS="--sysroot=$TC/sysroot -O2 -fPIC -I$PYINC"
export LDFLAGS="--sysroot=$TC/sysroot -fuse-ld=lld -L$PYLIB"
rm -rf build
"$ROOTFS/run-python.sh" setup.py build_ext --inplace

# ---------- 打包（双层布局） ----------
rm -rf "$LIBS/Crypto" && mkdir -p "$LIBS/Crypto"
( cd lib/Crypto && find . -name '*.so' | while read -r f; do
    mkdir -p "$LIBS/Crypto/$(dirname "$f")"; cp -f "lib/Crypto/$f" "$LIBS/Crypto/$f"; done )
find "$LIBS/Crypto" -name '*.so' -exec "$STRIP" --strip-unneeded {} \; 2>/dev/null || true

mkdir -p "$EXTRAS"
rm -rf "$EXTRAS/Crypto"
cp -r lib/Crypto "$EXTRAS/Crypto"
find "$EXTRAS/Crypto" -name '*.so' -delete

# 打补丁: 让 _file_system.py 在找不到包内 .so 时回落到应用 lib 目录
python3 - "$EXTRAS/Crypto/Util/_file_system.py" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
i = t.find('def pycryptodome_filename')
assert i > 0
p.write_text(t[:i] + '''def pycryptodome_filename(dir_comps, filename):
    """Return the complete file name for the module"""

    if dir_comps[0] != "Crypto":
        raise ValueError("Only available for modules under 'Crypto'")

    rel = os.path.join("Crypto", *(list(dir_comps[1:]) + [filename]))
    pkg_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    candidates = [os.path.join(pkg_root, rel)]
    libdir = os.environ.get("GUNCAT_PY_LIBDIR", "")
    if libdir:
        candidates.append(os.path.join(libdir, rel))
    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate
    return candidates[0]
''')
PY

echo "== 产物"
du -sm "$LIBS/Crypto" "$EXTRAS/Crypto" | awk '{print $2, $1"MB"}'
echo "== Crypto 的 .py 需要在 extras.zip 里（已放到 $EXTRAS/Crypto）"
