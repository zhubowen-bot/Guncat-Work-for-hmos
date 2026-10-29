#!/bin/bash
# switch_version.sh — 在几个"发行变体"之间切换（versions/ 下的快照）
#
# 只干三件事：
#   1) 改 bundleName 与 label
#   2) 用快照里的 requestPermissions 覆盖 entry 的权限配置
#   3) 打印这个配置该用哪套签名（配置名 + 材料路径 + 构建命令）
#
# **不再同步 `feature/bsh_main/libs/arm64-v8a/` 与 `rawfile/tools/`**。那两处是构建产物，
# 内容该由各自的 build_*.sh 决定、去留该由 .gitignore 决定；让"切版本"顺带 rsync 整目录，
# 等于把两件事绑在一起，而 `--delete` 还会删掉 tools/ 里已入库的源文件（hello.c 等）。
# 快照里遗留的 `arm64-v8a/`、`tools/` 目录本脚本一律不再读（只提一句，见 list）。
#
# 快照 = `versions/<名>/` 下这几个文件（整个 versions/ 不入库，见 .gitignore）：
#
#   bundleName           必需。一行，如 `com.yiyan.bettershdev`
#   module.json5         必需。**只取其中的 requestPermissions 那一段**，其余不读 ——
#                        所以快照里那份的 `module.name` 是旧值也无所谓。
#   phone.module.json5   可选。同上；不给就**不动** phone（保留仓库基线：无 JIT 权限）。
#   label                可选。一行，如 `BetterSH Dev`；不给就不动 label。
#   signingConfig        可选。一行，`build-profile.json5` 里某个 signingConfig 的名字；
#                        不给则按版本名推：`*-dev` → `debug-jit`，其余 → `release`。
#   buildProfile         可选。一行，用哪份 build-profile.json5（相对路径按仓库根解析）；
#                        不给就用 env.sh 的 BUILD_PROFILE_FILE。**换了 bundleName 就得换它**
#                        —— profile 里写着 bundle-name，两个包各自是独立的 DevEco 工程生成的。
#
# 两处刻意的做法：
#   * 权限与 bundleName/label 都是**就地改那一段/那一行**，不整份重写文件 —— 目标文件里
#     还有模块名、abilities、设备类型这些不该被快照带跑的东西（快照是 10-01 拷的，
#     那时模块还叫 entry）。
#   * label 要写三处：`AppScope/.../app_name` 是应用名，两个 entry 的
#     `EntryAbility_label` 才是桌面图标上显示的那个，只改一处会出现"名字不一致"。
#
# 用法：
#     scripts/switch_version.sh                 # 列出可选版本
#     scripts/switch_version.sh <名>            # 切过去
#     scripts/switch_version.sh <名> -n         # dry-run：只说打算做什么
#
# 切完要重新构建（脚本末尾会把命令打出来）。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

VERS_DIR="$ROOT/versions"
APP_JSON="$ROOT/AppScope/app.json5"
APP_STR="$ROOT/AppScope/resources/base/element/string.json"
TABLET_MOD="$ROOT/product/tablet/src/main/module.json5"
PHONE_MOD="$ROOT/product/phone/src/main/module.json5"
TABLET_STR="$ROOT/product/tablet/src/main/resources/base/element/string.json"
PHONE_STR="$ROOT/product/phone/src/main/resources/base/element/string.json"

NAME="${1:-}"
DRY_RUN=0
[ "${2:-}" = "-n" ] && DRY_RUN=1

# 快照里可选的一行文件；不存在或为空 → 空串
opt_file() {  # <路径>
    [ -f "$1" ] || return 0
    head -n1 "$1" | tr -d '[:space:]'
}

# 这个版本默认用哪套签名。理由：带 JIT 权限的那些是设备自测/自举用的变体，走 debug-jit
# （debug 类型 profile 装得上 + 开 ALLOW_WRITABLE_CODE_MEMORY）；其余按发布件走 release。
default_signing() {  # <版本名>
    case "$1" in
        *-dev) printf 'debug-jit' ;;
        *)     printf 'release' ;;
    esac
}

# 从 string.json 里取某个字符串资源的值（只用于显示）。值在 name 的下一行。
string_value() {  # <文件> <键>
    sed -n '/"name": *"'"$2"'"/{n;s/.*"value": *"\([^"]*\)".*/\1/p;q;}' "$1"
}

