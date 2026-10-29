#!/bin/bash
# build_numpy.sh — 交叉编译 numpy(CPython 3.12 / aarch64-linux-ohos / musl)
#
# 产物(默认 NUMPY_LAYOUT=flat,老形态):
#   build/numpy-<abi>/build-install/…                meson install 结果
#   feature/bsh_main/libs/<abi>/numpy__*.so                     C 扩展(平铺,随 HAP 进设备)
#   feature/bsh_main/src/main/resources/rawfile/tools/numpy.tar 纯 Python 部分 + sitecustomize.py
#
# NUMPY_LAYOUT=wheel 时改成产出 pip 能装的 wheel(见 §3b):
#   dist/pkgs/numpy-<ver>-cp312-cp312-linux_aarch64.whl
#   —— 为什么需要这一形态:设备上 `pip install numpy` **不可能**成功。我们的平台 tag 是
#      `cp312-cp312-harmonyos_hongmeng_kernel_1_13_0_aarch64`(实测 tags.sys_tags()),
#      PyPI 上没有这种 wheel,pip 于是退回 sdist 现场构建,而设备上没有 make/cmake/ninja
#      (实测 "Could not find a make program")。numpy 只能由宿主机交叉编好、打成 wheel 交付。
#
# 用法:./scripts/build_numpy.sh        (幂等:产物已存在则跳过构建)
#
# 前置:
#   - scripts/build_python.sh 已跑(build/python/… 提供**目标** python 的 include/pyconfig)
#   - host 只需要 cython>=3.1(numpy 的 .pyx 要现场生成):
#       python3.12 -m venv ~/.venvs/numpy
#       ~/.venvs/numpy/bin/pip install 'cython>=3.1'
#       export PATH=~/.venvs/numpy/bin:$PATH      # 必须前置,脚本按 PATH 取 python3/cython
#     meson 不用装:numpy 自带 vendored-meson(它多带一个 meson_cpu 要用的 features
#     模块,宿主那版没有 → 会报 Module "features" does not exist),脚本直接用它的。
#
# 为什么"平铺 + 名字混淆"(与 build_pyqt.sh 同一套理由):
#   * app 数据目录($HOME)是 noexec ⇒ 扩展 .so 只能进 bundle 的 libs/<abi>/;
#   * 那里 hvigor 只收**平铺**的 .so(子目录会被丢掉)⇒ numpy 的扩展分散在
#     numpy/、numpy/_core/、numpy/linalg/、numpy/random/、numpy/fft/、numpy/ma/
#     等多层嵌套包里,逐层给 __path__ 前插太脆;
#   * 于是约定 模块 a.b.c → <libs>/a__b__c.so(文件名随意,CPython 找的是
#     PyInit_c),由 scripts/sitecustomize.py 里的 meta path finder 兜底导入。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

NUMPY_VER="${NUMPY_VER:-2.5.3}"
NUMPY_SRC_DIR="${NUMPY_SRC_DIR:-$ROOT/thirdparty/numpy-src}"
NUMPY_SRC="$NUMPY_SRC_DIR/numpy-$NUMPY_VER"
NUMPY_TAR="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools/numpy.tar"
NUMPY_WB="$BUILD_DIR/numpy-$NATIVE_ARCH"
# 交付形态:flat(默认,平铺 so + tar 随 HAP 走)| wheel(打成 pip 能装的 wheel,见 §3b)
NUMPY_LAYOUT="${NUMPY_LAYOUT:-flat}"
# wheel 的平台 tag。**不**用设备实测的 `harmonyos_hongmeng_kernel_<版本>_aarch64` ——
# 那个 tag 里带内核版本号，换台设备/升个系统就变，写进轮子名等于给自己绑死。
# 而 pip 从**本地** find-links 装包时只做"tag 有没有交集"这一道检查，`py3-none-any`
# 必然在 `sys_tags()` 里，于是任何设备都能装上；WHEEL 里的 `Root-Is-Purelib: false`
# 是从 PyPI 模板抄来的，保证它进 platlib（site-packages）而不是 purelib。
# （想换成真实 tag 就用 NUMPY_WHEEL_TAG= 覆盖。）
# 试过的另一条路走不通：PIP_PLATFORM/PIP_ONLY_BINARY 会被 pip 26 拒掉 ——
# "Can not use any platform or abi specific options unless installing via '--target'"。
NUMPY_WHEEL_TAG="${NUMPY_WHEEL_TAG:-py3-none-any}"
NUMPY_WHEEL_OUT="${NUMPY_WHEEL_OUT:-$ROOT/dist/pkgs}"
CROSS_FILE="$BUILD_DIR/numpy-cross-$NATIVE_ARCH.txt"
# 目标 python(我们自己的 CPython 构建树;宿主的 3.12 sysconfig 指向 /usr/include,不能用)
PY_SRC="${PY_SRC:-$BUILD_DIR/python/src/Python-3.12.14}"
PY_BUILD="${PY_BUILD:-$BUILD_DIR/python/cpython-build}"
PY_SERIES="${PY_SERIES:-3.12}"

