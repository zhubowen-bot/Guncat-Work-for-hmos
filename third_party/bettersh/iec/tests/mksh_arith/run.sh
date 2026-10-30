#!/usr/bin/env bash
# run.sh — mksh 64 位算术 / shell 语义回归（宿主编译，不连设备）。
#
# 背景：随包 mksh 用 -DMKSH_LEGACY_MODE 重编，让 mksh_ari_t = long（LP64 下 64 位），
# 修掉 $((2000000000+2000000000)) 溢出成 -294967296 的老问题（见
# third_party/bettersh/iec/scripts/build_mksh.sh）。本脚本在宿主用同一份源码、同一套
# DEFS 编出两份二进制做对照：
#   /tmp/mksh64  带 -DMKSH_LEGACY_MODE   → 64 位算术（被验证对象）
#   /tmp/mksh32  不带                    → 32 位算术（对照，应溢出）
#
# 覆盖：
#   1. 64 位边界字面量与回绕；2. 四则/溢出；3. 除法与取模（含 /0）；
#   4. 位移/位运算；5. 进制；6. 变量/赋值/自增/let；7. $((...)) 内嵌命令替换；
#   8. 与 Python 大整数逐条对拍（oracle.py）；9. shell 语义回归（set -e、$?、[[ ]]、
#      函数、管道、重定向、here-doc、case、for/while）；10. 32 位对照断言。
#
# 用法:
#   bash third_party/bettersh/iec/tests/mksh_arith/run.sh
#   bash .../run.sh --keep          保留临时目录
#
# 环境变量:
#   MKSH64=<path>   指定 64 位二进制（默认 /tmp/mksh64，不存在则现场编译）
#   MKSH32=<path>   指定 32 位对照（默认 /tmp/mksh32，不存在则现场编译）
#   MKSH_SRC=<dir>  指定 mksh 源码目录（默认 ../../thirdparty/mksh）
#
# 退出码: 0 全部通过（允许内部 skip）；1 有 FAIL；77 宿主缺 cc（check-all 记 SKIP）。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../../.." && pwd)"
MKSH_SRC="${MKSH_SRC:-$(cd "$HERE/../../thirdparty/mksh" && pwd)}"
MKSH64="${MKSH64:-/tmp/mksh64}"
MKSH32="${MKSH32:-/tmp/mksh32}"

export LC_ALL=C
export MKSH_SRC

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mksh_arith.XXXXXX")"
KEEP=0
PASS=0
FAIL=0
SKIP=0
ORACLE_EXACT=0
ORACLE_WRAP=0

case "${1:-}" in
    --keep) KEEP=1 ;;
    "") : ;;
    *) echo "run.sh: 未知参数 $1（只支持 --keep）" >&2; exit 2 ;;
esac

