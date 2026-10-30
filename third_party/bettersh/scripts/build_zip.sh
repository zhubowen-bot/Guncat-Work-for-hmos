#!/bin/bash
# build_zip.sh — Info-ZIP zip 3.0 / unzip 6.0 → 两个命令 so(libzipcmd.so / libunzipcmd.so)
#
# 目标:和其它命令一样走 kSoMain(fork → dlopen → 调入口符号),不 exec。
#
# 为什么是**两个独立 so**:zip 与 unzip 是两套互不相干的代码库 —— 各自一份
# unix/Makefile、各自一份 crc32/ttyio/globals/zipfile,连 main 都在自己那份源里。
# 硬合成一个 so 会撞符号(两个 crc32、两个 ttyio),收益却只是省一次 dlopen。
#
# 命名:命令 so 叫 libzipcmd.so / libunzipcmd.so,**不能**叫 libzip.so ——
# feature/bsh_main/libs/arm64-v8a/libzip.so 已经被 JDK 的 java.util.zip 原生库占着
# (scripts/build_jdk.sh 的 install 阶段拷进去的),同名会互相覆盖。
# 入口符号:bsh_zip_main / bsh_unzip_main(llvm-objcopy --redefine-sym main=…)。
#
# 编译走上游 unix/Makefile 的 generic 路线:
#   make -f unix/Makefile flags CC=… CFLAGS_NOOPT="…-fPIC"   # 生成 flags(自动探测)
#   eval make -f unix/Makefile zip $(cat flags)              # 只编 zip 一个程序
# 上游 configure 是**编译探测**(只 -c,不跑目标程序),交叉编译下结论可信;它自己
# 探出 -DUNICODE_SUPPORT -DHAVE_DIRENT_H -DHAVE_TERMIOS_H。
# 只编 zip / unzip 两个目标,不碰 zipcloak/zipnote/zipsplit/funzip/unzipsfx。
#
# ── 补丁层:目前**一个 shim 都不需要**(以下是查过的账,不是想当然) ──────────
#   getpwuid/getpwnam  不用补:两个程序根本不引用它们 ——
#                      `llvm-nm -u build/zip/{zip30,unzip60}/*.o | grep getpw` 零命中。
#                      zip 只存数字 uid/gid;unzip 只在 -X 时把归档里的 uid/gid 喂给
#                      chown,从不查 passwd 库。
#   utime              不用补:OHOS libc 有且实测能用。解包时每个目录都要 utime()
#                      还原时间戳(unix/unix.c 的 set_direc_attribs),失败会退成
#                      PK_WARN(rc=1);而自检里 `unzip -d out` 那条断言 rc=0,过了。
#   getpass            不用补:两个程序都不引用(unzip 的密码提示走自己的
#                      UzpPassword/getp,走 ttyio.c)。
#   chown/fchown/lchown 不补,但记着这是**没走过**的路径:unzip 只在 `-X` **且**归档
#                      带 0x7875(Unix UID/GID)扩展字段时才调,而我们 zip 只写 0x5455
#                      (扩展时间戳)。真要用 `unzip -X` 得先补一层并实测 —— 沙箱里
#                      改属主的调用既往表现是"进程直接消失"(见 ssh/pwshim.c)。
# 真要加补丁时:在脚本里加一段把 `*.c` 编进 ZIPOHOS_OBJS、并把它接进 relink 即可。
#
# ── 已知缺口(明确**不做**,自检里也不测) ─────────────────────────────────
#   zip64 与 >4GiB 条目、多卷;符号链接/设备文件的还原;`unzip -X`(见上);
#   加密(`zip -e`/`unzip -P`,能编进去但提示路径未实测);
#   `zip -T`(它要 system("unzip -t …") 真 exec,沙箱里必然失败)。
#   另外:裸 `zip` 无参数是上游的**过滤模式**(rc=0),不是错误。
#
# 链接:把 .o 重链成 .so,接上 exec_shim.o + bsh_client.o(exec 委托)、tty_shim.o
# (软 tty → isatty/tcgetattr/ioctl/tcsetpgrp 都问 procmgr),并加
#   -Wl,--wrap=exit            保住退出码(shim/exec_shim.c 的 __wrap_exit)
#   -Wl,--wrap=exec*+posix_spawn  这两个程序其实不 exec,加上无害(与其它命令 so 一致)
#   -Wl,-Bsymbolic-functions   让 so 内部对 isatty/… 的调用绑到 tty_shim 的实现
# scripts/zip-ohos/*.c 是自有补丁层(OHOS libc 缺接口时在此兜底),逐个编进来。
#
# 阶段:src | build | link | install | all(默认 all)
# 用法:./scripts/build_zip.sh [src|build|link|install|all]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"
# shim 家族（见 feature/bsh_main/src/main/cpp/shim/README.md）：沙箱拒绝 symlink(2)，命令 so 侧
# 统一用 -DBSH_SHIM_WRAP + -Wl,--wrap=（链接期替换；真实现=链接器生成的 __real_<名>）。
# 不能用 RTLD_NEXT：命令 so 是主进程 dlopen 进来的、排在搜索序末尾，拿不到真实现。
source "$SCRIPT_DIR/shim-wrap-flags.sh"