mkdir -p "$BUILD_DIR" "$HAP_LIBS_DIR" "$NUMPY_SRC_DIR" "$(dirname "$NUMPY_TAR")"

# ══════════════════════════════════════════════════════════
# 0. 源码(sdist,缓存;PyPI 取最新同级版本地址)
# ══════════════════════════════════════════════════════════
fetch_src() {
    local tgz="$NUMPY_SRC_DIR/numpy-$NUMPY_VER.tar.gz"
    if [ ! -s "$tgz" ]; then
        log "下载 numpy $NUMPY_VER sdist"
        local url
        url="$(curl -sL --retry 3 --max-time 120 "https://pypi.org/pypi/numpy/$NUMPY_VER/json" \
            | python3 -c 'import json,sys
urls=[u["url"] for u in json.load(sys.stdin)["urls"] if u["packagetype"]=="sdist"]
print(urls[0] if urls else "")')" || true
        [ -n "$url" ] || err "取不到 numpy $NUMPY_VER 的 sdist 地址"
        curl -sL --retry 3 --max-time 900 -o "$tgz" "$url" || err "numpy 下载失败: $url"
    fi
    [ -d "$NUMPY_SRC" ] || tar xzf "$tgz" -C "$NUMPY_SRC_DIR"
    [ -f "$NUMPY_SRC/meson.build" ] || err "numpy 源码结构异常: $NUMPY_SRC"
    log "numpy 源码: $NUMPY_SRC"
}

# ══════════════════════════════════════════════════════════
# 1. 前置检查(目标 python 头 / cython / sitecustomize)
# ══════════════════════════════════════════════════════════
check_prereq() {
    [ -f "$PY_SRC/Include/Python.h" ] || err "缺 Python 头 $PY_SRC/Include(先跑 scripts/build_python.sh)"
    [ -f "$PY_BUILD/pyconfig.h" ] || err "缺 pyconfig.h $PY_BUILD(先跑 scripts/build_python.sh)"
    command -v cython >/dev/null 2>&1 || err "缺 cython>=3.1(numpy 的 .pyx 要现场生成):
      python3.12 -m venv ~/.venvs/numpy && ~/.venvs/numpy/bin/pip install 'cython>=3.1'
      然后 export PATH=~/.venvs/numpy/bin:\$PATH 再跑本脚本"
    cython --version 2>&1 | head -1 | sed 's/^/cython: /'
    # meson 用 numpy 自带的 vendored-meson:meson_cpu 的 `import('features')` 只有它
    # 那份带(宿主 meson 会报 Module "features" does not exist)。没有才退回 PATH 上的,
    # 并要求版本达标(numpy 2.5 要 >=1.8.3)。
    VENDORED_MESON=""
    if [ -f "$NUMPY_SRC/vendored-meson/meson/meson.py" ]; then
        VENDORED_MESON="$NUMPY_SRC/vendored-meson/meson/meson.py"
        log "meson: 用 numpy 自带 vendored-meson(含 features 模块)"
    else
        local meson_ver meson_min="${NUMPY_MESON_MIN:-1.8.3}"
        command -v meson >/dev/null 2>&1 || err "缺 meson且源码里没有 vendored-meson"
        meson_ver="$(meson --version 2>/dev/null || echo 0)"
        [ "$(printf '%s\n%s\n' "$meson_min" "$meson_ver" | sort -V | tail -1)" = "$meson_ver" ] \
            || err "meson $meson_ver 太旧,numpy 需要 >= $meson_min"
        log "meson: PATH 上的 $meson_ver"
    fi
    log "ninja $(ninja --version 2>/dev/null || echo '?')"
    [ -f "$SCRIPT_DIR/sitecustomize.py" ] || err "缺 $SCRIPT_DIR/sitecustomize.py(平铺扩展的导入兜底)"
}

