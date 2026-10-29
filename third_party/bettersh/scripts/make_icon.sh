#!/bin/bash
# make_icon.sh — 把 assets/icon/bettersh-icon.svg 渲染成 PNG 图标。
#
# 为什么要有这个脚本：图标当初是一次性命令转出来的（见提交 e372eaf），
# 源 SVG 和转换脚本都没留下来 —— 想改图标就得从头再来一遍，而且新旧图对不上还没法查。
# 现在 SVG 进库、转换可复现，改图标 = 改 SVG + 跑本脚本。
#
# 用法：
#   scripts/make_icon.sh                # 默认生成 1024×1024 → assets/icon/bettersh-icon-1024.png
#   scripts/make_icon.sh 216 512 1024   # 生成多个尺寸
#   APPLY=1 scripts/make_icon.sh 512    # 另外把 512 那份写回 AppScope/ 与 entry/ 的 foreground.png
#   SVG=... OUT_DIR=... scripts/make_icon.sh
#
# 关于 APPLY：应用图标是**分层图标**（AppScope/resources/base/media/layered_image.json
# 指向 background + foreground），当前前景就是这张图的整图（含深色底板），所以 APPLY
# 只是把渲染结果拷到那两个 foreground.png（两处都要，AppScope 是应用级、entry 是模块级）。
# 不传 APPLY 时只产出 assets/icon/ 下的 PNG，不动任何随包资源。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SVG="${SVG:-$ROOT/assets/icon/bettersh-icon.svg}"
OUT_DIR="${OUT_DIR:-$ROOT/assets/icon}"
SIZES=("$@")
[ "${#SIZES[@]}" -gt 0 ] || SIZES=(1024)

[ -f "$SVG" ] || { echo "找不到 SVG：$SVG" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# 渲染器：优先 rsvg-convert（快），否则 cairosvg（纯 python），再退到 inkscape。
# 这台机器上只有 cairosvg，所以它是实际走的那条。
render() {  # <尺寸> <输出文件>
    local size="$1" out="$2"
    if command -v rsvg-convert >/dev/null 2>&1; then
        rsvg-convert -w "$size" -h "$size" "$SVG" -o "$out"
    elif python3 -c "import cairosvg" 2>/dev/null; then
        python3 - "$SVG" "$out" "$size" <<'PY'
import sys, cairosvg
svg, out, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
cairosvg.svg2png(url=svg, write_to=out, output_width=size, output_height=size)
PY
    elif command -v inkscape >/dev/null 2>&1; then
        inkscape "$SVG" -w "$size" -h "$size" -o "$out" >/dev/null 2>&1
    else
        echo "需要 rsvg-convert / cairosvg(python3) / inkscape 之一" >&2
        exit 1
    fi
}

for s in "${SIZES[@]}"; do
    case "$s" in ''|*[!0-9]*) echo "尺寸必须是数字：$s" >&2; exit 2;; esac
    out="$OUT_DIR/bettersh-icon-$s.png"
    render "$s" "$out"
    printf '  %-32s %s\n' "$(basename "$out")" "$(file -b "$out")"
done

if [ "${APPLY:-0}" = "1" ]; then
    # 用哪个尺寸写回：命令行里若给了 512 就用它，否则用第一个尺寸
    apply_size="${SIZES[0]}"
    for s in "${SIZES[@]}"; do [ "$s" = "512" ] && apply_size=512; done
    src="$OUT_DIR/bettersh-icon-$apply_size.png"
    for dst in "$ROOT/AppScope/resources/base/media/foreground.png" \
               "$ROOT/feature/bsh_main/src/main/resources/base/media/foreground.png"; do
        cp -f "$src" "$dst"
        printf '  → %s (%s)\n' "${dst#"$ROOT/"}" "$(basename "$src")"
    done
    echo "已写回应用图标；重新打包即可生效（scripts/build_hap.sh）"
fi
