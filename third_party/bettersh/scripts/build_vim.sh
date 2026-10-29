#!/bin/bash
# build_vim.sh — 把 vim 移植为 libvim.so
#
#   1) 交叉编译 ncurses(静态、widec、--with-fallbacks=xterm-256color 内嵌
#      terminfo,免设备端 terminfo 库)→ objects/*.o(PIC);
#   2) 交叉编译 zlib(PIC)→ *.o;
#   3) vim FEAT_NORMAL 交叉 configure + make(thirdparty/vim/src 树内);
#   4) 聚合 libvim.so = vim objects + ncurses objects + zlib objects
#      + tty_shim.o(软 tty 拦截:isatty/tcgetattr/ioctl/…→宿主 bsh_tty_*)
#      + exec_shim.o(exec 委托),链接加
#      -Wl,-Bsymbolic-functions 与 --wrap=execvp/execv/execve/posix_spawn;
#   5) 校验:NEEDED 仅 libc、导出 main。
#
# 产物:$ROOT/feature/bsh_main/libs/arm64-v8a/libvim.so(随 HAP 打包)。
# 依赖:thirdparty/{vim,zlib,ncurses} submodule、aarch64 musl 交叉工具链、
#       宿主 tic + xterm-256color terminfo(ncurses fallback 生成用)。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_VIM="$ROOT/thirdparty/vim"
SRC_ZLIB="$ROOT/thirdparty/zlib"
SRC_NCURSES="$ROOT/thirdparty/ncurses"
TC_DIR="$ROOT/feature/bsh_main/src/main/cpp"
# shim 家族的 --wrap 清单（要在编 tty_shim 之前 source，后面直接用 $SHIM_SRC_DIR）
source "$SCRIPT_DIR/shim-wrap-flags.sh"

BUILD="$ROOT/build/vim"
NC_BUILD="$BUILD/ncurses"
ZSRC="$BUILD/zlib-src"
OUTDIR="$ROOT/feature/bsh_main/libs/arm64-v8a"
OUT="$OUTDIR/libvim.so"
JOBS="${JOBS:-$(nproc)}"

TRIPLE="aarch64-linux-musl"
MUSL_TC="${MUSL_TOOLCHAIN:-/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross}"
OHOS_SDK="${OHOS_SDK:-/apps/harmony/sdk/default/openharmony}"
OHOS_CLANG="$OHOS_SDK/native/llvm/bin/clang"

# 工具链:优先 OHOS SDK clang(--target=aarch64-linux-ohos,开源用户仅需 DevEco),
# VIM_CC 显式指定则优先;musl-cross 兜底(与 build_toybox.sh 策略一致)。
CC=""; NM=""; READELF=""
if [ -n "${VIM_CC:-}" ]; then
    CC="$VIM_CC"
elif [ -x "$OHOS_CLANG" ]; then
    CC="$OHOS_CLANG --target=aarch64-linux-ohos --sysroot=$OHOS_SDK/native/sysroot -fuse-ld=lld"
    NM="$OHOS_SDK/native/llvm/bin/llvm-nm"
    READELF="$OHOS_SDK/native/llvm/bin/llvm-readelf"
else
    CC="$MUSL_TC/bin/$TRIPLE-gcc"
    NM="$MUSL_TC/bin/$TRIPLE-nm"
    READELF="$MUSL_TC/bin/$TRIPLE-readelf"
fi
[ -n "$CC" ] || { echo "编译器不可用(设 VIM_CC 或用 OHOS SDK/musl-cross)"; exit 1; }
CC_FIRST="$(printf '%s' "$CC" | awk '{print $1}')"
[ -x "$CC_FIRST" ] || { echo "编译器不存在:$CC_FIRST"; exit 1; }
[ -x /usr/bin/tic ] || { echo "需要宿主 tic(生成 ncurses fallback terminfo)"; exit 1; }
for d in "$SRC_VIM/src/version.h" "$SRC_ZLIB/configure" "$SRC_NCURSES/configure"; do
    [ -e "$d" ] || { echo "缺 submodule 源码:$d(先 git submodule update --init)"; exit 1; }
done
mkdir -p "$BUILD" "$OUTDIR"
export PATH="/usr/bin:$PATH"   # fallback 生成阶段让 MKfallback 找到宿主 tic