cleanup() {
    if [ "$KEEP" = 1 ]; then
        echo "保留临时目录: $TMP"
    else
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
skip() { SKIP=$((SKIP + 1)); printf 'skip  %s\n' "$1"; }
die() { echo "run.sh: $*" >&2; exit 1; }

# ---------------------------------------------------------------- 编译两份二进制

ensure_binaries() {
    if [[ ! -x "$MKSH64" ]]; then
        echo "==> 未找到 $MKSH64，现场编译 64 位版（与 scripts/build_mksh.sh 同一套 DEFS）"
        bash "$HERE/build_host.sh" 64 "$MKSH64" || return $?
    fi
    if [[ ! -x "$MKSH32" ]]; then
        echo "==> 未找到 $MKSH32，现场编译 32 位对照版"
        bash "$HERE/build_host.sh" 32 "$MKSH32" || return $?
    fi
    return 0
}

echo "== mksh 64 位算术 / 语义回归 =="
echo "源码: $MKSH_SRC"
echo "64 位: $MKSH64"
echo "32 位: $MKSH32"

ensure_binaries
build_rc=$?
if [[ "$build_rc" -eq 77 ]]; then
    echo "skip  宿主没有 C 编译器（cc），无法编译 mksh"
    exit 77
elif [[ "$build_rc" -ne 0 ]]; then
    die "编译 mksh 失败（exit=$build_rc）"
fi

[[ -x "$MKSH64" ]] || die "$MKSH64 不可执行"
[[ -x "$MKSH32" ]] || die "$MKSH32 不可执行"
[[ "$("$MKSH64" -c 'echo $((1+1))' 2>/dev/null)" == "2" ]] || die "$MKSH64 不是可用的 mksh"
[[ "$("$MKSH32" -c 'echo $((1+1))' 2>/dev/null)" == "2" ]] || die "$MKSH32 不是可用的 mksh"

# ---------------------------------------------------------------- 小工具

# 在 mksh 里求值 $(( expr ))，结果放 ARITH_OUT，stderr 放 ARITH_ERR，退出码 ARITH_RC。
run_expr() { # <bin> <expr>
    ARITH_OUT="$("$1" -c 'printf "%s" "$(( $1 ))"' sh "$2" 2>"$TMP/stderr")"
    ARITH_RC=$?
    ARITH_ERR="$(<"$TMP/stderr")"
}

# 运行一段 mksh 脚本，结果放 ARITH_OUT / ARITH_ERR / ARITH_RC。
run_code() { # <bin> <code>
    ARITH_OUT="$("$1" -c "$2" 2>"$TMP/stderr")"
    ARITH_RC=$?
    ARITH_ERR="$(<"$TMP/stderr")"
}

# 断言表达式结果（64 位版）。
expect_expr() { # <标签> <表达式> <期望值>
    local label="$1" expr="$2" want="$3"
    run_expr "$MKSH64" "$expr"
    if [[ "$ARITH_RC" -eq 0 && "$ARITH_OUT" == "$want" ]]; then
        pass "$label: \$(( $expr )) = $want"
    else
        fail "$label: \$(( $expr )) => [${ARITH_OUT}] (rc=$ARITH_RC，期望 [$want])${ARITH_ERR:+ stderr=[$ARITH_ERR]}"
    fi
}

# 断言表达式结果（32 位对照版）。
expect_expr32() { # <标签> <表达式> <期望值>
    local label="$1" expr="$2" want="$3"
    run_expr "$MKSH32" "$expr"
    if [[ "$ARITH_RC" -eq 0 && "$ARITH_OUT" == "$want" ]]; then
        pass "$label: 32 位 \$(( $expr )) = $want"
    else
        fail "$label: 32 位 \$(( $expr )) => [${ARITH_OUT}] (rc=$ARITH_RC，期望 [$want])${ARITH_ERR:+ stderr=[$ARITH_ERR]}"
    fi
}

# 断言脚本输出与退出码。
expect_code() { # <标签> <脚本> <期望输出> [期望退出码]
    local label="$1" code="$2" want="$3" want_rc="${4:-0}"
    run_code "$MKSH64" "$code"
    if [[ "$ARITH_RC" -eq "$want_rc" && "$ARITH_OUT" == "$want" ]]; then
        pass "$label"
    else
        fail "$label: rc=$ARITH_RC（期望 $want_rc）out=[$ARITH_OUT]（期望 [$want]）${ARITH_ERR:+ stderr=[$ARITH_ERR]}"
    fi
}

# ---------------------------------------------------------------- 1. 64 位边界字面量

echo
echo "== 1. 64 位边界字面量与回绕 =="
# mksh 用无符号解析字面量再落到有符号 long：超过 2^63-1 的字面量按 64 位回绕，
# 不报错（与 32 位版的行为一致，只是位宽不同）。
expect_expr "2^31-1" '2147483647' '2147483647'
expect_expr "2^31" '2147483648' '2147483648'
expect_expr "2^32-1" '4294967295' '4294967295'
expect_expr "2^32" '4294967296' '4294967296'
expect_expr "2^63-1（LONG_MAX）" '9223372036854775807' '9223372036854775807'
expect_expr "-2^63（LONG_MIN）" '-9223372036854775808' '-9223372036854775808'
expect_expr "2^63 字面量回绕为 LONG_MIN" '9223372036854775808' '-9223372036854775808'
expect_expr "2^64-1 字面量回绕为 -1" '18446744073709551615' '-1'
expect_expr "2^64 字面量回绕为 0" '18446744073709551616' '0'
expect_expr "0x8000000000000000" '0x8000000000000000' '-9223372036854775808'
expect_expr "0xFFFFFFFFFFFFFFFF" '0xFFFFFFFFFFFFFFFF' '-1'
# mksh 把前导 0 当十进制（不是 C 的八进制），这里按实测行为钉住。
expect_expr "前导 0 按十进制（010）" '010' '10'

# ---------------------------------------------------------------- 2. 四则与溢出

echo
echo "== 2. 四则运算与 64 位溢出回绕 =="
expect_expr "回归主角" '2000000000+2000000000' '4000000000'
expect_expr "大数加法" '4000000000+4000000000' '8000000000'
expect_expr "大数减法" '0-4000000000' '-4000000000'
expect_expr "大数乘法" '2000000000*2000000000' '4000000000000000000'
expect_expr "大数乘法（未溢出）" '4000000000*3' '12000000000'
expect_expr "LONG_MAX+1 回绕为 LONG_MIN" '9223372036854775807+1' '-9223372036854775808'
expect_expr "LONG_MIN-1 回绕为 LONG_MAX" '-9223372036854775808-1' '9223372036854775807'
expect_expr "LONG_MAX*2 回绕为 -2" '9223372036854775807*2' '-2'
expect_expr "平方溢出按 64 位回绕" '3037000500*3037000500' '-9223372036709301616'
expect_expr "溢出后参与后续运算" '3037000500*3037000500/2' '-4611686018354650808'

# "未溢出必须精确等于 Python 大整数"：4000000000^2 = 16000000000000000000
# 已超过 LONG_MAX，回绕后为 -2446744073709551616。
python_expect="$(python3 - <<'PY' 2>/dev/null
v = 4000000000 * 4000000000
mask = (1 << 64) - 1
v &= mask
if v >= 1 << 63:
    v -= 1 << 64
print(v)
PY
)"
if [[ -n "$python_expect" ]]; then
    expect_expr "乘法溢出回绕值由 Python 大整数复算" '4000000000*4000000000' "$python_expect"
