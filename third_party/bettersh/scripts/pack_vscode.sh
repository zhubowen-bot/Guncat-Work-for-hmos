#!/bin/bash
# pack_vscode.sh — 把官方 VS Code（linux-arm64）连它的依赖闭包装成一个能在设备上跑的目录
#
# ── 为什么是 glibc 路线 ─────────────────────────────────────────────────
# 官方 arm64 包的 `code` 是 **glibc** 二进制：
#     ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked,
#     interpreter /lib/ld-linux-aarch64.so.1
# 而本项目本来就有一条 glibc guest 通路（node / hdc / code-server 都是这么跑的）：
# bundle libs 里那份**打过补丁的 glibc** + 按 NEEDED 逐层收的闭包。所以不必为它造新机制。
#
# （对照：我们自己的 GTK3 探针走的是 **musl** 那条路 —— OHOS SDK clang + musl sysroot。
#   两条路各有各的闭包，别混用：musl 的 .so 与 glibc 的 .so 不能互换。）
#
# ── 依赖为什么不自己编 ──────────────────────────────────────────────────
# `code` 的 NEEDED 有 34 条，缺的 13 个是：
#   libnspr4/libnss3/libnssutil3/libsmime3（NSS）、libatk-bridge-2.0/libatspi（无障碍）、
#   libcups、libdbus-1、libX11/libXcomposite/libXdamage/libXext/libXfixes/libXrandr/libxcb、
#   libgbm、libudev、libasound
# 自己编一遍除了证明能编没有别的收益，而这些 .so 本来就是**配好的**（GTK 的 X11+wayland
# 双后端、NSS 的证书库、gbm…）。所以直接从 **Ubuntu noble 的 arm64 .deb** 里取：
#   * 版本对得上：noble 编在 glibc 2.39 上，正是 scripts/build_glibc.sh 编的那版；
#   * 我们只是**组装运行期闭包**，与 pack_codeserver.sh / pack_hdc.sh 是同一套路子
#     （那两处也是从发行版/工具链里取 .so，而不是重编）。
# 唯一要留意的是**别把发行版的 libc.so.6/ld-linux 也带进来** —— 那两个由应用自己提供
# （bundle libs 里那份打过"不做文件映射"补丁的 glibc，elfloader 路径要用）。
#
# ── 阶段 ────────────────────────────────────────────────────────────────
#   fetch   下 VS Code 包 + 两个 Packages 索引
#   debs    解出种子包的依赖闭包 → 下载 → 解包到 build/vscode/debs/root
#   closure 铺平闭包：VS Code 树 + glibc 补件 + 按 NEEDED 收的发行版 .so + GSettings schema
#   pack    打成 tar（产物在 build/vscode/out/vscode.tar，未入库）
#
# 用法：./scripts/pack_vscode.sh [fetch|debs|closure|pack|all]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PHASE="${1:-all}"

VS_VER_TAR="$ROOT/build/vscode/code-arm64.tar.gz"
VS_URL="https://code.visualstudio.com/sha/download?build=stable&os=linux-arm64"
VS_DIR="$ROOT/build/vscode/VSCode-linux-arm64"
DEB_ROOT="$ROOT/build/vscode/debs"
DEB_TREE="$DEB_ROOT/root"
IDX_DIR="$ROOT/build/vscode/index"
STAGE="$ROOT/build/vscode/out/vscode"
OUT_TAR="$ROOT/build/vscode/out/vscode.tar"

MIRROR="http://ports.ubuntu.com/ubuntu-ports"
SUITE="noble"
ARCH="arm64"

READELF="$CLANG_DIR/llvm-readelf"

# 种子包：只要这几条，剩下的靠 Depends 闭包 + NEEDED 闭包补。
# 命名带 t64 的是 noble 的 time_t 迁移名（Provides 里同时提供旧名）。
SEEDS=(
    libgtk-3-0t64          # 一条就把 pango/cairo/gdk-pixbuf/atk/harfbuzz/fribidi/fontconfig/
                           # freetype/pixman/libepoxy/libxkbcommon/libglib/libpng 全带出来
    libnss3 libnspr4
    libatk-bridge2.0-0t64 libatspi2.0-0t64
    libcups2t64 libdbus-1-3 libgbm1 libasound2t64 libudev1
    libx11-6 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxrandr2 libxcb1
    libxkbfile1            # VS Code 的 native-keymap 预编译模块（keymapping.node）
                           # NEEDED 它；它是**运行期 dlopen** 的，NEEDED 闭包走不到，
                           # 缺了 keymapping.node 加载失败 → main 的 _doInitialize 抛异常
)
# 明确不要的：glibc 与 libgcc 一律由应用/工具链提供（见文件头）
SKIP_PKGS="libc6 libgcc-s1 libcrypt1"