echo "==> 1) ncurses(交叉静态,fallback xterm-256color) build=$NC_BUILD"
if [ ! -f "$NC_BUILD/config.status" ]; then
    mkdir -p "$NC_BUILD"
    ( cd "$NC_BUILD" && CC="$CC" CFLAGS="-O2 -fPIC" "$SRC_NCURSES/configure" \
        --host=aarch64-linux-musl --build=x86_64-pc-linux-gnu \
        --prefix=/usr --without-shared --without-debug --without-ada \
        --without-cxx --without-progs --without-manpages --without-tests \
        --with-fallbacks=xterm-256color > configure.log 2>&1 )
fi
make -C "$NC_BUILD" -j"$JOBS" libs > "$BUILD/ncurses-make.log" 2>&1 \
    || { echo "ncurses make 失败,见 $BUILD/ncurses-make.log"; exit 1; }
ls "$NC_BUILD"/lib/libncursesw.a >/dev/null 2>&1 \
    || { echo "未产出 libncursesw.a;见 $BUILD/ncurses-make.log"; exit 1; }

echo "==> 2) zlib(交叉静态 PIC) build=$ZSRC"
if [ ! -d "$ZSRC" ]; then
    cp -a "$SRC_ZLIB" "$ZSRC"
    rm -rf "$ZSRC/.git"
fi
if [ ! -f "$ZSRC/zlib.pc" ]; then
    ( cd "$ZSRC" && CC="$CC" CFLAGS="-O2 -fPIC" ./configure --static \
        > configure.log 2>&1 )
fi
make -C "$ZSRC" -j"$JOBS" > "$BUILD/zlib-make.log" 2>&1 \
    || { echo "zlib make 失败,见 $BUILD/zlib-make.log"; exit 1; }
ls "$ZSRC"/libz.a >/dev/null 2>&1 || { echo "zlib 未产出 libz.a"; exit 1; }

echo "==> 3) vim(FEAT_NORMAL 交叉) src=$SRC_VIM/src"
if [ ! -f "$SRC_VIM/src/auto/config.mk" ]; then
    # 配置变化需全量重建:先 distclean 并删除 objects 目录——vim 的 distclean
    # 不清理 objects/,旧配置残留对象(如 wayland=yes 时的 objects/wayland.o)
    # 会让聚合误带 GUI 未定义符号 → dlopen 失败。
    make -C "$SRC_VIM/src" distclean >/dev/null 2>&1 || true
    rm -rf "$SRC_VIM/src/objects"
    rm -f "$SRC_VIM/src/auto/config.cache"
    ( cd "$SRC_VIM/src" && CC="$CC" CFLAGS="-O2 -fPIC" \
        CPPFLAGS="-I$NC_BUILD/include -I$ZSRC" \
        LDFLAGS="-L$NC_BUILD/lib -L$ZSRC" \
        PKG_CONFIG=false \
        ./configure --host=aarch64-linux-musl --build=x86_64-pc-linux-gnu \
        --with-tlib=ncursesw --with-features=normal --without-x \
        --with-wayland=no --disable-gui --disable-channel --disable-netbeans \
        --disable-xim --enable-multibyte --with-compiledby=BetterSH \
        --prefix=/data/storage/el2/base/haps/entry/files \
        > "$BUILD/vim-config.log" 2>&1 )
fi
make -C "$SRC_VIM/src" -j"$JOBS" vim > "$BUILD/vim-make.log" 2>&1 \
    || { echo "vim make 失败,见 $BUILD/vim-make.log"; exit 1; }
ls "$SRC_VIM/src/objects/main.o" >/dev/null 2>&1 || { echo "vim objects 缺失"; exit 1; }

echo "==> 4) 聚合 libvim.so"
# vim 对象清单取自 make 输出中的链接行(与旧工程一致),按序进入链接
OBJS="$(grep -oE '(^| )objects/[a-zA-Z0-9_./-]+\.o' "$BUILD/vim-make.log" \
        | tr -d ' ' | sort -u | tr '\n' ' ' || true)"