else
    skip "找不到 python3，跳过 4000000000^2 的 Python 复算"
fi

# ---------------------------------------------------------------- 3. 除法与取模

echo
echo "== 3. 除法与取模（含除零） =="
expect_expr "正/正" '7/2' '3'
expect_expr "负/正" '-7/2' '-3'
expect_expr "正/负" '7/-2' '-3'
expect_expr "负/负" '-7/-2' '3'
expect_expr "正%正" '7%2' '1'
expect_expr "负%正（符号随被除数）" '-7%2' '-1'
expect_expr "正%负（符号随被除数）" '7%-2' '1'
expect_expr "负%负" '-7%-2' '-1'
expect_expr "大数除法" '4000000000/7' '571428571'
expect_expr "大数取模" '4000000000%7' '3'
expect_expr "LONG_MIN/-1 不崩溃，回绕为 LONG_MIN" '-9223372036854775808/-1' '-9223372036854775808'
expect_expr "LONG_MIN%-1" '-9223372036854775808%-1' '0'

# 除零：报 "zero divisor"、退出码非 0，且不能是信号崩溃（rc<128）。
for op in '/' '%'; do
    run_expr "$MKSH64" "1${op}0"
    if [[ "$ARITH_RC" -eq 1 && -z "$ARITH_OUT" && "$ARITH_ERR" == *"zero divisor"* ]]; then
        pass "除零 1${op}0: 报错并退出 rc=1（未崩溃）"
    else
        fail "除零 1${op}0: rc=$ARITH_RC out=[$ARITH_OUT] stderr=[$ARITH_ERR]（期望 rc=1 且含 zero divisor）"
    fi
done

# 除零之后的语句不再执行（非交互 shell 的整体行为）。
expect_code "除零终止当前 mksh 进程，后续语句不执行" 'echo $((1/0)); echo after' '' '1'
expect_code "除零后 stderr 含 zero divisor" 'echo $((1%0))' '' '1'

# ---------------------------------------------------------------- 4. 位移与位运算

echo
echo "== 4. 位移与位运算 =="
expect_expr "1<<10" '1<<10' '1024'
expect_expr "1<<31（64 位下仍为正）" '1<<31' '2147483648'
expect_expr "1<<32" '1<<32' '4294967296'
expect_expr "1<<62" '1<<62' '4611686018427387904'
expect_expr "1<<63 置符号位 → LONG_MIN" '1<<63' '-9223372036854775808'
expect_expr "8>>2" '8>>2' '2'
expect_expr "1>>63" '1>>63' '0'
expect_expr "-8>>1（算术右移）" '-8>>1' '-4'
expect_expr "LONG_MIN>>63" '-9223372036854775808>>63' '-1'
expect_expr "~0" '~0' '-1'
expect_expr "~1" '~1' '-2'
expect_expr "~-1" '~-1' '0'
expect_expr "~LONG_MIN" '~-9223372036854775808' '9223372036854775807'
expect_expr "6&3" '6&3' '2'
expect_expr "6|3" '6|3' '7'
expect_expr "5^3" '5^3' '6'
expect_expr "0xF0F0&0x0FF0" '0xF0F0&0x0FF0' '240'
expect_expr "0xF0F0|0x0F0F" '0xF0F0|0x0F0F' '65535'
expect_expr "0xAAAA^0x5555" '0xAAAA^0x5555' '65535'
expect_expr "LONG_MIN|1" '-9223372036854775808|1' '-9223372036854775807'

