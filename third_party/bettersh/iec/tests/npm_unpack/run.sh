#!/usr/bin/env bash
# run.sh — npm.tar.gz 解包的宿主回归（不连设备）。
#
# 验证三条线：
#   1) 随包 npm.tar.gz 本身：2697 个条目、顶层 npm/、package.json=10.9.3、
#      npm-cli.js / npx-cli.js 非空、解包字节数等于归档非压缩总量；
#   2) 抽出的 C 核心：tests/npm_unpack/harness.cpp 直接调用
#      common/archive_extract.cpp 的 IecExtractTar()，与 bsdtar（宿主
#      libarchive）解出的参考树逐文件比 sha256（固定种子抽 200 个 + 两个入口）；
#   3) 失败路径：截断到 1KB 的 tar 必须返回非 0 且不留 <dest>/npm/.unpack-complete
#      与 npm/bin/npm-cli.js；只读目标目录必须报错。
#
# 依赖：python3、bsdtar（Ubuntu: libarchive-tools）、宿主 libarchive 运行库
# （libarchive.so.13，Ubuntu: libarchive13）与一个 C++17 编译器。缺任何一项
# 退出 77（check-all 记为 SKIP）。不需要 libarchive 头文件：被测核心和设备
# 一样是运行期 dlopen，宿主直接加载同一个 .so。
#
# 用法：
#   bash third_party/bettersh/iec/tests/npm_unpack/run.sh
#   NPM_TAR=/path/to/npm.tar.gz BSDTAR=/path/to/bsdtar bash .../run.sh
#   CXX=clang++ IEC_NPM_TEST_VERBOSE=1 bash .../run.sh
#
# 退出码：0 = PASS，1 = FAIL，77 = SKIP。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IEC_ROOT="$(cd "$HERE/../.." && pwd)"
TAR="${NPM_TAR:-$IEC_ROOT/platform/ohos/har/src/main/resources/rawfile/tools/npm.tar.gz}"
PYTHON="${PYTHON:-python3}"
BSDTAR="${BSDTAR:-bsdtar}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/npm_unpack.XXXXXX")" || exit 2
cleanup() {
    # 只读用例失败时目录可能还是 0555；先恢复再删。
    chmod -R u+rwX "$TMP" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
SKIP=0
MISSING=()

pass() { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  [SKIP] %s\n' "$*"; SKIP=$((SKIP + 1)); }
info() { printf '  [INFO] %s\n' "$*"; }

need() {
    command -v "$1" >/dev/null 2>&1 && return 0
    case " ${MISSING[*]:-} " in
        *" $1 "*) ;;
        *) MISSING+=("$1") ;;
    esac
    skip "找不到 $1"
    return 1
}

# 与 archive_extract.cpp 的 dlopen 候选一致：宿主上能加载 libarchive.so.13
# 或 libarchive.so，harness 才跑得起来。
have_libarchive() {
    "$PYTHON" - <<'PY' >/dev/null 2>&1
import ctypes
for name in ("libarchive.so.13", "libarchive.so"):
    try:
        ctypes.CDLL(name)
        raise SystemExit(0)
    except OSError:
        pass
raise SystemExit(1)
PY
}

printf '== npm unpack: %s\n' "$TAR"

# ---------- 依赖 ----------
need "$PYTHON" || true
if ! command -v "$BSDTAR" >/dev/null 2>&1; then
    MISSING+=("$BSDTAR")
    skip "找不到 bsdtar（Ubuntu: apt-get install libarchive-tools）"
fi
if command -v "$PYTHON" >/dev/null 2>&1 && ! have_libarchive; then
    MISSING+=("libarchive")
    skip "宿主加载不了 libarchive.so.13（Ubuntu: apt-get install libarchive13）"
fi

CXX_BIN="${CXX:-}"
if [ -z "$CXX_BIN" ]; then
    for c in c++ g++ clang++; do
        if command -v "$c" >/dev/null 2>&1; then CXX_BIN="$c"; break; fi
    done
fi
if [ -z "$CXX_BIN" ]; then
    MISSING+=("c++")
    skip "找不到 C++17 编译器（或用 CXX=... 指定）"
fi

if ! [ -f "$TAR" ]; then
    fail "tar 不存在：$TAR（应先跑 scripts/optional/build_node.sh）"
    echo "SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    exit 1
fi

