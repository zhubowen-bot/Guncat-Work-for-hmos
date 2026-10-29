#!/bin/bash
# build_pyqt.sh — 交叉编译 PyQt6(绑定 + sip 运行时),按本仓库的运行时模型交付
#
# 前置:scripts/fetch_pyqt.sh(源码)+ scripts/build_qt.sh(Qt 产物)+ scripts/build_python.sh
#       (Python 头/libpython —— 与设备上跑的那份 ABI 一致)
#
# 产物:
#   build/pyqt6-build/PyQt6/{QtCore,QtGui,QtWidgets,sip}.so   编译产物
#   feature/bsh_main/libs/<abi>/{QtCore,QtGui,QtWidgets,sip}.so          C 扩展(平铺,随 HAP 进设备)
#   feature/bsh_main/src/main/resources/rawfile/tools/pyqt6.tar          纯 Python 包壳(见下)
#
# 运行时模型 —— 受两条硬约束决定的布局:
#   1) **app 数据目录($HOME)是 noexec**:.so 放那儿没法 dlopen(纯 .py 不受影响,
#      所以 python-stdlib.tar 一直好用)。唯一能被 exec/映射执行的位置是
#      bundle 的 libs/<abi>/(设备侧 /data/storage/el1/bundle/libs/arm64/),
#      而且 hvigor 只收**这一层平铺的 .so**(子目录会被丢掉,名字不要求 lib 前缀)。
#      → 四个 C 扩展平铺进 feature/bsh_main/libs;
#   2) Python 要 `import PyQt6.QtCore` 这种**包限定名**,平铺目录本身表达不了包。
#      → site-packages 里只放一个纯 Python 的 PyQt6/__init__.py(落 $HOME 无所谓,
#        noexec 只挡可执行映射),把平铺目录**前插**进 __path__;这样
#        `from PyQt6 import QtCore` 就去 dlopen <libs>/QtCore.so(扩展 init 符号
#        取模块名最后一段,即 PyInit_QtCore,与文件名 QtCore.so 正好对上)。
#        这本来就是上游支持的用法:PyQt6 自己的 __init__.py 结尾就是
#        `__path__ = pkgutil.extend_path(...)`,我们只是多插一项。
#        (机制已在宿主机用真扩展模块验证过;PyQt6 的 project.py 也写明
#         sip_module='PyQt6.sip' → 平铺的 sip.so 正好满足。)
#   * Qt 库/插件/外部依赖 → 由 build_qt.sh 第 6 段平铺,本脚本不重复带
#     (xkb/weston 数据也不用:weston-terminal 那套已解到 <sysroot>/usr/share 并设了环境变量)。
#
# 仍未验证:sip-build 跑在 python3.11 上也能生成绑定(实测通了),但生成的
# include/ABI 判断来自它的 sysconfig —— 见 fetch_pyqt.sh 的告警,想更稳妥就用
# python3.12 的 venv 跑它。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PYQT_SRC_DIR="$ROOT/thirdparty/pyqt6-src"
PYQT_BUILD_DIR="$BUILD_DIR/pyqt6-build"
PYQT6_VER="${PYQT6_VER:-6.11.0}"
SIP_VER="${SIP_VER:-13.9.1}"
PY_SERIES="${PY_SERIES:-3.12}"            # site-packages 目录名 = python3.12
QT_BUILD="$ROOT/thirdparty/qt-src/qtbase/build-target"
QT_HOST="${QT_HOST:-$ROOT/thirdparty/qt-src/qtbase/build-host}"   # host qmake/moc

PYQT6_SRC="$PYQT_SRC_DIR/pyqt6-$PYQT6_VER"        # PyQt6 sdist 解压
SIP_SRC="$PYQT_SRC_DIR/pyqt6_sip-$SIP_VER"        # PyQt6-sip sdist 解压
# Python 头/库来自 build_python.sh 的构建树(与设备上那份同版本同配置):
#   公共头 $PY_SRC/Include + 生成的 pyconfig.h $PY_BUILD + libpython3.12.a
PY_SRC="${PY_SRC:-$BUILD_DIR/python/src/Python-3.12.14}"
PY_BUILD="${PY_BUILD:-$BUILD_DIR/python/cpython-build}"
PY_INC_DIRS="-I$PY_BUILD -I$PY_SRC/Include"
PY_LIB="$PY_BUILD"

