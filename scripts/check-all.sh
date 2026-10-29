#!/usr/bin/env bash
# Guncat Work 一键本地检查入口（WSL / Linux / macOS）。
#
# 逐项运行宿主侧检查，单项失败不中断，最后汇总 PASS/FAIL/SKIP 并以非零退出码
# 表示存在失败。供本地提交前预检与 CI 复用。
#
#   bash scripts/check-all.sh            # 全量
#   bash scripts/check-all.sh --fast     # 跳过 soname / py_runner / IEC 命令集 / exec 压测
#   bash scripts/check-all.sh --list     # 只列出检查项
#   bash scripts/check-all.sh --help
#
# 环境变量：
#   GUNCAT_LLVM_BIN   DevEco / OHOS SDK 的 native/llvm/bin（含 llvm-readelf）
#   IEC_PY_LIBPYTHON  py_runner 测试使用的宿主 libpython（默认自动探测）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$ROOT/test/guncat-harness"
FAST=0
LIST_ONLY=0

PASS=0
FAIL=0
SKIP=0
TMP_DIRS=()

cleanup() {
    if ((${#TMP_DIRS[@]})); then
        local d
        for d in "${TMP_DIRS[@]}"; do
            rm -rf "$d"
        done
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
用法: bash scripts/check-all.sh [选项]

选项:
  --fast    跳过需要额外环境或较慢的项（soname 检查、py_runner、IEC 命令集、
            IEC exec 会话压测），
            被跳过的项计入 SUMMARY 的 SKIP
  --list    列出所有检查项后退出
  -h, --help
            显示本帮助

环境变量:
  GUNCAT_LLVM_BIN   DevEco / OHOS SDK 的 native/llvm/bin（含 llvm-readelf）。
                    未设置时自动探测常见安装路径；WSL 下会自动用 GNU readelf
                    兼容 Windows 版 llvm-readelf.exe（它读不了 /mnt 路径）。
  IEC_PY_LIBPYTHON  py_runner 宿主测试使用的 libpython 共享库路径。

退出码: 0 = 全部 PASS/SKIP；1 = 至少一项 FAIL；2 = 参数错误。
EOF
}

# ---- 检查项清单 ---------------------------------------------------------
# 顺序即执行顺序；FAST_SKIP=1 的项在 --fast 下不运行。
ITEM_IDS=(
    logic
    types
    ui-copy
    docs
    license
    sonames
    py-runner
    cmd-tools
    iec-native-host
    iec-exec-stress
    iec-libs
)
ITEM_NAMES=(
    "纯逻辑单测（setup.mjs + test-core.mjs，683 项）"
    "服务层类型检查（check-setup.mjs + tsc）"
    "界面文案可复制护栏（check-ui-copy.mjs）"
    "Markdown 相对链接（docs-check.py --strict）"
    "随包第三方许可（license-check.py --strict）"
    "共享库 soname 依赖（check-sonames.py --strict）"
    "py_runner 宿主协议测试"
    "IEC 命令集宿主测试（nc / hexdump / diff）"
    "IEC 原生代码宿主回归（exec 路由 / cwd / NCP / fs shim）"
    "IEC exec 会话并发/生命周期压测（8 路 / 终止 / fd / 超时）"
    "IEC 随包库检查（tools/check-iec-libs.py）"
)
ITEM_FAST_SKIP=(0 0 0 0 0 1 1 1 0 1 0)

print_list() {
    local i
    for i in "${!ITEM_IDS[@]}"; do
        printf '%2d. %-16s %s%s\n' \
            "$((i + 1))" "${ITEM_IDS[$i]}" "${ITEM_NAMES[$i]}" \
            "$([[ ${ITEM_FAST_SKIP[$i]} == 1 ]] && echo '  [--fast 跳过]')"
    done
}

# ---- 通用小工具 ---------------------------------------------------------
now_us() {
    local t="${EPOCHREALTIME:-}"
    if [[ -n "$t" ]]; then
        printf '%s' "${t//[.,]/}"
    else
        printf '%s000000' "$(date +%s)"
    fi
}

have_node() {
    command -v node >/dev/null 2>&1
}

# harness 依赖 Node >= 22.6 的原生 TypeScript strip。
node_supports_ts() {
    local version major rest minor
    version="$(node -p 'process.versions.node' 2>/dev/null)" || return 1
    major="${version%%.*}"
    rest="${version#*.}"
    minor="${rest%%.*}"
    ((major > 22 || (major == 22 && minor >= 6)))
}

skip_msg() {
    printf '    跳过: %s\n' "$*"
}

is_wsl() {
    [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}

# Git Bash 等场景下把 C:\... 转成 /mnt/c/...；非 WSL 环境原样返回。
normalize_path() {
    local path="$1"
    if [[ "$path" == [A-Za-z]:\\* || "$path" == [A-Za-z]:/* || "$path" == \\\\* ]]; then
        if command -v wslpath >/dev/null 2>&1; then
            wslpath -u "$path" 2>/dev/null && return 0
        fi
    fi
    printf '%s\n' "$path"
}

has_libpython() {
    [[ -n "${IEC_PY_LIBPYTHON:-}" ]] && return 0
    compgen -G '/usr/lib/*/libpython3.*.so*' >/dev/null 2>&1 ||
        compgen -G '/usr/lib/libpython3.*.so*' >/dev/null 2>&1 ||
        compgen -G '/usr/lib64/libpython3.*.so*' >/dev/null 2>&1 ||
        compgen -G '/usr/local/lib/libpython3.*.so*' >/dev/null 2>&1
}

# ---- 各检查项 -----------------------------------------------------------
# 返回 0 = PASS，1 = FAIL，77 = SKIP。函数在 if 条件下调用，errexit 已关闭，
# 因此每条命令都显式用 `|| rc=1` 收集失败，保证单项内部的后续命令仍会执行。

check_logic() {
    have_node || { skip_msg "找不到 node（需要 Node >= 22.6）"; return 77; }
    node_supports_ts || { skip_msg "node $(node --version 2>/dev/null) 过旧，需要 >= 22.6"; return 77; }

    local rc=0
    echo "    $ cd test/guncat-harness && node setup.mjs"
    (cd "$HARNESS" && node setup.mjs) || rc=1
    echo "    $ cd test/guncat-harness && node test-core.mjs"
    (cd "$HARNESS" && node test-core.mjs) || rc=1
    return "$rc"
}

check_types() {
    have_node || { skip_msg "找不到 node（需要 Node >= 22.6）"; return 77; }
    node_supports_ts || { skip_msg "node $(node --version 2>/dev/null) 过旧，需要 >= 22.6"; return 77; }
    command -v npx >/dev/null 2>&1 || { skip_msg "找不到 npx"; return 77; }

    local rc=0
    echo "    $ cd test/guncat-harness && node check-setup.mjs"
    (cd "$HARNESS" && node check-setup.mjs) || rc=1
    # 仓库根目录没有 node_modules；`npx tsc` 会误装同名的 tsc@2.0.4，
    # 因此与 CI 一致，显式指定 TypeScript 版本。
    echo "    $ cd test/guncat-harness && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json"
    (cd "$HARNESS" && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json) || rc=1
    return "$rc"
}

check_ui_copy() {
    have_node || { skip_msg "找不到 node"; return 77; }
    local rc=0
    echo "    $ cd test/guncat-harness && node check-ui-copy.mjs"
    (cd "$HARNESS" && node check-ui-copy.mjs) || rc=1
    return "$rc"
}

check_docs() {
    command -v python3 >/dev/null 2>&1 || { skip_msg "找不到 python3"; return 77; }
    python3 "$ROOT/tooling/docs-check.py" --strict
}

check_license() {
    command -v python3 >/dev/null 2>&1 || { skip_msg "找不到 python3"; return 77; }
    python3 "$ROOT/tooling/license-check.py" --strict
}

# 探测可用的 llvm-readelf，结果写入 LLVM_DIR / LLVM_KIND（native|exe|shim）。
LLVM_DIR=""
LLVM_KIND=""

find_llvm_readelf() {
    LLVM_DIR=""
    LLVM_KIND=""

    local candidates=() dir

    if [[ -n "${GUNCAT_LLVM_BIN:-}" ]]; then
        dir="$(normalize_path "$GUNCAT_LLVM_BIN")"
        if [[ -f "$dir/llvm-readelf" ]]; then
            LLVM_DIR="$dir"
            LLVM_KIND="native"
            return 0
        elif [[ -f "$dir/llvm-readelf.exe" ]]; then
            LLVM_DIR="$dir"
            LLVM_KIND="exe"
            return 0
        fi
        echo "    提示: GUNCAT_LLVM_BIN=$GUNCAT_LLVM_BIN 下没有 llvm-readelf，继续自动探测" >&2
    fi

    candidates=(
        "/opt/ohos-cmdline/command-line-tools/sdk/default/openharmony/native/llvm/bin"
        "$HOME/command-line-tools/sdk/default/openharmony/native/llvm/bin"
        "$HOME/DevEco Studio/sdk/default/openharmony/native/llvm/bin"
        "/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native/llvm/bin"
        "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/bin"
    )
    for dir in "${candidates[@]}"; do
        if [[ -f "$dir/llvm-readelf" ]]; then
            LLVM_DIR="$dir"
            LLVM_KIND="native"
            return 0
        elif [[ -f "$dir/llvm-readelf.exe" ]]; then
            LLVM_DIR="$dir"
            LLVM_KIND="exe"
            return 0
        fi
    done

    if command -v llvm-readelf >/dev/null 2>&1; then
        LLVM_DIR="$(dirname "$(command -v llvm-readelf)")"
        LLVM_KIND="native"
        return 0
    fi
    return 1
}

# WSL 里 DevEco 是 Windows 装的，llvm-readelf.exe 无法打开 /mnt/c/... 路径，
# 会静默返回空输出，把每个 Python 扩展都误报成“缺 libpython”。用 GNU readelf
# 做一个同名 shim，走同一套 DT_NEEDED 解析。结果写入 SHIM_DIR（不要用
# $(make_readelf_shim) 调用：命令替换是子 shell，TMP_DIRS 带不回父进程，临时目录会漏删）。
SHIM_DIR=""

make_readelf_shim() {
    SHIM_DIR=""
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/guncat-llvm.XXXXXX")" || return 1
    TMP_DIRS+=("$dir")
    printf '#!/usr/bin/env bash\nexec readelf "$@"\n' >"$dir/llvm-readelf" || return 1
    chmod +x "$dir/llvm-readelf" || return 1
    SHIM_DIR="$dir"
}

check_sonames() {
    command -v python3 >/dev/null 2>&1 || { skip_msg "找不到 python3"; return 77; }
    if [[ ! -d "$ROOT/entry/libs/arm64-v8a" ]]; then
        skip_msg "entry/libs/arm64-v8a 不存在（未同步随包库？）"
        return 77
    fi
    if ! find_llvm_readelf; then
        skip_msg "找不到 llvm-readelf；请安装 llvm 或设置 GUNCAT_LLVM_BIN=<SDK>/native/llvm/bin"
        return 77
    fi

    if [[ "$LLVM_KIND" == "exe" ]]; then
        if ! is_wsl; then
            skip_msg "只找到 Windows 版 llvm-readelf.exe；请安装 Linux llvm 或设置 GUNCAT_LLVM_BIN 指向 Linux 工具链"
            return 77
        fi
        if ! command -v readelf >/dev/null 2>&1; then
            skip_msg "WSL 下 Windows 版 llvm-readelf.exe 读不了 /mnt 路径，且系统没有 readelf"
            return 77
        fi
        if ! make_readelf_shim; then
            skip_msg "无法创建 readelf 兼容 shim"
            return 77
        fi
        echo "    提示: WSL 检测到 Windows 版 llvm-readelf.exe，改用 GNU readelf 读取 ELF"
        LLVM_DIR="$SHIM_DIR"
        LLVM_KIND="shim"
    fi

    echo "    $ GUNCAT_LLVM_BIN=$LLVM_DIR python3 tooling/python/check-sonames.py --strict"
    GUNCAT_LLVM_BIN="$LLVM_DIR" python3 "$ROOT/tooling/python/check-sonames.py" --strict
}

check_py_runner() {
    command -v python3 >/dev/null 2>&1 || { skip_msg "找不到 python3"; return 77; }
    command -v cc >/dev/null 2>&1 || { skip_msg "找不到 cc"; return 77; }
    command -v c++ >/dev/null 2>&1 || { skip_msg "找不到 c++"; return 77; }
    has_libpython || { skip_msg "找不到宿主 libpython 共享库（可装 python3-dev 或设 IEC_PY_LIBPYTHON）"; return 77; }

    bash "$ROOT/third_party/bettersh/scripts/test_py_runner_host.sh"
}

check_cmd_tools() {
    command -v bash >/dev/null 2>&1 || { skip_msg "找不到 bash"; return 77; }
    command -v cc >/dev/null 2>&1 || { skip_msg "找不到 cc"; return 77; }
    command -v git >/dev/null 2>&1 || { skip_msg "找不到 git"; return 77; }
    command -v timeout >/dev/null 2>&1 || { skip_msg "找不到 timeout（coreutils）"; return 77; }
    command -v od >/dev/null 2>&1 || { skip_msg "找不到 od"; return 77; }

    bash "$ROOT/third_party/bettersh/iec/tests/cmd_tools/run.sh"
}

# IEC 原生代码的宿主回归：exec 路由（ResolveKind）、cwd 校验、NCP 拒绝分类、
# fs shim 路径映射。全部在宿主编/跑，不需要设备或 OHOS SDK；脚本尚未合入时跳过。
check_iec_native_host() {
    local script="$ROOT/third_party/bettersh/iec/scripts/test_iec_native_host.sh"
    if [[ ! -f "$script" ]]; then
        skip_msg "third_party/bettersh/iec/scripts/test_iec_native_host.sh 不存在（该检查尚未合入）"
        return 77
    fi
    command -v bash >/dev/null 2>&1 || { skip_msg "找不到 bash"; return 77; }
    command -v cmake >/dev/null 2>&1 || { skip_msg "找不到 cmake"; return 77; }
    command -v cc >/dev/null 2>&1 || { skip_msg "找不到 cc"; return 77; }
    command -v c++ >/dev/null 2>&1 || { skip_msg "找不到 c++"; return 77; }

    bash "$script"
}

# IEC exec 会话的并发/生命周期压测：整条流上限、8 路并发、中途终止、fd 与 RSS
# 不随轮次增长、200 次短会话、0/1/50ms 超时边界。宿主上编跑，不需要设备或 SDK；
# 比原生回归慢（50 轮 + 200 次起停），所以放在 --fast 之外。
check_iec_exec_stress() {
    local script="$ROOT/third_party/bettersh/iec/scripts/stress_exec_session.sh"
    if [[ ! -f "$script" ]]; then
        skip_msg "third_party/bettersh/iec/scripts/stress_exec_session.sh 不存在（该检查尚未合入）"
        return 77
    fi
    command -v bash >/dev/null 2>&1 || { skip_msg "找不到 bash"; return 77; }
    command -v cmake >/dev/null 2>&1 || { skip_msg "找不到 cmake"; return 77; }
    command -v cc >/dev/null 2>&1 || { skip_msg "找不到 cc"; return 77; }
    command -v c++ >/dev/null 2>&1 || { skip_msg "找不到 c++"; return 77; }

    bash "$script"
}

# 找到能用的 Linux 版 llvm-nm 目录。WSL 下 Windows 的 llvm-nm.exe 读不了
# /mnt 路径，不能交给 check-iec-libs.py，否则会把所有入口符号误报成缺失。
llvm_nm_dir() {
    local dir
    if [[ -n "${GUNCAT_LLVM_BIN:-}" ]]; then
        dir="$(normalize_path "$GUNCAT_LLVM_BIN")"
        if [[ -f "$dir/llvm-nm" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
    fi

    if [[ "$LLVM_KIND" == "native" && -f "$LLVM_DIR/llvm-nm" ]]; then
        printf '%s\n' "$LLVM_DIR"
        return 0
    fi

    if find_llvm_readelf >/dev/null 2>&1 &&
        [[ "$LLVM_KIND" == "native" && -f "$LLVM_DIR/llvm-nm" ]]; then
        printf '%s\n' "$LLVM_DIR"
        return 0
    fi
    return 1
}

check_iec_libs() {
    local script="$ROOT/tools/check-iec-libs.py"
    if [[ ! -f "$script" ]]; then
        skip_msg "tools/check-iec-libs.py 不存在（该检查尚未合入）"
        return 77
    fi
    command -v python3 >/dev/null 2>&1 || { skip_msg "找不到 python3"; return 77; }

    local llvm_dir=""
    llvm_dir="$(llvm_nm_dir)" || llvm_dir=""
    if [[ -n "$llvm_dir" ]]; then
        echo "    使用 llvm-nm: $llvm_dir/llvm-nm"
        GUNCAT_LLVM_BIN="$llvm_dir" python3 "$script"
    else
        # 清掉可能是 Windows 路径的 GUNCAT_LLVM_BIN，交给脚本自己探测。
        GUNCAT_LLVM_BIN= python3 "$script"
    fi
}

# ---- 运行与汇总 ---------------------------------------------------------
run_check() {
    local index="$1" name="$2" fn="$3"
    local start_us end_us elapsed_ms rc=0

    printf '\n==> [%d/%d] %s\n' "$index" "${#ITEM_IDS[@]}" "$name"
    start_us="$(now_us)"

    if "$fn"; then
        rc=0
    else
        rc=$?
    fi

    end_us="$(now_us)"
    elapsed_ms=$(((end_us - start_us) / 1000))

    case "$rc" in
        0)
            PASS=$((PASS + 1))
            printf '    PASS (%d.%02ds)\n' "$((elapsed_ms / 1000))" "$(((elapsed_ms % 1000) / 10))"
            ;;
        77)
            SKIP=$((SKIP + 1))
            printf '    SKIP (%d.%02ds)\n' "$((elapsed_ms / 1000))" "$(((elapsed_ms % 1000) / 10))"
            ;;
        *)
            FAIL=$((FAIL + 1))
            printf '    FAIL (exit=%d, %d.%02ds)\n' \
                "$rc" "$((elapsed_ms / 1000))" "$(((elapsed_ms % 1000) / 10))"
            ;;
    esac
}

main() {
    while (($#)); do
        case "$1" in
            --fast) FAST=1 ;;
            --list) LIST_ONLY=1 ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "check-all.sh: 未知参数 $1" >&2
                usage >&2
                exit 2
                ;;
        esac
        shift
    done

    if ((LIST_ONLY)); then
        print_list
        exit 0
    fi

    if ((FAST)); then
        local skipped=() i
        for i in "${!ITEM_IDS[@]}"; do
            if [[ "${ITEM_FAST_SKIP[$i]}" == "1" ]]; then
                skipped+=("${ITEM_IDS[$i]}")
            fi
        done
        echo "模式: --fast（跳过 ${skipped[*]}）"
    else
        echo "模式: 全量"
    fi

    local i fn
    for i in "${!ITEM_IDS[@]}"; do
        if ((FAST)) && [[ "${ITEM_FAST_SKIP[$i]}" == "1" ]]; then
            printf '\n==> [%d/%d] %s\n' "$((i + 1))" "${#ITEM_IDS[@]}" "${ITEM_NAMES[$i]}"
            echo "    SKIP (--fast)"
            SKIP=$((SKIP + 1))
            continue
        fi
        fn="check_${ITEM_IDS[$i]//-/_}"
        run_check "$((i + 1))" "${ITEM_NAMES[$i]}" "$fn"
    done

    echo
    echo "SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    ((FAIL == 0))
}

main "$@"