# ══ 1. fetch ══════════════════════════════════════════════════════════════
do_fetch() {
    mkdir -p "$ROOT/build/vscode" "$IDX_DIR"
    if [ ! -s "$VS_VER_TAR" ]; then
        log "下载 VS Code arm64（约 338MB，一次就够）"
        curl -L --retry 3 -m 3000 -o "$VS_VER_TAR.part" "$VS_URL" || err "下载失败"
        mv "$VS_VER_TAR.part" "$VS_VER_TAR"
    fi
    log "VS Code 包：$(du -h "$VS_VER_TAR" | cut -f1)"
    for c in main universe; do
        local f="$IDX_DIR/Packages-$c.xz"
        [ -s "$f" ] || { log "下载索引 $c"; curl -sL --retry 2 -m 600 -o "$f" \
            "$MIRROR/dists/$SUITE/$c/binary-$ARCH/Packages.xz" || err "索引 $c 下载失败"; }
    done
    log "索引就绪：$(du -sh "$IDX_DIR" | cut -f1)"
}

# ══ 2. debs ══════════════════════════════════════════════════════════════
# 用 python 在 Packages 索引上跑 Depends 闭包（含 Provides 别名），把要下的包列出来，
# 再逐个下载 + dpkg-deb -x 解到同一棵树里。
do_debs() {
    do_fetch
    command -v dpkg-deb >/dev/null || err "缺 dpkg-deb（apt install dpkg）"
    mkdir -p "$DEB_TREE"
    local list="$DEB_ROOT/want.txt"
    log "=== 解依赖闭包（Depends + Provides）==="
    python3 - "$IDX_DIR" "$list" "${SEEDS[@]}" <<'PY'
import lzma, sys, os

idx_dir, out_path = sys.argv[1], sys.argv[2]
seeds = sys.argv[3:]

pkgs = {}
order = []
for comp in ('main', 'universe'):
    p = os.path.join(idx_dir, 'Packages-%s.xz' % comp)
    with lzma.open(p, 'rt', encoding='utf-8', errors='replace') as f:
        cur = None
        for line in f:
            line = line.rstrip('\n')
            if not line:
                if cur:
                    pkgs[cur['Package']] = cur
                    order.append(cur['Package'])
                cur = None
                continue
            if line[0] in ' \t':        # 续行（Description 之类）
                continue
            k, _, v = line.partition(': ')
            if k == 'Package':
                cur = {'Package': v, 'comp': comp}
            elif cur is not None and k in ('Version', 'Filename', 'Depends', 'Provides'):
                cur[k] = v

def dep_names(dep_str):
    """Depends/Provides 文本 → 名字列表；'a | b' 取第一个存在的。"""
    names = []
    for part in (dep_str or '').split(','):
        part = part.strip()
        if not part:
            continue
        alts = [a.strip().split(' ')[0].split(':')[0] for a in part.split('|')]
        pick = next((a for a in alts if a in pkgs), alts[0])
        names.append(pick)
    return names

# Provides: 虚拟名 → 提供者（取第一个）
prov = {}
for n, p in pkgs.items():
    for v in (p.get('Provides') or '').split(','):
        v = v.strip().split(' ')[0].split(':')[0]
        if v and v not in prov:
            prov[v] = n

want, todo = [], list(seeds)
seen = set()
while todo:
    n = todo.pop()
    rn = prov.get(n, n)
    if rn in seen or rn in ('libc6', 'libgcc-s1', 'libcrypt1'):
        continue
    if rn not in pkgs:
        sys.stderr.write('  跳过（索引里没有）：%s\n' % rn)
        continue
    seen.add(rn)
    want.append(rn)
    todo.extend(dep_names(pkgs[rn].get('Depends')))

with open(out_path, 'w') as f:
    for n in want:
        f.write('%s\t%s\t%s\n' % (n, pkgs[n]['comp'], pkgs[n]['Filename']))
sys.stderr.write('  包数：%d\n' % len(want))
PY
    [ -s "$list" ] || err "依赖闭包为空（索引解析出问题？）"
    log "  要下的包：$(wc -l < "$list") 个"

    log "=== 下载 + 解包 deb ==="
    local n=0
    while IFS=$'\t' read -r name comp relpath; do
        local deb="$DEB_ROOT/$(basename "$relpath")"
        if [ ! -s "$deb" ]; then
            curl -sL --retry 2 -m 600 -o "$deb.part" "$MIRROR/$relpath" || { warn "  下不到 $name（$relpath）"; rm -f "$deb.part"; continue; }
            mv "$deb.part" "$deb"
        fi
        dpkg-deb -x "$deb" "$DEB_TREE" 2>/dev/null || warn "  解包失败：$deb"
        n=$((n+1))
    done < "$list"
    log "  解出 $n 个包 → $DEB_TREE（$(du -sh "$DEB_TREE" | cut -f1)）"
}