# ══════════════════════════════════════════════════════════
# 2. 交叉配置 + 编译 + 安装(驱动 meson,不走 pip/meson-python)
# ══════════════════════════════════════════════════════════
build_numpy() {
    local inst="$NUMPY_WB/build-install"
    # 幂等:只看 install 树里有没有 numpy 包目录,不写死中间布局(见 layout 的说明)。
    # 不用 `find … | grep -q .`:pipefail 下 grep 提前退出会让 find 收 SIGPIPE → 误判。
    if [ -n "$(find "$inst" -maxdepth 6 -type d -name numpy -print -quit 2>/dev/null)" ]; then
        log "numpy 已构建,跳过(删 $NUMPY_WB 可重来)"; return
    fi
    log "=== 构建 numpy ($NATIVE_ARCH) ==="
    # long double 表示法(numpy 交叉编译必须注入,见交叉文件里的说明)
    case "$NATIVE_ARCH" in
        arm64-v8a) NUMPY_LDOUBLE_FMT="${NUMPY_LDOUBLE_FMT:-IEEE_QUAD_LE}" ;;      # aarch64: binary128 小端
        x86_64)    NUMPY_LDOUBLE_FMT="${NUMPY_LDOUBLE_FMT:-IEEE_EXTENDED_LE}" ;;  # x86 80-bit(本工程没验证)
        *)         err "未知 NATIVE_ARCH=$NATIVE_ARCH" ;;
    esac
    # 交叉文件按 build_wayland.sh 的写法在脚本里生成
    cat > "$CROSS_FILE" <<EOF
[binaries]
# 目标 python 的 include 必须放在**编译器参数**里:c_args 会被 meson 排在
# 依赖注入的 -I 之后,而 meson 的 python 依赖是从宿主 python 的 sysconfig 取
# include 的(-I/usr/include/python3.12),先命中它会去 include 不存在的
# aarch64-linux-gnu/python3.12/pyconfig.h 而编译失败。编译器参数排在所有 -I 之前,
# 先命中者胜 → 用的是我们 build/python 那份 Python.h/pyconfig.h。
c          = ['$CLANG', '--target=$TARGET', '--sysroot=$SYSROOT', '-I$PY_BUILD', '-I$PY_SRC/Include']
cpp        = ['$CLANGXX', '--target=$TARGET', '--sysroot=$SYSROOT', '-I$PY_BUILD', '-I$PY_SRC/Include']
ar         = '$CLANG_DIR/llvm-ar'
strip      = '$CLANG_DIR/llvm-strip'
ranlib     = '$CLANG_DIR/llvm-ranlib'
pkg-config = 'pkg-config'

[built-in options]
# 目标 python 的头/pyconfig 用我们自己的构建树;libpython 不进 LINK 搜索路径的
# 常规位置,而是靠 -L$HAP_LIBS_DIR -lpython 记一条 NEEDED(运行期由宿主已加载的
# libpython.so 解析 —— procmgr 是 RTLD_LOCAL dlopen,不能指望全局符号表)。
c_args        = ['-O2', '-fPIC', '-D__MUSL__=1', '-DOHOS_NDK', '-I$PY_BUILD', '-I$PY_SRC/Include']
cpp_args      = ['-O2', '-fPIC', '-D__MUSL__=1', '-DOHOS_NDK', '-I$PY_BUILD', '-I$PY_SRC/Include']
c_link_args   = ['-L$HAP_LIBS_DIR', '-lpython', '-Wl,--unresolved-symbols=ignore-all']
cpp_link_args = ['-L$HAP_LIBS_DIR', '-lpython', '-Wl,--unresolved-symbols=ignore-all']

