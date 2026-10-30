#!/usr/bin/env bash
# run.sh — IEC 内置 CA bundle（assets/cacert.pem）的可用性与接线验证。
#
# 只做宿主侧验证，不连设备、不需要 HarmonyOS SDK。分三段：
#
#   1) bundle 本身：PEM 结构是否完整、每个根证书能否被 OpenSSL / Python 解析、
#      GitHub（DigiCert）与 Let's Encrypt 的根在不在、有没有早已过期的根；
#   2) 接线：CMake 嵌入的源文件就是 assets/cacert.pem、embed_file.py 能原样
#      转成 C 头、C++ 落盘路径是 <dir>/cacert.pem、ArkTS 侧目录是
#      <sysroot>/etc/ssl/certs，且 GIT_SSL_CAINFO / SSL_CERT_FILE /
#      CURL_CA_BUNDLE 三个变量都指向同一个文件；
#   3) 真握手：curl --cacert、python3 ssl.create_default_context(cafile=)、
#      GIT_SSL_CAINFO 下的 git ls-remote，以及对应的环境变量写法。
#
# 判定口径（本检查的要害是区分"证书错"与"网不通"）：
#   * 证书错误（verify failed / unable to get local issuer / curl 60 等）
#     一律 FAIL —— 这正是要抓的回归；
#   * 网络不可达（DNS 失败、超时、拒连、代理不通）一律 SKIP，不算回归；
#   * 缺少 curl / openssl / python3 / git 时退出 77（check-all 记 SKIP）。
#
# 用法:
#   bash third_party/bettersh/iec/tests/ca_bundle/run.sh
#   CA_BUNDLE=/path/to/cacert.pem bash .../run.sh   # 验证别的 bundle
#   CA_REQUIRE_NET=1 bash .../run.sh                # 没有可达主机也算 FAIL
#
# 退出码：0 = PASS，1 = FAIL，77 = SKIP。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IEC_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$IEC_ROOT/../../.." 2>/dev/null && pwd)" || REPO_ROOT=""

CA="${CA_BUNDLE:-$IEC_ROOT/assets/cacert.pem}"
case "$CA" in
    /*) ;;
    *) CA="$(pwd)/$CA" ;;
esac
CA_DIR="$(cd "$(dirname "$CA")" 2>/dev/null && pwd)" || CA_DIR=""
[ -n "$CA_DIR" ] && CA="$CA_DIR/$(basename "$CA")"

FAILS=0
MISSING=()
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ca_bundle.XXXXXX")" || exit 2
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass() { printf '  [PASS] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }
skip() { printf '  [SKIP] %s\n' "$*"; }
info() { printf '  [INFO] %s\n' "$*"; }
need() {
    command -v "$1" >/dev/null 2>&1 && return 0
    case " ${MISSING[*]:-} " in
        *" $1 "*) ;;
        *) MISSING+=("$1") ;;
    esac
    skip "找不到 $1（相关用例略过）"
    return 1
}

printf '== CA bundle: %s\n' "$CA"
[ -d "$REPO_ROOT" ] || REPO_ROOT=""

# ---------- 1. bundle 本身 ----------
echo
echo '-- bundle 结构'

if [ ! -f "$CA" ]; then
    fail "bundle 文件不存在：$CA"
    echo "SUMMARY: FAIL=$FAILS"
    exit 1
fi

SIZE=$(wc -c <"$CA" | tr -d ' ')
if [ "$SIZE" -gt 0 ]; then
    pass "文件存在且非空（$SIZE 字节，sha256 $(sha256sum "$CA" | cut -d' ' -f1)）"
else
    fail "bundle 是空文件：$CA"
fi

# 后续所有解析都用去掉 CR 的副本：设备侧按字节原样写出去，CRLF 不算错，
# 但不能让它干扰"按行匹配 PEM 边界"的检查。
CA_PEM="$TMP/cacert.pem"
tr -d '\r' <"$CA" >"$CA_PEM"

if cmp -s "$CA_PEM" "$CA"; then
    pass '纯 LF 行尾，没有 CR 混入'
else
    info '检测到 CRLF 行尾（OpenSSL 可以接受，仅记录；已按 LF 副本解析）'
fi

BEGIN=$(grep -c '^-----BEGIN CERTIFICATE-----$' "$CA_PEM" || true)
END=$(grep -c '^-----END CERTIFICATE-----$' "$CA_PEM" || true)
if [ "$BEGIN" -gt 0 ] && [ "$BEGIN" -eq "$END" ]; then
    pass "PEM 块配对：$BEGIN 个 BEGIN / $END 个 END"
else
    fail "PEM 块不配对：$BEGIN 个 BEGIN / $END 个 END（文件被截断或拼坏）"
fi

# 私钥混进随包 trust store 是安全事故，顺带守一道。
if grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$CA_PEM"; then
    fail 'bundle 里出现 PRIVATE KEY 块（随包文件不能有私钥）'
else
    pass '不含任何私钥块'
fi

# 头部元数据：curl.se 的 bundle 会写 "Certificate data from Mozilla as of: ..."。
META=$(head -6 "$CA_PEM" | grep -i 'Certificate data from Mozilla as of' | sed 's/^#* *//' || true)
if [ -n "$META" ]; then
    info "$META"
