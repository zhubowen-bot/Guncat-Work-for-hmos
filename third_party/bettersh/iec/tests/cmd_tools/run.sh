#!/usr/bin/env bash
# run.sh — nc / hexdump / diff 三个自写命令的宿主行为测试。
#
# 在 x86_64 Linux（含 WSL）上直接把 cmd_nc.c / cmd_hexdump.c / cmd_diff.c 编成
# 普通可执行文件跑，不连设备、不需要 HarmonyOS SDK、不访问外部网络（只用回环）。
#
# 依赖：cc、git、bash、coreutils；可选系统 hexdump（有就逐字节对拍，没有就用
# golden/ 下的期望文本）。
#
#   ./run.sh          # 跑完删除临时目录
#   ./run.sh --keep   # 保留临时目录（排查用）
#
# 环境变量：
#   CMD_TOOLS_SRC=<dir>      指定待测源码目录（默认 ../../scripts/optional）
#   CMD_TOOLS_NO_HEXDUMP=1   假装宿主没有 hexdump，走 golden 期望文本比对
#
# 全部通过退出 0，否则 1；用例总耗时 < 20s。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${CMD_TOOLS_SRC:-$(cd "$HERE/../../scripts/optional" && pwd)}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cmd_tools.XXXXXX")"
DATA="$TMP/data"
WORK="$TMP/work"
KEEP=0
PASS=0
FAIL=0
SKIP=0

case "${1:-}" in
    --keep) KEEP=1 ;;
    "") : ;;
    *) echo "run.sh: 未知参数 $1" >&2; exit 2 ;;
esac

