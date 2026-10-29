#!/bin/sh
# ============================================================================
# Code-Server 启动器（由 shell.cpp 从 rawfile 解压）
#
# 职责：自检资源并在缺失时给出**可照做的下载指引**；② 摆好一整套环境变量；
#       ③ 用正确的可执行文件和必需的 Chromium 开关启动。
# ============================================================================

S="${BSH_SYSROOT:-/data/storage/el2/base/haps/tablet/files}"

EXE="$S/usr/lib/code-server/bin/code-server"
[ -x "$EXE" ] || EXE=""

if [ -z "$EXE" ]; then
    cat <<EOF

╭─ Code-Server 未就绪 ──────────────────────────────────────────────────────
│ 还没装。装法：
│
│ 1) 下载官方 arm64 的 .deb：
│    https://github.com/coder/code-server/releases
│
│ 2) cd 到安装包所在目录，然后：
│    apt install ./code-server_x.yyy.z_arm64.deb
│
│ 装完再敲 code-server 就行。
╰──────────────────────────────────────────────────────────────────────────
EOF
    exit 127
fi

exec "$EXE" "$@"