# ══ 3. closure ═══════════════════════════════════════════════════════════
do_closure() {
    [ -d "$DEB_TREE/usr" ] || do_debs
    [ -s "$VS_VER_TAR" ] || do_fetch

    log "=== 铺暂存树 → $STAGE ==="
    rm -rf "$STAGE"; mkdir -p "$STAGE"

    # 3.1 VS Code 树（顶层那些文件全要：pak/icudtl/snapshot 都是启动期就读的）
    log "  解 VS Code 包"
    tar xzf "$VS_VER_TAR" -C "$ROOT/build/vscode"
    cp -a "$VS_DIR/." "$STAGE/"
    rm -rf "$STAGE/resources/app/extensions"   # 内置扩展几十万个小文件，先不带（探路用）

    # 3.2 glibc 补件：libm/libdl/libpthread/librt 取**我们自编的 glibc 2.39**（与 bundle 里
    #     那份 libc.so.6 同源），libstdc++/libgcc_s 取交叉工具链（也是 glibc 2.39 口径）。
    #     **不带 libc.so.6 / ld-linux-aarch64.so.1** —— 那两个由应用提供（见文件头）。
    local GLIBC_B="$BUILD_DIR/glibc/b"
    declare -A GLIBC_SRC=(
        [libm.so.6]="$GLIBC_B/math/libm.so.6"
        [libpthread.so.0]="$GLIBC_B/nptl/libpthread.so.0"
        [libdl.so.2]="$GLIBC_B/dlfcn/libdl.so.2"
        [librt.so.1]="$GLIBC_B/rt/librt.so.1"
        [libutil.so.1]="$GLIBC_B/login/libutil.so.1"
        # libresolv 在 noble 里归 libc6（被我们跳过了），但它只是 glibc 里一个
        # 独立子库，自编的那份就有 —— 从 b/resolv 取，别从 deb 里拿发行版 libc6。
        [libresolv.so.2]="$GLIBC_B/resolv/libresolv.so.2"
        [libanl.so.1]="$GLIBC_B/resolv/libanl.so.1"
        [libnsl.so.1]="$GLIBC_B/nis/libnsl.so.1"
        [libstdc++.so.6]="/usr/aarch64-linux-gnu/lib/libstdc++.so.6"
        [libgcc_s.so.1]="/usr/aarch64-linux-gnu/lib/libgcc_s.so.1"
    )
    for dst in "${!GLIBC_SRC[@]}"; do
        [ -e "${GLIBC_SRC[$dst]}" ] || err "缺 glibc 补件 ${GLIBC_SRC[$dst]}（先跑 build_glibc.sh / 装交叉工具链）"
        cp -aL "${GLIBC_SRC[$dst]}" "$STAGE/$dst"
    done
    log "  glibc 补件：$(ls "$STAGE" | grep -cE '^lib(m|dl|pthread|rt|util|stdc|gcc)') 个"

    # 3.3 发行版 .so：从 `code` 的 NEEDED 出发逐层收（与 copy_needed_closure 同一路子）
    local search="$DEB_TREE/usr/lib/aarch64-linux-gnu"
    local seen="" missing=""
    resolve() {
        local name="$1"
        case " $seen " in *" $name "*) return ;; esac
        seen="$seen $name"
        # 应用/glibc 补件提供的，跳过
        case "$name" in
            libc.so.6|ld-linux-aarch64.so.1|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|\
            libutil.so.1|libstdc++.so.6|libgcc_s.so.1) return ;;
        esac
        [ -f "$STAGE/$name" ] && return          # VS Code 自带的那几个（libffmpeg.so 等）
        local p=""
        for d in "$search" "$DEB_TREE/usr/lib"; do
            [ -f "$d/$name" ] && { p="$d/$name"; break; }
        done
        if [ -z "$p" ]; then missing="$missing $name"; return; fi
        cp -Lf "$p" "$STAGE/$name"
        local n
        for n in $("$READELF" -d "$p" 2>/dev/null | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF); print $NF}'); do
            resolve "$n"
        done
    }
    log "  收 NEEDED 闭包（从 code 出发）"
    local n
    for n in $("$READELF" -d "$STAGE/code" | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF); print $NF}'); do
        resolve "$n"
    done
    [ -z "$missing" ] || err "这些 NEEDED 在 deb 里没找到：$missing
  往 SEEDS 里补对应的包再来（多半是某个 -dev/额外运行库没被 Depends 带出来）"
    log "  闭包 .so：$(ls "$STAGE" | grep -c '\.so') 个"

    # 3.3b **运行期 dlopen 的模块** —— NEEDED 闭包 ≠ 运行期闭包。
    #     第 3.3 步是沿 NEEDED 走的，而有些库是**运行期才 dlopen** 的，NEEDED 里根本
    #     没有它们，于是会被整段漏掉。踩过两次：
    #       * NSS 的 softoken/`freebl`/`nssckbi`（Chromium 的 `nss_util.cc` 会 FATAL：
    #         `libsoftokn3.so: cannot open shared object file` → `nss_error=-5925`）；
    #       * Chromium 自己的 `libEGL` / `libGLESv2`（VS Code 包里自带，见 do_pack 的自检）。
    #     这些在发行版的 deb 里是**同包**的，所以直接从 deb 树里点名拷过来。
    for n in libsoftokn3 libfreebl3 libfreeblpriv3 libnssckbi libnssdbm3; do
        for f in "$DEB_TREE/usr/lib/aarch64-linux-gnu/$n.so" "$DEB_TREE/usr/lib/aarch64-linux-gnu/$n.chk"; do
            [ -e "$f" ] && cp -Lf "$f" "$STAGE/" || true
        done
    done
    log "  NSS dlopen 模块：$(ls "$STAGE" | grep -cE 'softokn|freebl|nssckbi|nssdbm') 个"

    # 3.4 GSettings schema：GTK3 初始化时**必须**能读到 gschemas.compiled，
    #     否则 gtk_init 直接 abort（"Settings schema 'org.gtk.Settings…' is not installed"）。
    #     deb 里带的是 .xml 源，编译缓存是装包时由触发器生成的 —— 我们在宿主上用
    #     glib-compile-schemas 现场编一份（它只做 XML→二进制，不涉及目标架构）。
    local schemadir="$STAGE/share/glib-2.0/schemas"
    if [ -d "$DEB_TREE/usr/share/glib-2.0/schemas" ]; then
        mkdir -p "$schemadir"
        cp -a "$DEB_TREE/usr/share/glib-2.0/schemas/"*.xml "$schemadir/" 2>/dev/null || true
        command -v glib-compile-schemas >/dev/null \
            && glib-compile-schemas "$schemadir" 2>/dev/null \
            && log "  GSettings schema：$(ls "$schemadir" | wc -l) 个 xml → 已编译" \
            || warn "  glib-compile-schemas 不可用/失败（宿主缺 libglib2.0-dev？）—— GTK 起来会 abort"
    else
        warn "  deb 里没有 share/glib-2.0/schemas —— GTK3 会因缺 schema 而 abort"
    fi

    # 3.5 gdk-pixbuf 的 loader：发行版是**模块式**的（usr/lib/.../gdk-pixbuf-2.0/2.10.0/loaders/*.so
    #     + loaders.cache）。GTK 加载 PNG 图标要用它。cache 里是路径列表，跟着一起拷。
    local gdklib="$DEB_TREE/usr/lib/aarch64-linux-gnu/gdk-pixbuf-2.0"
    if [ -d "$gdklib" ]; then
        mkdir -p "$STAGE/gdk-pixbuf-2.0"
        cp -a "$gdklib/." "$STAGE/gdk-pixbuf-2.0/"
        log "  gdk-pixbuf loaders：$(find "$STAGE/gdk-pixbuf-2.0" -name '*.so' | wc -l) 个"
    fi

    # 3.5b shared-mime-info + 图标主题：这两个**看着像可选项，其实是必需的**。
    #
    #   gdk-pixbuf 选 loader 不是靠魔数嗅探，而是：
    #       g_content_type_guess() → mime → 按 mime 找模块
    #   `g_content_type_guess` 走 GIO，读的是 XDG_DATA_DIRS 下的 `/mime/{magic,globs,aliases,…}`。
    #   这份库不在包里 → 猜出来的类型是 `application/octet-stream` → 找不到 loader →
    #   `GdkPixbufError(UNKNOWN_TYPE) "Unrecognized image file format"`。
    #   宿主上 `XDG_DATA_DIRS=/nonexistent gdk-pixbuf-thumbnailer x.png` 能 1:1 复现同一句。
    #
    #   症状为什么是"GTK 一碰图标就 abort"：GTK 找不到主题图标时会退到自带的
    #   `image-missing.png`（在它自己的 gresource 里，内容必然是合法 PNG），
    #   而这一步要过 gdk-pixbuf → 就撞上上面那条 → `ensure_surface_for_gicon` 断言失败 →
    #   `Bail out!` → abort。所以 mime 库和图标主题要一起补，缺一个都还是 abort。
    #
    #   mime.cache 与 icon-theme.cache 都是**装包时的 dpkg trigger 生成的**，deb 里没有，
    #   在宿主上用 update-mime-database / gtk-update-icon-cache 现场生成（纯数据变换，不涉及架构）。
    if [ -d "$DEB_TREE/usr/share/mime" ]; then
        mkdir -p "$STAGE/share/mime"
        cp -a "$DEB_TREE/usr/share/mime/." "$STAGE/share/mime/"
        if command -v update-mime-database >/dev/null; then
            update-mime-database "$STAGE/share/mime" >/dev/null 2>&1 \
                && log "  shared-mime-info：已生成 mime.cache（$(du -sh "$STAGE/share/mime" | cut -f1)）" \
                || warn "  update-mime-database 失败 —— gdk-pixbuf 仍会认不出 PNG"
        else
            warn "  宿主没有 update-mime-database（apt install shared-mime-info）"
        fi
    else
        warn "  deb 里没有 usr/share/mime —— gdk-pixbuf 会报 Unrecognized image file format"
    fi
    # 图标主题只要 hicolor（兜底必需）+ Adwaita（GTK3 默认）；Humanity/ubuntu-mono 那几套
    # 是 Ubuntu 桌面主题，几十 MB 全无用处，不要。
    # 用 cp -L **解引用软链**：Debian 的图标主题里到处是软链（尺寸别名、`cursors/`），
    # 而 pkg 的打包格式（bsh_tar.c）只认普通文件/目录，软链会让 do_pack 直接报错；
    # 设备侧 tar 建软链也被沙箱拒（"can't link … Permission denied"）。
    mkdir -p "$STAGE/share/icons"
    for t in hicolor Adwaita; do
        [ -d "$DEB_TREE/usr/share/icons/$t" ] || { warn "  deb 里没有图标主题 $t"; continue; }
        cp -aL "$DEB_TREE/usr/share/icons/$t" "$STAGE/share/icons/"
        if command -v gtk-update-icon-cache >/dev/null; then
            gtk-update-icon-cache -q -t -f "$STAGE/share/icons/$t" >/dev/null 2>&1 || true
        fi
    done
    log "  图标主题：$(ls "$STAGE/share/icons" | tr '\n' ' ')（$(du -sh "$STAGE/share/icons" | cut -f1)）"

    # 3.5c 两个"运行期才需要、NEEDED 闭包走不到"的东西：
    #   libxkbfile.so.1  —— VS Code 的 native-keymap/keymapping.node 的 NEEDED
    #                        （dlopen 进来的，第 3.3 步沿 NEEDED 走时看不到它）
    #   libnetiffix.so   —— getifaddrs 兜底（见 shim/netif_shim.c）：沙箱不给
    #                        NETLINK raw socket，Electron 的 os.networkInterfaces()
    #                        抛 EACCES 到 VS Code main 的 startup() 上，工作台就不下发
    for n in libxkbfile.so.1; do
        f="$DEB_TREE/usr/lib/aarch64-linux-gnu/$n"
        if [ -e "$f" ]; then cp -Lf "$f" "$STAGE/"; else warn "  缺 $n（keymapping.node 会加载失败）"; fi
    done
    local netif_src="$ROOT/feature/bsh_main/src/main/cpp/shim/netif_shim.c"
    if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 && [ -f "$netif_src" ]; then
        aarch64-linux-gnu-gcc -shared -fPIC -O2 -o "$STAGE/libnetiffix.so" "$netif_src" 2>/dev/null \
            && log "  netif preload：libnetiffix.so 已编" \
            || warn "  netif_shim.c 编译失败"
    else
        warn "  缺 aarch64-linux-gnu-gcc 或 netif_shim.c —— os.networkInterfaces() 会抛 EACCES"
    fi

    # 3.6 GTK3 自己的运行时模块（immodules/printbackends）—— 缺了只是少功能 + 警告，带上更省事
    for m in gtk-3.0; do
        [ -d "$DEB_TREE/usr/lib/aarch64-linux-gnu/$m" ] || continue
        mkdir -p "$STAGE/$m"
        cp -a "$DEB_TREE/usr/lib/aarch64-linux-gnu/$m/." "$STAGE/$m/"
        log "  $m 模块：$(find "$STAGE/$m" -name '*.so' | wc -l) 个"
    done

    # 3.7 启动器：把运行期要用的环境变量都摆好（资源都在包内，不依赖会话环境）
    #     装完后落在 <资源根>/usr/bin/code（见 do_pack），所以 root 从自身位置上溯两级。
    cat > "$STAGE/code-run" <<'LAUNCHER'
