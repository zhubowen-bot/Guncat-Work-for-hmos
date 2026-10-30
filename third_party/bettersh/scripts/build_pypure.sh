#!/bin/bash
# build_pypure.sh — 收集 matplotlib 依赖里的**纯 Python** 包,打成一个 tar
#
# 产物:
#   feature/bsh_main/src/main/resources/rawfile/tools/pypure.tar
#     顶层 python/lib/python3.12/site-packages/{包}/…(与 python-stdlib/numpy 同一套解包路径)
#
# 包里都有什么/为什么:
#   matplotlib 3.9.4 的 requires_dist 里除了 numpy(已单做)和三个要编译的 C 扩展
#   (contourpy/kiwisolver/pillow)之外,其余全是纯 Python —— 它们不受 noexec 约束
#   (纯 .py 可以放 $HOME),直接取 PyPI wheel 解包即可,不需要交叉编译。
#   包含:cycler、fonttools、packaging、pyparsing、python-dateutil、six
#   (six 是 python-dateutil 的依赖;fonttools 自带的加速 C 扩展是可选的,
#    用 py3-none-any 的纯 wheel 即可)
#
# 两个必须钉死的点(否则会拿到错的东西):
#   1) 用 **python3.12** 跑 pip(与目标同系列)。PATH 上的 python3 可能是别的
#      pyenv/系统版本,会挑 cp311 的包;
#   2) 强制**平台无关** wheel(--platform any --implementation py3 --abi none):
#      不加的话 pip 会挑 manylinux x86_64 的二进制 wheel(fonttools 就有),
#      里面带 .so —— 解到 noexec 的 $HOME 上是废的,而且架构也不对。
#
# 注:sitecustomize.py(平铺扩展的导入兜底)由 numpy.tar 交付,这里不重复带。
#
# 版本:默认取 PyPI 最新(会打印实际文件名,便于回溯);要钉版本就覆盖:
#   PYPURE_PKGS="cycler==0.12.1 fonttools==4.65.0 …" ./scripts/build_pypure.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PYPURE_PY="${PYPURE_PY:-python3.12}"
PYPURE_PKGS="${PYPURE_PKGS:-cycler fonttools packaging pyparsing python-dateutil six}"
PYPURE_TAR="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools/pypure.tar"
PY_SERIES="${PY_SERIES:-3.12}"
WORK="$BUILD_DIR/pypure"
RT="$WORK/rt"
WHL="$WORK/wheels"
SP="$RT/python/lib/python$PY_SERIES/site-packages"

command -v "$PYPURE_PY" >/dev/null 2>&1 || err "缺 $PYPURE_PY(必须用与目标同系列的解释器)"
mkdir -p "$(dirname "$PYPURE_TAR")" "$SP" "$WHL"

log "=== 下载纯 Python wheel($PYPURE_PY): $PYPURE_PKGS ==="
# shellcheck disable=SC2086
"$PYPURE_PY" -m pip download -q --no-deps --only-binary=:all: \
    --platform any --implementation py3 --abi none --python-version "$PY_SERIES" \
    -d "$WHL" $PYPURE_PKGS \
    || err "wheel 下载失败(检查网络/代理,或该包没有平台无关 wheel)"

log "=== 解包到 site-packages ==="
shopt -s nullglob
n=0
for w in "$WHL"/*.whl; do
    # 平台无关 wheel 里不该有 .so;有就直接报错(说明上面的过滤没生效)
    if "$PYPURE_PY" -c "import sys,zipfile;sys.exit(0 if any(n.endswith('.so') for n in zipfile.ZipFile(sys.argv[1]).namelist()) else 1)" "$w"; then
        err "$(basename "$w") 里含 .so,不是纯 Python 包"
    fi
    # wheel 就是 zip:直接展开(dist-info 保留,importlib.metadata 要用)
    "$PYPURE_PY" -c "import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
        "$w" "$SP" || err "解包失败: $w"
    log "  + $(basename "$w")"
    n=$((n + 1))
done
shopt -u nullglob
[ "$n" -gt 0 ] || err "没有下到任何 wheel"

tar -C "$RT" -cf "$PYPURE_TAR" python

# ── 校验 ────────────────────────────────────────────────
# 注意:不要写成 `tar -tf … | grep -q …` —— set -o pipefail 下 grep 命中即退出会
# 让 tar 收到 SIGPIPE,整条管道变成失败 → 误报"缺包"。先把清单落文件再查。
tar -tf "$PYPURE_TAR" > "$WORK/list.txt"
nso="$(grep -c '\.so$' "$WORK/list.txt" || true)"
[ "$nso" = "0" ] || err "pypure.tar 里混进了 $nso 个 .so(会被解到 noexec 的 \$HOME)"
# 注意目录名/形态:fontTools 是大写 T;six 是模块文件(six.py)不是包
for p in cycler/__init__.py fontTools/__init__.py packaging/__init__.py \
         pyparsing/__init__.py dateutil/__init__.py six.py; do
    grep -qx "python/lib/python$PY_SERIES/site-packages/$p" "$WORK/list.txt" \
        || err "tar 里缺 site-packages/$p"
done
log "✅ $PYPURE_TAR ($(du -h "$PYPURE_TAR" | cut -f1))"
log "   内容: python/lib/python$PY_SERIES/site-packages/{cycler,fontTools,packaging,pyparsing,dateutil,six}/…"
log "   将 shell.cpp 的 initResource 加一条即可(与 numpy.tar 同样写法):"
log "     UnpackRes(\"tools/pypure.tar\", home, home + \"/python/lib/python$PY_SERIES/site-packages/six.py\")"
