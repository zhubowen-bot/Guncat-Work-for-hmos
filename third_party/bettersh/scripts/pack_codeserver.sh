#!/bin/bash
# pack_codeserver.sh — 把 code-server 打成一个能给 pkg 发的包（`code-server`）
#
# 为什么单独发：它解包后 640MB 出头（大头是自带的 node 96MB + 两个 Copilot 扩展各
# 96MB 的 runtime.node），常驻 HAP 意味着每次装机都要多传 214MB —— 而它跟应用本身
# 没关系，属于"想用才装"。
#
# 包里放什么（顶层就一个 usr/，安装 = `tar -C <资源根> -x`，与 weston-terminal 同一口径）：
#   usr/lib/code-server/…           上游 linux-arm64 release 的完整目录树
#   usr/lib/code-server/lib/*.so*   **glibc 运行时闭包**，见下
#   usr/bin/code-server             启动器（<资源根>/usr/bin 在 PATH 上，敲 `code-server` 即可）
#
# 为什么不放 <资源根>/bin：那是**命令表生成**的启动器目录（cmd_make_launchers 每会话按表
# 写一遍），用户/包的东西不该混进去。usr/bin 才是 FHS 里装程序的位置 —— 而整棵树挪到
# usr/lib/code-server 也是同一个理由（code-server 内部全按 __dirname 找自己的文件，
# 整棵一起挪不影响）。
#
# 为什么闭包要塞进 lib/：
#   自带的 lib/node 是 glibc 二进制（ET_EXEC + PT_INTERP，NEEDED libstdc++.so.6 /
#   libgcc_s.so.1 / libm.so.6 / libpthread.so.0 / libdl.so.2 / libutil.so.1），而随 HAP
#   走的 bundle libs 里只有 ld-linux-aarch64.so.1 与 libc.so.6。procmgr 会把 **guest
#   自己所在目录**加进 LD_LIBRARY_PATH（procmgr.cpp 的 ChildRunElf）—— 所以闭包必须与
#   node 同层，ld.so 才找得到（同 ohos-sdk-prune 的做法）。
#   来源：glibc 那几个桩库取**项目自编的 glibc 2.39** 构建树，libstdc++/libgcc_s 取交叉
#   工具链（Ubuntu 24.04，也是 glibc 2.39 口径）—— 与 bundle 里那份 libc.so.6 对得上。
#
# 三条约束（pkg 的 bsh_tar.c 只认普通文件/目录）：
#   1) **不能有软链**：上游的 libstdc++.so.6 是软链，必须 -L 展开成真文件；
#   2) 顶层只有一个 code-server/；
#   3) 打完自检：软链 0 个、lib/node 可执行位在、几个 NEEDED 都在树里。
#
# 用法：scripts/pack_codeserver.sh          （产物 dist/pkgs/code-server.tar.zst）
#       CS_VER=4.140.0 …                   （换版本）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

CS_VER="${CS_VER:-4.140.0}"
WORK="$BUILD_DIR/codeserver"
STAGE="$WORK/stage"
NAME="code-server-$CS_VER-linux-arm64"
TGZ="$WORK/$NAME.tar.gz"
URL="https://github.com/coder/code-server/releases/download/v$CS_VER/$NAME.tar.gz"
CLOSURE_DIR="$WORK/closure"

mkdir -p "$WORK" "$CLOSURE_DIR"

# ── 1/4 上游 tarball（有就不重下）────────────────────────────────────────
if [ ! -f "$TGZ" ]; then
    log "下载 $NAME.tar.gz（约 210MB）"
    if [ -n "${https_proxy:-}" ]; then log "  经代理 $https_proxy"; fi
    curl -L --retry 3 -m 3000 -o "$TGZ.part" "$URL" || err "下载失败：$URL"
    mv "$TGZ.part" "$TGZ"
fi
log "上游包：$(du -h "$TGZ" | cut -f1)"

# ── 2/4 glibc 运行时闭包 ────────────────────────────────────────────────
# 键 = 树里的名字，值 = 来源路径。glibc 桩库（glibc 2.34 之后它们大多只剩兼容符号）
GLIBC_B="$BUILD_DIR/glibc/b"
declare -A SRC=(
    [libm.so.6]="$GLIBC_B/math/libm.so.6"
    [libpthread.so.0]="$GLIBC_B/nptl/libpthread.so.0"
    [libdl.so.2]="$GLIBC_B/dlfcn/libdl.so.2"
    [librt.so.1]="$GLIBC_B/rt/librt.so.1"
    [libutil.so.1]="$GLIBC_B/login/libutil.so.1"
    [libstdc++.so.6]="/usr/aarch64-linux-gnu/lib/libstdc++.so.6"
    [libgcc_s.so.1]="/usr/aarch64-linux-gnu/lib/libgcc_s.so.1"
)
rm -rf "$CLOSURE_DIR"; mkdir -p "$CLOSURE_DIR"
for dst in "${!SRC[@]}"; do
    src="${SRC[$dst]}"
    [ -e "$src" ] || err "缺闭包：$src（先跑 scripts/build_glibc.sh / 装 gcc-aarch64-linux-gnu）"
    cp -aL "$src" "$CLOSURE_DIR/$dst"          # -L：把软链展开成真文件（约束 1）