#!/bin/sh
# VS Code 启动器 —— 由 pack_vscode.sh 生成，随包安装到 <资源根>/usr/bin/code。
#
# 关键环境变量：
#   GSETTINGS_SCHEMA_DIR  GTK3 初始化要读 gschemas.compiled（缺它 gtk_init 直接 abort）
#   GDK_PIXBUF_MODULE_FILE / GDK_PIXBUF_MODULEDIR  gdk-pixbuf 的 loader 模块
#   FONTCONFIG_FILE 沿用会话里那份（.bshrc 已经导出）；XKB_CONFIG_ROOT 由本文件自己设
#   （libxkbcommon 编译期内置的是 /usr/share/X11/xkb，沙箱里没有那个绝对路径）
#   XDG_DATA_DIRS 给 GIO 找 shared-mime-info 与图标主题（缺它 PNG 都认不出来）
#   LD_PRELOAD 挂 libnetiffix.so（getifaddrs 兜底，见 shim/netif_shim.c）
#
# Chromium 的三个开关都不是可选项：
#   --ozone-platform=wayland  沙箱里只有 wayland，没有 X11
#   --disable-gpu             没有 DRI，走 SwiftShader（包里自带 libEGL/libGLESv2）
#   --no-sandbox              chrome-sandbox 要 setuid root + 用户命名空间，沙箱里都没有
#
# ⚠ **不要走上游的 bin/code**（虽然它才是官方入口）：那个脚本的头一行是
#   `#!/usr/bin/env sh`，而 guest 的 /usr/bin/env 并不存在 —— elfloader 一侧
#   解析 shebang 会失败并把它当 EACCES 报出来，症状是一串
#   "…/usr/bin/code[19]: …/usr/bin/code: Permission denied" 的自我递归。
#   CLI 那点事（ELECTRON_RUN_AS_NODE + out/cli.js）自己起就行。
root="${BSH_SYSROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
vsc="$root/usr/lib/vscode"

