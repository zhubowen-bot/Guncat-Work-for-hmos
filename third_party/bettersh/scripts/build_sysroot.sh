#!/bin/bash
# build_sysroot.sh — 打包 musl sysroot(头 + 静态库/CRT)供设备端 clang 编译
#
# 从 musl 交叉工具链 sysroot 取 include/ 与静态库/CRT,打成 rawfile/
# tools/sysroot.tar(顶层 musl/),设备上解到 $HOME/musl;clang 入口包装
# 默认带上 --sysroot=$HOME/musl -static-pie -fuse-ld=lld,故终端里 `clang a.c -o a`
# 免参数即可(与旧工程 M10 行为一致;static-pie 的来由见 build_llvm.sh)。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUSL_TC="${MUSL_TOOLCHAIN:-/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross}"
SYS="$MUSL_TC/aarch64-linux-musl"
STAGE="$ROOT/build/sysroot"
OUT="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools/sysroot.tar"

[ -d "$SYS/include" ] || { echo "缺 musl sysroot:$SYS(设 MUSL_TOOLCHAIN)"; exit 1; }
GCCDIR="$(ls -d "$MUSL_TC"/lib/gcc/aarch64-linux-musl/*/ 2>/dev/null | head -1)"

echo "==> 收集 sysroot → $STAGE/musl"
rm -rf "$STAGE"
mkdir -p "$STAGE/musl/lib"
# 只带 C 编译所需:排除 c++ 头(13M)、linux 内核头(6.2M)与 libstdc++.a(40M),
# 与旧工程 sysroot.tar(~5M)一致;clang++/C++ 暂不支持。
cp -a "$SYS/include" "$STAGE/musl/include"
rm -rf "$STAGE/musl/include/c++" "$STAGE/musl/include/linux"

# rcrt1.o 是 musl 的 static-PIE 启动代码:clang -static-pie 会来找这个文件,
# 缺了会报 "cannot open rcrt1.o"。设备端编出来的 guest 现在走 static PIE。
LIBS=(crt1.o rcrt1.o crti.o crtn.o libc.a)
for f in "${LIBS[@]}"; do
    [ -f "$SYS/lib/$f" ] && cp -a "$SYS/lib/$f" "$STAGE/musl/lib/" || true
done
# libgcc/libgcc_eh 在 GCC 运行库目录(不在 sysroot/lib);旧工程把它平铺进 musl/lib。
# crtbegin/crtend 两套都要:oT 是 -static(非 PIC)用,S 是 -static-pie / -shared 用,
# 只带其中一套会在另一种模式下报 "cannot open crtbeginS.o"。
if [ -n "$GCCDIR" ]; then
    for f in libgcc.a libgcc_eh.a crtbeginT.o crtend.o crtbeginS.o crtendS.o; do
        [ -f "$GCCDIR/$f" ] && cp -a "$GCCDIR/$f" "$STAGE/musl/lib/" || true
    done
else
    echo "warn: 未找到 GCC 运行库目录,libgcc.a/libgcc_eh.a 缺失"
fi

echo "==> tar → $OUT"
mkdir -p "$(dirname "$OUT")"
( cd "$STAGE" && tar -cf "$OUT" musl )
echo "==> sysroot.tar: $(du -h "$OUT" | cut -f1) / $(find "$STAGE/musl" -type f | wc -l) files"