RTAR="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools/pyqt6.tar"

# ── 0. 前置检查 ──────────────────────────────────────────
[ -f "$PYQT6_SRC/pyproject.toml" ] || err "缺 PyQt6 源码(先运行 scripts/fetch_pyqt.sh)"
[ -f "$SIP_SRC/sip.h" ] || err "缺 PyQt6-sip 源码(先运行 scripts/fetch_pyqt.sh)"
[ -d "$QT_BUILD/include" ] || err "缺 Qt 产物(先运行 scripts/build_qt.sh)"
[ -x "$QT_HOST/bin/qmake" ] || err "缺 host qmake:$QT_HOST/bin/qmake(build_qt.sh 第 1 段)"
[ -f "$PY_SRC/Include/Python.h" ] || err "缺 Python 头(先运行 scripts/build_python.sh)"
[ -f "$PY_BUILD/pyconfig.h" ] || err "缺 pyconfig.h:$PY_BUILD(先运行 scripts/build_python.sh)"
command -v sip-build >/dev/null 2>&1 || err "缺 host sip-build(见 fetch_pyqt.sh 的说明)"
# Qt 侧的库/插件必须已经在 feature/bsh_main/libs 里(否则 PyQt6 模块装上也跑不起来)
for f in libQt6Core.so libQt6Gui.so libQt6Widgets.so libqwayland.so libxdg-shell.so; do
    [ -f "$HAP_LIBS_DIR/$f" ] \
        || err "缺 $HAP_LIBS_DIR/$f —— 先跑 scripts/build_qt.sh(它第 6 段负责平铺复制)"
done

# ── 1. sip-build 生成绑定(host qmake 探测)────────────────
# sip-build 必须在项目目录里跑;生成物落在 <src>/build/(--target-dir 只影响
# 编译产物),所以两步都用绝对路径引用,不依赖 cwd。
GEN_DIR="$PYQT6_SRC/build"
if [ "${PYQT_REGEN:-0}" = 1 ] || [ ! -d "$GEN_DIR/QtCore" ]; then
    log "sip-build 生成绑定(--no-compile)"
    ( cd "$PYQT6_SRC" && rm -rf build && \
      sip-build --confirm-license --qmake "$QT_HOST/bin/qmake" \
        --qt-shared --no-compile --target-dir "$PYQT_BUILD_DIR" >/dev/null ) \
        || err "sip-build 失败(看 $PYQT6_SRC 下的 build 日志)"
fi
[ -d "$GEN_DIR/QtCore" ] \
    || err "sip-build 没生成绑定代码(找过 $GEN_DIR/QtCore)"

# ── 2. QEvent 占位修复(Qt 6.12 移除 EnterEditFocus 枚举)──
sed -i 's|{sipName_EnterEditFocus, static_cast<int>(::QEvent::EnterEditFocus)},|{sipName_EnterEditFocus, static_cast<int>(::QEvent::User) + 1000},|;
        s|{sipName_LeaveEditFocus, static_cast<int>(::QEvent::LeaveEditFocus)},|{sipName_LeaveEditFocus, static_cast<int>(::QEvent::User) + 1001},|' \
    "$GEN_DIR/QtCore/sipQtCoreQEvent.cpp" 2>/dev/null || true

# ── 3. 交叉编译绑定(增量)────────────────────────────────
QT_INC="$QT_BUILD/include"
SIP_INC="$SIP_SRC"
OBJ="$PYQT_BUILD_DIR/obj"
mkdir -p "$OBJ"/{QtCore,QtGui,QtWidgets,qpy-QtCore,qpy-QtWidgets,moc}
rm -f "$OBJ/.err"
BASE="-fPIC -O1 -std=c++17 -D__MUSL__ -DOHOS_NDK -DSIP_PROTECTED_IS_PUBLIC \
      $PY_INC_DIRS -I$SIP_INC -I$QT_INC"