GSETTINGS_SCHEMA_DIR="$vsc/share/glib-2.0/schemas"
export GSETTINGS_SCHEMA_DIR
# ⚠ 必须给 GIO 一份 shared-mime-info 库（包内 `$vsc/share/mime`），否则
# `g_content_type_guess` 猜不出 `image/png` → gdk-pixbuf 找不到 loader →
# 报 "Unrecognized image file format" → GTK 加载图标失败 → `Bail out!` → abort。
# 复现与根因见 STATUS §57；闭包里那份 mime.cache 由 pack_vscode.sh 用
# update-mime-database 现场生成。
#
# ⚠ 不要去设 GDK_PIXBUF_MODULE_FILE / GDK_PIXBUF_MODULEDIR：
# noble 的 libgdk_pixbuf-2.0.so.0 **内建了 image/png 与 image/jpeg**，不需要
# loaders.cache；而 debian 的 loaders.cache 是装包时由 dpkg trigger 生成的，
# .deb 里根本没有 —— 指一个不存在的路径反而会让模块查找整条退化。
XDG_DATA_DIRS="$vsc/share:$root/usr/share"
export XDG_DATA_DIRS
# libxkbcommon 的编译期内置 include 路径是 `/usr/share/X11/xkb`（沙箱里不存在）。
# libxkbcommon 认 XKB_CONFIG_ROOT（xkb_context.c 里的 secure_getenv），指到包内那份。
[ -d "$root/usr/share/x11/xkb" ] && XKB_CONFIG_ROOT="$root/usr/share/x11/xkb" && export XKB_CONFIG_ROOT
# getifaddrs 兜底：沙箱不给 NETLINK raw socket，Electron 的 os.networkInterfaces()
# 会抛 EACCES 到 VS Code main 的 startup() 上，工作台就不下发（见 shim/netif_shim.c）。
# netif / xkb 路径映射由 shim 家族提供（libbshguest-glibc.so），不再单独 preload。