if ((${#MISSING[@]})); then
    echo "SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    echo "缺少依赖：${MISSING[*]}"
    exit 77
fi

# ---------- 1. 参考树：bsdtar ----------
echo
echo '-- bsdtar 参考解包'
mkdir -p "$TMP/ref"
if "$BSDTAR" -xzf "$TAR" -C "$TMP/ref" >"$TMP/bsdtar.log" 2>&1; then
    pass "bsdtar 解包成功（$(find "$TMP/ref" -mindepth 1 | wc -l | tr -d ' ') 个条目）"
else
    fail "bsdtar 解包失败：$(tr '\n' ' ' <"$TMP/bsdtar.log" | cut -c1-300)"
fi

# ---------- 2. 被测核心：harness + IecExtractTar ----------
echo
echo '-- 宿主 harness（common/archive_extract.cpp）'
HARNESS="$TMP/iec_npm_unpack"
CXXFLAGS=(-std=c++17 -O1 -g -Wall -Wextra -I "$IEC_ROOT")
if "$CXX_BIN" "${CXXFLAGS[@]}" \
        "$HERE/harness.cpp" \
        "$IEC_ROOT/common/archive_extract.cpp" \
        "$IEC_ROOT/logger/logger.cpp" \
        -ldl -pthread -o "$HARNESS" >"$TMP/build.log" 2>&1; then
    pass "harness 编译通过（$CXX_BIN）"

    mkdir -p "$TMP/impl"
    if "$HARNESS" "$TAR" "$TMP/impl" >"$TMP/harness.log" 2>&1; then
        pass "IecExtractTar 解包返回 0"
    else
        fail "IecExtractTar 解包返回非 0：$(tr '\n' ' ' <"$TMP/harness.log" | cut -c1-300)"
    fi

    if [ -f "$TMP/impl/npm/.unpack-complete" ] &&
       [ "$(tr -d '\r\n' <"$TMP/impl/npm/.unpack-complete")" = "ok" ]; then
        pass "成功路径写好 npm/.unpack-complete（ok）"
    else
        fail "成功路径缺少 npm/.unpack-complete 或内容不对"
    fi
else
    fail "harness 编译失败：$(tr '\n' ' ' <"$TMP/build.log" | cut -c1-500)"
fi

# ---------- 3. 断言 + 逐文件比对 ----------
echo
echo '-- 归档/参考树/实现树断言'
if "$PYTHON" "$HERE/check.py" --tar "$TAR" --ref "$TMP/ref" \
        --impl "$TMP/impl" --sample 200; then
    pass "check.py 全部断言通过"
else
    fail "check.py 有断言失败（见上）"
fi

# ---------- 4. 失败路径：截断的 tar ----------
echo
echo '-- 失败路径：截断到 1KB 的 tar'
dd if="$TAR" of="$TMP/truncated.tar.gz" bs=1024 count=1 status=none 2>/dev/null
TRUNC_DEST="$TMP/truncated_dest"
mkdir -p "$TRUNC_DEST/npm/bin"
printf 'ok\n' >"$TRUNC_DEST/npm/.unpack-complete"
printf '// stale entry\n' >"$TRUNC_DEST/npm/bin/npm-cli.js"

if "$HARNESS" "$TMP/truncated.tar.gz" "$TRUNC_DEST" >"$TMP/truncated.log" 2>&1; then
    fail "截断 tar 被当成成功（应返回非 0）"
else
    pass "截断 tar 返回非 0"
fi
if [ -e "$TRUNC_DEST/npm/.unpack-complete" ]; then
    fail "截断 tar 失败后仍留下 .unpack-complete"
else
    pass "截断 tar 失败后未留下 .unpack-complete"
fi
if [ -e "$TRUNC_DEST/npm/bin/npm-cli.js" ]; then
    fail "截断 tar 失败后仍留下 npm-cli.js"
else
    pass "截断 tar 失败后未留下 npm-cli.js"
fi

# ---------- 5. 失败路径：只读目标目录 ----------
echo
echo '-- 失败路径：目标目录只读'
if [ "$(id -u)" -eq 0 ]; then
    skip "以 root 运行，chmod 0555 挡不住写入（跳过只读用例）"
else
    RO_DEST="$TMP/readonly_dest"
    mkdir -p "$RO_DEST"
    chmod 0555 "$RO_DEST"
    if "$HARNESS" "$TAR" "$RO_DEST" >"$TMP/readonly.log" 2>&1; then
        fail "只读目标目录解包却返回 0（应报错）"
    else
        pass "只读目标目录返回非 0"
    fi
    chmod 0755 "$RO_DEST"
fi

echo
echo "SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
((FAIL == 0)) && exit 0
exit 1
