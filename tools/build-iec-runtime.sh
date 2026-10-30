#!/bin/bash
# 一键构建 IEC 随包命令集（WSL + Linux 版 OHOS SDK）。
#
#   export OHOS_SDK=/opt/ohos-cmdline/command-line-tools/sdk/default/openharmony
#   tools/build-iec-runtime.sh            # 除 node 外的全部
#   tools/build-iec-runtime.sh node       # 只编 node（V8，最久）
#   tools/build-iec-runtime.sh all        # 含 node
#
# 产物直接落在 third_party/bettersh/iec/platform/ohos/har/libs/arm64-v8a/，
# hvigor 会把它们合进 HAP 的 libs/arm64-v8a/。
#
# 源码来源：GitHub 直连在 WSL 里通常不可用（github.com 被墙，codeload 可用）。
# 因此 pcre2 / git / dropbear 用 git 克隆的，请在 Windows 侧先克隆到
# iec/thirdparty/ 下（scripts/optional/build_*.sh 只检查目录存在）。
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
IEC="$HERE/third_party/bettersh/iec"
: "${OHOS_SDK:?set OHOS_SDK to the Linux OHOS SDK (native/sysroot must exist)}"
export OHOS_SDK

# github.com 不通时，zlib 的 release 下载改走 codeload（内容相同）。
export IEC_ZLIB_URL="${IEC_ZLIB_URL:-https://codeload.github.com/madler/zlib/tar.gz/refs/tags/v1.3.1}"

cd "$IEC"

build_deps() {
	bash ./scripts/optional/build_zlib.sh
	bash ./scripts/optional/build_openssl.sh
	bash ./scripts/optional/build_pcre2.sh
	bash ./scripts/optional/build_curl.sh
	bash ./scripts/build_libarchive.sh
	bash ./scripts/optional/build_git.sh
	bash ./scripts/optional/build_dropbear.sh
}

# 自写/依赖 shim 的补充命令：nc、hexdump、diff 先产出 shim 对象，后面的命令复用。
# 统一用 `bash <脚本>` 调用：iec 下的脚本在仓库里没有可执行位（Windows 检出也没有），
# 直接 ./xxx 会 permission denied。
build_commands() {
	bash ./scripts/build_extra_commands.sh
	bash ./scripts/optional/build_jq.sh
	bash ./scripts/optional/build_curlcmd.sh
	bash ./scripts/optional/build_bc.sh
	bash ./scripts/optional/build_sftp.sh
}

build_node() {
	bash ./scripts/optional/build_node.sh all
}

case "${1:-deps}" in
	deps) build_deps; build_commands ;;
	node) build_node ;;
	all)  build_deps; build_commands; build_node ;;
	*) echo "usage: $0 [deps|node|all]" >&2; exit 2 ;;
esac

echo
echo "==> libs now in $IEC/platform/ohos/har/libs/arm64-v8a:"
ls -lh "$IEC/platform/ohos/har/libs/arm64-v8a"