# mksh 的 LEGACY_MODE 不掩码移位数，C 的移位溢出属未定义行为；x86_64 上硬件按
# 63 掩码，这里只记录实测（不当作可移植契约），非 x86_64 宿主跳过。
if [[ "$(uname -m)" == "x86_64" ]]; then
    expect_expr "移位数 >=64 的实测行为（UB，仅记录）" '1<<64' '1'
    expect_expr "移位数 >=64 的实测行为（UB，仅记录）" '1<<65' '2'
else
    skip "移位数 >=64 属 C 未定义行为，仅在 x86_64 记录实测值"
fi

# ---------------------------------------------------------------- 5. 进制

echo
echo "== 5. 进制字面量 =="
expect_expr "16#ff" '16#ff' '255'
expect_expr "8#777" '8#777' '511'
expect_expr "2#101" '2#101' '5'
expect_expr "2#1010" '2#1010' '10'
expect_expr "36#z" '36#z' '35'
expect_expr "36#zz" '36#zz' '1295'
expect_expr "10#42" '10#42' '42'
expect_expr "16#FFFFFFFFFFFFFFFF" '16#FFFFFFFFFFFFFFFF' '-1'
expect_expr "0x10" '0x10' '16'
expect_expr "进制与十进制混算" '2#1010+0x10+8#777' '537'

# ---------------------------------------------------------------- 6. 变量/赋值/let

echo
echo "== 6. 变量、赋值、自增与 let =="
expect_code "算术中引用变量" 'a=5; echo $((a*2))' '10'
expect_code "变量保存 64 位值" 'a=4000000000; echo $((a/3))' '1333333333'
expect_code "变量保存 LONG_MAX 后 +1 回绕" 'a=9223372036854775807; echo $((a+1))' '-9223372036854775808'
expect_code "后置自增返回旧值" 'a=5; echo $((a++)); echo $a' $'5\n6'
expect_code "前置自增返回新值" 'a=5; echo $((++a)); echo $a' $'6\n6'
expect_code "算术内赋值表达式" 'a=0; echo $((a=9)); echo $a' $'9\n9'
expect_code "算术复合赋值 += 溢出" 'a=9223372036854775807; echo $((a+=1)); echo $a' $'-9223372036854775808\n-9223372036854775808'
expect_code "let a+=3" 'a=5; let a+=3; echo $a' '8'
expect_code "let 计算 64 位结果" 'let "b = 2000000000 + 2000000000"; echo $b' '4000000000'
expect_code "let 的退出码（非零表达式为真）" 'let 1+1; echo $?; let 0; echo $?' $'0\n1'
expect_code "未定义变量按 0 参与运算" 'unset x; echo $((x+1))' '1'

# ---------------------------------------------------------------- 7. 命令替换嵌套

echo
echo "== 7. \$((...)) 内嵌命令替换 =="
expect_code "外层算术 + 内层命令替换" 'echo $(( $(echo 2) + 3 ))' '5'
expect_code "命令替换结果参与乘法" 'echo $(( 1 + $(printf 4) ))' '5'
expect_code "命令替换输出表达式串（mksh 会再解析）" 'echo $(( $(echo "3*4") ))' '12'
expect_code "变量来自命令替换后做大数加法" 'v=$(echo 2000000000); echo $((v+v))' '4000000000'
expect_code "两个命令替换分别取 2e9" 'echo $(( $(echo 2000000000) + $(echo 2000000000) ))' '4000000000'

# ---------------------------------------------------------------- 8. Python 大整数对拍