[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$SYSROOT_EXT_PC'
sys_root = '$SYSROOT'
# numpy 的 long double 表示法:拿不到这个属性它会去"跑"一个目标程序探测 →
# 交叉下 meson 直接报 "Can not run test applications in this cross environment"。
# aarch64 = IEEE 754 binary128 小端。
longdouble_format = '$NUMPY_LDOUBLE_FMT'

[host_machine]
system     = 'linux'
cpu_family = 'aarch64'
cpu        = 'aarch64'
endian     = 'little'
EOF
    case "$NATIVE_ARCH" in
        x86_64) sed -i "s/cpu_family = 'aarch64'/cpu_family = 'x86_64'/; s/^cpu        = 'aarch64'/cpu        = 'x86_64'/" "$CROSS_FILE" ;;
    esac

    rm -rf "$NUMPY_WB"; mkdir -p "$NUMPY_WB"
    # meson 入口:优先 numpy 自带的 vendored-meson(见 check_prereq 的说明)
    local meson_cmd
    if [ -n "$VENDORED_MESON" ]; then
        meson_cmd=("$(command -v python3)" "$VENDORED_MESON")
    else
        meson_cmd=("$(command -v meson)")
    fi
    # 宿主 pkg-config 只应看到 sysroot-ext;交叉侧由 pkg_config_libdir 提供
    env -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_SYSROOT_DIR \
        "${meson_cmd[@]}" setup "$NUMPY_WB/build" "$NUMPY_SRC" \
            --cross-file "$CROSS_FILE" \
            --prefix="$inst" --libdir=lib \
            --buildtype=release \
            -Ddisable-optimization=true \
            > "$NUMPY_WB/meson-setup.log" 2>&1 \
        || { tail -40 "$NUMPY_WB/meson-setup.log" >&2; err "meson setup 失败(日志 $NUMPY_WB/meson-setup.log)"; }
    ninja -C "$NUMPY_WB/build" -j"$JOBS" > "$NUMPY_WB/ninja.log" 2>&1 \
        || { tail -40 "$NUMPY_WB/ninja.log" >&2; err "numpy 编译失败(日志 $NUMPY_WB/ninja.log)"; }
    ninja -C "$NUMPY_WB/build" install > "$NUMPY_WB/install.log" 2>&1 \
        || { tail -40 "$NUMPY_WB/install.log" >&2; err "numpy install 失败"; }
    log "numpy → $inst"
}