done
log "glibc 闭包：$(ls "$CLOSURE_DIR" | tr '\n' ' ')"

# ── 3/4 铺 + 打包 ──────────────────────────────────────────────────────
rm -rf "$STAGE"; mkdir -p "$STAGE"
tar -xzf "$TGZ" -C "$WORK"
[ -d "$WORK/$NAME" ] || err "上游包解出来不是 $NAME/？"
mkdir -p "$STAGE/usr/lib"
mv "$WORK/$NAME" "$STAGE/usr/lib/code-server"
cp -a "$CLOSURE_DIR"/* "$STAGE/usr/lib/code-server/lib/"

# 上游树里有 12 个软链（全是 node_modules/.bin/* → 树内的相对路径）。pkg 的 bsh_tar.c
# 只认普通文件/目录，所以一律**展开成真文件**（同 ohos-sdk-prune 的做法），并补上可执行位
# （npm 的 .bin 壳是 0755，它指向的 JS 本体常常是 0644，直接 cp 会把执行位丢掉）。
# 指向树外的软链直接拒绝 —— 那种得先想清楚"拷什么进去"，不能默默跟着拷。
# 启动器：<资源根>/usr/bin 已在 PATH 上（见 .bshrc），敲 `code-server` 就能用。
# 用 $BSH_SYSROOT 定位安装根，拿不到就按脚本自身位置推（<资源根>/usr/bin/..）——
# 两条路都不依赖 cwd。
mkdir -p "$STAGE/usr/bin"
cat > "$STAGE/usr/bin/code-server" <<'LAUNCHER'
#!/bin/sh
# code-server 启动器 —— 由 pkg 的 `code-server` 包安装到 <资源根>/usr/bin/
#
#   code-server                      走它自己的默认参数（默认只绑 127.0.0.1，带密码）
#   code-server --bind-addr 0.0.0.0:8080 --auth none
#                                    想从别的机器/浏览器直接访问时用（注意：那是**无认证**
#                                    对外监听，只在可信网络里这么干）
#
# 它解包后 640MB、冷启动要几十秒，别指望秒开。
root="${BSH_SYSROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
exec "$root/usr/lib/code-server/lib/node" "$root/usr/lib/code-server/out/node/entry.js" "$@"
LAUNCHER
chmod 0755 "$STAGE/usr/bin/code-server"

find "$STAGE" -type l > "$WORK/links.txt"
nfill=0
while IFS= read -r l; do
    tgt="$(readlink -f "$l")" || err "断链：$l"
    case "$tgt" in "$STAGE"/*) ;; *) err "软链指向树外：$l -> $tgt" ;; esac
    cp -L "$tgt" "$l.new" && mv -f "$l.new" "$l" && chmod +x "$l" || err "展开软链失败：$l"
    nfill=$((nfill+1))
done < "$WORK/links.txt"
log "把 $nfill 个软链展开成真文件"

mkdir -p "$ROOT/dist/pkgs"
OUT="$ROOT/dist/pkgs/code-server.tar.zst"
tar -C "$STAGE" -c usr | zstd -19 -T0 -o "$OUT" -f -q
log "打包：$OUT  $(du -h "$OUT" | cut -f1)"

# ── 4/4 自检 ───────────────────────────────────────────────────────────
# 先把清单落一份下来再查，**不要**写 `zstd -dc | tar -t | grep -q ...`：
# 本仓库开着 pipefail，grep -q 一命中就退出 → 上游拿到 SIGPIPE → 整条管道判失败，
# 于是"明明有也报没有"（本仓库在 build_testprogs / build_shim 都踩过同一个坑）。
zstd -dc "$OUT" | tar -tv > "$WORK/list-v.txt"
zstd -dc "$OUT" | tar -t  > "$WORK/list.txt"

n_link="$(grep -c '^l' "$WORK/list-v.txt" || true)"
n_file="$(grep -c '^-' "$WORK/list-v.txt" || true)"
[ "$n_link" = "0" ] || err "包里有 $n_link 个软链 —— pkg 的 bsh_tar.c 只认普通文件/目录"
log "自检：$n_file 个文件，0 个软链"

grep -q '^-rwx.*usr/lib/code-server/lib/node$' "$WORK/list-v.txt" || err "lib/node 丢了可执行位"
miss=""
for so in libstdc++.so.6 libgcc_s.so.1 libm.so.6 libpthread.so.0 libdl.so.2 libutil.so.1; do
    grep -q "^usr/lib/code-server/lib/$so\$" "$WORK/list.txt" || miss="$miss $so"
done
[ -z "$miss" ] || err "闭包缺：$miss"
grep -q '^usr/bin/code-server$' "$WORK/list.txt" || err "启动器 usr/bin/code-server 没进包"
grep -q '^-rwx.*usr/bin/code-server$' "$WORK/list-v.txt" || err "usr/bin/code-server 丢了可执行位"
log "自检：lib/node 可执行位在，glibc 闭包齐全，启动器在 usr/bin/ 下"
