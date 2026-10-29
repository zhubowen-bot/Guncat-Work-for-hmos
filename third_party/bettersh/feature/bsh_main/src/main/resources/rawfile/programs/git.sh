#!/bin/sh
# ============================================================================
# git 启动器（由 shell.cpp 从 rawfile/programs/git.sh 解到 $SYSROOT/bin/git）
# ============================================================================

S="${BSH_SYSROOT:-/data/storage/el2/base/haps/tablet/files}"
GIT_BIN="$S/usr/bin/git"

if [ ! -x "$GIT_BIN" ]; then
    cat <<EOF

╭─ git 未就绪 ─────────────────────────────────────────────────────────────
│ 请先手动下载安装包并进行安装！
│
│ 1) 下载官方 arm64 包（推荐下载 Ubuntu 24.04 LTS 版本，已经过实测）：
│    https://pkgs.org/download/git
│
│ 2) cd 至安装包下载目录，或者拷贝安装包到当前目录，随后执行命令：
│    apt install ./git_x.yy.z-1ubuntu7_arm64.deb
│
│ 装完即可通过 git 运行。
╰──────────────────────────────────────────────────────────────────────────
EOF
    exit 127
fi

# ① 依赖库：deb 把它们放在 multiarch 目录下
LD_LIBRARY_PATH="$S/usr/lib/aarch64-linux-gnu:$S/usr/lib:$S/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH

# ② ③ git 自己的运行期路径（编进去的是 /usr/...，与我们装在资源根下对不上）
GIT_EXEC_PATH="$S/usr/lib/git-core"
GIT_TEMPLATE_DIR="$S/usr/share/git-core/templates"
export GIT_EXEC_PATH GIT_TEMPLATE_DIR

# ④ link(2)：请 shim 报内核的真相（见文件头第 4 条）
BSH_SHIM_LINK_STRICT=1
export BSH_SHIM_LINK_STRICT

# ⑤ CA bundle。设备上没有 /etc/ssl/certs —— 那个文件是 update-ca-certificates 在**装包
#    时**生成的，而 apt 的 `git` 并不依赖 ca-certificates（Ubuntu 假设系统自带），所以
#    装着 git 也没有证书。git 的 HTTPS 走 libcurl，得给它一个 bundle。按可用性依次找：
#      a) 自编 git 那个 pkg 自带的 cacert.pem（curl.se 出的 Mozilla 根）
#      b) apt 装 ca-certificates 之后由 update-ca-certificates 拼出来的那份
#      c) 现场把 usr/share/ca-certificates/mozilla/*.crt 拼一份到 HOME 下缓存
if [ -z "${GIT_SSL_CAINFO:-}" ]; then
    for c in "$S/usr/share/git-core/cacert.pem" \
             "$S/etc/ssl/certs/ca-certificates.crt"; do
        [ -s "$c" ] && { GIT_SSL_CAINFO="$c"; break; }
    done
    if [ -z "${GIT_SSL_CAINFO:-}" ] && [ -d "$S/usr/share/ca-certificates/mozilla" ]; then
        bundle="${XDG_CACHE_HOME:-$HOME/.cache}/ca-bundle.crt"
        if [ ! -s "$bundle" ]; then
            mkdir -p "$(dirname "$bundle")"
            cat "$S/usr/share/ca-certificates/mozilla"/*.crt > "$bundle" 2>/dev/null
        fi
        [ -s "$bundle" ] && GIT_SSL_CAINFO="$bundle"
    fi
fi
if [ -n "${GIT_SSL_CAINFO:-}" ]; then
    export GIT_SSL_CAINFO
    [ -n "${CURL_CA_BUNDLE:-}" ] || CURL_CA_BUNDLE="$GIT_SSL_CAINFO"
    export CURL_CA_BUNDLE
else
    echo "[git] 提示：没找到 CA bundle，HTTPS（clone/fetch）会失败。装一个：" >&2
    echo "[git]       apt install ca-certificates" >&2
fi

exec "$GIT_BIN" "$@"