comp_all() { # comp_all <glob> <outdir> <extra-includes...>
    local glob="$1" outdir="$2"; shift 2
    local incs="$*"
    for f in $glob; do
        local o="$outdir/$(basename "$f" .cpp).o"
        [ -f "$o" ] && continue
        # 编译错误不再吞进 /dev/null:日志留档,失败时能直接看原因
        if ! "$CLANG" --target="$TARGET" --sysroot="$SYSROOT" -c "$f" -o "$o" \
                $BASE $incs >>"$OBJ/.compile.log" 2>&1; then
            echo "FAIL: $f" >> "$OBJ/.err"
        fi
    done
}
log "=== 交叉编译绑定(QtCore/Gui/Widgets + qpy)==="
comp_all "$GEN_DIR/QtCore/*.cpp"    "$OBJ/QtCore"    -I"$GEN_DIR/QtCore"    -I"$PYQT6_SRC/qpy/QtCore"    -I"$QT_INC/QtCore"
comp_all "$GEN_DIR/QtGui/*.cpp"     "$OBJ/QtGui"     -I"$GEN_DIR/QtGui"     -I"$PYQT6_SRC/qpy/QtGui"     -I"$QT_INC/QtGui" -I"$QT_INC/QtCore"
comp_all "$GEN_DIR/QtWidgets/*.cpp" "$OBJ/QtWidgets" -I"$GEN_DIR/QtWidgets" -I"$PYQT6_SRC/qpy/QtWidgets" -I"$QT_INC/QtWidgets" -I"$QT_INC/QtGui" -I"$QT_INC/QtCore"
comp_all "$PYQT6_SRC/qpy/QtCore/*.cpp"    "$OBJ/qpy-QtCore"    -I"$PYQT6_SRC/qpy/QtCore"    -I"$GEN_DIR/QtCore"    -I"$QT_INC/QtCore"
comp_all "$PYQT6_SRC/qpy/QtWidgets/*.cpp" "$OBJ/qpy-QtWidgets" -I"$PYQT6_SRC/qpy/QtWidgets" -I"$GEN_DIR/QtWidgets" -I"$QT_INC/QtWidgets" -I"$QT_INC/QtGui" -I"$QT_INC/QtCore"
if [ -f "$OBJ/.err" ]; then
    head -5 "$OBJ/.err" >&2
    grep -m3 -B2 -A6 "error:" "$OBJ/.compile.log" >&2 || true
    err "编译有失败(完整日志 $OBJ/.compile.log,清单 $OBJ/.err)"
fi

# ── 4. moc(Q_OBJECT 类)────────────────────────────────
MOC="$QT_HOST/libexec/moc"
mkdir -p "$OBJ/moc"
for h in "$PYQT6_SRC/qpy/QtCore/qpycore_event_handlers.h" \
         "$PYQT6_SRC/qpy/QtCore/qpycore_qrangemodel.h"; do
    base="$(basename "$h" .h)"
    [ -f "$OBJ/moc/moc_${base}.o" ] && continue
    # -I$QT_INC/QtCore 必需:Q_OBJECT 宏/基类解析,缺失时 moc 输出 "No relevant classes"(空)
    "$MOC" -I"$QT_INC" -I"$QT_INC/QtCore" -I"$PYQT6_SRC/qpy" -I"$PYQT6_SRC/qpy/QtCore" \
        "$h" -o "$OBJ/moc/moc_${base}.cpp" || err "moc 失败 $h"
    grep -q "metaObject" "$OBJ/moc/moc_${base}.cpp" \
        || err "moc 输出为空(缺 QtCore include?):$h"
    "$CLANG" --target="$TARGET" --sysroot="$SYSROOT" -c "$OBJ/moc/moc_${base}.cpp" \
        -o "$OBJ/moc/moc_${base}.o" $BASE -I"$GEN_DIR/QtCore" -I"$PYQT6_SRC/qpy/QtCore" -I"$QT_INC/QtCore"
done