cleanup() {
    if [ "$KEEP" = 1 ]; then
        echo "保留临时目录: $TMP"
    else
        # 收掉可能残留的后台 nc/peer
        local p
        for p in $(jobs -p 2>/dev/null); do kill "$p" 2>/dev/null; done
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
skip() { SKIP=$((SKIP + 1)); printf 'skip  %s\n' "$1"; }
die() { echo "run.sh: $*" >&2; exit 1; }

command -v cc >/dev/null 2>&1 || die "需要 cc"
command -v git >/dev/null 2>&1 || die "diff 测试需要宿主 git"
command -v timeout >/dev/null 2>&1 || die "需要 coreutils 的 timeout"
command -v od >/dev/null 2>&1 || die "需要 od（失败时打印差异）"

mkdir -p "$DATA" "$WORK"

# ---------------------------------------------------------------- 编译

build() { # 名字 入口 源文件
    local name="$1" entry="$2" src="$3"
    # 与设备侧一致，源码用 -Dmain=入口 编译（现有源码本身没有 main）
    cc -std=gnu11 -O1 -g -Wall -Wextra -D_GNU_SOURCE -Dmain="$entry" \
        -c "$src" -o "$TMP/$name.o" || die "编译 $src 失败"
    cc -std=gnu11 -O1 -g -Wall -Wextra -D_GNU_SOURCE -DENTRY="$entry" \
        -c "$HERE/host_main.c" -o "$TMP/$name.main.o" || die "编译 host_main.c 失败"
    cc -o "$TMP/$name" "$TMP/$name.o" "$TMP/$name.main.o" || die "链接 $name 失败"
}

BSH_NC="$TMP/bsh_nc"
BSH_HEXDUMP="$TMP/bsh_hexdump"
BSH_DIFF="$TMP/bsh_diff"
PEER="$TMP/peer"

build bsh_nc iec_nc_main "$SRC/cmd_nc.c"
build bsh_hexdump iec_hexdump_main "$SRC/cmd_hexdump.c"
build bsh_diff iec_diff_main "$SRC/cmd_diff.c"
cc -std=gnu11 -O1 -g -Wall -Wextra -D_GNU_SOURCE -o "$PEER" "$HERE/peer.c" ||
    die "编译 peer.c 失败"

REF_HEXDUMP="$(command -v hexdump || true)"
HAVE_REF=0
if [ -n "$REF_HEXDUMP" ] && [ "${CMD_TOOLS_NO_HEXDUMP:-0}" != 1 ]; then
    HAVE_REF=1
fi

dump_pair() { # 期望 实际
    printf '  --- 期望 ---\n' >&2
    od -An -v -c "$1" | head -30 >&2
    printf '  --- 实际 ---\n' >&2
    od -An -v -c "$2" | head -30 >&2
}

# ---------------------------------------------------------------- hexdump

# 生成测试数据
gen_hex_data() {
    local i
    printf 'AB' > "$DATA/ab"
    : > "$DATA/all256"
    for ((i = 0; i < 256; i++)); do
        printf "\\$(printf '%03o' "$i")" >> "$DATA/all256"
    done
    : > "$DATA/b16"
    for ((i = 0; i < 16; i++)); do
        printf "\\$(printf '%03o' "$i")" >> "$DATA/b16"
    done
    printf '0123456789abcdefg' > "$DATA/s17"
    printf '0123456789' > "$DATA/s10"
    printf '0123456789abcdef' > "$DATA/f1"
    printf 'XYZ' > "$DATA/f2"
    printf '\001\002\003\004\005\006\007\010' > "$DATA/f3"
    head -c 32 /dev/zero > "$DATA/zeros32"
    : > "$DATA/empty"
}

# 逐字节比较我们的输出与 golden/ 期望文本（始终执行），有系统 hexdump 时再对拍一次。
hex_case() { # 标签 输入文件 golden 文件名 参数...
    local label="$1" input="$2" golden="$3"
    shift 3
    local rc

    "$BSH_HEXDUMP" "$@" < "$input" > "$TMP/hex.ours" 2> "$TMP/hex.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$label: 退出码 $rc（应为 0）"
        return
    fi
    if cmp -s "$TMP/hex.ours" "$HERE/golden/$golden"; then
        pass "$label"
    else
        fail "$label（与 golden 不一致）"
        dump_pair "$HERE/golden/$golden" "$TMP/hex.ours"
    fi
    if [ "$HAVE_REF" = 1 ]; then
        "$REF_HEXDUMP" "$@" < "$input" > "$TMP/hex.ref" 2>/dev/null
        if cmp -s "$TMP/hex.ours" "$TMP/hex.ref"; then
            pass "$label（系统 hexdump 对拍）"
        else
            fail "$label（与系统 hexdump 不一致）"
            dump_pair "$TMP/hex.ref" "$TMP/hex.ours"
        fi
    fi
}

run_hexdump_tests() {
    gen_hex_data
    if [ "$HAVE_REF" = 0 ]; then
        skip "宿主没有 hexdump：改用 golden/ 期望文本比对"
    fi

    hex_case "hexdump -C 'AB'"            "$DATA/ab"      ab_C.golden          -C
    hex_case "hexdump -C 0x00-0xff"       "$DATA/all256"  all256_C.golden      -C
    hex_case "hexdump -b 'AB'"            "$DATA/ab"      ab_b.golden          -b
    hex_case "hexdump -c 0x00-0x0f 转义"  "$DATA/b16"     b16_c.golden         -c
    hex_case "hexdump -x 'AB'"            "$DATA/ab"      ab_x.golden          -x
    hex_case "hexdump -d 'AB'"            "$DATA/ab"      ab_d.golden          -d
    hex_case "hexdump -o 'AB'"            "$DATA/ab"      ab_o.golden          -o
    hex_case "hexdump -C -s 3 -n 5"       "$DATA/s17"     s17_C_s3n5.golden    -C -s 3 -n 5
    hex_case "hexdump -C 17 字节部分行"    "$DATA/s17"     s17_C.golden         -C
    hex_case "hexdump -x 17 字节部分行"    "$DATA/s17"     s17_x.golden         -x
    hex_case "hexdump -C 多文件连续偏移"   /dev/null       multi_C.golden       -C "$DATA/f1" "$DATA/f2"
    hex_case "hexdump -C -n 跨文件总长度"  /dev/null       multi_n17_C.golden   -C -n 17 "$DATA/f1" "$DATA/f2"
    hex_case "hexdump -C 重复块折叠"       "$DATA/zeros32" zeros32_C.golden     -C
    hex_case "hexdump -C -v 不折叠"        "$DATA/zeros32" zeros32_C_v.golden   -C -v
    hex_case "hexdump -C -s 5（文件内偏移）" "$DATA/s10"     s10_C_s5.golden      -C -s 5
    hex_case "hexdump -C 空输入"           "$DATA/empty"   empty_C.golden       -C

    # 错误路径：不存在的文件 -> 退出码 1 + stderr 有信息
    "$BSH_HEXDUMP" -C "$DATA/does-not-exist" > "$TMP/hex.errout" 2> "$TMP/hex.err"
    local rc=$?
    if [ "$rc" -eq 1 ] && [ -s "$TMP/hex.err" ] && [ ! -s "$TMP/hex.errout" ]; then
        pass "hexdump 不存在的文件：退出码 1 + stderr"
    else
        fail "hexdump 不存在的文件：退出码 $rc（应为 1），stderr=$(cat "$TMP/hex.err")"
    fi
}

# ---------------------------------------------------------------- diff

run_diff_tests() {
    local rc ref_rc

    export HOME="$TMP/home"
    export GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_PAGER=cat
    export GIT_TERMINAL_PROMPT=0
    mkdir -p "$HOME"
    : > "$GIT_CONFIG_GLOBAL"

    ( cd "$WORK" &&
        printf 'a\nb\nc\n' > a &&
        printf 'a\nX\nc\n' > b &&
        printf 'a\nb\nc\n' > same &&
        printf '1\n2\n3\n4\n5\n6\n7\n' > m1 &&
        printf '1\n2\nX\n4\n5\n6\n7\n' > m2 ) || die "准备 diff 测试数据失败"

    # 我们的 diff（先 cd 到 work，避免被仓库的 .git 影响）
    our_diff() {
        ( cd "$WORK" && "$BSH_DIFF" "$@" ) > "$TMP/d.out" 2> "$TMP/d.err"
    }
    ref_diff() {
        git -C "$WORK" diff --no-index "$@" > "$TMP/d.ref" 2> "$TMP/d.referr"
    }

    # 1) -u 有差异：输出与 git diff --no-index 一致，退出码 1
    our_diff -u a b
    rc=$?
    ref_diff -- a b
    ref_rc=$?
    if [ "$rc" -eq 1 ] && [ "$ref_rc" -eq 1 ] && cmp -s "$TMP/d.out" "$TMP/d.ref" &&
        [ ! -s "$TMP/d.err" ]; then
        pass "diff -u 有差异：输出与 git 一致、退出码 1"
    else
        fail "diff -u 有差异：rc=$rc ref_rc=$ref_rc"
        dump_pair "$TMP/d.ref" "$TMP/d.out"
    fi

    # 2) 相同内容：退出码 0、无输出
    our_diff a same
    rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "$TMP/d.out" ] && [ ! -s "$TMP/d.err" ]; then
        pass "diff 相同文件：退出码 0、无输出"
    else
        fail "diff 相同文件：rc=$rc out=$(cat "$TMP/d.out") err=$(cat "$TMP/d.err")"
    fi

    # 3) 不存在文件：退出码 2、stderr 有信息
    our_diff -u a nope
    rc=$?
    if [ "$rc" -eq 2 ] && [ -s "$TMP/d.err" ] && [ ! -s "$TMP/d.out" ]; then
        pass "diff 不存在文件：退出码 2 + stderr"
    else
        fail "diff 不存在文件：rc=$rc（应为 2），stderr=$(cat "$TMP/d.err")"
    fi

    # 4) -q 透传：有差异退出码 1 且无输出；相同退出码 0
    our_diff -q a b
    rc=$?
    if [ "$rc" -eq 1 ] && [ ! -s "$TMP/d.out" ]; then
        pass "diff -q 有差异：退出码 1、无输出"
    else
        fail "diff -q 有差异：rc=$rc out=$(cat "$TMP/d.out")"
    fi
    our_diff -q a same
    rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "$TMP/d.out" ]; then
        pass "diff -q 相同：退出码 0、无输出"
    else
        fail "diff -q 相同：rc=$rc out=$(cat "$TMP/d.out")"
    fi

    # 5) -U n 分开写：与 git -U<n> 一致
    our_diff -U 1 m1 m2
    rc=$?
    ref_diff -U1 -- m1 m2
    ref_rc=$?
    if [ "$rc" -eq 1 ] && [ "$ref_rc" -eq 1 ] && cmp -s "$TMP/d.out" "$TMP/d.ref"; then
        pass "diff -U 1 分开写：输出与 git -U1 一致"
    else
        fail "diff -U 1 分开写：rc=$rc ref_rc=$ref_rc"
        dump_pair "$TMP/d.ref" "$TMP/d.out"
    fi

    # 6) -s 相同文件：打印 identical、退出码 0
    our_diff -s a same
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$(cat "$TMP/d.out")" = "Files a and same are identical" ]; then
        pass "diff -s 相同：打印 identical、退出码 0"
    else
        fail "diff -s 相同：rc=$rc out=$(cat "$TMP/d.out")"
    fi

    # 7) -s 有差异：仍输出 diff、退出码 1
    our_diff -s a b
    rc=$?
    if [ "$rc" -eq 1 ] && grep -q '^diff --git ' "$TMP/d.out"; then
        pass "diff -s 有差异：仍输出 diff、退出码 1"
    else
        fail "diff -s 有差异：rc=$rc out=$(head -3 "$TMP/d.out")"
    fi
}

