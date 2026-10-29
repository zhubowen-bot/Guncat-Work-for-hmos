#!/bin/bash
# build_release.sh — 出**发布用**的包：release 模式构建 + 用 build-profile.json5 里
# 名为 `release` 的 signingConfig 材料签名。
#
# 产出（默认落 $ROOT/build/release/）：
#   BetterSH-<versionName>-release.hap   已签名的模块包（装机自测 / 内测分发）
#   BetterSH-<versionName>-release.app   已签名的 App Pack（上架 AppGallery 用）
#
# 为什么不直接 `hvigorw assembleApp` 完事：hvigor 侧 product 的 signingConfig 指向的名字，
# 在这份 profile 里不一定有对应材料（示例 profile 的 signingConfigs 干脆是空的），拿不到
# 证书就只能产出 unsigned —— 这也是仓库一直用 sign_hap.sh/sign_hap.py 在外面签的原因。
#
# 签名材料默认读**仓库根的 build-profile.json5**（`app.signingConfigs`），用 `SIGN_PROFILE_FILE`
# 可换成别的；用哪一项由 `SIGN_CFG_NAME` 定（默认 `release`）。材料里的 `C:/keys/...` 由签名
# 脚本转成 /mnt/c/...（hvigor 跑在 WSL 里解不了这种路径）。
#
# App Pack 为什么要重打一遍（而不是直接签 hvigor 产出的 .app）：
#   1) hvigor 打出的 .app 里，内层 hap 是**未签名**的 —— 只签外层，内层仍然
#      `verify-app` 失败（实测：`Verify Hap failed, signature not found`），商店不收；
#   2) 所以顺序必须是 **先签 hap → 用它重打 .app → 再签 .app**；
#   3) 重打时 `--replace-pack-info` 必须显式给 **false**：默认 true 会让打包工具改写 hap
#      内部的 pack.info 并重新压一遍 zip，**签名块随之丢失**（实测解出来的内层 hap 哈希
#      与签好的那份不一致、verify 失败）。
#   4) 内层 hap 在 .app 里的**文件名**得是模块名（`entry-default.hap`），不能跟着输入
#      文件名走 —— 否则打出来叫 `xxx.hap`，与 pack.info 对不上。
#
# 用法：
#   scripts/build_release.sh                  # 构建 + 签名（hap 与 app 都出）
#   SKIP_BUILD=1 scripts/build_release.sh     # 只重新签名现有产物（复用上次构建）
#   SKIP_APP=1   scripts/build_release.sh     # 只要 hap，跳过 App Pack
#   OUT_DIR=/tmp/x scripts/build_release.sh
#   SIGN_CFG_NAME=xxx scripts/build_release.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

SIGN_CFG_NAME="${SIGN_CFG_NAME:-release}"
# 签名材料来源：默认**仓库根的 build-profile.json5**；用 SIGN_PROFILE_FILE 可换成别的
# （例如 env.sh 里那份 Windows 侧的 BUILD_PROFILE_FILE —— build_test.sh 就是这么用的）。
SIGN_PROFILE_FILE="${SIGN_PROFILE_FILE:-$ROOT/build-profile.json5}"
OUT_DIR="${OUT_DIR:-$ROOT/build/release}"
JAR_SIGN="${HAP_SIGN_JAR:-$OHOS_SDK/toolchains/lib/hap-sign-tool.jar}"
JAR_PACK="${HAP_PACK_JAR:-$OHOS_SDK/toolchains/lib/app_packing_tool.jar}"
APP_JSON="$ROOT/AppScope/app.json5"
# HAP 产物目录由 env.sh 按 $BSH_PRODUCT 给(分包后有两个 entry)，这里不要覆盖它
APP_OUT_DIR="$ROOT/build/outputs/default"

[ -f "$SIGN_PROFILE_FILE" ] || err "缺少签名配置：$SIGN_PROFILE_FILE（用 SIGN_PROFILE_FILE 覆盖）"
[ -f "$JAR_SIGN" ] || err "找不到 hap-sign-tool.jar：$JAR_SIGN"
command -v java    >/dev/null || err "java 未安装"
command -v python3 >/dev/null || err "python3 未安装"

# ── 0) 从 build-profile.json5 取 $SIGN_CFG_NAME 那条签名材料（并转成 WSL 路径）─────
log "=== 0/4 校验签名材料（signingConfig: $SIGN_CFG_NAME）==="
eval "$(python3 - "$SIGN_PROFILE_FILE" "$SIGN_CFG_NAME" <<'PY'
import json, re, shlex, sys
path, name = sys.argv[1], sys.argv[2]
s = open(path, encoding='utf-8').read()
s = re.sub(r'//.*$', '', s, flags=re.M)          # 去注释
s = re.sub(r',\s*([}\]])', r'\1', s)             # 去尾逗号
cfgs = json.loads(s)["app"]["signingConfigs"]
hit = [c for c in cfgs if c.get("name") == name]
if not hit:
    names = ", ".join(c.get("name", "?") for c in cfgs)
    sys.exit(f"error: build-profile.json5 里没有名为 {name!r} 的 signingConfig（可用：{names}）")