else
    info '头部没有 curl.se 的 Mozilla 时间戳（可能是自制的 bundle）'
fi

echo
echo '-- 所有根证书都能解析'

if need openssl; then
    if ! openssl crl2pkcs7 -nocrl -certfile "$CA_PEM" >"$TMP/all.p7b" 2>"$TMP/p7.err"; then
        fail "openssl 无法把 bundle 转成 PKCS#7：$(head -3 "$TMP/p7.err" | tr '\n' ' ')"
    else
        openssl pkcs7 -in "$TMP/all.p7b" -print_certs -noout >"$TMP/subjects.txt" 2>"$TMP/p7p.err" || true
        PARSED=$(grep -c '^subject=' "$TMP/subjects.txt" || true)
        if [ "$PARSED" -eq "$BEGIN" ] && [ "$PARSED" -gt 0 ]; then
            pass "openssl 解析出 $PARSED 张证书，与 PEM 块数一致"
        else
            fail "openssl 只解析出 $PARSED 张证书，PEM 块有 $BEGIN 个（有坏块/非证书块）"
        fi

        # 逐个根查有效期。Mozilla bundle 里可能残留已过期的根，不作为失败，
        # 但过期数突然变多通常意味着 bundle 太久没更新。
        EXPIRED=()
        mkdir -p "$TMP/certs"
        awk -v dir="$TMP/certs" '
            /^-----BEGIN CERTIFICATE-----$/ { n++ }
            n > 0 { print > (dir "/" n ".pem") }
        ' "$CA_PEM"
        for f in "$TMP"/certs/*.pem; do
            [ -f "$f" ] || continue
            if ! openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1; then
                EXPIRED+=("$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^subject=//')")
            fi
        done
        if [ "${#EXPIRED[@]}" -eq 0 ]; then
            pass '所有根证书当前都未过期'
        else
            info "${#EXPIRED[@]} 张根已过期（仅记录，不判失败）"
            for s in "${EXPIRED[@]}"; do info "  过期: $s"; done
        fi
    fi
fi

echo
echo '-- 关键根证书是否在'

check_root() {  # check_root <CN> <用途>
    if grep -qF "CN=$1" "$TMP/subjects.txt" 2>/dev/null; then
        pass "含 $1（$2）"
    else
        fail "缺少 $1（$2）"
    fi
}
if [ -s "$TMP/subjects.txt" ]; then
    check_root 'ISRG Root X1' "Let's Encrypt，pypi / 清华镜像等"
    check_root 'ISRG Root X2' "Let's Encrypt ECDSA"
    check_root 'DigiCert Global Root G2' 'github.com / gitcode.com'
    # 以下不强制，只报告，方便看出 bundle 的新旧。
    for cn in 'USERTrust ECC Certification Authority' 'AAA Certificate Services' \
        'GlobalSign Root CA - R3' 'Amazon Root CA 1' 'GTS Root R1' \
        'Sectigo Public Server Authentication Root R46'; do
        grep -qF "CN=$cn" "$TMP/subjects.txt" && info "另有 $cn"
    done
    ROOT_COUNT=$(grep -c '^subject=' "$TMP/subjects.txt" || true)
    if [ "$ROOT_COUNT" -ge 80 ]; then
        pass "根证书数量 $ROOT_COUNT 张，量级正常（截断的 bundle 通常远少于 80）"
    else
        fail "根证书只有 $ROOT_COUNT 张，疑似被截断或混入了中间证书包"
    fi
fi

# Python 的 ssl 模块是另一套消费方，它能加载说明文件对标准 PEM 多证书
# bundle 的解析也成立。
if need python3; then
    if python3 - "$CA_PEM" "$BEGIN" <<'PY'
import ssl, sys
ca, expect = sys.argv[1], int(sys.argv[2])
ctx = ssl.create_default_context(cafile=ca)
roots = ctx.get_ca_certs()
print("  已加载 %d 张根证书" % len(roots))
sys.exit(0 if len(roots) == expect else 1)
PY
    then
        pass 'python ssl.create_default_context(cafile=...) 能加载全部根'
    else
        fail 'python ssl 加载的根数量与 PEM 块数不一致'
    fi
fi

# ---------- 2. 接线 ----------
echo
echo '-- CMake 嵌入 / C++ 落盘 / ArkTS 环境变量接线'

HAR_CMAKE="$IEC_ROOT/platform/ohos/har/src/main/cpp/CMakeLists.txt"
CA_CPP="$IEC_ROOT/common/ca_bundle.cpp"
EMBED_TOOL="$IEC_ROOT/tools/embed_file.py"
RUNTIME_ETS="$REPO_ROOT/entry/src/main/ets/service/IecRuntime.ets"
SHELL_ETS="$REPO_ROOT/entry/src/main/ets/service/IecShellService.ets"

wire_grep() {  # wire_grep <文件> <固定子串> <说明>
    local f="$1" pat="$2" what="$3"
    if [ ! -f "$f" ]; then
        skip "找不到 $(basename "$f")，跳过：$what"
        return 0
    fi
    if grep -qF -- "$pat" "$f"; then
        pass "$what"
    else
        fail "$what（$f 里找不到 '$pat'）"
    fi
}

wire_grep "$HAR_CMAKE" 'IEC_CA_SOURCE "${IEC_ROOT}/assets/cacert.pem"' \
    'CMake 嵌入源是 assets/cacert.pem'
wire_grep "$HAR_CMAKE" 'iec_cacert_pem' 'CMake 生成的符号名是 iec_cacert_pem'
wire_grep "$CA_CPP" 'iec_cacert_pem_size' 'C++ 写入的是嵌入数组的字节长度'
wire_grep "$CA_CPP" '"/cacert.pem"' 'C++ 落盘文件名是 <dir>/cacert.pem'
wire_grep "$RUNTIME_ETS" "SYSROOT + '/etc/ssl/certs'" 'ArkTS 落盘目录是 <sysroot>/etc/ssl/certs'
wire_grep "$RUNTIME_ETS" 'installCaBundle(dir)' 'ArkTS 调用 IEC 的 installCaBundle(dir)'
wire_grep "$SHELL_ETS" "env['GIT_SSL_CAINFO'] = ca" '子进程注入 GIT_SSL_CAINFO'
wire_grep "$SHELL_ETS" "env['SSL_CERT_FILE'] = ca" '子进程注入 SSL_CERT_FILE'
wire_grep "$SHELL_ETS" "env['CURL_CA_BUNDLE'] = ca" '子进程注入 CURL_CA_BUNDLE'

# 嵌入流程可用性：真的跑一遍 embed_file.py，再把十六进制还原回字节比对。
# 等于替 CMake 的 add_custom_command 做了一次宿主侧预演。
if need python3 && [ -f "$EMBED_TOOL" ]; then
    if python3 "$EMBED_TOOL" "$CA_PEM" "$TMP/cacert_pem.h" iec_cacert_pem >/dev/null 2>&1 &&
        python3 - "$CA_PEM" "$TMP/cacert_pem.h" <<'PY'
import re, sys
src, hdr = sys.argv[1], sys.argv[2]
want = open(src, "rb").read()
text = open(hdr, encoding="utf-8").read()
body = text.split("iec_cacert_pem[] = {", 1)[1].split("};", 1)[0]
got = bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", body))
sys.exit(0 if got == want else 1)
PY
    then
        pass "embed_file.py 生成的 C 头与 $CA 逐字节一致（$SIZE 字节）"
    else
        fail 'embed_file.py 嵌入结果与源文件不一致（CMake 流程会烙印错误内容）'
    fi
fi

# ---------- 3. 真握手 ----------
echo
echo '-- 用该 bundle 做真实 TLS 校验'

# 隔离用目录：Ubuntu 的 curl 即使给了 --cacert，也仍会加载编译期的 CApath
# （/etc/ssl/certs），OpenSSL 侧 SSL_CERT_FILE 与默认 SSL_CERT_DIR 同理。
# 只传一个 bundle 时，系统库会一起参与校验，于是"少了根也照样通过"——测不出
# bundle 单独够不够用。把 capath 指到这个空目录，信任锚才只剩被测文件；
# 这也更接近设备现场：假根里没有系统 CA 库。
EMPTY_CA_DIR="$TMP/empty-ca"
mkdir -p "$EMPTY_CA_DIR"

NET_OK=0         # 至少有一台主机用该 bundle 验通过
CERT_FAIL=0      # 出现过证书错误（必须 FAIL）
UNREACHABLE=0    # 不可达的主机数
HOSTS=(
    'https://pypi.org/simple/'
    'https://github.com/'
    'https://gitcode.com/'
    'https://mirrors.tuna.tsinghua.edu.cn/'
)
VERIFIED_HOSTS=()

# curl 是否真的会用 --cacert：Schannel / SecureTransport 后端忽略该参数，
# 拿它当判据会给出假 PASS，所以后端不对就跳过 curl 用例。
CURL_OK=0
if need curl; then
    CURL_VER_LINE=$(curl --version 2>/dev/null | head -1)
    if printf '%s' "$CURL_VER_LINE" | grep -qiE 'schannel|securetransport'; then
        info "curl 后端用的是系统信任存储（$CURL_VER_LINE），--cacert 不生效，跳过 curl 用例"
        info '  请在 WSL / Linux 上跑本脚本，或装 OpenSSL 后端的 curl'
    else
        CURL_OK=1
    fi
fi

classify_curl_stderr() {  # 命中说明是"证书错"，不是"网不通"
    grep -qiE 'certificate|unable to get (local )?issuer|self[- ]signed|verify (error|failed)|unknown ca' "$1"
}

if [ "$CURL_OK" = 1 ]; then
    for url in "${HOSTS[@]}"; do
        host=${url#https://}; host=${host%%/*}
        : >"$TMP/curl.err"
        code=$(curl --cacert "$CA_PEM" --capath "$EMPTY_CA_DIR" -sS -o /dev/null -m 25 \
            -w '%{http_code}' "$url" 2>"$TMP/curl.err")
        rc=$?
        err=$(head -2 "$TMP/curl.err" | tr '\n' ' ')
        if [ "$rc" -eq 0 ] && [ "${code:-0}" -ge 200 ] && [ "${code:-0}" -lt 400 ]; then
            pass "curl --cacert https://$host → HTTP $code"
            NET_OK=1
            VERIFIED_HOSTS+=("$host")
        elif [ "$rc" -eq 0 ]; then
            # 握手与证书校验都过了，只是应用层返回 4xx/5xx。
            pass "curl --cacert https://$host → 证书校验通过（HTTP ${code:-?}，应用层响应）"
            NET_OK=1
            VERIFIED_HOSTS+=("$host")
        elif classify_curl_stderr "$TMP/curl.err" || \
            [ "$rc" -eq 60 ] || [ "$rc" -eq 51 ] || [ "$rc" -eq 58 ] || \
            [ "$rc" -eq 59 ] || [ "$rc" -eq 77 ] || [ "$rc" -eq 83 ] || \
            [ "$rc" -eq 90 ] || [ "$rc" -eq 91 ]; then
            fail "curl --cacert https://$host 证书校验失败（rc=$rc）：$err"
            CERT_FAIL=1
        else
            info "curl https://$host 网络不可达（rc=$rc）：$err"
            UNREACHABLE=$((UNREACHABLE + 1))
        fi
    done

    # 环境变量写法（IecShellService 注入的就是这些名字）单独验一次。
    if [ "${#VERIFIED_HOSTS[@]}" -gt 0 ]; then
        url="https://${VERIFIED_HOSTS[0]}/"
        : >"$TMP/curl_env.err"
        code=$(CURL_CA_BUNDLE="$CA_PEM" curl --capath "$EMPTY_CA_DIR" -sS -o /dev/null -m 25 \
            -w '%{http_code}' "$url" 2>"$TMP/curl_env.err")
        rc=$?
        if [ "$rc" -eq 0 ]; then
            pass "CURL_CA_BUNDLE 环境变量生效（https://${VERIFIED_HOSTS[0]} → HTTP ${code:-?}）"
        elif classify_curl_stderr "$TMP/curl_env.err"; then
            fail "CURL_CA_BUNDLE 下证书校验失败（rc=$rc）：$(head -2 "$TMP/curl_env.err" | tr '\n' ' ')"
            CERT_FAIL=1
        else
            info "CURL_CA_BUNDLE 用例网络不可达（rc=$rc）"
        fi
    fi
fi

# python3：cafile= 与 SSL_CERT_FILE 两种写法。独立遍历候选主机，不依赖
# curl 那条路是否可用（curl 后端是 Schannel 时这段仍然有效）。
if need python3; then
    PY_HOST=""
    for url in "${HOSTS[@]}"; do
        host=${url#https://}; host=${host%%/*}
        out=$(python3 - "$CA_PEM" "$host" <<'PY' 2>&1
import socket, ssl, sys
ca, host = sys.argv[1], sys.argv[2]
ctx = ssl.create_default_context(cafile=ca)
try:
    with socket.create_connection((host, 443), timeout=20) as raw:
        with ctx.wrap_socket(raw, server_hostname=host) as tls:
            print("OK %s %s" % (tls.version(), tls.cipher()[0]))
except ssl.SSLCertVerificationError as exc:
    print("CERTFAIL %s" % exc)
    sys.exit(1)
except (socket.gaierror, socket.timeout, ssl.SSLError, OSError) as exc:
    print("UNREACHABLE %s" % exc)
    sys.exit(2)
PY
        )
        rc=$?
        case "$rc" in
            0) pass "python ssl.create_default_context(cafile=...) 握手成功：$host（${out#OK }）"
               PY_HOST=$host; NET_OK=1; break ;;
            1) fail "python cafile= 证书校验失败：$host（${out#CERTFAIL }）"; CERT_FAIL=1 ;;
            *) info "python 连不上 $host（${out#UNREACHABLE }）" ;;
        esac
    done

    if [ -n "$PY_HOST" ]; then
        out=$(SSL_CERT_FILE="$CA_PEM" SSL_CERT_DIR="$EMPTY_CA_DIR" python3 - "$PY_HOST" <<'PY' 2>&1
import socket, ssl, sys
host = sys.argv[1]
ctx = ssl.create_default_context()   # 只靠 SSL_CERT_FILE
try:
    with socket.create_connection((host, 443), timeout=20) as raw:
        with ctx.wrap_socket(raw, server_hostname=host) as tls:
            print("OK %s" % tls.version())
except ssl.SSLCertVerificationError as exc:
    print("CERTFAIL %s" % exc)
    sys.exit(1)
except (socket.gaierror, socket.timeout, ssl.SSLError, OSError) as exc:
    print("UNREACHABLE %s" % exc)
    sys.exit(2)
PY
        )
        rc=$?
        case "$rc" in
            0) pass "SSL_CERT_FILE 环境变量生效：$PY_HOST（${out#OK }）" ;;
            1) fail "SSL_CERT_FILE 下证书校验失败：$PY_HOST（${out#CERTFAIL }）" ; CERT_FAIL=1 ;;
            *) info "SSL_CERT_FILE 用例连不上 $PY_HOST（${out#UNREACHABLE }）" ;;
        esac
    elif [ "$CERT_FAIL" = 0 ]; then
        info 'python 访问的候选主机都不可达，SSL_CERT_FILE 用例记 SKIP'
    fi
fi

# git：GIT_SSL_CAINFO 是设备上最要紧的那条。GitHub 常常不通，依次试镜像。
if need git; then
    GIT_OK=0
    GIT_URLS=(
        'https://github.com/git/git.git'
        'https://gitcode.com/gh_mirrors/gi/git.git'
        'https://gitee.com/mirrors/git.git'
        'https://mirrors.tuna.tsinghua.edu.cn/git/git.git'
    )
    for url in "${GIT_URLS[@]}"; do
        : >"$TMP/git.err"
        if command -v timeout >/dev/null 2>&1; then
            out=$(GIT_SSL_CAINFO="$CA_PEM" GIT_SSL_CAPATH="$EMPTY_CA_DIR" GIT_TERMINAL_PROMPT=0 \
                timeout 60 git ls-remote "$url" HEAD 2>"$TMP/git.err")
        else
            out=$(GIT_SSL_CAINFO="$CA_PEM" GIT_SSL_CAPATH="$EMPTY_CA_DIR" GIT_TERMINAL_PROMPT=0 \
                git ls-remote "$url" HEAD 2>"$TMP/git.err")
        fi
        rc=$?
        err=$(head -3 "$TMP/git.err" | tr '\n' ' ')
        if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qE '^[0-9a-f]{40}[[:space:]]+HEAD'; then
            pass "GIT_SSL_CAINFO git ls-remote ${url} → $(printf '%s' "$out" | cut -c1-12)…"
            GIT_OK=1
            NET_OK=1
            break
        fi
        if grep -qiE 'SSL certificate problem|certificate (verify|verification) failed|unable to get (local )?issuer|certificate signer not trusted|self[- ]signed certificate' "$TMP/git.err"; then
            fail "GIT_SSL_CAINFO git ls-remote ${url} 证书校验失败（rc=$rc）：$err"
            CERT_FAIL=1
            GIT_OK=-1
            break
        fi
        info "git ls-remote ${url} 不可用（rc=$rc）：$err"
    done
    if [ "$GIT_OK" = 0 ]; then
        info '没有任何 git 远端可用（GitHub/镜像都不通），git 用例记 SKIP'
    fi
fi

# ---------- 汇总 ----------
echo
if [ "$CERT_FAIL" = 1 ]; then
    echo '网络验证：出现证书错误（FAIL）'
elif [ "$NET_OK" = 1 ]; then
    echo "网络验证：至少一台主机用该 bundle 验通（${VERIFIED_HOSTS[*]:-git}）"
else
    echo '网络验证：所有候选主机都不可达，按 SKIP 处理（不是 bundle 的问题）'
fi
[ "${#MISSING[@]}" -gt 0 ] && echo "缺少依赖：${MISSING[*]}"

if [ "$FAILS" -gt 0 ]; then
    echo "SUMMARY: FAIL=$FAILS"
    exit 1
fi
if [ "$CERT_FAIL" = 1 ]; then
    echo 'SUMMARY: FAIL=1（证书校验失败）'
    exit 1
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo 'SUMMARY: SKIP（缺少依赖）'
    exit 77
fi
if [ "$NET_OK" != 1 ]; then
    if [ "${CA_REQUIRE_NET:-0}" = 1 ]; then
        echo 'SUMMARY: FAIL=1（CA_REQUIRE_NET=1 且没有可达主机）'
        exit 1
    fi
    echo 'SUMMARY: SKIP（离线检查已通过，网络不可达）'
    exit 77
fi
echo "SUMMARY: PASS（离线检查 + ${#VERIFIED_HOSTS[@]} 台主机真握手）"
exit 0
