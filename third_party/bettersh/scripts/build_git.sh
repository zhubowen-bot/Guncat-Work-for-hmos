#!/bin/bash
# build_git.sh — 把 git 交叉编成 pkg 的**可执行包**（`git`），装到资源根后能直接 `git clone`
#
# 与 `devtools` / `weston-terminal` 同一个形态：**pkg 的包**（dist/pkgs/git.tar.zst），
# 顶层 usr/，安装 = `tar -C <资源根> -x`；不进 HAP，也不做成命令 so。
#
# ── 为什么是"可执行文件"而不是命令 so ────────────────────────────────
# git 是个会**大量 exec 自己人**的程序（`git-remote-http` 助手、hook、pager、ssh、
# 用户配置的 editor）。命令 so 形态跑在宿主进程里，exec 要靠 exec_shim 委托 procmgr，
# 而 git 的 fork/exec 模式（管道、双向 socketpair、`silent_exec_failure`）比 make
# 复杂得多 —— 做成 guest 可执行，直接用我们已经验证过的那整条通路更稳。
#
# ── 为什么必须**动态链接 musl**（不能 -static）───────────────────────
# 与 build_devtools.sh 同一条理由：静态 guest 吃不到 LD_PRELOAD 的 shim
# （`[elf] loaded ET_EXEC`），exec/execvp 会**直接打到内核** → 资源根是 noexec →
# 内核给 EACCES → `git clone ssh://…` 里那次 `ssh`、`git commit` 里那次 editor 全死。
# 动态之后 libbshguest-musl.so 生效 → exec 委托生效 → 那些 exec 走 procmgr。
# 顺带白拿 fs_shim 的 `BSH_SYMLINK` 用户态软链（git 在 sandbox 里建不出真 symlink）。
#
# ── 依赖闭包（全部**静态**链进 git 这一个二进制）─────────────────────
#   zlib      libz.a        ← build/sysroot-ext-<arch>/usr/lib/<triple>/（build_weston_deps.sh 的产物）
#   pcre2     libpcre2-8.a  ← 同上
#   openssl   libssl.a/libcrypto.a ← build/openssl（build_openssl.sh，no-shared）
#   curl      libcurl.a     ← 本脚本第一段现编（静态；带 openssl + zlib）
# 静态的理由：资源根是 noexec，guest 的 .so 要靠补丁过的 ld.so 才映射得起来；多个
# 第三方 .so 就多几处"装到设备上才发现加载不了"的风险，而 git 不需要共享这些库。
# 注意这只对**第三方库**成立 —— libc/ld 必须动态（见上）。
#
# ── 装出来的布局与两个环境变量 ──────────────────────────────────────
#   usr/bin/git                          **启动器脚本**（见下）
#   usr/libexec/git-core/git             真二进制
#   usr/libexec/git-core/git-remote-http  curl 传输助手（git 会 exec 它）
#   usr/libexec/git-core/git-remote-https 同一份二进制的副本（上游是硬链，pkg 不能有软链/硬链）
#   usr/share/git-core/templates         `git init` 的模板（hooks/description/info/exclude）
#   usr/share/git-core/cacert.pem        HTTPS 用的 CA bundle（Mozilla 根证书，curl.se 出的）
#   usr/share/git-core/gitconfig         启动器 --system 指向的配置（见下）
#
# 为什么 `usr/bin/git` 是**启动器脚本**而不是二进制：三件事必须在运行期才知道路径 ——
#
#   1) GIT_EXEC_PATH：git 找 `git-remote-http` 的地方。编进去的默认值是**绝对路径**
#      `/usr/libexec/git-core`（构建时的 --prefix=/usr），而实际装在资源根下的
#      `<资源根>/usr/libexec/git-core`。不设它，`git clone https://…` 直接报
#      "unable to find remote helper for 'https'"。
#   2) GIT_TEMPLATE_DIR：同上，编进去的是 `/usr/share/git-core/templates`。
#   3) GIT_SSL_CAINFO：设备上没有 /etc/ssl/certs，CA bundle 只能随包走。
#
# 三件事都在启动器里按 `$BSH_SYSROOT`（拿不到就按 `$0` 的上级目录推）算出来，
# 与 code-server 的启动器同一个套路 —— 挪布局只改一处。
#
# ── 刻意**不做**的东西（省体积，也避免"看着有其实不通"）─────────────
#   * 那 100 多个 `git-<cmd>` 硬链：git 的内建命令在**同一个进程里**派发，根本不会
#     exec 它们（`SKIP_DASHED_BUILT_INS=YesPlease` 让上游别装）。只有 `git-remote-http`
#     这类**非内建**的助手才会被 exec，所以只留那两个。
#   * i18n（NO_GETTEXT）：省掉几百个 .mo，也免了 iconv。
#   * Perl/Python/TclTk 的脚本与 GUI（NO_PERL / NO_PYTHON / NO_TCLTK）：设备上没这些
#     解释器的那几个是命令 so，git 的 perl 脚本靠它们跑不起来，装了也是坏的。
#   * expat（NO_EXPAT）：只影响 `git http-push` 与"哑 HTTP"（dumb protocol）—— 前者没
#     人用，后者服务器早就不这么发了。
#
# 用法：scripts/build_git.sh [deps|build|pack|all]   （GIT_REBUILD=1 强制重来）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PHASE="${1:-all}"