# CLI 类子命令：拿 Electron 当 node 跑 out/cli.js（不开窗口）。其余当成"开 GUI"。
case "${1-}" in
    --version|-v|--help|-h|--status|--list-extensions|--show-versions|\
    --install-extension|--uninstall-extension|--update-extensions|tunnel|serve-web|--locate-shell-integration-path)
        ELECTRON_RUN_AS_NODE=1
        export ELECTRON_RUN_AS_NODE
        exec "$vsc/code" "$vsc/resources/app/out/cli.js" "$@" ;;
esac

exec "$vsc/code" \
    --ozone-platform="${BSH_OZONE:-wayland}" \
    --disable-gpu \
    --in-process-gpu \
    --disable-gpu-sandbox \
    --disable-seccomp-filter-sandbox \
    --no-sandbox \
    --disable-dev-shm-usage \
    "$@"
LAUNCHER
    chmod 0755 "$STAGE/code-run"
    chmod 0755 "$STAGE/code" "$STAGE/chrome-sandbox" "$STAGE/chrome_crashpad_handler" 2>/dev/null || true

    log "暂存树：$(du -sh "$STAGE" | cut -f1)"
    log "  未解出的 NEEDED（应为空）：$( ( cd "$STAGE" && for f in code *.so*; do "$READELF" -d "$f" 2>/dev/null | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF);print $NF}'; done ) | sort -u | while read -r x; do case "$x" in libc.so.6|ld-linux-aarch64.so.1) ;; *) [ -f "$STAGE/$x" ] || echo "$x" ;; esac; done | tr '\n' ' ')"
}

