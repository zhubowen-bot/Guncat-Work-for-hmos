#!/bin/sh
# install-dsh.sh — 在 BetterSH 里安装 @deepseek-ai/dsh（DeepSeek 的 harness CLI）
#
# 为什么不能直接 `npm install -g @deepseek-ai/dsh`：这条依赖树里有原生包，在设备上
# 装不了 / 又用不到，默认安装必挂：
#   * koffi（FFI 原生扩展）——预编译是 glibc 的，加载失败就回退"源码编译"，要 CMake。
#     但它所有用法都是 **Windows-only 且懒加载**（代码注释原话 "Load the small Win32
#     API lazily so non-Windows processes never load Koffi"），设备上根本不会加载它。
#     → 用 `--ignore-scripts` 跳过它的原生构建，安全。
#   * node-addon-require-builtin —— dsh **启动**时要靠它取 Node 的 internal module；
#     它的预编译 .node NEEDED libstdc++.so.6（HarmonyOS 只有 libc++）→ 加载失败，
#     报 `No usable native binding found ...`。该包只做"把 internal module id 透传给
#     Node 内建 require"这一件事，所以用等价的纯 JS 顶替，并让 node 带
#     `--expose-internals` 启动即可（`NODE_OPTIONS` 不收这个 flag，只能放命令行）。
#
# 用法（在 BetterSH 终端里）：
#   sh install-dsh.sh
#   DSH_INSTALL_DIR=$HOME/.dsh-app sh install-dsh.sh
#   NPM_REGISTRY=https://registry.npmmirror.com sh install-dsh.sh   # 国内加速
#   DSH_VERSION=0.2.0-rc.2 sh install-dsh.sh
#
# 装完：`dsh --help`、`dsh web`。`dsh headless "..."` 还需要模型凭据
# （DEEPSEEK_API_KEY，或 dsh web 的 Models 页里填）。

set -e

DIR="${DSH_INSTALL_DIR:-$HOME/dshtest}"
WRAP="$HOME/dsh"
PKG="@deepseek-ai/dsh"
VER="${DSH_VERSION:-0.2.0-rc.2}"
REG="${NPM_REGISTRY:-}"

say() { echo "[install-dsh] $*"; }
die() { echo "[install-dsh] 错误：$*" >&2; exit 1; }

say "0. 环境检查"
command -v node >/dev/null 2>&1 || die "找不到 node（BetterSH 内置的，应在 PATH 上）"
command -v npm  >/dev/null 2>&1 || die "找不到 npm"
say "   node=$(node -v 2>&1)  npm=$(npm -v 2>&1)"
say "   安装目录：$DIR   版本：$VER"

say "1. 安装 $PKG@$VER（--ignore-scripts，跳过 koffi 的原生构建）"
mkdir -p "$DIR"
cd "$DIR"
if [ ! -f package.json ]; then
    printf '{\n  "name": "dsh-local",\n  "private": true\n}\n' > package.json
fi
if [ -n "$REG" ]; then
    npm install "$PKG@$VER" --ignore-scripts --no-audit --no-fund --registry="$REG"
else
    npm install "$PKG@$VER" --ignore-scripts --no-audit --no-fund
fi

BIN="$DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
[ -f "$BIN" ] || die "装完却找不到 $BIN（安装没成功？）"

say "2. 用纯 JS 顶替 node-addon-require-builtin 的原生绑定"
RAB="$DIR/node_modules/node-addon-require-builtin/lib/index.js"
if [ ! -f "$RAB" ]; then
    say "   !! 没找到 $RAB（包结构可能变了），跳过——dsh 可能 boot 不起来"
elif grep -q "BetterSH(OHOS) 替换实现" "$RAB" 2>/dev/null; then
    say "   已打过补丁，跳过"
else
    cp -f "$RAB" "$RAB.orig" 2>/dev/null || true
    cat > "$RAB" <<'EOF'
"use strict";
/* ── BetterSH(OHOS) 替换实现 ─────────────────────────────────────────────
 * 原实现加载预编译的 node-addon-require-builtin-<平台> 原生绑定；那个 .node
 * NEEDED libstdc++.so.6（HarmonyOS 只有 libc++），加载必失败。该 addon 的语义
 * 只是"把 internal module id 透传给 Node 的内建 require"（其 README：
 *   requireBuiltin(id) forwards any id to Node's builtin require;
 *   isAllowedInternalId() always returns true），
 * 所以进程带 --expose-internals 启动时，require(id) 是逐字等价的替代（启动器负责带 flag）。 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.requireBuiltin = requireBuiltin;
exports.isAllowedInternalId = isAllowedInternalId;
exports.getBindingInfo = getBindingInfo;

function requireBuiltin(moduleId) { return require(moduleId); }
function isAllowedInternalId() { return true; }
const BINDING_INFO = Object.freeze({
    mode: "js-fallback",
    product: "node-addon-require-builtin",
    backend: "require",
    abi: "napi-v9",
    bindingPath: "",
    bindingSource: "js-fallback",
    localBindingPath: "",
    optionalPackageName: "",
    optionalBinaryRelativePath: "",
    platformPackageSuffix: "",
});
function getBindingInfo() { return BINDING_INFO; }
exports.default = { requireBuiltin, isAllowedInternalId, getBindingInfo };
EOF
    say "   已打补丁（原件备份为 $RAB.orig）"
fi

say "3. 写启动器 $WRAP（带 --expose-internals）"
cat > "$WRAP" <<EOF
#!/bin/sh
# 由 install-dsh.sh 生成。dsh 的 profile 解析器要 Node 的 internal module，原版靠
# 原生 addon 取；这里改用 --expose-internals + 纯 JS 补丁，所以必须带这个 flag。
# 注意：不要写 exec —— 沙箱里 exec 那一路会撞 #BSHSO 文本启动器报 "Exec format error"。
node --expose-internals "$BIN" "\$@"
EOF
chmod 0755 "$WRAP" 2>/dev/null || true
say "   已生成（\$HOME 在 PATH 第一段，直接敲 dsh 即可）"

say "4. 自检"
"$WRAP" --version || die "dsh --version 失败"
N=$("$WRAP" --profile web --dump-default-config 2>/dev/null | wc -l)
say "   dsh --version OK；--profile web --dump-default-config 行数=$N"

echo
say "完成。用法："
say "   dsh --help"
say "   dsh web                       # 起 web UI（默认只绑 127.0.0.1）"
say "   dsh headless \"say hi\"          # 需要 DEEPSEEK_API_KEY（或 dsh web 的 Models 页里填）"