GIT_VER="${GIT_VER:-2.56.0}"
CURL_VER="${CURL_VER:-8.22.0}"

GIT_SRC="$ROOT/build/git-src"
GIT_BLD="$ROOT/build/git-bld"
GIT_DEST="$ROOT/build/git-dest"
CURL_SRC="$ROOT/build/curl-src"
CURL_BLD="$ROOT/build/curl-bld"
CURL_PREFIX="$ROOT/build/curl"
CACERT="$ROOT/build/git-ca/cacert.pem"
STAGE="$ROOT/build/git-pkg"
OUT_PKG="$ROOT/dist/pkgs/git.tar.zst"

DEPS_LIB="$SYSROOT_EXT_LIB"                 # zlib/pcre2 的静态库所在（build_weston_deps.sh 产出）
DEPS_INC="$SYSROOT_EXT_INC"

CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT"
TRIPLE_FLAGS="--target=$TARGET --sysroot=$SYSROOT"
AR="$CLANG_DIR/llvm-ar"
RANLIB="$CLANG_DIR/llvm-ranlib"
STRIP="$CLANG_DIR/llvm-strip"
READELF="$CLANG_DIR/llvm-readelf"

# 与 build_devtools.sh 完全同源的两条：
#   * 解释器写 /lib/ld-musl-aarch64.so.1 —— bundle libs 里那份 musl loader 的固定位置；
#     procmgr 按 PT_INTERP 的 basename 去 bundle libs 找它。
#   * 关 fortify —— OHOS 的 sys/select.h 把 FD_SET/FD_CLR 展开成 __fd_chk(fd)（OHOS musl
#     私有），而 bundle 里那份是 vanilla musl 1.2.2、没这个符号；git 的 run-command /
#     pager 路径会碰 select。不关就是运行期 "Error relocating git: __fd_chk: symbol not found"。
LD_MUSL="-Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1"
NO_FORTIFY="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"

fetch_src() {   # $1=tar 路径 $2=解压目标目录 $3..=候选 URL
    local tar="$1" dest="$2"; shift 2
    [ -e "$dest" ] && return 0
    if [ ! -s "$tar" ]; then
        log "下载 $(basename "$tar")"
        local ok= u
        for u in "$@"; do
            if curl -sL --retry 3 -m 900 -o "$tar.part" "$u" && [ -s "$tar.part" ]; then
                mv "$tar.part" "$tar"; ok=1; break
            fi
        done
        [ -n "$ok" ] || err "下载失败：$tar"
    fi
    mkdir -p "$dest"
    case "$tar" in
        *.tar.xz) tar xf "$tar" -C "$dest" --strip-components=1 ;;
        *)        tar xzf "$tar" -C "$dest" --strip-components=1 ;;
    esac
}