# ══ 4. pack ══════════════════════════════════════════════════════════════
# 产物按 pkg 包的约定摆：顶层 `usr/`，安装到 <资源根>/。
#   usr/lib/vscode/…   上面那棵暂存树（VS Code 树 + 闭包 + schema + 模块）
#   usr/bin/code       启动器（usr/bin 已在 PATH 上，敲 `code` 即可）
# 为什么整棵塞进 usr/lib/vscode 而不是直接摊在根上：摊在根上会往 <资源根> 里撒
# 100 多个 .so，跟别的包（python/node/qt…）的同名库打架 —— 而 procmgr 会把
# **guest 自己所在目录**加进 LD_LIBRARY_PATH，只要闭包与 code 同层就够了。
do_pack() {
    [ -x "$STAGE/code" ] || do_closure
    command -v zstd >/dev/null || err "缺 zstd（apt install zstd）"

    local pkg="$ROOT/build/vscode/out/pkg"
    rm -rf "$pkg"; mkdir -p "$pkg/usr/lib" "$pkg/usr/bin"
    mv "$STAGE" "$pkg/usr/lib/vscode"
    mv "$pkg/usr/lib/vscode/code-run" "$pkg/usr/bin/code"
    STAGE="$pkg/usr/lib/vscode"

    # pkg 的 bsh_tar.c 只认普通文件/目录，软链一律展开成真文件（同 pack_codeserver.sh）。
    local links; links="$(find "$pkg" -type l)"
    if [ -n "$links" ]; then
        while IFS= read -r l; do
            local tgt; tgt="$(readlink -f "$l")" || err "断链：$l"
            case "$tgt" in "$pkg"/*) ;; *) err "软链指向树外：$l -> $tgt" ;; esac
            cp -L "$tgt" "$l.new" && mv -f "$l.new" "$l" || err "展开软链失败：$l"
        done <<< "$links"
        log "  展开软链 $(echo "$links" | wc -l) 个"
    fi

    mkdir -p "$ROOT/dist/pkgs"
    OUT_TAR="$ROOT/dist/pkgs/vscode.tar.zst"
    log "  zstd -19 压缩中（原树 $(du -sh "$pkg" | cut -f1)）"
    tar -C "$pkg" -cf - usr | zstd -19 -T0 -q -o "$OUT_TAR" -f
    log "✅ $OUT_TAR（$(du -h "$OUT_TAR" | cut -f1)）"

    # ── 自检 ──（清单先落盘再查 —— 本仓库开着 pipefail，grep -q 一命中就 SIGPIPE，
    #   管道会被判失败，"明明有也报没有"，build_testprogs/build_shim 都踩过）
    zstd -dc "$OUT_TAR" | tar -tv > "$ROOT/build/vscode/list-v.txt"
    zstd -dc "$OUT_TAR" | tar -t  > "$ROOT/build/vscode/list.txt"
    local n_link; n_link="$(grep -c '^l' "$ROOT/build/vscode/list-v.txt" || true)"
    [ "$n_link" = "0" ] || err "包里有 $n_link 个软链 —— pkg 的 bsh_tar.c 只认普通文件/目录"
    grep -q '^-rwx.*usr/lib/vscode/code$'  "$ROOT/build/vscode/list-v.txt" || err "usr/lib/vscode/code 丢了可执行位"
    grep -q '^-rwx.*usr/bin/code$'         "$ROOT/build/vscode/list-v.txt" || err "usr/bin/code 丢了可执行位"
    grep -q '^usr/lib/vscode/resources/app/out/cli.js$' "$ROOT/build/vscode/list.txt" || err "resources/app/out/cli.js 没进包"
    local miss=""
    for so in libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libutil.so.1 libresolv.so.2 \
              libstdc++.so.6 libgcc_s.so.1 libgtk-3.so.0 libnss3.so libgbm.so.1 libasound.so.2 libdbus-1.so.3; do
        grep -q "^usr/lib/vscode/$so\$" "$ROOT/build/vscode/list.txt" || miss="$miss $so"
    done
    [ -z "$miss" ] || err "闭包缺：$miss"
    grep -q '^usr/lib/vscode/share/glib-2.0/schemas/gschemas.compiled$' "$ROOT/build/vscode/list.txt" \
        || err "gschemas.compiled 没进包（GTK 起来会 abort）"
    log "  自检：$(grep -c '^-' "$ROOT/build/vscode/list-v.txt") 个文件、0 个软链、闭包与 schema 齐全"
    echo
    log "设备上怎么装："
    log "    pkg install vscode        # 先把它传到 bsh.y1yan.com 并登记进 index.json"
    log "    code                      # 起窗口"
    log "    code --version            # CLI 路径（走 bin/code，不开窗口）"
}

case "$PHASE" in
    fetch)   do_fetch ;;
    debs)    do_debs ;;
    closure) do_closure ;;
    pack)    do_pack ;;
    all)     do_fetch; do_debs; do_closure; do_pack ;;
    *)       err "用法：$0 [fetch|debs|closure|pack|all]" ;;
esac
log "✅ pack_vscode.sh 完成（阶段 $PHASE）"