list_versions() {
    log "可选版本（$VERS_DIR）："
    local v bn lb sg left
    for v in "$VERS_DIR"/*/; do
        [ -d "$v" ] || continue
        v="$(basename "$v")"
        bn="$(opt_file "$VERS_DIR/$v/bundleName")"
        lb="$(opt_file "$VERS_DIR/$v/label")"
        sg="$(opt_file "$VERS_DIR/$v/signingConfig")"
        printf '  %-14s bundle=%-22s label=%-16s 签名=%s\n' \
            "$v" "${bn:-?}" "${lb:-（不动）}" "${sg:-$(default_signing "$v")（按名推）}"
        left=""
        for d in arm64-v8a tools; do
            [ -d "$VERS_DIR/$v/$d" ] && left="$left $d/"
        done
        [ -n "$left" ] && printf '  %-14s ⚠ 快照里还有%s（本脚本已不再使用，可自行删）\n' "" "$left"
    done
    echo >&2
    printf '  当前工程     bundle=%-22s label=%s\n' \
        "$(sed -n 's/.*"bundleName": *"\([^"]*\)".*/\1/p' "$APP_JSON" | head -1)" \
        "$(string_value "$APP_STR" app_name)"
    echo >&2
    log "切过去：scripts/switch_version.sh <版本名>"
}

if [ -z "$NAME" ]; then
    list_versions
    exit 0
fi

VSRC="$VERS_DIR/$NAME"
[ -d "$VSRC" ] || { list_versions >&2; err "没有这个版本：$NAME"; }
for piece in bundleName module.json5; do
    [ -s "$VSRC/$piece" ] || err "版本快照不完整：缺 $VSRC/$piece"
done
[ -f "$TABLET_MOD" ] || err "缺 $TABLET_MOD（首次构建前先从 .example 拷一份）"

python3 - "$NAME" "$VSRC" "$APP_JSON" "$APP_STR" "$TABLET_STR" "$PHONE_STR" \
         "$TABLET_MOD" "$PHONE_MOD" "$BUILD_PROFILE_FILE" "$DRY_RUN" <<'PY'
import json, os, re, sys

(name, vsrc, app_json, app_str, tab_str, pho_str,
 tablet_mod, phone_mod, profile_file, dry_run) = sys.argv[1:11]
DRY = dry_run == "1"


def log(msg):
    print("\033[32m[BSH]\033[0m %s" % msg, file=sys.stderr)


def warn(msg):
    print("\033[33m[BSH]\033[0m %s" % msg, file=sys.stderr)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    if not DRY:
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)


def read_opt(path):
    """快照里的单行可选文件：不存在/空白 → None"""
    if not os.path.exists(path):
        return None
    v = open(path, encoding="utf-8").read().strip()
    return v or None


def strip_json5(t):
    """与 sign_hap.py 同一套：去 // 注释与尾逗号，然后按严格 JSON 解析。"""
    t = re.sub(r"//.*$", "", t, flags=re.MULTILINE)
    t = re.sub(r",\s*([}\]])", r"\1", t)
    return t


def load(path):
    return json.loads(strip_json5(read(path)))


# ── 就地改一行（bundleName / 字符串资源）────────────────────────────────
# 不整份重写文件：这些文件是入库的，重写会带出一屏只有格式差异的 diff。
def patch_one_line(path, pattern, value):
    text = read(path)
    m = re.search(pattern, text)
    if not m:
        return None
    old = m.group(2)
    if old != value:
        write(path, text[:m.start(2)] + value + text[m.end(2):])
    return old


# ── 取 module.json5 里 requestPermissions 的数组文本 ────────────────────
def slice_array(text, key):
    """返回 (数组起, 数组止, key 所在行的缩进)。括号匹配跳过字符串，
    免得被字符串里的 ] 骗到。"""
    m = re.search(r'"%s"\s*:\s*\[' % re.escape(key), text)
    if not m:
        return None
    start = m.end() - 1
    depth, instr, esc = 0, False, False
    for i in range(start, len(text)):
        c = text[i]
        if instr:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                instr = False
            continue
        if c == '"':
            instr = True
        elif c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                line_start = text.rfind("\n", 0, m.start()) + 1
                indent = m.start() - line_start
                return (start, i, indent)
    return None