PHASE="${1:-all}"

ZIP_VER="3.0"
ZIP_SHA256="f0e8bb1f9b7eb0b01285495a2699df3a4b766784c1765a8f1aeedf63c0806369"
ZIP_URL="https://deb.debian.org/debian/pool/main/z/zip/zip_${ZIP_VER}.orig.tar.gz"

UNZIP_VER="6.0"
UNZIP_SHA256="036d96991646d0449ed0aa952e4fbe21b476ce994abc276e49d30e686708bd37"
UNZIP_URL="https://deb.debian.org/debian/pool/main/u/unzip/unzip_${UNZIP_VER}.orig.tar.gz"

BUILD_ROOT="$ROOT/build/zip"
SRC_ZIP="$BUILD_ROOT/zip30"
SRC_UNZIP="$BUILD_ROOT/unzip60"
OUTDIR="$BUILD_ROOT/out"                # link 阶段的产物(install 阶段拷进 feature/bsh_main/libs)
OUT_ZIP="$OUTDIR/libzipcmd.so"
OUT_UNZIP="$OUTDIR/libunzipcmd.so"

TC_DIR="$ROOT/feature/bsh_main/src/main/cpp"
OBJDIR="$BUILD_ROOT/obj"                # 公共对象(exec 委托 / tty shim / shim)

# ── 工具链 ─────────────────────────────────────────────────
CC=""; NM=""; READELF=""; OBJCOPY=""
if [ -n "${ZIP_CC:-}" ]; then
    CC="$ZIP_CC"
    NM="${ZIP_NM:-nm}"; READELF="${ZIP_READELF:-readelf}"; OBJCOPY="${ZIP_OBJCOPY:-objcopy}"
elif [ -x "$CLANG" ]; then
    CC="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"
    NM="$CLANG_DIR/llvm-nm"; READELF="$CLANG_DIR/llvm-readelf"
    OBJCOPY="$CLANG_DIR/llvm-objcopy"
else
    err "找不到 OHOS clang:$CLANG(设 ZIP_CC 指定交叉编译器)"
fi
# 上游源码是 K&R 原型 + 老式声明,clang 15 下这一串只是噪音(不是错误),
# 关掉之后 make.log 里剩下的才是真问题。
WARN_OFF="-Wno-deprecated-non-prototype -Wno-implicit-function-declaration \
          -Wno-int-conversion -Wno-parentheses -Wno-unused-variable"

# 单次下载(带续传;代理下 deb.debian.org 偶尔会断)
fetch() {
    local url="$1" out="$2" sha="$3"
    if [ -f "$out" ] && echo "$sha  $out" | sha256sum -c - >/dev/null 2>&1; then
        log "源码已在:$out"; return 0
    fi
    local n=0
    while :; do
        n=$((n + 1))
        if curl -L -C - --connect-timeout 20 --max-time 300 -sS "$url" -o "$out"; then break; fi
        [ "$n" -ge 8 ] && err "连续 $n 次下载失败:$url"
        log "下载中断,续传(第 $n 次)"
        sleep 3
    done
    echo "$sha  $out" | sha256sum -c - || err "sha256 校验失败:$out"
}