# ══ 1. deps：静态 libcurl（openssl + zlib）════════════════════════════
do_deps() {
    [ -f "$DEPS_LIB/libz.a" ]      || err "缺 $DEPS_LIB/libz.a —— 先跑 scripts/build_weston_deps.sh"
    [ -f "$DEPS_LIB/libpcre2-8.a" ]|| err "缺 $DEPS_LIB/libpcre2-8.a —— 先跑 scripts/build_weston_deps.sh"
    [ -f "$BUILD_DIR/openssl/lib/libssl.a" ] \
        || err "缺 $BUILD_DIR/openssl/lib/libssl.a —— 先跑 scripts/build_openssl.sh"

    if [ -f "$CURL_PREFIX/lib/libcurl.a" ] && [ -z "${GIT_REBUILD:-}" ]; then
        log "libcurl 已在：$CURL_PREFIX/lib/libcurl.a"
    else
        fetch_src "$ROOT/thirdparty/curl-$CURL_VER.tar.gz" "$CURL_SRC" \
            "https://curl.se/download/curl-$CURL_VER.tar.gz" \
            "https://github.com/curl/curl/releases/download/curl-$CURL_VER/curl-$CURL_VER.tar.gz"
        [ -f "$CURL_SRC/configure" ] || err "curl 源码结构异常：$CURL_SRC"

        log "=== 配置 curl（静态，openssl + zlib）==="
        rm -rf "$CURL_BLD"; mkdir -p "$CURL_BLD"
        ( cd "$CURL_BLD" && \
          "$CURL_SRC/configure" \
            --host="$HOST_TRIPLE" --build=x86_64-pc-linux-gnu \
            --prefix="$CURL_PREFIX" --libdir="$CURL_PREFIX/lib" \
            --disable-shared --enable-static \
            --with-openssl="$BUILD_DIR/openssl" \
            --with-zlib="$SYSROOT_EXT/usr" \
            --without-libpsl --without-libidn2 --without-brotli --without-zstd \
            --without-nghttp2 --without-nghttp3 --without-ngtcp2 --without-quiche \
            --without-librtmp --without-libssh2 --without-zstd \
            --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet \
            --disable-tftp --disable-pop3 --disable-imap --disable-smtp --disable-gopher \
            --disable-mqtt --disable-smb --disable-ftp --disable-file --disable-docs \
            --disable-manual --disable-libcurl-option --disable-versioned-symbols \
            CC="$CC_TARGET -fuse-ld=lld $NO_FORTIFY" AR="$AR" RANLIB="$RANLIB" \
            CFLAGS="-O2 -fPIC" \
            LDFLAGS="-fuse-ld=lld $TRIPLE_FLAGS" \
            > "$ROOT/build/git-curl-configure.log" 2>&1 ) || {
                tail -40 "$ROOT/build/git-curl-configure.log" >&2 || true
                err "curl configure 失败：build/git-curl-configure.log"
            }
        log "=== 编译 curl ==="
        make -C "$CURL_BLD" -j"$JOBS" > "$ROOT/build/git-curl-make.log" 2>&1 \
            || { tail -40 "$ROOT/build/git-curl-make.log" >&2; err "curl make 失败（build/git-curl-make.log）"; }
        # 只装库、头与 .pc（不装 curl 工具本身：我们不需要它，也不该让它在 PATH 上冒出来）。
        # 注意 `install-exec` 只装 lib/bin，**头文件在 install-data 里** —— 少装这一步
        # 的症状是 git 编到 help.o 才报 `curl/curl.h file not found`（踩过）。
        make -C "$CURL_BLD" install-exec install-data install-pkgconfigDATA \
            > "$ROOT/build/git-curl-install.log" 2>&1 || true
        rm -f "$CURL_PREFIX/bin/curl"
        [ -f "$CURL_PREFIX/lib/libcurl.a" ] || {
            tail -30 "$ROOT/build/git-curl-install.log" >&2 || true
            err "没产出 $CURL_PREFIX/lib/libcurl.a"
        }
        log "libcurl 就绪：$(du -h "$CURL_PREFIX/lib/libcurl.a" | cut -f1)"
    fi

    # curl-config 桩：git 的 Makefile 只用它问 `--vernum`（问到一个 >= 072200 的值才会
    # 走 USE_CURL_FOR_IMAP_SEND 分支，否则 imap-send 会去链 openssl 自己那套）。
    # 真正的 --cflags/--libs 由我们在 make 命令行上显式给，不依赖这个桩。
    mkdir -p "$CURL_PREFIX/bin"
    cat > "$CURL_PREFIX/bin/curl-config" <<EOF
#!/bin/sh
case "\$1" in
  --vernum) echo 082200 ;;
  --version) echo "$CURL_VER" ;;
  --cflags) echo "-I$CURL_PREFIX/include" ;;
  --libs)   echo "-L$CURL_PREFIX/lib -lcurl -lssl -lcrypto -lz" ;;
  --static-libs) echo "-L$CURL_PREFIX/lib -lcurl -lssl -lcrypto -lz" ;;
  --ssl-backends) echo "OpenSSL" ;;
  --protocols) echo "http https" ;;
  *) ;;