# 扩展模块的未定义符号(Py* / sip*)必须在运行期从**宿主已加载的 libpython.so**
# 解析:procmgr 是用 RTLD_LOCAL dlopen 命令 so 的,libpython 不在全局作用域,
# 所以不能只靠“运行期再说”——必须像 libvim.so→libentry.so 那样显式记一条
# NEEDED(给 -L$HAP_LIBS_DIR -lpython;我们的 libpython.so 的 SONAME 正是
# libpython.so)。其余符号用 --unresolved-symbols=ignore-all 容忍。
QT_LIB="$QT_BUILD/lib"
LINK_BASE="-L$HAP_LIBS_DIR -L$QT_LIB -lpython \
           -Wl,--unresolved-symbols=ignore-all -Wl,-rpath-link,$HAP_LIBS_DIR"

# ── 5. sip 运行时(PyQt6-sip)─────────────────────────────
mkdir -p "$PYQT_BUILD_DIR/PyQt6"
if [ ! -f "$PYQT_BUILD_DIR/PyQt6/sip.so" ]; then
    log "编译 sip 运行时"
    mkdir -p "$OBJ/sip"
    for f in "$SIP_SRC"/*.c; do
        "$CLANG" --target="$TARGET" --sysroot="$SYSROOT" -c "$f" \
            -o "$OBJ/sip/$(basename "${f%.c}").o" -fPIC -O1 -D__MUSL__ -DOHOS_NDK -I"$PY_SRC/Include" -I"$PY_BUILD"
    done
    "$CLANG" --target="$TARGET" --sysroot="$SYSROOT" -shared -o "$PYQT_BUILD_DIR/PyQt6/sip.so" \
        "$OBJ"/sip/*.o $LINK_BASE || err "sip.so 链接失败"
fi

# ── 6. 链接 QtCore/Gui/Widgets.so ────────────────────────
log "=== 链接 PyQt6 模块 ==="
[ -f "$PYQT_BUILD_DIR/PyQt6/QtCore.so" ] || \
    "$CLANG" --target="$TARGET" --sysroot="$SYSROOT" -shared -o "$PYQT_BUILD_DIR/PyQt6/QtCore.so" \
        "$OBJ"/QtCore/*.o "$OBJ"/qpy-QtCore/*.o "$OBJ"/moc/*.o \
        $LINK_BASE -lQt6Core || err "QtCore.so 链接失败"
[ -f "$PYQT_BUILD_DIR/PyQt6/QtGui.so" ] || \
    "$CLANG" --target="$TARGET" --sysroot="$SYSROOT" -shared -o "$PYQT_BUILD_DIR/PyQt6/QtGui.so" \
        "$OBJ"/QtGui/*.o $LINK_BASE -lQt6Gui -lQt6Core || err "QtGui.so 链接失败"
[ -f "$PYQT_BUILD_DIR/PyQt6/QtWidgets.so" ] || \
    "$CLANG" --target="$TARGET" --sysroot="$SYSROOT" -shared -o "$PYQT_BUILD_DIR/PyQt6/QtWidgets.so" \
        "$OBJ"/QtWidgets/*.o "$OBJ"/qpy-QtWidgets/*.o \
        $LINK_BASE -lQt6Widgets -lQt6Gui -lQt6Core || err "QtWidgets.so 链接失败"

# ── 7. 交付:C 扩展平铺进 libs,纯 Python 包壳进 tar ────────
# 见文件头:app 数据目录 noexec ⇒ 扩展只能放 bundle 的 libs/<abi>(平铺);包限定
# 名靠 site-packages 里的 __init__.py 把该目录前插进 __path__ 解决。
log "=== 交付:扩展 → $HAP_LIBS_DIR,包壳 → $RTAR ==="
DEV_LIBS_DIR="${DEV_LIBS_DIR:-/data/storage/el1/bundle/libs/arm64}"   # 设备侧同一目录
mkdir -p "$HAP_LIBS_DIR"
for m in QtCore QtGui QtWidgets sip; do
    cp -f "$PYQT_BUILD_DIR/PyQt6/$m.so" "$HAP_LIBS_DIR/$m.so" || err "复制 $m.so 失败"
done

# 包壳:上游 __init__.py + 前插一行 __path__(保留它的 extend_path 逻辑与许可证头)
PKG="$BUILD_DIR/pyqt6-rt/python/lib/python$PY_SERIES/site-packages/PyQt6"
rm -rf "$BUILD_DIR/pyqt6-rt"
mkdir -p "$PKG"
SRC_INIT="$GEN_DIR/__init__.py"
[ -f "$SRC_INIT" ] || SRC_INIT="$PYQT6_SRC/__init__.py"
[ -f "$SRC_INIT" ] || err "找不到 PyQt6/__init__.py"
{
    echo "# 由 scripts/build_pyqt.sh 生成:C 扩展平铺在 bundle 的 libs 目录里"
    echo "# ($DEV_LIBS_DIR;app 数据目录是 noexec,不能放 .so),"
    echo "# 这里把该目录前插进 __path__,使 import PyQt6.QtCore 直接命中 QtCore.so。"
    echo "__path__ = ['$DEV_LIBS_DIR'] + __path__"
    echo
    cat "$SRC_INIT"
} > "$PKG/__init__.py"
grep -q "$DEV_LIBS_DIR" "$PKG/__init__.py" || err "包壳没写进 __path__"
tar -C "$BUILD_DIR/pyqt6-rt" -cf "$RTAR" python

# ── 8. 校验 ──────────────────────────────────────────────
for m in QtCore QtGui QtWidgets sip; do
    so="$HAP_LIBS_DIR/$m.so"
    [ -f "$so" ] || err "缺 $so"
    # 1) 架构 + 入口符号:扩展模块导出 PyInit_<name>(不是 main)。名字对齐:
    #    PyQt6.QtCore → 找 PyInit_QtCore,所以文件名必须正好是 QtCore.so
    "$CLANG_DIR/llvm-readelf" -h "$so" > "$OBJ/.arch" 2>/dev/null || true
    grep -q AArch64 "$OBJ/.arch" || err "$m.so 非 AArch64"
    "$CLANG_DIR/llvm-nm" -D "$so" > "$OBJ/.syms" 2>/dev/null || true
    grep -qE " (T|W) PyInit_$m\$" "$OBJ/.syms" \
        || err "$m.so 未导出 PyInit_$m(import 会失败)"
    # 2) 必须显式依赖 libpython.so:procmgr 以 RTLD_LOCAL dlopen 命令 so,libpython
    #    不在全局作用域,不写这条 NEEDED 就会 undefined symbol(同 libvim→libentry)
    "$CLANG_DIR/llvm-readelf" -d "$so" > "$OBJ/.dyn" 2>/dev/null || true
    grep -q "Shared library: \[libpython.so\]" "$OBJ/.dyn" \
        || err "$m.so 没有 NEEDED libpython.so —— import 时会报 undefined symbol"
done
rm -f "$OBJ/.arch" "$OBJ/.syms" "$OBJ/.dyn"
# 包壳必须是**纯 Python**(不能带 .so),否则解到 $HOME(noexec)就废了
[ "$(tar -tf "$RTAR" | grep -c '\.so$' || true)" = "0" ] \
    || err "packyqt6.tar 里混进了 .so(它会被解到 noexec 的 \$HOME):$(tar -tf "$RTAR" | grep '\.so$' | head -3)"

log "✅ 产物:"
log "  $HAP_LIBS_DIR/{QtCore,QtGui,QtWidgets,sip}.so"
log "  $RTAR ($(du -h "$RTAR" | cut -f1)) = site-packages/PyQt6/__init__.py(纯 Python 包壳)"
"$CLANG_DIR/llvm-readelf" -d "$HAP_LIBS_DIR/QtWidgets.so" 2>/dev/null | grep -E "NEEDED" || true
log "接线(下一步):"
log "  shell.cpp initResource 加一条(只解包壳,很小):"
log "    UnpackRes(\"tools/pyqt6.tar\", home,"
log "              home + \"/python/lib/python$PY_SERIES/site-packages/PyQt6/__init__.py\")"
log "  QT_PLUGIN_PATH / QT_QPA_PLATFORM 已由会话环境设好(shell.cpp),不用再配"
log "  设备上验证:python -c \"from PyQt6.QtWidgets import QApplication;print('PyQt6 OK', QApplication)\""