# ── 1. 源码 ────────────────────────────────────────────────
do_src() {
    mkdir -p "$ROOT/thirdparty" "$BUILD_ROOT"
    fetch "$ZIP_URL"   "$ROOT/thirdparty/zip_${ZIP_VER}.orig.tar.gz"     "$ZIP_SHA256"
    fetch "$UNZIP_URL" "$ROOT/thirdparty/unzip_${UNZIP_VER}.orig.tar.gz" "$UNZIP_SHA256"
    [ -f "$SRC_ZIP/unix/Makefile" ]   || tar -xzf "$ROOT/thirdparty/zip_${ZIP_VER}.orig.tar.gz"   -C "$BUILD_ROOT"
    [ -f "$SRC_UNZIP/unix/Makefile" ] || tar -xzf "$ROOT/thirdparty/unzip_${UNZIP_VER}.orig.tar.gz" -C "$BUILD_ROOT"
    [ -f "$SRC_ZIP/unix/Makefile" ]   || err "源码树不完整:$SRC_ZIP"
    [ -f "$SRC_UNZIP/unix/Makefile" ] || err "源码树不完整:$SRC_UNZIP"
    log "源码就绪:$SRC_ZIP / $SRC_UNZIP"
}

# ── 2. 编译 ────────────────────────────────────────────────
# 上游 flags 文件里带引号(CC="… --target=…"),所以取用时必须 eval ——
# $(cat flags) 直接展开的话 shell 会按空格重新分词,把 --target=… 当成 make 的选项
# (报 "make: unrecognized option '--target=aarch64-linux-ohos'")。
do_build() {
    do_src
    mkdir -p "$BUILD_ROOT"
    log "==> zip $ZIP_VER(make flags + zip)"
    # CFLAGS_NOOPT 进 flags 文件,最终的 CFLAGS = "-O2 $(CFLAGS_NOOPT)";
    # -fPIC 必须在这里给:上游默认非 PIC,进 so 会报 R_AARCH64_ADR_PREL_PG_HI21 之类重定位错。
    ( cd "$SRC_ZIP" && rm -f *.o zip flags && \
      eval make -f unix/Makefile flags CC="\"$CC\"" \
           CFLAGS_NOOPT="\"-I. -DUNIX -fPIC $WARN_OFF\"" > "$BUILD_ROOT/zip-flags.log" 2>&1 \
        || { tail -20 "$BUILD_ROOT/zip-flags.log" >&2; err "zip: 生成 flags 失败"; } && \
      eval make -f unix/Makefile zip $(cat flags) > "$BUILD_ROOT/zip-make.log" 2>&1 ) \
        || { tail -30 "$BUILD_ROOT/zip-make.log" >&2; err "zip: 编译失败($BUILD_ROOT/zip-make.log)"; }
    [ -f "$SRC_ZIP/zip.o" ] || err "zip: 没产出 zip.o"

    log "==> unzip $UNZIP_VER(make flags + unzip)"
    # unzip 那边 flags 目标读的是 CF_NOOPT(不是 CFLAGS_NOOPT)。
    #
    # -DNO_WORKING_ISPRINT 是给 unzip 的**本地化显示**补的一刀,原因在 OHOS 的
    # ctype.h:它把 ctype 一族定义成
    #     #define isprint(a) (0 ? isprint(a) : ((unsigned)(a)-0x20) < 0x5f)
    # 也就是"永远按 ASCII 判"的宏(musl 风格,不随 locale 变)。而 unzip 的
    # unix/unxcfg.h 默认认为宿主 isprint 是 ANSI/locale 感知的,于是打开
    # HAVE_WORKING_ISPRINT,fnfilter()(extract.c:2588)走"不可打印 → 换成 ?"那条,
    # 结果 `unzip -l` 把中文名印成 ????/ 。这个宏是编译期内联的,**用 shim 遮蔽
    # 符号修不了**,只能在上游给的开关上关掉它:unxcfg.h 里 NO_WORKING_ISPRINT
    # 正是为这种 libc 准备的。全树查过,HAVE_WORKING_ISPRINT 只被 fnfilter 用到,
    # 所以影响面就是"显示名不再过滤 0x80-0xFF"(ESC 等 <0x20 的控制字符照样转义,
    # 注入面没变大),解包写盘用的始终是 G.filename 原始字节,不受影响。
    ( cd "$SRC_UNZIP" && rm -f *.o unzip flags && \
      eval make -f unix/Makefile flags CC="\"$CC\"" \
           CF_NOOPT="\"-I. -DUNIX -fPIC -DNO_WORKING_ISPRINT $WARN_OFF\"" \
           > "$BUILD_ROOT/unzip-flags.log" 2>&1 \
        || { tail -20 "$BUILD_ROOT/unzip-flags.log" >&2; err "unzip: 生成 flags 失败"; } && \
      eval make -f unix/Makefile unzip $(cat flags) > "$BUILD_ROOT/unzip-make.log" 2>&1 ) \
        || { tail -30 "$BUILD_ROOT/unzip-make.log" >&2; err "unzip: 编译失败($BUILD_ROOT/unzip-make.log)"; }
    [ -f "$SRC_UNZIP/unzip.o" ] || err "unzip: 没产出 unzip.o"

    log "上游 configure 自动探测到的 -D 开关:"
    grep -o '\-D[A-Z_0-9]*' "$SRC_ZIP/flags"   | sort -u | tr '\n' ' ' \
        | sed 's/^/    zip:   /' >&2; echo >&2
    grep -o '\-D[A-Z_0-9]*' "$SRC_UNZIP/flags" | sort -u | tr '\n' ' ' \
        | sed 's/^/    unzip: /' >&2; echo >&2
    log "✅ 编译完成(zip / unzip)"
}