# ── 3b. NUMPY_LAYOUT=wheel:打成 pip 能装的 wheel ──────────────
#
# 布局就是"install 树里那个 numpy 包目录 + 一份 dist-info":
#   METADATA / entry_points.txt 从 PyPI 同版本的 wheel 里抄(与平台无关,抄最准)
#   WHEEL 的 Tag 换成我们自己的(NUMPY_WHEEL_TAG)
#   RECORD 现场生成(逐文件 sha256 + 大小;pip 拿它做卸载与校验)
layout_wheel() {
    local inst="$NUMPY_WB/build-install"
    local pkg
    pkg="$(dirname "$(find "$inst" -maxdepth 6 -type d -name numpy -print -quit 2>/dev/null)")"
    [ -n "$pkg" ] && [ -d "$pkg/numpy" ] || err "install 结果里找不到 numpy 包目录(在 $inst 下)"

    local root="$NUMPY_WB/wheel-root"
    rm -rf "$root"; mkdir -p "$root"
    cp -a "$pkg/numpy" "$root/numpy"
    find "$root" -type d -name tests -prune -exec rm -rf {} + 2>/dev/null || true

    # ⚠ 扩展的 ABI 后缀是 meson 按**宿主** python 的 sysconfig 起的
    # （实测落成 `...cpython-312-x86_64-linux-gnu.so`，尽管内容是交叉编出来的 aarch64），
    # 而设备上的 CPython 是按**自己的** EXT_SUFFIX 去找扩展文件的
    # （`_multiarray_umath.cpython-312-aarch64-linux-gnu.so`）—— 名字对不上就是
    # "ModuleNotFoundError: No module named 'numpy._core._multiarray_umath'"，
    # 而且看不出任何线索。所以在打包前统一改成目标的 EXT_SUFFIX。
    local host_ext target_ext
    host_ext="$(python3 -c 'import sysconfig;print(sysconfig.get_config_var("EXT_SUFFIX") or "")')"
    target_ext="$(sed -n "s/.*'EXT_SUFFIX': '\([^']*\)'.*/\1/p" \
                  "$(find "$PY_BUILD" -name '_sysconfigdata*.py' | head -1)" | head -1)"
    [ -n "$target_ext" ] || err "取不到目标 EXT_SUFFIX（先跑 scripts/build_python.sh）"
    if [ "$host_ext" != "$target_ext" ]; then
        log "扩展后缀：$host_ext → $target_ext"
        while IFS= read -r f; do
            mv "$f" "${f%$host_ext}$target_ext"
        done < <(find "$root" -type f -name "*$host_ext")
    fi
    find "$root" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
    # 扩展 so 去符号:wheel 要往设备传,strip 能省不少(install 树留着原样)
    find "$root" -name '*.so' -type f -exec "$CLANG_DIR/llvm-strip" --strip-unneeded {} + 2>/dev/null || true

    local di="$root/numpy-$NUMPY_VER.dist-info"
    mkdir -p "$di"
    local refwhl="$NUMPY_SRC_DIR/numpy-$NUMPY_VER-ref.whl"
    if [ ! -s "$refwhl" ]; then
        log "取一份 PyPI 的 numpy aarch64 wheel 当 dist-info 模板"
        local url
        url="$(curl -sL --retry 3 --max-time 120 "https://pypi.org/pypi/numpy/$NUMPY_VER/json" \
            | python3 -c 'import json,sys
urls=[u["url"] for u in json.load(sys.stdin)["urls"]
      if u["packagetype"]=="bdist_wheel" and "cp312" in u["filename"] and "aarch64" in u["filename"]]
print(urls[0] if urls else "")')" || true
        [ -n "$url" ] || err "取不到 numpy $NUMPY_VER 的 aarch64 wheel 地址"
        curl -sL --retry 3 --max-time 900 -o "$refwhl" "$url" || err "下载模板 wheel 失败"
    fi
    python3 - "$refwhl" "$di" <<'PY'
import os, sys, zipfile
whl, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(whl) as z:
    for n in z.namelist():
        # 只取顶层 dist-info 里的文本件(RECORD 我们重做,不抄);
        # 以 "/" 结尾的是目录条目,跳过(拿它当文件名会 IsADirectoryError)
        if n.endswith("/") or n.count("/") != 1 or ".dist-info/" not in n:
            continue
        if n.endswith("RECORD"):
            continue
        with open(os.path.join(out, os.path.basename(n)), "wb") as f:
            f.write(z.read(n))
PY
    [ -f "$di/METADATA" ] || err "模板 wheel 里没找到 METADATA"

    python3 - "$di/WHEEL" "$NUMPY_WHEEL_TAG" <<'PY'
import sys
p, tag = sys.argv[1], sys.argv[2]
out = [f"Tag: {tag}" if ln.startswith("Tag:") else ln
       for ln in open(p, encoding="utf-8").read().splitlines()]