# ---------------------------------------------------------------- nc

wait_pid() { # pid 超时秒数 -> WAIT_RC，进程正常退出返回 0
    local pid="$1" secs="${2:-5}" i=0 n
    n=$((secs * 20))
    while [ "$i" -lt "$n" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid"
            WAIT_RC=$?
            return 0
        fi
        sleep 0.05
        i=$((i + 1))
    done
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    WAIT_RC=124
    return 1
}

free_port() {
    local i p
    for i in $(seq 1 100); do
        p=$(((RANDOM % 40000) + 20000))
        if ! "$PEER" probe "$p" 2>/dev/null; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# 带重试地跑一次 nc 客户端（服务端可能还没 bind 好）
nc_client() { # 输出文件 错误文件 stdin 生成函数 参数...
    local out="$1" err="$2" gen="$3"
    shift 3
    local attempt=0 rc
    while [ "$attempt" -lt 6 ]; do
        "$gen" | timeout 6 "$BSH_NC" "$@" > "$out" 2> "$err"
        rc=$?
        [ "$rc" -eq 0 ] && return 0
        attempt=$((attempt + 1))
        sleep 0.1
    done
    return "$rc"
}

gen_greeting_client() { sleep 0.3; printf 'client-request\n'; sleep 0.3; }
gen_short_client() { sleep 0.1; printf 'Q\n'; sleep 0.2; }

run_nc_tests() {
    local PORT S_PID C_RC S_RC

    # 1) nc -l -p 与 nc host port 双向收发
    PORT="$(free_port)" || die "找不到空闲端口"
    ( printf 'server-greeting\n'; sleep 0.6 ) |
        "$BSH_NC" -l -p "$PORT" > "$TMP/nc_s.out" 2> "$TMP/nc_s.err" &
    S_PID=$!
    sleep 0.25
    nc_client "$TMP/nc_c.out" "$TMP/nc_c.err" gen_greeting_client -w 4 127.0.0.1 "$PORT"
    C_RC=$?
    wait_pid "$S_PID" 6
    S_RC=$WAIT_RC
    if [ "$C_RC" -eq 0 ] && [ "$S_RC" -eq 0 ]; then
        pass "nc 双向转发：两端退出码 0"
    else
        fail "nc 双向转发：client rc=$C_RC server rc=$S_RC err=$(cat "$TMP/nc_s.err" "$TMP/nc_c.err")"
    fi
    printf 'server-greeting\n' > "$TMP/exp_greeting"
    printf 'client-request\n' > "$TMP/exp_request"
    if cmp -s "$TMP/nc_c.out" "$TMP/exp_greeting"; then
        pass "nc 客户端收到服务端数据"
    else
        fail "nc 客户端收到服务端数据：实际=$(cat "$TMP/nc_c.out")"
    fi
    if cmp -s "$TMP/nc_s.out" "$TMP/exp_request"; then
        pass "nc 服务端收到客户端数据（stdin EOF 后仍继续读）"
    else
        fail "nc 服务端收到客户端数据：实际=$(cat "$TMP/nc_s.out")"
    fi

    # 2) 位置端口监听 + -p 指定端口连接
    PORT="$(free_port)" || die "找不到空闲端口"
    ( printf 'P\n'; sleep 0.5 ) |
        "$BSH_NC" -l "$PORT" > "$TMP/nc_s2.out" 2> "$TMP/nc_s2.err" &
    S_PID=$!
    sleep 0.25
    nc_client "$TMP/nc_c2.out" "$TMP/nc_c2.err" gen_short_client -w 3 -p "$PORT" 127.0.0.1
    C_RC=$?
    wait_pid "$S_PID" 6
    S_RC=$WAIT_RC
    printf 'P\n' > "$TMP/exp_p"
    printf 'Q\n' > "$TMP/exp_q"
    if [ "$C_RC" -eq 0 ] && [ "$S_RC" -eq 0 ] &&
        cmp -s "$TMP/nc_c2.out" "$TMP/exp_p" && cmp -s "$TMP/nc_s2.out" "$TMP/exp_q"; then
        pass "nc 位置端口监听 + -p 连接"
    else
        fail "nc 位置端口监听 + -p 连接：client rc=$C_RC server rc=$S_RC c=$(cat "$TMP/nc_c2.out") s=$(cat "$TMP/nc_s2.out")"
    fi

    # 3) -w 1 连不存在的端口：立即失败，不挂死
    PORT="$(free_port)" || die "找不到空闲端口"
    local start end rc
    start=$(date +%s%N)
    timeout 6 "$BSH_NC" -w 1 127.0.0.1 "$PORT" < /dev/null > "$TMP/nc_w.out" 2> "$TMP/nc_w.err"
    rc=$?
    end=$(date +%s%N)
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ -s "$TMP/nc_w.err" ] &&
        [ $(((end - start) / 1000000)) -lt 4000 ]; then
        pass "nc -w 1 不存在端口：快速失败（$(((end - start) / 1000000))ms）"
    else
        fail "nc -w 1 不存在端口：rc=$rc elapsed=$(((end - start) / 1000000))ms err=$(cat "$TMP/nc_w.err")"
    fi

    # 4) 客户端 stdin 先 EOF，对端随后才发数据：必须继续读
    PORT="$(free_port)" || die "找不到空闲端口"
    "$PEER" listen "$PORT" 300 > "$TMP/peer.out" 2> "$TMP/peer.err" &
    S_PID=$!
    sleep 0.2
    timeout 6 "$BSH_NC" -w 3 127.0.0.1 "$PORT" < /dev/null > "$TMP/nc_late.out" 2> "$TMP/nc_late.err"
    C_RC=$?
    wait_pid "$S_PID" 5
    printf 'LATE-PAYLOAD\n' > "$TMP/exp_late"
    if [ "$C_RC" -eq 0 ] && cmp -s "$TMP/nc_late.out" "$TMP/exp_late"; then
        pass "nc 客户端 stdin EOF 后仍收到对端迟到数据"
    else
        fail "nc 客户端 stdin EOF 后仍收到对端迟到数据：rc=$C_RC out=$(cat "$TMP/nc_late.out")"
    fi

    # 5) 监听端 stdin 先 EOF，对端随后才发数据：必须继续读
    PORT="$(free_port)" || die "找不到空闲端口"
    "$BSH_NC" -l -p "$PORT" < /dev/null > "$TMP/nc_late2.out" 2> "$TMP/nc_late2.err" &
    S_PID=$!
    sleep 0.2
    "$PEER" connect "$PORT" 300 > "$TMP/peer2.out" 2> "$TMP/peer2.err"
    C_RC=$?
    wait_pid "$S_PID" 5
    S_RC=$WAIT_RC
    if [ "$C_RC" -eq 0 ] && [ "$S_RC" -eq 0 ] && cmp -s "$TMP/nc_late2.out" "$TMP/exp_late"; then
        pass "nc 监听端 stdin EOF 后仍收到对端迟到数据"
    else
        fail "nc 监听端 stdin EOF 后仍收到对端迟到数据：peer rc=$C_RC server rc=$S_RC out=$(cat "$TMP/nc_late2.out")"
    fi

    # 6) stdin EOF 会作为对端可读的 EOF 送到对端
    PORT="$(free_port)" || die "找不到空闲端口"
    "$PEER" listen-eof "$PORT" > "$TMP/peer_eof.out" 2> "$TMP/peer_eof.err" &
    S_PID=$!
    sleep 0.2
    timeout 6 "$BSH_NC" -w 3 127.0.0.1 "$PORT" < /dev/null > "$TMP/nc_eof.out" 2> "$TMP/nc_eof.err"
    C_RC=$?
    wait_pid "$S_PID" 5
    if [ "$C_RC" -eq 0 ] && grep -q '^SAW_EOF$' "$TMP/peer_eof.out"; then
        pass "nc stdin EOF 传到对端（对端读到 0）"
    else
        fail "nc stdin EOF 传到对端：client rc=$C_RC peer=$(cat "$TMP/peer_eof.out")"
    fi
}

# ---------------------------------------------------------------- 入口

echo "== cmd_tools 宿主行为测试 =="
echo "源码: $SRC"
run_hexdump_tests
run_diff_tests
run_nc_tests

echo
echo "== 结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 0