def w2w(p):
    m = re.match(r'^([A-Za-z]):[\\/](.*)$', p)
    return "/mnt/%s/%s" % (m.group(1).lower(), m.group(2).replace("\\", "/")) if m else p

m = hit[0]["material"]
for k, v in (("CERT", m["certpath"]), ("PROFILE", m["profile"]), ("STORE", m["storeFile"])):
    print("SIGN_%s=%s" % (k, shlex.quote(w2w(v))))
PY
)"

for f in "$SIGN_CERT" "$SIGN_PROFILE" "$SIGN_STORE"; do
    [ -f "$f" ] || err "签名材料不存在：$f"
done
[ -d "$(dirname "$SIGN_CERT")/material" ] || \
    err "缺 material/ 目录（DevEco 加密口令的解密密钥）：$(dirname "$SIGN_CERT")/material"

# AppScope/app.json5 的 bundleName 必须与证书 profile 里的一致，否则签出来装不上也上不了架
read -r APP_BUNDLE APP_VER <<EOF
$(python3 - "$APP_JSON" <<'PY'
import json, re, sys
s = open(sys.argv[1], encoding='utf-8').read()
s = re.sub(r'//.*$', '', s, flags=re.M)
s = re.sub(r',\s*([}\]])', r'\1', s)
app = json.loads(s)["app"]
print(app["bundleName"], app["versionName"])
PY
)
EOF
# 注：字段不一定都有（debug 类型的 profile 就没有 app-distribution-type），grep 取不到时
# 要容忍 —— 这里开了 pipefail，空的 grep 会让整条管道失败、set -e 直接终止脚本。
prof_field() {
    # 末尾的 || true 是给 pipefail 用的：字段不存在时 grep 返回 1，整条管道就"失败"了，
    # set -e 会当场退出（debug 类型的 profile 没有 app-distribution-type，实测踩过）。
    grep -a -o "$1" "$SIGN_PROFILE" 2>/dev/null | head -1 | sed 's/^[^:]*://' | tr -d '"' || true
}
PROFILE_BUNDLE="$(prof_field '"bundle-name":"[^"]*"')"
PROFILE_DIST="$(prof_field '"app-distribution-type":"[^"]*"')"
PROFILE_DEV="$(prof_field '"developer-id":"[^"]*"')"
PROFILE_TYPE="$(prof_field '"type":"[^"]*"')"
NOT_AFTER="$(grep -a -o '"not-after":[0-9]*' "$SIGN_PROFILE" 2>/dev/null | head -1 | cut -d: -f2 || true)"

log "  bundleName : $APP_BUNDLE (versionName $APP_VER)"
log "  profile    : $PROFILE_BUNDLE / type=$PROFILE_TYPE / dist=$PROFILE_DIST / developer-id $PROFILE_DEV"
[ "$APP_BUNDLE" = "$PROFILE_BUNDLE" ] || \
    err "bundleName 不一致：app.json5=$APP_BUNDLE，profile=$PROFILE_BUNDLE"
if [ -n "$NOT_AFTER" ] && [ "$NOT_AFTER" -le "$(date +%s)" ]; then
    err "profile 已过期（not-after=$NOT_AFTER = $(date -d @"$NOT_AFTER" '+%F' 2>/dev/null)）"
fi

# ── 1) release 构建 ──────────────────────────────────────────────────────────
if [ "${SKIP_BUILD:-0}" = "1" ]; then
    warn "SKIP_BUILD=1：跳过构建，直接用现有产物"
else
    log "=== 1/4 release 构建 ==="
    BUILD_MODE=release "$SCRIPT_DIR/build_hap.sh"
    if [ "${SKIP_APP:-0}" != "1" ]; then
        # App Pack 由项目级任务产出；这一步同时生成 pack.info/pac.json（重打 .app 要用）
        ( cd "$ROOT" && "$TOOL_HOME/bin/hvigorw" assembleApp --mode project \
            -p product=default -p buildMode=release --no-daemon )
    fi
fi

newest() {  # 取最新修改的那个文件；都不存在就输出空。永远返回 0（否则 set -e/pipefail 会误杀）
    local f latest="" latest_t=-1 t
    for f in "$@"; do
        [ -f "$f" ] || continue
        t="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        if [ "$t" -gt "$latest_t" ]; then latest="$f"; latest_t="$t"; fi
    done
    [ -n "$latest" ] && printf '%s\n' "$latest"
    return 0
}

HAP_IN="$(newest "$HAP_OUT_DIR"/*-unsigned.hap)"
[ -n "$HAP_IN" ] || HAP_IN="$(newest "$HAP_OUT_DIR"/*.hap)"
[ -n "$HAP_IN" ] || err "找不到构建出的 .hap（$HAP_OUT_DIR）"

mkdir -p "$OUT_DIR"
HAP_OUT="$OUT_DIR/BetterSH-$APP_VER-$SIGN_CFG_NAME.hap"
APP_OUT="$OUT_DIR/BetterSH-$APP_VER-$SIGN_CFG_NAME.app"

# ── 2) 签 hap ───────────────────────────────────────────────────────────────
log "=== 2/4 签名 HAP ==="
log "  in : $(basename "$HAP_IN")"
python3 "$SCRIPT_DIR/sign_hap.py" "$SIGN_PROFILE_FILE" "$HAP_IN" "$HAP_OUT" "$SIGN_CFG_NAME"
[ -f "$HAP_OUT" ] || err "HAP 签名未产出文件"

# ── 3) 用签好的 hap 重打 App Pack ────────────────────────────────────────────
APP_IN="$(newest "$APP_OUT_DIR"/*.app "$HAP_OUT_DIR"/*.app)"
PACK_INFO="$(newest "$APP_OUT_DIR"/pack.info)"
PAC_JSON="$(newest "$APP_OUT_DIR"/pac.json)"

if [ "${SKIP_APP:-0}" = "1" ]; then
    warn "SKIP_APP=1：跳过 App Pack"
    APP_OUT=""
elif [ -z "$PACK_INFO" ]; then
    err "找不到 pack.info（$APP_OUT_DIR）—— 需要先跑完 assembleApp；只要 hap 请加 SKIP_APP=1"
else
    [ -f "$JAR_PACK" ] || err "找不到 app_packing_tool.jar：$JAR_PACK"
    # 内层 hap 在 .app 里的名字（从 hvigor 打出的那份里取，通常是 entry-default.hap）
    INNER_NAME=""
    [ -n "$APP_IN" ] && INNER_NAME="$(unzip -Z1 "$APP_IN" '*.hap' 2>/dev/null | head -1)"
    [ -n "$INNER_NAME" ] || INNER_NAME="$(basename "$HAP_IN" | sed 's/-unsigned//')"

    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cp "$HAP_OUT" "$WORK/$INNER_NAME"
    log "=== 3/4 重打 App Pack（内层 hap: $INNER_NAME，已签名）==="
    pack_args=(--mode app --hap-path "$WORK/$INNER_NAME"
               --pack-info-path "$PACK_INFO"
               --out-path "$WORK/unsigned.app" --force true
               --replace-pack-info false)   # true 会重压 hap 并丢掉签名块，必须是 false
    [ -n "$PAC_JSON" ] && pack_args+=(--pac-json-path "$PAC_JSON")
    java -jar "$JAR_PACK" "${pack_args[@]}" >/dev/null

    log "=== 4/4 签名 App Pack ==="
    python3 "$SCRIPT_DIR/sign_hap.py" "$SIGN_PROFILE_FILE" "$WORK/unsigned.app" "$APP_OUT" "$SIGN_CFG_NAME"
    [ -f "$APP_OUT" ] || err "App Pack 签名未产出文件"
fi

# ── 校验 + 汇总 ─────────────────────────────────────────────────────────────
verify() {  # <file> <label>
    local f="$1" label="$2" tmp rc
    tmp="$(mktemp -d)"
    set +e
    java -jar "$JAR_SIGN" verify-app -inFile "$f" \
        -outCertChain "$tmp/cert.cer" -outProfile "$tmp/profile.p7b" >"$tmp/log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        sed 's/^/    /' "$tmp/log" >&2
        rm -rf "$tmp"
        err "$label 校验失败：$f"
    fi
    grep -iE "verify: Verify success" "$tmp/log" | head -1 | sed 's/^/    /'
    rm -rf "$tmp"
}

log "=== 校验 ==="
verify "$HAP_OUT" "hap"
if [ -n "$APP_OUT" ]; then
    verify "$APP_OUT" "app"
    # 内层 hap 也要能过（这正是“只签外层”会漏掉的那一步）
    tmpd="$(mktemp -d)"
    unzip -o -q "$APP_OUT" '*.hap' -d "$tmpd"
    inner="$(find "$tmpd" -maxdepth 1 -name '*.hap' -print -quit)"
    if [ -n "$inner" ]; then verify "$inner" "app 内层 hap"; else warn "app 里没找到 hap"; fi
    rm -rf "$tmpd"
fi

log "✅ 发布包就绪（$OUT_DIR）"
for f in "$HAP_OUT" "$APP_OUT"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    printf '  %-42s %9s  sha256=%s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)" \
        "$(sha256sum "$f" | cut -c1-16)"
done