open(p, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY

    local wheelfile="$NUMPY_WHEEL_OUT/numpy-$NUMPY_VER-$NUMPY_WHEEL_TAG.whl"
    mkdir -p "$NUMPY_WHEEL_OUT"
    rm -f "$wheelfile"
    python3 - "$root" "$wheelfile" "numpy-$NUMPY_VER.dist-info" <<'PY'
import base64, hashlib, os, sys, zipfile
root, out, di = sys.argv[1], sys.argv[2], sys.argv[3]
rec = []
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dp, _dn, fns in os.walk(root):
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            if rel == f"{di}/RECORD":
                continue
            data = open(p, "rb").read()
            z.writestr(rel, data)
            h = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
            rec.append(f"{rel},sha256={h},{len(data)}")
    rec.append(f"{di}/RECORD,,")
    z.writestr(f"{di}/RECORD", "\n".join(rec) + "\n")
PY
    [ -s "$wheelfile" ] || err "wheel 打包失败"
    log "✅ wheel: $wheelfile ($(du -h "$wheelfile" | cut -f1))"

    # 随 HAP 带一份(文件名必须**规范**:pip 靠 `name-ver-py-abi-plat.whl` 里的 tag
    # 判兼容,名字不合规它会当没看见)。shell.cpp 的 initResource 把它复制到
    # $SYSROOT/pkgs/,.bshrc 里的 PIP_FIND_LINKS 指向那里 —— 于是 `pip install numpy`
    # 从本地就能装上,不必联网、也绕开了"设备上没有编译器"。
    cp -f "$wheelfile" "$HAP_RAWFILE_TOOLS_DIR/$(basename "$wheelfile")"
    log "  已随包: $(basename "$wheelfile")"
}

# ── 3a. NUMPY_LAYOUT=flat(默认):C 扩展平铺进 HAP libs,纯 Python 打进 tar ──
# ══════════════════════════════════════════════════════════
# 3. 交付:C 扩展平铺进 HAP libs,纯 Python 打进 tar
# ══════════════════════════════════════════════════════════
layout() {
    if [ "$NUMPY_LAYOUT" = wheel ]; then layout_wheel; return; fi
    local inst="$NUMPY_WB/build-install"
    local rt="$NUMPY_WB/pyqt-rt-placeholder"
    # numpy 的安装子目录由 meson 按**宿主** python 的 sysconfig 决定(实测落到
    # lib/python3/dist-packages),所以不写死:在 install 树里找 numpy 包目录。
    # 我们对外交付的布局(tar 里的 site-packages/numpy)是脚本自己铺的,与它无关。
    local pkg
    pkg="$(dirname "$(find "$inst" -maxdepth 6 -type d -name numpy -print -quit 2>/dev/null)")"
    [ -n "$pkg" ] && [ -d "$pkg/numpy" ] || err "install 结果里找不到 numpy 包目录(在 $inst 下)"
    log "numpy 包目录: $pkg/numpy"
    log "=== 布局:扩展 → $HAP_LIBS_DIR,纯 Python → $NUMPY_TAR ==="
    local list="$NUMPY_WB/flat-map.txt"
    : > "$list"
    while IFS= read -r so; do
        local sub="${so#$pkg/}"              # numpy/_core/_multiarray_umath.cpython-312-….so
        local dir="${sub%/*}"                # numpy/_core
        local base="${sub##*/}"
        local mod="${base%%.*}"              # _multiarray_umath
        local full="${dir//\//.}.$mod"       # numpy._core._multiarray_umath
        local flat="${full//./__}.so"        # numpy__core___multiarray_umath.so
        cp -f "$so" "$HAP_LIBS_DIR/$flat" || err "复制 $so 失败"
        echo "$flat $full" >> "$list"
    done < <(find "$pkg/numpy" -name '*.so' -type f | sort)
    [ -s "$list" ] || err "numpy 下没找到任何扩展 .so(构建异常?)"

    # 纯 Python 部分(去掉 .so 与测试/缓存):顶层 python/lib/python3.12/site-packages/
    rt="$NUMPY_WB/rt"
    rm -rf "$rt"; mkdir -p "$rt/python/lib/python$PY_SERIES/site-packages"
    cp -a "$pkg/numpy" "$rt/python/lib/python$PY_SERIES/site-packages/"
    find "$rt" -name '*.so' -type f -delete
    find "$rt" -type d -name tests -prune -exec rm -rf {} + 2>/dev/null || true
    find "$rt" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
    cp -f "$SCRIPT_DIR/sitecustomize.py" "$rt/python/lib/python$PY_SERIES/site-packages/"
    tar -C "$rt" -cf "$NUMPY_TAR" python
    log "  扩展 $(wc -l < "$list") 个 → $HAP_LIBS_DIR"
    log "  纯 Python → $NUMPY_TAR ($(du -h "$NUMPY_TAR" | cut -f1))"
}