# ── 3. 链接成命令 so ───────────────────────────────────────
compile_common() {
    mkdir -p "$OBJDIR"
    log "==> 编译公共对象(exec 委托 / tty shim)"
    $CC -O2 -fPIC -DBSH_SHIM_WRAP -I"$SHIM_SRC_DIR" -I"$TC_DIR/procmgr" -c "$SHIM_SRC_DIR/exec_shim.c" -o "$OBJDIR/exec_shim.o"
    $CC -O2 -fPIC -I"$TC_DIR/procmgr" -c "$TC_DIR/procmgr/bsh_client.c" -o "$OBJDIR/bsh_client.o"
FS_OBJ="$OBJDIR/fs_shim.o"
OPEN_OBJ="$OBJDIR/open_shim.o"
$CC -O2 -fPIC -DBSH_SHIM_WRAP -DBSH_SHIM_MERGED_OPEN -I"$SHIM_SRC_DIR" -c "$SHIM_SRC_DIR/fs_shim.c" -o "$FS_OBJ"
$CC -O2 -fPIC -DBSH_SHIM_WRAP -I"$SHIM_SRC_DIR" -c "$SHIM_SRC_DIR/open_shim.c" -o "$OPEN_OBJ"

    $CC -O2 -fPIC -I"$TC_DIR/tty" -I"$TC_DIR/procmgr" \
        -DBSH_SHIM_WRAP -DBSH_SHIM_MERGED_OPEN -c "$SHIM_SRC_DIR/tty_shim.c" -o "$OBJDIR/tty_shim.o"
}