esac
EOF
    chmod 0755 "$CURL_PREFIX/bin/curl-config"

    # CA bundle：设备上没有 /etc/ssl/certs，HTTPS 只能靠随包带一份根证书
    if [ ! -s "$CACERT" ]; then
        mkdir -p "$(dirname "$CACERT")"
        log "下载 CA bundle（curl.se 的 Mozilla 根证书）"
        curl -sL --retry 3 -m 300 -o "$CACERT.part" https://curl.se/ca/cacert.pem \
            && mv "$CACERT.part" "$CACERT" || err "CA bundle 下载失败"
    fi
    log "CA bundle：$CACERT（$(grep -c 'BEGIN CERTIFICATE' "$CACERT") 张证书）"
}

# ══ 2. build：编 git 并 install 到 DESTDIR ════════════════════════════
do_build() {
    [ -f "$CURL_PREFIX/lib/libcurl.a" ] || do_deps
    fetch_src "$ROOT/thirdparty/git-$GIT_VER.tar.xz" "$GIT_SRC" \
        "https://www.kernel.org/pub/software/scm/git/git-$GIT_VER.tar.xz" \
        "https://mirrors.edge.kernel.org/pub/software/scm/git/git-$GIT_VER.tar.xz"
    [ -f "$GIT_SRC/Makefile" ] || err "git 源码结构异常：$GIT_SRC"

    rm -rf "$GIT_DEST"

    # musl 只声明不实现的那几个 pthread 取消 API（原因与"为什么返回 0 是对的"见
    # scripts/git-ohos/pthread_cancel_stub.c 的文件头）。走 git 的 LDFLAGS_APPEND
    # 钩子参与链接 —— 不能做成头文件里的 static inline，会和 pthread.h 已有的
    # extern 声明撞。
    local STUB_OBJ="$ROOT/build/git-compat/pthread_cancel_stub.o"
    mkdir -p "$(dirname "$STUB_OBJ")"
    "$CLANG" --target=$TARGET --sysroot=$SYSROOT -O2 -fPIC -c \
        "$SCRIPT_DIR/git-ohos/pthread_cancel_stub.c" -o "$STUB_OBJ" \
        || err "编 pthread 取消兜底失败"

    log "=== 编 git $GIT_VER 并 install 到 $GIT_DEST/usr ==="
    # 关掉几个 autoconf 风格的**运行期**探测（git 的 Makefile 有几处 $(shell …) 会去跑
    # 宿主上的 curl-config/编译器探针，交叉编译下结论不可信，所以一律显式给值）。
    make -C "$GIT_SRC" -j"$JOBS" \
        prefix=/usr \
        gitexecdir=/usr/libexec/git-core \
        template_dir=/usr/share/git-core/templates \
        DESTDIR="$GIT_DEST" \
        CC="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld" \
        AR="$AR" RANLIB="$RANLIB" \
        CFLAGS="-O2 -fPIC -I$DEPS_INC $NO_FORTIFY" \
        LDFLAGS="-fuse-ld=lld $TRIPLE_FLAGS -L$DEPS_LIB -L$BUILD_DIR/openssl/lib -L$CURL_PREFIX/lib $LD_MUSL" \
        LDFLAGS_APPEND="$STUB_OBJ" \
        NO_GETTEXT=YesPlease NO_ICONV=YesPlease NO_PERL=YesPlease NO_PYTHON=YesPlease \
        NO_TCLTK=YesPlease NO_EXPAT=YesPlease NO_INSTALL_HARDLINKS=YesPlease \
        SKIP_DASHED_BUILT_INS=YesPlease \
        NO_REGEX=NeedsStartEnd \
        NO_RUST=YesPlease \
        USE_LIBPCRE2=YesPlease \
        ZLIB_PATH="$SYSROOT_EXT/usr" \
        OPENSSLDIR="$BUILD_DIR/openssl" \
        CURLDIR="$CURL_PREFIX" \
        CURL_CFLAGS="-I$CURL_PREFIX/include" \
        CURL_LDFLAGS="-L$CURL_PREFIX/lib -lcurl -lssl -lcrypto -lz" \
        CURL_CONFIG="$CURL_PREFIX/bin/curl-config" \
        all install \
        > "$ROOT/build/git-make.log" 2>&1 \
        || { tail -50 "$ROOT/build/git-make.log" >&2; err "git 构建失败（build/git-make.log）"; }
    [ -x "$GIT_DEST/usr/bin/git" ] || err "没产出 $GIT_DEST/usr/bin/git"

    # NEEDED 只该有 libc：第三方库必须全是静态链进去的，否则设备上找不到 .so
    local bad
    bad="$("$READELF" -d "$GIT_DEST/usr/bin/git" | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF); print $NF}' \
          | grep -Ev '^(libc\.so|libc\.so\.6|libpthread\.so\.0|libm\.so\.6|libdl\.so\.2|librt\.so\.1|libgcc_s\.so\.1)$' || true)"
    [ -z "$bad" ] || err "git 动态依赖里有非 libc 的库：$bad（说明第三方库没静态链进去）"
    log "git 二进制：$(du -h "$GIT_DEST/usr/bin/git" | cut -f1)"
}