# ══════════════════════════════════════════════════════════
# 4. 校验
# ══════════════════════════════════════════════════════════
# wheel 形态的校验:架构、导出符号、NEEDED 都对不对
verify_wheel() {
    log "=== 校验(wheel) ==="
    local w
    w="$(ls -t "$NUMPY_WHEEL_OUT"/numpy-"$NUMPY_VER"-*.whl 2>/dev/null | head -1)"
    [ -n "$w" ] || err "没找到 wheel 产物(在 $NUMPY_WHEEL_OUT)"
    local tmp="$NUMPY_WB/wheel-check"
    rm -rf "$tmp"; mkdir -p "$tmp"
    python3 - "$w" "$tmp" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
    local bad=0 nso=0
    while IFS= read -r so; do
        nso=$((nso + 1))
        "$CLANG_DIR/llvm-readelf" -h "$so" 2>/dev/null | grep -q AArch64 \
            || { warn "$(basename "$so") 非 AArch64"; bad=1; }
        "$CLANG_DIR/llvm-readelf" -d "$so" 2>/dev/null \
            | grep -q "Shared library: \[libpython.so\]" \
            || { warn "$(basename "$so") 缺 NEEDED libpython.so(import 会 undefined symbol)"; bad=1; }
    done < <(find "$tmp" -name '*.so' -type f)
    [ "$nso" -gt 0 ] || err "wheel 里一个 .so 都没有"
    [ -f "$tmp/numpy/__init__.py" ] || { warn "wheel 里没有 numpy/__init__.py"; bad=1; }
    # 文件名必须用**目标**的 EXT_SUFFIX：留着宿主那套(x86_64)的话，设备上的 CPython
    # 压根不会去看这些文件（见 layout_wheel 里那段说明）。
    if find "$tmp" -name '*.so' | grep -q 'x86_64'; then
        warn "wheel 里还有按宿主后缀命名的扩展 → 设备上 import 会 ModuleNotFoundError"
        bad=1
    fi
    [ "$bad" = 0 ] || err "wheel 校验未通过(见上面 warn)"
    log "✅ 校验通过:$nso 个扩展 so"
}

verify() {
    if [ "$NUMPY_LAYOUT" = wheel ]; then verify_wheel; return; fi
    log "=== 校验 ==="
    local list="$NUMPY_WB/flat-map.txt" flat full last arch syms dyn bad=0
    while read -r flat full; do
        last="${full##*.}"
        "$CLANG_DIR/llvm-readelf" -h "$HAP_LIBS_DIR/$flat" > "$NUMPY_WB/.arch" 2>/dev/null || true
        grep -q AArch64 "$NUMPY_WB/.arch" || { warn "$flat 非 AArch64"; bad=1; }
        "$CLANG_DIR/llvm-nm" -D "$HAP_LIBS_DIR/$flat" > "$NUMPY_WB/.syms" 2>/dev/null || true
        grep -qE " (T|W) PyInit_$last\$" "$NUMPY_WB/.syms" \
            || { warn "$flat 未导出 PyInit_$last"; bad=1; }
        "$CLANG_DIR/llvm-readelf" -d "$HAP_LIBS_DIR/$flat" > "$NUMPY_WB/.dyn" 2>/dev/null || true
        grep -q "Shared library: \[libpython.so\]" "$NUMPY_WB/.dyn" \
            || { warn "$flat 缺 NEEDED libpython.so(import 会 undefined symbol)"; bad=1; }
    done < "$list"
    rm -f "$NUMPY_WB/.arch" "$NUMPY_WB/.syms" "$NUMPY_WB/.dyn" 2>/dev/null || true
    [ "$bad" = 0 ] || err "校验未通过(见上面 warn)"
    local nso
    nso="$(tar -tf "$NUMPY_TAR" | grep -c '\.so$' || true)"
    [ "$nso" = "0" ] || err "numpy.tar 里混进了 $nso 个 .so(会被解到 noexec 的 \$HOME)"
    log "✅ 校验通过:$(wc -l < "$list") 个扩展 + 纯 Python 包 + sitecustomize.py"
}

fetch_src
check_prereq
build_numpy
layout
verify
log "✅ build_numpy.sh 完成 ($NATIVE_ARCH)"