[ -n "$OBJS" ] || OBJS="$(cd "$SRC_VIM/src" && ls objects/*.o | tr '\n' ' ')"
# shim 与 exec 委托对象(每次现编,保证与当前源码一致)
# tty_shim 现在 include bsh_client.h(它靠 control socket 读写 tty 状态)
$CC -O2 -fPIC -I"$TC_DIR/tty" -I"$TC_DIR/procmgr" -DBSH_SHIM_WRAP -DBSH_SHIM_MERGED_OPEN -c "$SHIM_SRC_DIR/tty_shim.c" -o "$BUILD/tty_shim.o"
$CC -O2 -fPIC -DBSH_SHIM_WRAP -I"$TC_DIR/shim" -I"$TC_DIR/procmgr" -c "$TC_DIR/shim/exec_shim.c" -o "$BUILD/exec_shim.o"
$CC -O2 -fPIC -I"$TC_DIR/procmgr" -c "$TC_DIR/procmgr/bsh_client.c" -o "$BUILD/bsh_client.o"
# shim 家族（见 feature/bsh_main/src/main/cpp/shim/README.md）：fs_shim 补"沙箱禁 symlink"，
# 与 tty_shim 共用同一份合并 open 入口。命令 so 侧统一走 -DBSH_SHIM_WRAP + --wrap（链接
# 期替换；真实现=链接器生成的 __real_<名>）—— 命令 so 排在搜索序末尾，RTLD_NEXT 拿不到。
source "$SCRIPT_DIR/shim-wrap-flags.sh"
$CC -O2 -fPIC -DBSH_SHIM_WRAP -DBSH_SHIM_MERGED_OPEN -I"$SHIM_SRC_DIR" -c "$SHIM_SRC_DIR/fs_shim.c" -o "$BUILD/fs_shim.o"
$CC -O2 -fPIC -DBSH_SHIM_WRAP -I"$SHIM_SRC_DIR" -c "$SHIM_SRC_DIR/open_shim.c" -o "$BUILD/open_shim.o"
FS_OBJ="$BUILD/fs_shim.o"
OPEN_OBJ="$BUILD/open_shim.o"

# 符号解析:exec 委托与 tty 读写都经 control socket 问 procmgr(exec_shim.o +
# bsh_client.o),tty_shim 只在本地维护"哪些 fd 是 tty" —— 命令 so 不再链接宿主
# libentry.so,编它也不要求先跑过一次 build_hap。

( cd "$SRC_VIM/src" && eval "$CC -shared -o \"$OUT\" $OBJS \
    \"$NC_BUILD\"/objects/*.o \"$ZSRC\"/libz.a \
    \"$BUILD/tty_shim.o\" \"$FS_OBJ\" \"$OPEN_OBJ\" \"$BUILD/exec_shim.o\" \"$BUILD/bsh_client.o\" \
    -Wl,-soname,libvim.so \
    $SHIM_WRAP_FLAGS \
    -static-libgcc" )

echo "==> 5) 校验 $OUT"
"$READELF" -d "$OUT" | grep -E 'NEEDED|SONAME'
"$NM" -D "$OUT" | grep -E ' main$' || { echo "warn: main 未导出"; exit 1; }
LEFTOVER="$("$NM" -D --undefined-only "$OUT" | grep -E 'wl_|cairo_|pango|wayland' || true)"
[ -z "$LEFTOVER" ] || echo "warn: 仍有 GUI 相关未定义符号:$LEFTOVER"
echo "==> 6) pack vim runtime subset as rawfile/tools/vim-runtime.tar"
# 只带交互编辑必需的最小运行时(vim 启动即 source defaults.vim→filetype/syntax):
# 完整 runtime 约 50MB(含 doc 12MB/syntax 21MB),不适合打进 HAP。
RT="$SRC_VIM/runtime"
RTAR="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools/vim-runtime.tar"
mkdir -p "$ROOT/feature/bsh_main/src/main/resources/rawfile/tools"
rm -f "$RTAR"
tar -C "$RT" -cf "$RTAR" \
    defaults.vim filetype.vim ftplugin.vim indent.vim \
    colors/default.vim colors/lists/default.vim \
    autoload/dist/ft.vim \
    syntax/syntax.vim syntax/synload.vim syntax/syncolor.vim \
    syntax/nosyntax.vim \
    syntax/vim.vim syntax/c.vim syntax/cpp.vim syntax/sh.vim \
    syntax/make.vim syntax/python.vim syntax/diff.vim syntax/help.vim \
    syntax/conf.vim syntax/json.vim
echo "==> vim-runtime.tar: $(du -h "$RTAR" | cut -f1)"
echo "==> done: $OUT ($(du -h "$OUT" | cut -f1))"