def rebase(value_text, indent):
    """把源的数组文本按目标的缩进重排（元素 = indent+2，收尾的 ] = indent）。"""
    lines = value_text.split("\n")
    if len(lines) < 2:
        return value_text
    body = [l for l in lines[1:-1] if l.strip()]
    base = min(len(l) - len(l.lstrip()) for l in body) if body else indent + 2
    out = [lines[0]]
    for l in lines[1:-1]:
        out.append(" " * (indent + 2) + l[base:] if l.strip() else "")
    out.append(" " * indent + lines[-1].lstrip())
    return "\n".join(out)


def apply_perms(src_mod, dst_mod, who):
    """把 src 的 requestPermissions 段原样搬到 dst（只碰这一段）。"""
    src = read(src_mod)
    s = slice_array(src, "requestPermissions")
    if s is None:
        warn("%s：快照里没有 requestPermissions，跳过" % who)
        return None
    names = [p["name"] for p in load(src_mod)["module"]["requestPermissions"]]

    dst = read(dst_mod)
    d = slice_array(dst, "requestPermissions")
    if d is None:
        warn("%s：目标里没有 requestPermissions 段，无法就地替换 —— 请手工加上" % who)
        return None
    key_start = dst.rfind('"requestPermissions"')
    new = rebase(src[s[0]:s[1] + 1], d[2])       # 按目标的缩进重排
    write(dst_mod, dst[:key_start] + '"requestPermissions": ' + new + dst[d[1] + 1:])
    return names


# ── 1) bundleName ──────────────────────────────────────────────────────
bn = read_opt(os.path.join(vsrc, "bundleName"))
old_bn = patch_one_line(app_json, r'("bundleName"\s*:\s*")([^"]*)(")', bn)
if old_bn is None:
    warn("%s 里没有 bundleName 那一行，无法就地改" % app_json)
log("bundleName: %s → %s" % (old_bn, bn))

# ── 2) label（应用名 + 两个 entry 的桌面图标名）──────────────────────────
def app_name_now():
    m = re.search(r'"name"\s*:\s*"app_name"\s*,\s*"value"\s*:\s*"([^"]*)"', read(app_str))
    return m.group(1) if m else "?"


label = read_opt(os.path.join(vsrc, "label"))
if label is None:
    warn("快照没给 label → 不动（当前 %s）" % app_name_now())
else:
    for path, key in ((app_str, "app_name"),
                      (tab_str, "EntryAbility_label"),
                      (pho_str, "EntryAbility_label")):
        if not os.path.exists(path):
            continue
        old = patch_one_line(path, r'("name"\s*:\s*"%s"\s*,\s*"value"\s*:\s*")([^"]*)(")'
                                   % re.escape(key), label)
        if old is None:
            warn("%s 里找不到 %s，跳过" % (path, key))
        elif old != label:
            log("label: %s  %s → %s" % (key, old, label))

# ── 3) 权限（tablet 必需，phone 可选）────────────────────────────────────
tab_names = apply_perms(os.path.join(vsrc, "module.json5"), tablet_mod, "tablet")
if tab_names is None:
    sys.exit(1)
log("tablet 权限 %d 条：%s" % (len(tab_names), " ".join(tab_names)))

phone_src = os.path.join(vsrc, "phone.module.json5")
if os.path.exists(phone_src) and os.path.exists(phone_mod):
    ph_names = apply_perms(phone_src, phone_mod, "phone")
    if ph_names is not None:
        log("phone  权限 %d 条：%s" % (len(ph_names), " ".join(ph_names)))
else:
    warn("快照没给 phone.module.json5 → 不动 phone（保留仓库基线）")

# ── 4) 这个配置该用哪套签名 ─────────────────────────────────────────────
declared = read_opt(os.path.join(vsrc, "signingConfig"))
cfg_name = declared or ("debug-jit" if name.endswith("-dev") else "release")
how = "快照声明" if declared else "按版本名推（*-dev → debug-jit，其余 → release）"

# profile 也能按版本指定：bundleName 换了就得换一份 profile —— 设备校验 bundle 与 profile
# 的一致性（`com.yiyan.bettershdev` 那套材料跟正式包那份是两个 DevEco 工程各自生成的）。
# 给相对路径时按仓库根解析。
prof_declared = read_opt(os.path.join(vsrc, "buildProfile"))
if prof_declared and not os.path.isabs(prof_declared):
    prof_declared = os.path.join(os.path.dirname(os.path.dirname(vsrc)), prof_declared)
