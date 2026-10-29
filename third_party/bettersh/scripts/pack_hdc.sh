#!/bin/bash
# pack_hdc.sh — 把设备侧用的 aarch64 hdc 打成一个能给 pkg 发的包（`hdc`）。
#
# 为什么单独发：hdc 是"想用才装"的东西 —— 它连设备自身的 hdcd（`hdc tconn`），
# 用来装/拉起 HAP，自举流水线要靠它（设备侧那套见 build/dist/bshsign/README）。
# 原来它跟签名材料一起塞在 rawfile 的 bshsign-tools.tar 里，而那个包 631MB、大头是**预编译
# 的 dev HAP** —— dev 改成我们自己构建之后，shell.cpp 里那段 UnpackRes 就注释掉了。
# 现在剩下的 hdc + 它的 .so 闭包只有几 MB，正好单独发一个包。
#
# 源：build/dist/bshsign/bin/（闭包来源见那里的 README「hdc's shared-library closure」）——
#   hdc                HarmonyOS command-line-tools 的 linux-arm64 包，**glibc 构建**
#   libusb_shared.so   同一份 toolchains/
#   libstdc++.so.6 / libgcc_s.so.1 / libatomic.so.1     Ubuntu 24.04 arm64 14.2.0
#   libm.so.6 / libpthread.so.0 / libdl.so.2 / librt.so.1  项目自编 glibc 2.39 的构建树
#   **不带** ld-linux-aarch64.so.1 与 libc.so.6：那两个由应用自己提供（bundle libs 里那份
#   打过"不做文件映射"补丁的 glibc，elfloader 要用），包里再塞一份只会盖掉更新的。
#
# 三条约束（前两条在 pack_ohos_sdk_prune.sh 里踩过）：
#   1) **不能有软链**：pkg 的 tar 解包器（programs/pkg/bsh_tar.c）只认普通文件/目录，
#      沙箱里也建不出软链。所以只收 SONAME 形态的真文件（`libstdc++.so.6` 等），
#      不带 `libstdc++.so.6.0.33` 这类版本名副本 —— ld.so 是按 SONAME 找的。
#   2) **摆位要能被 ld.so 找到**：hdc 的 RPATH 是 `$ORIGIN/.`，而 procmgr 给每个 guest
#      显式补了 `<dir>`、`<dir>/../lib`、`<dir>/../lib64`（procmgr.cpp 的 ChildRunElf 与
#      ChildRunExec 里各一处）。于是照 weston-terminal 那个包的既有布局：
#          usr/bin/hdc  +  usr/lib/<闭包>
#      —— 不用改 .bshrc，也不必往 usr/bin 里塞一堆 .so。
#   3) **自检**：扫 hdc 与每个闭包 .so 的 NEEDED，凡是不在本包、又不属于"应用自己会提供"
#      的那两个名字，直接报错退出 —— 免得打出"装上去才发现缺库"的包。
#
# 用法：scripts/pack_hdc.sh
#   产出：dist/pkgs/hdc.tar.zst（+ 打印 size/sha256，供 index.json 用）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

SRC_BIN="$ROOT/build/dist/bshsign/bin"
STAGE="$ROOT/build/hdc-pkg"
OUT_DIR="$ROOT/dist/pkgs"
OUT="$OUT_DIR/hdc.tar.zst"

# 闭包（SONAME 形态；顺序只是为了日志好看）
LIBS="libstdc++.so.6 libgcc_s.so.1 libatomic.so.1 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libusb_shared.so"
# 由应用自己提供的 soname（bundle libs / 资源根 lib 里本来就有）
PROVIDED_RE='^(libc\.so\.6|ld-linux-aarch64\.so\.1|libc\.so|ld-musl-aarch64\.so\.1)$'

RE="${CLANG_DIR}/llvm-readelf"
[ -x "$RE" ] || RE=readelf

[ -x "$SRC_BIN/hdc" ] || { echo "缺 $SRC_BIN/hdc（见 build/dist/bshsign/README）" >&2; exit 1; }

log "=== 铺暂存树 → $STAGE ==="
rm -rf "$STAGE"
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/lib"
cp -p "$SRC_BIN/hdc" "$STAGE/usr/bin/hdc"
chmod 0755 "$STAGE/usr/bin/hdc"
for l in $LIBS; do
    [ -f "$SRC_BIN/$l" ] || { echo "缺闭包里的 $l（见 build/dist/bshsign/README 的闭包表）" >&2; exit 1; }
    cp -p "$SRC_BIN/$l" "$STAGE/usr/lib/$l"
    log "    usr/lib/$l  $(stat -c%s "$SRC_BIN/$l") 字节"
done

log "=== 自检：动态依赖都要能找到 ==="
bad=0
for f in "$STAGE/usr/bin/hdc" "$STAGE/usr/lib"/*; do
    while read -r lib; do
        [ -n "$lib" ] || continue
        if [ -e "$STAGE/usr/lib/$lib" ]; then continue; fi
        if printf '%s' "$lib" | grep -Eq "$PROVIDED_RE"; then continue; fi
        echo "    [!] $(basename "$f") 需要 $lib —— 本包没有，也不是应用会提供的那几个" >&2
        bad=1
    done < <("$RE" -d "$f" 2>/dev/null | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF); print $NF}')
done
[ "$bad" = "0" ] || { echo "有文件缺依赖（见上）—— 先补齐再打包" >&2; exit 1; }
log "    通过：hdc 与闭包的 NEEDED 都能落在本包或应用的 glibc 运行期上"

log "=== 不打软链检查（pkg 的 tar 解包器只认普通文件/目录）==="
if find "$STAGE" -type l | grep -q .; then
    echo "    暂存树里有软链，pkg 装不了" >&2; exit 1
fi
log "    通过：全是普通文件/目录"

log "=== 打包（zstd -19 -T$JOBS）==="
mkdir -p "$OUT_DIR"
tar -C "$STAGE" -c usr | zstd -q -f -19 -T"$JOBS" -o "$OUT"
[ -s "$OUT" ] || { echo "包是空的" >&2; exit 1; }
log "    条目：$(tar --zstd -tf "$OUT" | wc -l) 个"

echo
log "包里的内容："
tar --zstd -tvf "$OUT" | sed 's/^/    /'
echo
log "$(numfmt --to=iec "$(du -sb "$STAGE" | cut -f1)")（未压缩） → $(numfmt --to=iec "$(stat -c%s "$OUT")")  $OUT"
echo
echo "index.json 需要的三项："
echo "  \"file\"   : $(basename "$OUT")"
echo "  \"size\"   : $(stat -c%s "$OUT")"
echo "  \"sha256\" : $(sha256sum "$OUT" | cut -d' ' -f1)"