# ══ 3. pack：铺暂存树 → tar.zst ═══════════════════════════════════════
do_pack() {
    [ -x "$GIT_DEST/usr/bin/git" ] || do_build

    log "=== 铺暂存树 → $STAGE ==="
    rm -rf "$STAGE"
    mkdir -p "$STAGE/usr/bin" "$STAGE/usr/libexec/git-core" "$STAGE/usr/share/git-core"

    # 真二进制搬到 libexec（同时它就位在 GIT_EXEC_PATH 里），usr/bin 留给启动器
    cp -f "$GIT_DEST/usr/bin/git" "$STAGE/usr/libexec/git-core/git"
    chmod 0755 "$STAGE/usr/libexec/git-core/git"

    # libexec 里只装三类：
    #   1) 三份 ELF —— git 本体与 curl 的两个传输助手（`git clone https://` 时 git 会
    #      exec 后者）；
    #   2) 上游**用 shell 写的**子命令与 shell 库（git-mergetool / git-submodule /
    #      git-request-pull / git-filter-branch / git-quiltimport / git-merge-* /
    #      git-difftool--helper / git-web--browse，以及被 source 的 git-sh-setup /
    #      git-sh-i18n / git-mergetool--lib）—— 几十 KB 一个，缺了对应子命令就没了；
    #   3) 别的都不要。
    #
    # perl/python 那几个（git-svn / git-p4 / git-instaweb / git-send-email / git-cvsserver /
    # git-archimport / git-cvsimport / git-cvsexportcommit）**装不了也装不对**：上游
    # install 出来的是 `#!/bin/sh` 的**壳**（内容是 exec perl/python），设备上的
    # python 是命令 so、perl 根本没有，装了只是"看着有、一跑就错"。按名字排除 ——
    # 按 shebang 排不掉，那些壳自己就是 sh。
    #
    # 其余 ELF（git-http-backend 是服务端、git-daemon、git-shell、git-remote-ftp(s)、
    # git-http-fetch、git-imap-send、scalar）按"非上述三份就跳过"处理。
    local skipped="" b
    keep_elf() {
        case "$1" in git|git-remote-http|git-remote-https) return 0 ;; *) return 1 ;; esac
    }
    for f in "$GIT_DEST/usr/libexec/git-core"/*; do
        [ -f "$f" ] || continue
        b="$(basename "$f")"
        case "$b" in
            git-svn|git-p4|git-instaweb|git-send-email|git-cvsserver|git-archimport|\
            git-cvsimport|git-cvsexportcommit)
                skipped="$skipped $b"; continue ;;
        esac
        if [ "$(head -c 4 "$f")" = "$(printf '\177ELF')" ]; then
            keep_elf "$b" || { skipped="$skipped $b"; continue; }
        fi
        cp -f "$f" "$STAGE/usr/libexec/git-core/$b"
        chmod 0755 "$STAGE/usr/libexec/git-core/$b"
    done
    log "libexec：$(ls "$STAGE/usr/libexec/git-core" | tr '\n' ' ')"
    log "  跳过：$skipped"

    # 模板 + mergetools：`git init` 会读 templates（没有只是少几个 hook，但 `git mergetool`
    # 要靠 mergetools/ 里的定义，几 KB 的事）。同样只用普通文件，软链一律展开。
    cp -a "$GIT_DEST/usr/share/git-core/templates" "$STAGE/usr/share/git-core/"
    if [ -d "$GIT_DEST/usr/share/git-core/mergetools" ]; then
        cp -a "$GIT_DEST/usr/share/git-core/mergetools" "$STAGE/usr/share/git-core/"
    fi
    cp -f "$CACERT" "$STAGE/usr/share/git-core/cacert.pem"

    # ── 启动器 ────────────────────────────────────────────────────────
    # `usr/bin/` 下要**四个**名字：`git` 自己，加上 `git-upload-pack` /
    # `git-receive-pack` / `git-upload-archive`。
    #
    # 后三个不是摆设：git 连**本地**仓库（`git clone <目录>`、`git fetch <目录>`）走的是
    # smart 传输，它会 `/bin/sh -c "git-upload-pack '<路径>'"` —— 这次 exec 是**由 shell
    # 按 PATH 找名字**的，跟 GIT_EXEC_PATH 无关。上游正是为此把这三个装进 bindir
    # （Makefile 的 `BINDIR_PROGRAMS_NO_X`）。我们又不带 exec-path 里那堆 `git-<cmd>`
    # 副本（SKIP_DASHED_BUILT_INS），所以更得把它们补在 PATH 上。实测缺了它们的症状：
    #     git-upload-pack '/…/a/.git': git-upload-pack: inaccessible or not found
    # 这三个都是**内建命令**（`git upload-pack` 在同一个进程里就能跑），启动器只负责转发。
    #
    # 为什么是脚本而不是二进制副本：三个副本要 13MB，而它们只是换一个子命令名。
    # 启动器里那三件事（GIT_EXEC_PATH / GIT_TEMPLATE_DIR / GIT_SSL_CAINFO）都是运行期才
    # 知道的路径，编进二进制里的是构建前缀 `/usr/...`，与装在资源根下的实际位置对不上。
    local env_text='root="${BSH_SYSROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
GIT_EXEC_PATH="$root/usr/libexec/git-core"
GIT_TEMPLATE_DIR="$root/usr/share/git-core/templates"
export GIT_EXEC_PATH GIT_TEMPLATE_DIR
# link(2) 在本沙箱里被拒（release 构建一律 EACCES），fs_shim 的兜底会把它变成一次
# 「复制」而**返回成功**。git 的本地克隆会核对 link 的结果（比 st_ino/st_dev），
# 发现不是同一个 inode 就 fatal: hardlink different from source —— 它预期的是
# "link 失败，我自己退化成复制"。所以这里请 shim 报内核的真相。
BSH_SHIM_LINK_STRICT=1
export BSH_SHIM_LINK_STRICT
# 设备上没有 /etc/ssl/certs，CA bundle 只能随包走
[ -n "${GIT_SSL_CAINFO:-}" ] || GIT_SSL_CAINFO="$root/usr/share/git-core/cacert.pem"
export GIT_SSL_CAINFO
# curl 自己也认这个（git 的 http 走 libcurl；两边都设，免得某条路径绕过 git 的设置）
[ -n "${CURL_CA_BUNDLE:-}" ] || CURL_CA_BUNDLE="$GIT_SSL_CAINFO"
export CURL_CA_BUNDLE'
    mk_launcher() {   # $1 = usr/bin 下的名字；$2 = 转发给 git 的子命令（空 = 不转）
        local f="$STAGE/usr/bin/$1"
        {
            echo '#!/bin/sh'
            echo "# git 启动器（$1）—— 由 pkg 的 \`git\` 包安装到 <资源根>/usr/bin/"
            echo '# 路径按 $BSH_SYSROOT 算，拿不到就按脚本自身位置推（<资源根>/usr/bin/..）——'
            echo '# 两条路都不依赖 cwd，也不依赖 PATH 里先被别的 git 抢到。'
            printf '%s\n' "$env_text"
            if [ -n "${2:-}" ]; then
                printf 'exec "$root/usr/libexec/git-core/git" %s "$@"\n' "$2"
            else
                printf 'exec "$root/usr/libexec/git-core/git" "$@"\n'
            fi
        } > "$f"
        chmod 0755 "$f"
    }
    mk_launcher git ""
    mk_launcher git-upload-pack upload-pack
    mk_launcher git-receive-pack receive-pack
    mk_launcher git-upload-archive upload-archive

    # 软链一律展开（pkg 的 bsh_tar.c 只认普通文件/目录）
    local nfill=0 l tgt
    while IFS= read -r l; do
        tgt="$(readlink -f "$l")" || err "断链：$l"
        case "$tgt" in "$STAGE"/*) ;; *) err "软链指向树外：$l -> $tgt" ;; esac
        cp -L "$tgt" "$l.new" && mv -f "$l.new" "$l" && nfill=$((nfill+1))
    done < <(find "$STAGE" -type l)
    [ "$nfill" = 0 ] || log "把 $nfill 个软链展开成真文件"

    "$STRIP" --strip-all "$STAGE/usr/libexec/git-core/git" \
                          "$STAGE/usr/libexec/git-core/git-remote-http" \
                          "$STAGE/usr/libexec/git-core/git-remote-https" 2>/dev/null || true

    mkdir -p "$(dirname "$OUT_PKG")"
    tar -C "$STAGE" -cf - usr | zstd -q -f -19 -T"$JOBS" -o "$OUT_PKG"
    [ -s "$OUT_PKG" ] || err "包是空的"

    # ── 自检 ──
    # 清单先落文件再查：`zstd -dc | tar -t | grep -q` 在 pipefail 下会被 SIGPIPE 判失败
    # （本仓库在 build_testprogs / pack_codeserver 都踩过）。
    tar --zstd -tf "$OUT_PKG" > "$ROOT/build/git-pkg-list.txt"
    tar --zstd -tvf "$OUT_PKG" > "$ROOT/build/git-pkg-list-v.txt"
    local nlink nfile
    nlink="$(grep -c '^l' "$ROOT/build/git-pkg-list-v.txt" || true)"
    nfile="$(grep -c '^-' "$ROOT/build/git-pkg-list-v.txt" || true)"
    [ "$nlink" = "0" ] || err "包里有 $nlink 个软链 —— pkg 的 bsh_tar.c 只认普通文件/目录"
    for f in usr/bin/git usr/bin/git-upload-pack usr/bin/git-receive-pack \
             usr/bin/git-upload-archive \
             usr/libexec/git-core/git usr/libexec/git-core/git-remote-http \
             usr/libexec/git-core/git-remote-https usr/share/git-core/cacert.pem \
             usr/share/git-core/templates/description; do
        grep -q "^$f\$" "$ROOT/build/git-pkg-list.txt" || err "包里缺 $f"
    done
    for f in usr/bin/git usr/bin/git-upload-pack; do
        grep -q "^-rwx.*$f\$" "$ROOT/build/git-pkg-list-v.txt" || err "$f 丢了可执行位"
    done
    grep -q '^-rwx.*usr/libexec/git-core/git$' "$ROOT/build/git-pkg-list-v.txt" || err "libexec/git 丢了可执行位"
    log "自检：$nfile 个文件、0 个软链，启动器/二进制/助手/模板/CA 都在"

    echo
    log "✅ git：$OUT_PKG"
    log "   解包后 $(du -sh "$STAGE" | cut -f1) → $(du -h "$OUT_PKG" | cut -f1)"
    echo
    echo "index.json 需要的三项："
    echo "  \"version\": \"$GIT_VER\""
    echo "  \"file\"   : $(basename "$OUT_PKG")"
    echo "  \"size\"   : $(stat -c%s "$OUT_PKG")"
    echo "  \"sha256\" : $(sha256sum "$OUT_PKG" | cut -d' ' -f1)"
}

case "$PHASE" in
    deps)  do_deps ;;
    build) do_build ;;
    pack)  do_pack ;;
    all)   do_deps; do_build; do_pack ;;
    *)     err "用法：$0 [deps|build|pack|all]" ;;
esac
log "✅ build_git.sh 完成（阶段 $PHASE）"