echo
echo "== 8. 与 Python 大整数逐条对拍（oracle.py） =="
ORACLE_EXPRS=(
    '1+2*3'
    '(1+2)*3'
    '2*3+4*5'
    '100/7'
    '-100/7'
    '100/-7'
    '-100%7'
    '100%-7'
    '2147483647+1'
    '2000000000+2000000000'
    '2000000000*2000000000'
    '4000000000*3'
    '3037000500*3037000500'
    '9223372036854775807+1'
    '-9223372036854775808-1'
    '9223372036854775807*2'
    '0x7fffffffffffffff'
    '0x8000000000000000'
    '0xFFFFFFFFFFFFFFFF'
    '16#ff'
    '8#777'
    '2#1010'
    '36#zz'
    '~0'
    '~-1'
    '-1^1'
    '0xF0F0&0x0FF0'
    '0xF0F0|0x0F0F'
    '0xAAAA^0x5555'
    '1<<10'
    '1<<31'
    '1<<32'
    '1<<62'
    '1<<63'
    '-1<<8'
    '8>>2'
    '-8>>1'
    '-1>>63'
    '4000000000/7'
    '4000000000%7'
    '3037000500*3037000500/2'
    '(1+2)*(3+4)*(5+6)'
    '1?2:3'
    '0?2:3'
    '-9223372036854775808/-1'
    '-9223372036854775808%-1'
    '1+2*3<<2'
    '0x10+8#777'
)

run_oracle() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "找不到 python3，跳过与 Python 大整数的逐条对拍"
        return
    fi

    local oracle_out
    if ! oracle_out="$(printf '%s\n' "${ORACLE_EXPRS[@]}" | python3 "$HERE/oracle.py")"; then
        fail "oracle.py 执行失败"
        return
    fi
    mapfile -t oracle_lines <<<"$oracle_out"
    if [[ "${#oracle_lines[@]}" -ne "${#ORACLE_EXPRS[@]}" ]]; then
        fail "oracle.py 输出行数 ${#oracle_lines[@]} != 用例数 ${#ORACLE_EXPRS[@]}"
        return
    fi

    local i expr line wrapped exact
    for i in "${!ORACLE_EXPRS[@]}"; do
        expr="${ORACLE_EXPRS[$i]}"
        line="${oracle_lines[$i]}"
        if [[ "$line" == ERR$'\t'* ]]; then
            fail "oracle 无法计算 [$expr]: ${line#*$'\t'}"
            continue
        fi
        wrapped="${line%%$'\t'*}"
        exact="${line#*$'\t'}"
        run_expr "$MKSH64" "$expr"
        if [[ "$ARITH_RC" -ne 0 ]]; then
            fail "oracle 对拍 [$expr]: mksh 退出 rc=$ARITH_RC stderr=[$ARITH_ERR]"
            continue
        fi
        if [[ "$ARITH_OUT" != "$wrapped" ]]; then
            fail "oracle 对拍 [$expr]: mksh=[$ARITH_OUT] Python=[$wrapped]${ARITH_ERR:+ stderr=[$ARITH_ERR]}"
            continue
        fi
        if [[ "$wrapped" == "$exact" ]]; then
            ORACLE_EXACT=$((ORACLE_EXACT + 1))
            pass "oracle 未溢出精确一致: $expr = $wrapped"
        else
            ORACLE_WRAP=$((ORACLE_WRAP + 1))
            pass "oracle 溢出按 64 位回绕: $expr = $wrapped（Python 精确值 $exact）"
        fi
    done

    # 两类用例都必须出现，否则说明对拍没有真正覆盖回绕/精确路径。
    if [[ "$ORACLE_EXACT" -gt 0 ]]; then
        pass "oracle 覆盖未溢出表达式 $ORACLE_EXACT 条"
    else
        fail "oracle 没有任何未溢出表达式，判据不完整"
    fi
    if [[ "$ORACLE_WRAP" -gt 0 ]]; then
        pass "oracle 覆盖 64 位溢出表达式 $ORACLE_WRAP 条"
    else
        fail "oracle 没有任何溢出表达式，判据不完整"
    fi
}

run_oracle

# ---------------------------------------------------------------- 9. shell 语义回归