profile_file = prof_declared or profile_file

print()
log("=== 这个配置要用哪套签名 ===")
log("  signingConfig : %s    [%s]" % (cfg_name, how))
log("  buildProfile  : %s    [%s]"
    % (profile_file, "快照声明" if prof_declared else "env.sh 的 BUILD_PROFILE_FILE"))
try:
    cfgs = load(profile_file)["app"]["signingConfigs"]
except Exception as e:
    warn("读不了 %s（%s）—— 下面只给名字" % (profile_file, e))
    cfgs = []


def p7b_field(path, pattern):
    """从 p7b（PKCS#7 里夹着一段明文 JSON）里读一个字段。"""
    try:
        blob = open(path, "rb").read()
    except OSError:
        return None
    m = re.search(pattern, blob)
    return m.group(1).decode() if m else None


hit = [c for c in cfgs if c.get("name") == cfg_name]
if not hit:
    warn("build-profile.json5 里没有名为 %s 的 signingConfig（可用：%s）"
         % (cfg_name, ", ".join(c.get("name", "?") for c in cfgs) or "无"))
else:
    mat = hit[0].get("material", {})

    def w2w(p):
        m = re.match(r"^([A-Za-z]):[\\/](.*)$", p)
        return "/mnt/%s/%s" % (m.group(1).lower(), m.group(2).replace("\\", "/")) if m else p

    for k in ("keyAlias", "certpath", "profile", "storeFile"):
        if mat.get(k):
            v = w2w(mat[k])
            mark = "" if (k == "keyAlias" or os.path.exists(v)) else "   ← 文件不存在"
            log("  %-13s : %s%s" % (k, v, mark))

    # ── 两道一致性检查：这两样对不上，装上去也是白装 ────────────────────
    # 1) profile 是给哪个 bundle 签的。签出来 bundle 与 profile 不一致的包，设备直接拒装。
    if mat.get("profile"):
        pb = p7b_field(w2w(mat["profile"]), rb'"bundle-name":"([^"]*)"')
        if pb is None:
            warn("  读不出 profile 的 bundle-name（文件在不在？）")
        elif pb != bn:
            warn("  ⚠ profile 是给 `%s` 签的，而本配置的 bundleName 是 `%s`"
                 " —— 这个包装不上/起不来" % (pb, bn))
        else:
            log("  profile 的 bundle-name 与配置一致（%s）" % pb)
    # 2) 受限权限（kernel.* 那几条）必须出现在 profile 的 allowed-acls 里，否则装上也拿不到。
    if mat.get("profile"):
        acl_txt = p7b_field(w2w(mat["profile"]), rb'"allowed-acls":\[([^\]]*)\]') or ""
        have = set(re.findall(r'"([^"]+)"', acl_txt))
        need = {p for p in (tab_names or []) if p.startswith("ohos.permission.kernel.")}
        miss = need - have
        if miss:
            warn("  ⚠ 配置要这些受限权限，但 profile 的 allowed-acls 没给：%s"
                 % " ".join(sorted(miss)))
        elif need:
            log("  受限权限 profile 都给了（%d 条）" % len(need))

print()
log("下一步：")
env_prefix = "" if not prof_declared else "BUILD_PROFILE_FILE=%s " % profile_file
log("  BSH_PRODUCT=tablet %sSIGN_CFG_NAME=%s ./scripts/build_release.sh" % (env_prefix, cfg_name))
env_bn = os.environ.get("BUNDLE_NAME", "")
if bn != env_bn:
    warn("  部署/拉起要带上 BUNDLE_NAME=%s —— deploy_hap.sh 默认拿 `%s` 去 aa start"
         % (bn, env_bn))
if cfg_name == "release":
    warn("  release 型 profile 签出来的包 hdc **装不上**"
         "（code:9568322 not trusted app source）—— 只用于提交/发布，验证要换 debug-jit")
elif cfg_name == "debug-jit" and not prof_declared:
    # 只有"正式包 + debug-jit"这一种组合才直接对上 build_test.sh（它内部写死了这两个）
    log("  设备一条龙（固定 debug-jit + 部署 + 拉起）：./scripts/build_test.sh")
else:
    log("  部署/拉起：HAP_SIGNED=<上面的 hap> BUNDLE_NAME=%s ./scripts/deploy_hap.sh" % bn)
if DRY:
    warn("dry-run：没有动任何文件")
PY
