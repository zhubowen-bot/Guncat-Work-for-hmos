#!/bin/bash
# build_pip.sh — 打一个 pkg 能装的 pip 包(dist/pkgs/pip.tar.zst)
#
# 产物:
#   dist/pkgs/pip.tar.zst
#     顶层 python/lib/python3.12/site-packages/{pip/, pip-<ver>.dist-info/}
#   —— 和 python-stdlib.tar 一样解到资源根(<sysroot>),但**不随 HAP 走**:
#     改由 pkg 服务器分发,设备上 `pkg install pip` 才落地(见 build/pkgserver/index.json)。
#     tar 路径相对资源根,所以 pkg 的"安装"就是 `tar -C <资源根> -x`。
#
# 为什么单列一个包:
#   stdlib.tar 是 **CPython 自己编出来的**(随 HAP),pip 是 **PyPI 上的纯 Python
#   wheel**,两者来源/更新节奏都不同;单列也方便"不带 pip 的瘦身版"继续用同一份 stdlib。
#   1.1 MB(zstd 后),不是人人一开始就要,放服务器按需下更合适。
#
# 为什么不用 ensurepip:
#   我们的 CPython 是 `--without-ensurepip` 编的(build_python.sh 的 configure),
#   而且 stdlib.tar 是裁剪过的、里面根本没有 ensurepip/_bundled。直接从 PyPI 拿
#   wheel 更直接,也顺便能指定版本。
#
# 依赖:宿主机 python3(只用 zipfile 解 wheel,不执行任何 pip 代码)。
#
# 用法:./scripts/build_pip.sh            (幂等,tar 在就跳过)
#       PIP_REBUILD=1 ./scripts/build_pip.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PIP_VER="${PIP_VER:-26.2.1}"
PY_SERIES="${PY_SERIES:-3.12}"
SRC_DIR="$ROOT/thirdparty/pip-src"
WHEEL="$SRC_DIR/pip-$PIP_VER-py3-none-any.whl"
RT_ROOT="$BUILD_DIR/pip-rt"              # tar 顶层组装区(内含 python/)
PIP_PKG="$ROOT/dist/pkgs/pip.tar.zst"    # 产物：**pkg 的包**，不再随 HAP 走
HOST_PY="${HOST_PYTHON:-python3}"

if [ -f "$PIP_PKG" ] && [ -z "${PIP_REBUILD:-}" ]; then
    log "pip 包已存在:$(du -h "$PIP_PKG" | cut -f1)（PIP_REBUILD=1 可重建）"
    exit 0
fi

command -v "$HOST_PY" >/dev/null 2>&1 || err "需要宿主机 python3(只用 zipfile 解 wheel)"
command -v zstd >/dev/null 2>&1 || err "缺 zstd（apt install zstd）"
mkdir -p "$SRC_DIR" "$(dirname "$PIP_PKG")"

# ── 0. 取 wheel(纯 Python,无平台 tag,任何宿主都能下)─────────
if [ ! -s "$WHEEL" ]; then
    log "取 pip $PIP_VER 的 wheel 地址"
    url="$("$HOST_PY" - "$PIP_VER" <<'PY'
import json, sys, urllib.request
ver = sys.argv[1]
with urllib.request.urlopen(f"https://pypi.org/pypi/pip/{ver}/json", timeout=60) as r:
    d = json.load(r)
for u in d["urls"]:
    if u["packagetype"] == "bdist_wheel" and u["filename"].endswith("py3-none-any.whl"):
        print(u["url"]); break
PY
)" || true
    [ -n "$url" ] || err "取不到 pip $PIP_VER 的 wheel 地址"
    log "下载 $url"
    curl -sL --retry 3 -m 600 -o "$WHEEL" "$url" || err "pip wheel 下载失败"
    [ -s "$WHEEL" ] || err "pip wheel 是空的"
fi

# ── 1. 解开 wheel 到 site-packages ─────────────────────────
# wheel 就是 zip:顶层是 pip/ 与 pip-<ver>.dist-info/,直接摊到 site-packages 即可。
# 不要用宿主 pip 去 `pip install`——那会把宿主 python 的路径写进 .dist-info/RECORD
# 之类(而且没必要)。
SP="$RT_ROOT/python/lib/python$PY_SERIES/site-packages"
rm -rf "$RT_ROOT"
mkdir -p "$SP"
"$HOST_PY" - "$WHEEL" "$SP" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PY

# ── 1.5 sitecustomize.py ───────────────────────────────────
# 解释器启动时由 site 模块自动 import。目前它管一件事：**pip 的平台 tag 伪装**
# （BSH_PIP_FAKE_PLATFORM，见该文件头部说明）。放这儿是因为它服务的就是 python 的
# 运行期环境，跟着 pip 一起走最省事。
cp -f "$SCRIPT_DIR/sitecustomize.py" "$SP/sitecustomize.py" || err "拷 sitecustomize.py 失败"

# ── 2. 校验 ────────────────────────────────────────────────
[ -f "$SP/pip/__main__.py" ] || err "解出来的 wheel 里没有 pip/__main__.py"
[ -d "$SP/pip/_vendor" ] || err "pip/_vendor 缺失(wheel 不完整?)"
# certifi 的根证书:直连 PyPI 的 https 靠它,少了就得靠 ssl 的默认路径(设备上没有)
[ -f "$SP/pip/_vendor/certifi/cacert.pem" ] || warn "没看到 pip/_vendor/certifi/cacert.pem,https 校验可能没根证书"

# ── 3. 打 pkg 包（tar + zstd，与 ohos-sdk-prune 同格式）──────────
# 这个产物是给 **pkg 服务器**的（用户在终端里 `pkg install pip`），不再随 HAP 打包：
# 它是"想用才装"的东西，而且更新节奏跟着 PyPI 走，没必要让每个装 BetterSH 的人
# 都背一份。顶层仍是 `python/`，pkg 会把它解到资源根。
log "打包 $PIP_PKG"
tar -C "$RT_ROOT" -cf - python | zstd -q -f -19 -T"$JOBS" -o "$PIP_PKG"
[ -s "$PIP_PKG" ] || err "pip 包是空的"
log "pip 就绪:$(du -h "$PIP_PKG" | cut -f1)（$(tar --zstd -tf "$PIP_PKG" 2>/dev/null | wc -l) 个条目）"
log "  上传：scp $PIP_PKG <server>:<bsh-packages>/，再把 size/sha256 写进 index.json"
log "  size=$(stat -c %s "$PIP_PKG")  sha256=$(sha256sum "$PIP_PKG" | cut -d' ' -f1)"