echo
echo "== 9. shell 语义回归（证明 LEGACY_MODE 没改坏） =="
expect_code "set -e 遇 false 立即退出" 'set -e; false; echo unreachable' '' '1'
expect_code "set -e 下算术正常继续" 'set -e; echo $((2000000000+2000000000)); echo ok' $'4000000000\nok'
expect_code "set -e 下除零退出" 'set -e; echo $((1/0)); echo unreachable' '' '1'
expect_code "\$? 记录 false/true 的退出码" 'false; echo $?; true; echo $?' $'1\n0'
expect_code "算术展开本身 \$? 为 0" 'echo $((1+1)) >/dev/null; echo $?' '0'
expect_code "(( 0 )) 的退出码为 1" '(( 0 )); echo $?' '1'
expect_code "[[ ]] 通配与数值比较" '[[ abc == a* ]] && [[ 3 -gt 2 ]] && echo yes' 'yes'
expect_code "[[ ]] 做 64 位数值比较" '[[ 4000000000 -gt 2000000000 ]] && echo gt' 'gt'
expect_code "(( )) 条件走 64 位（2e9+2e9>0）" 'if (( 2000000000 + 2000000000 > 0 )); then echo big; else echo small; fi' 'big'
expect_code "函数与 local/return" 'f() { local x=$1; echo "f:$x"; return 3; }; f hi; echo rc=$?' $'f:hi\nrc=3'
expect_code "管道" 'printf "b\na\n" | sort | tr a-z A-Z' $'A\nB'
expect_code "重定向写/追加/读" "echo hello > '$TMP/redir.txt'; echo world >> '$TMP/redir.txt'; cat '$TMP/redir.txt'" $'hello\nworld'
expect_code "here-doc（展开变量）" $'v=42\ncat <<EOF\nv=$v\nEOF' 'v=42'
expect_code "here-doc（引号定界符不展开）" $'cat <<\'EOF\'\n$((1+1))\nEOF' '$((1+1))'
expect_code "case" 'for x in aa bb; do case $x in a*) echo A;; *) echo other;; esac; done' $'A\nother'
expect_code "for/while 累加" 'i=0; for v in 1 2 3; do i=$((i+v)); done; while (( i < 8 )); do i=$((i+1)); done; echo $i' '8'
expect_code "for 列表循环" 'for i in 0 1 2; do printf "%s" "$i"; done; echo' '012'
expect_code "函数里做 64 位算术" 'f() { echo $(( $1 * 2 )); }; f 2000000000' '4000000000'
expect_code "位置参数参与算术" 'set -- 3 4; echo $(( $1 * $2 ))' '12'
expect_code "命令替换返回算术结果" 'echo "$(echo $((2000000000+2000000000)))"' '4000000000'

# ---------------------------------------------------------------- 10. 32 位对照

echo
echo "== 10. 32 位对照（不带 -DMKSH_LEGACY_MODE，应溢出） =="
# 若无 64 位模式，同一表达式在 32 位下回绕为 -294967296；这是本次改动的回归起点。
expect_expr32 "32 位应溢出：2e9+2e9" '2000000000+2000000000' '-294967296'
expect_expr32 "32 位应溢出：2^31" '2147483648' '-2147483648'
expect_expr32 "32 位应溢出：2^32" '4294967296' '0'
expect_expr32 "32 位应溢出：2e9*2e9" '2000000000*2000000000' '-1651507200'
expect_expr32 "32 位应溢出：4e9*2" '4000000000*2' '-589934592'
expect_expr32 "32 位应溢出：3037000500^2" '3037000500*3037000500' '145474192'
expect_expr32 "32 位应溢出：LONG_MAX 字面量截为 -1" '9223372036854775807' '-1'
expect_expr32 "32 位应溢出：1<<31" '1<<31' '-2147483648'
# 非溢出表达式两种位宽必须一致，证明差异只来自位宽而不是别的语义改动。
expect_expr32 "32 位非溢出应一致：7/2" '7/2' '3'
expect_expr32 "32 位非溢出应一致：-7/2" '-7/2' '-3'
expect_expr32 "32 位非溢出应一致：16#ff" '16#ff' '255'
expect_expr32 "32 位非溢出应一致：1<<10" '1<<10' '1024'
expect_expr32 "32 位非溢出应一致：~0" '~0' '-1'

# 直接并排比较一次，输出一目了然。
run_expr "$MKSH64" '2000000000+2000000000'; m64="$ARITH_OUT"
run_expr "$MKSH32" '2000000000+2000000000'; m32="$ARITH_OUT"
if [[ "$m64" == "4000000000" && "$m32" == "-294967296" ]]; then
    pass "64/32 对照：64 位=$m64，32 位=$m32（32 位按预期溢出）"
else
    fail "64/32 对照异常：64 位=[$m64]（期望 4000000000），32 位=[$m32]（期望 -294967296）"
fi

# ---------------------------------------------------------------- 汇总

echo
echo "== 结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP（oracle 精确 $ORACLE_EXACT / 回绕 $ORACLE_WRAP） =="
if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
exit 0