# relink_one <源目录> <原 main 所在对象> <入口符号> <so 输出路径> <soname>
relink_one() {
    local src="$1" mainobj="$2" entry="$3" out="$4" soname="$5"
    local renamed="$OBJDIR/${mainobj%.o}_${entry}.o"
    # 幂等:刚 build 过就以新对象为准(顺手清掉上次的 .bak);只有在没重编过时才还原。
    # 改名结果放 $OBJDIR,不落回 $src/*.o —— 否则改名版和原版会一起进链接,
    # 两套 main 的兄弟符号撞定义。
    if [ -f "$src/$mainobj" ]; then
        rm -f "$src/.$mainobj.bak"
    elif [ -f "$src/.$mainobj.bak" ]; then
        mv -f "$src/.$mainobj.bak" "$src/$mainobj"
    else
        err "缺 $src/$mainobj(先跑 ./scripts/build_zip.sh build)"
    fi

    log "==> 入口改名: $mainobj 的 main → $entry"
    "$OBJCOPY" --redefine-sym "main=$entry" "$src/$mainobj" "$renamed" \
        || err "objcopy 改名失败:$src/$mainobj"
    mv "$src/$mainobj" "$src/.$mainobj.bak"

    log "==> 聚合 $out"
    mkdir -p "$(dirname "$out")"
    # shellcheck disable=SC2086
    $CC -shared -o "$out" \
        "$src"/*.o "$renamed" \
        "$OBJDIR"/exec_shim.o "$OBJDIR"/bsh_client.o "$OBJDIR"/tty_shim.o "$FS_OBJ" "$OPEN_OBJ" \
        -Wl,-soname,"$soname" \
        $SHIM_WRAP_FLAGS \
        -Wl,-Bsymbolic-functions \
        > "$BUILD_ROOT/$(basename "$out").link.log" 2>&1 \
        || { tail -30 "$BUILD_ROOT/$(basename "$out").link.log" >&2; \
             err "链接失败:$out(见 $BUILD_ROOT/$(basename "$out").link.log)"; }

    # 未定义符号故意留着(dlopen 时从进程全局作用域解析);这里只核对入口与 NEEDED。
    "$NM" -D --defined-only "$out" | grep -qE " $entry\$" || err "$out 未导出 $entry"
    "$READELF" -d "$out" | grep -E 'NEEDED|SONAME' | sed 's/^/    /' >&2
    log "✅ $out ($(du -h "$out" | cut -f1))"
}

do_link() {
    [ -f "$SRC_ZIP/zip.o" ]     || do_build
    [ -f "$SRC_UNZIP/unzip.o" ] || do_build
    compile_common
    relink_one "$SRC_ZIP"   zip.o   bsh_zip_main   "$OUT_ZIP"   libzipcmd.so
    relink_one "$SRC_UNZIP" unzip.o bsh_unzip_main "$OUT_UNZIP" libunzipcmd.so
}

# ── 4. 安装 ────────────────────────────────────────────────
# feature/bsh_main/libs/$NATIVE_ARCH 下的 .so 会随 HAP 打包(kSoMain 按 so 名从 bundle 的
# lib 目录 dlopen)。这一步只做搬运 + 出口核对。
do_install() {
    [ -f "$OUT_ZIP" ] && [ -f "$OUT_UNZIP" ] || do_link
    mkdir -p "$HAP_LIBS_DIR"
    cp -f "$OUT_ZIP" "$OUT_UNZIP" "$HAP_LIBS_DIR/"
    log "==> 已装入 $HAP_LIBS_DIR(随 HAP 打包):"
    ls -la "$HAP_LIBS_DIR/libzipcmd.so" "$HAP_LIBS_DIR/libunzipcmd.so" | sed 's/^/    /' >&2
    "$NM" -D --defined-only "$HAP_LIBS_DIR/libzipcmd.so"   | grep -E ' bsh_zip_main$'   | sed 's/^/    /' >&2
    "$NM" -D --defined-only "$HAP_LIBS_DIR/libunzipcmd.so" | grep -E ' bsh_unzip_main$' | sed 's/^/    /' >&2
}

case "$PHASE" in
    src)     do_src ;;
    build)   do_build ;;
    link)    do_link ;;
    install) do_install ;;
    all)     do_build; do_link; do_install ;;
    *)       err "用法: $0 [src|build|link|install|all]" ;;
esac
log "✅ build_zip.sh 完成(阶段 $PHASE)"
