#!/bin/bash
# build_haptools.sh — 把 OHOS 的 C++ 版**签名工具**与**打包工具**交叉编成 aarch64 静态可执行
# 文件，再编一个动态的 `java` 转发壳，打成一个能给 pkg 发的包（`haptools`）。
#
# ── 为什么是这两个 ──────────────────────────────────────────────────────
# 设备内自举流水线跑到 @SignHap / @PackageHap 就停。hvigor 这两步不是 JS 干的，而是 fork
# 出
#     java -Dfile.encoding=utf-8 -jar <SDK>/.../hap-sign-tool.jar sign-app ...
#     java -Dfile.encoding=utf-8 -jar <SDK>/.../app_packing_tool.jar --mode hap ...
# 而沙箱里的 JVM 起不来：Error occurred during initialization of VM /
# "Failed to mark memory page as executable" —— 当前应用没有 jit 权限，沙箱拒绝 RW→RX 的
# 可执行内存（同一类限制见 scripts/glibc-ohos/README.md）。这台设备缺的不是能力，而是
# "一个能在无 jit 沙箱里跑起来的原生执行体"（详见 scripts/haptools-ohos/README.md）。
#
# ── 修法 ────────────────────────────────────────────────────────────────
# 1) developtools_hapsigner 的 **C++ 版**签名工具 → hap-sign-tool，静态 aarch64（musl）；
# 2) developtools_packing_tool 的 **C++ 版**打包工具 → app_packing_tool，同样静态；
#    两者 readelf 上 Type=EXEC、无 PT_INTERP、无 DT_NEEDED，设备里由 elfloader 装进匿名
#    内存执行（与先例 build/hapsigntool_cpp/build-aarch64.sh 一个路子）。
# 3) 一个动态的 usr/bin/java 转发壳：认 `-jar`，把已知的 jar 换到上面的原生工具
#    （javawrap/javawrap.c；**为什么它必须动态**见该文件头与 README）。
#
# 上游 clone 到 thirdparty/，**只读**：编译在 build/haptools/<tool>/src 的副本上做，
# patches/ 里的补丁打在副本上。
#
# ── 阶段 ────────────────────────────────────────────────────────────────
#   src       git clone 两个上游仓到 thirdparty/（已存在则跳过；不改远端、不 pull）
#   deps      zlib + openssl 静态库；**默认复用 build/hapsigntool_cpp/aarch64/sysroot**
#             里已编好的那份（同工具链同 ABI），不存在才自己编
#   build     编出 out/{hap-sign-tool,app_packing_tool}
#   javawrap  编出 out/java（动态 musl，见 javawrap/javawrap.c 头注释）
#   pack      产出 dist/pkgs/haptools.tar.zst（顶层只有 usr/bin/{三个文件}，无软链）
#   all       src + deps + build + javawrap + pack
#
# 用法：scripts/build_haptools.sh [src|deps|build|javawrap|pack|all]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PHASE="${1:-all}"

SPEC="$SCRIPT_DIR/haptools-ohos"                 # 构建期资产（compat/patches/third_party/javawrap）
BUILD="$ROOT/build/haptools"
OUT="$BUILD/out"
OUT_PKG="$ROOT/dist/pkgs/haptools.tar.zst"
STAGE="$BUILD/pkg"

# 上游（**只读参考**；src 阶段 clone 到这里，build 阶段整棵拷进 $BUILD/<tool>/src 再打补丁）
UP_HAPSIGNER="$ROOT/thirdparty/developtools_hapsigner"
UP_PACKING="$ROOT/thirdparty/developtools_packing_tool"
GITCODE_HAPSIGNER="${GITCODE_HAPSIGNER:-https://gitcode.com/openharmony/developtools_hapsigner.git}"
GITCODE_PACKING="${GITCODE_PACKING:-https://gitcode.com/openharmony/developtools_packing_tool.git}"

# 交叉工具链（与 build/hapsigntool_cpp/build-aarch64.sh、build_packing_tool.sh 同一套）
TC="${MUSL_TOOLCHAIN:-/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross}"
CROSS="$TC/bin/aarch64-linux-musl-"

# openssl/zlib 静态库安装根：默认复用 hapsigntool_cpp 编好的那份（同工具链同 ABI）
PREFIX="${OPENSSL_PREFIX:-$ROOT/build/hapsigntool_cpp/aarch64/sysroot}"
OPENSSL_VERSION="3.0.13"
OPENSSL_SRC="${OPENSSL_SRC:-$BUILD/openssl-$OPENSSL_VERSION}"
OPENSSL_TARBALL="$BUILD/openssl-$OPENSSL_VERSION.tar.gz"
OPENSSL_URL="${OPENSSL_URL:-https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz}"

# 工具链自带 zlib 源码（packing_tool 的 minizip 直接用它的 contrib/minizip）
ZLIB_SRC="${ZLIB_SRC:-$ROOT/thirdparty/zlib}"

TRIPLE_FLAGS=(--target="$TARGET" --sysroot="$SYSROOT")

# ══════════════════════════════════════════════════════════════════
# src：clone 两个上游仓（幂等；不改远端、不 pull）
# ══════════════════════════════════════════════════════════════════
clone_upstream() {   # $1=url $2=目标目录 $3=显示名
    if [ -d "$2/.git" ]; then
        log "src：已有 $3（$2），跳过"
        return 0
    fi
    [ -d "$2" ] && err "src：$2 存在但不是 git 仓 —— 先移走它再重跑"
    log "src：git clone --depth 1 $1 → $2"
    mkdir -p "$(dirname "$2")"
    git clone --depth 1 "$1" "$2" || err "src：clone $3 失败（网络/代理？见 scripts/env.sh）"
}

# 把两个上游路径写进 .gitignore（照现有条目风格：一行说明 + 路径）。
# 幂等：已经写过就不重复追加。
ensure_gitignore() {
    local gi="$ROOT/.gitignore"
    [ -f "$gi" ] || err "找不到 $gi"
    if grep -qF '/thirdparty/developtools_hapsigner' "$gi"; then
        if ! grep -qF '/thirdparty/developtools_packing_tool' "$gi"; then
            echo '/thirdparty/developtools_packing_tool' >> "$gi"
        fi
        return 0
    fi
    log "src：往 .gitignore 追加两个上游源码路径"
    cat >> "$gi" <<'GI_EOF'

# OHOS 签名/打包工具的 C++ 源码（scripts/build_haptools.sh 的 src 阶段 git clone；
# 上游只读，补丁与编译都在 build/haptools/ 的源码副本上做）
/thirdparty/developtools_hapsigner
/thirdparty/developtools_packing_tool
GI_EOF
}

do_src() {
    clone_upstream "$GITCODE_HAPSIGNER" "$UP_HAPSIGNER" "developtools_hapsigner"
    clone_upstream "$GITCODE_PACKING" "$UP_PACKING" "developtools_packing_tool"
    ensure_gitignore
}

# ══════════════════════════════════════════════════════════════════
# deps：zlib + openssl 静态库
# ══════════════════════════════════════════════════════════════════
do_deps() {
    if [ -f "$PREFIX/lib/libcrypto.a" ] && [ -f "$PREFIX/lib/libz.a" ]; then
        log "deps：复用已编好的静态库（$PREFIX/lib：$(ls "$PREFIX/lib" | tr '\n' ' ')）"
        return 0
    fi
    [ -x "${CROSS}gcc" ] || err "deps：没有交叉 gcc：${CROSS}gcc"
    log "deps：没有可复用的 sysroot，自己编 zlib + openssl → $PREFIX"
    command -v perl >/dev/null 2>&1 || err "deps：编 openssl 需要 perl"
    command -v make >/dev/null 2>&1 || err "deps：需要 make"

    # zlib（static）
    mkdir -p "$BUILD/zlib-build"
    ( cd "$BUILD/zlib-build"
      CHOST=aarch64-linux-musl CC="${CROSS}gcc" \
          "$ZLIB_SRC/configure" --static --prefix="$PREFIX" >configure.log 2>&1
      make -j"$JOBS" libz.a >make.log 2>&1
      mkdir -p "$PREFIX/lib" "$PREFIX/include"
      cp libz.a "$PREFIX/lib/"
      cp "$ZLIB_SRC/zlib.h" "$ZLIB_SRC/zconf.h" "$PREFIX/include/" )

    # openssl（no-shared，只要 libcrypto 里的 md5/sha）
    if [ ! -d "$OPENSSL_SRC" ]; then
        # 优先用本仓 already-downloaded 的 openssl 源码（build_openssl.sh 的产物）
        local cand
        cand="$(ls -d "$ROOT"/thirdparty/openssl-*/ 2>/dev/null | head -1 || true)"
        if [ -n "$cand" ]; then
            OPENSSL_SRC="${cand%/}"
            log "deps：复用本仓已有 openssl 源码 $OPENSSL_SRC"
        else
            if [ ! -f "$OPENSSL_TARBALL" ]; then
                log "deps：下载 openssl-$OPENSSL_VERSION（走 scripts/env.sh 探测到的代理）"
                mkdir -p "$BUILD"
                curl -fL --retry 3 -o "$OPENSSL_TARBALL" "$OPENSSL_URL" \
                    || err "deps：下载失败 $OPENSSL_URL（可手动放一份到 $OPENSSL_TARBALL）"
            fi
            tar -xzf "$OPENSSL_TARBALL" -C "$BUILD"
        fi
    fi
    mkdir -p "$BUILD/openssl-build"
    ( cd "$BUILD/openssl-build"
      CC="${CROSS}gcc" perl "$OPENSSL_SRC/Configure" linux-aarch64 \
          --prefix="$PREFIX" --openssldir="$PREFIX/ssl" --libdir=lib \
          no-shared no-tests >configure.log 2>&1
      make -j"$JOBS" build_libs >make.log 2>&1
      make install_dev >install.log 2>&1 )
    log "deps：完成（$(ls -l "$PREFIX/lib/libcrypto.a" "$PREFIX/lib/libz.a" | awk '{print $9, $5}' | tr '\n' ' ')）"
}

# ══════════════════════════════════════════════════════════════════
# 通用：源码副本 + 补丁（幂等写法照 scripts/build_musl.sh 的 do_patch）
# ══════════════════════════════════════════════════════════════════
# 上游只读：整棵拷到 $BUILD/<tool>/src，patches/ 里每个补丁按"正向能打就打、已打过就跳过、
# 两边都不通就报错"处理。拷贝每次重来，副本永远干净。
prepare_src() {   # $1=上游子树 $2=副本目录 $3=显示名
    [ -d "$1" ] || err "缺上游源码 $1（先跑 src 阶段）"
    rm -rf "$2"
    mkdir -p "$2"
    cp -a "$1/." "$2/"
    log "build：源码副本 $3 → $2"
}

apply_patches() {   # $1=副本目录
    local dir="$1" p
    shopt -s nullglob
    for p in "$SPEC"/patches/*.patch; do
        if patch -p1 -d "$dir" --dry-run --silent < "$p" >/dev/null 2>&1; then
            log "build：打补丁 $(basename "$p")"
            patch -p1 -d "$dir" < "$p" >/dev/null
        elif patch -p1 -R -d "$dir" --dry-run --silent < "$p" >/dev/null 2>&1; then
            log "build：已是打过补丁的状态，跳过 $(basename "$p")"
        else
            shopt -u nullglob
            err "build：补丁既不能正向也不能反向应用（上游代码变过？）：$p"
        fi
    done
    shopt -u nullglob
}

# 逐 TU 并行编译 + 失败汇总 + 链接；读全局 NAMES（"lang:path"）、INCLUDES、CFLAGS、
# CXXFLAGS、LDFLAGS（与 build-aarch64.sh 同一套做法：日志非空即失败）。
compile_and_link() {   # $1=objdir $2=logdir $3=输出
    local objdir="$1" logdir="$2" out="$3"
    rm -rf "$logdir"
    mkdir -p "$objdir" "$logdir" "$(dirname "$out")"
    local -a OBJS=()
    local i=0 spec lang f obj
    for spec in "${NAMES[@]}"; do
        lang="${spec%%:*}"
        f="${spec#*:}"
        obj="$objdir/$(printf '%03d' "$i")_$(basename "$f" | tr -c 'A-Za-z0-9._-' '_').o"
        OBJS+=("$obj")
        if [ "$lang" = "cc" ]; then
            ( "$CC" "${CFLAGS[@]}" "${INCLUDES[@]}" -c "$f" -o "$obj" \
                >"$logdir/$(printf '%03d' "$i").log" 2>&1 ) &
        else
            ( "$CXX" "${CXXFLAGS[@]}" "${INCLUDES[@]}" -c "$f" -o "$obj" \
                >"$logdir/$(printf '%03d' "$i").log" 2>&1 ) &
        fi
        i=$((i + 1))
        while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
    done
    wait || true

    local failed=0 j=0
    for spec in "${NAMES[@]}"; do
        if [ -s "$logdir/$(printf '%03d' "$j").log" ]; then
            echo "=== 编译失败：${spec#*:}" >&2
            cat "$logdir/$(printf '%03d' "$j").log" >&2
            failed=$((failed + 1))
        fi
        j=$((j + 1))
    done
    [ "$failed" -eq 0 ] || err "$failed 个 TU 编译失败（日志在 $logdir）"

    log "build：链接 $out（${#NAMES[@]} 个 TU）"
    "$CXX" "${OBJS[@]}" "${LDFLAGS[@]}" -o "$out"
    "${CROSS}strip" "$out" 2>/dev/null || true
}

# ── 签名工具（hapsigntool_cpp）───────────────────────────────────────────
# 源清单逐条抄自 hapsigntool_cpp/BUILD.gn + 各模块 signature_tools_*.gni
# （与 build/hapsigntool_cpp/build-aarch64.sh 完全一致）。
build_hap_sign_tool() {
    local work="$BUILD/hapsigntool/src"
    local out="$OUT/hap-sign-tool"
    prepare_src "$UP_HAPSIGNER/hapsigntool_cpp" "$work" "hapsigntool_cpp"
    # 签名工具没有补丁：它需要的差异全在 compat/ 里（securec/cJSON/minizip + -include 前缀头），
    # patches/ 里那两个只针对打包工具的调用点（见 scripts/haptools-ohos/README.md）。
    local SRC="$work"

    INCLUDES=(
        "-I$SPEC/compat/hapsigntool"   # securec.h + host_compat_prefix.h
        "-I$SPEC/third_party"          # cJSON.h + contrib/minizip/unzip.h
        "-I$SRC/api/include" "-I$SRC/signer/include" "-I$SRC/utils/include"
        "-I$SRC/zip/include" "-I$SRC/codesigning/datastructure/include"
        "-I$SRC/codesigning/fsverity/include" "-I$SRC/codesigning/utils/include"
        "-I$SRC/codesigning/sign/include" "-I$SRC/common/include"
        "-I$SRC/hap/verify/include" "-I$SRC/hap/config/include"
        "-I$SRC/hap/entity/include" "-I$SRC/hap/provider/include"
        "-I$SRC/hap/sign/include" "-I$SRC/hap/utils/include"
        "-I$SRC/hap/ticket/include" "-I$SRC/profile/include" "-I$SRC/cmd/include"
        "-I$PREFIX/include"
    )
    local SRCS=(
        "$SRC/main.cpp" "$SRC/api/src/sign_tool_service_impl.cpp" "$SRC/api/src/cert_tools.cpp"
        "$SRC/signer/src/signer_factory.cpp" "$SRC/signer/src/local_signer.cpp"
        "$SRC/utils/src/cert_dn_utils.cpp" "$SRC/utils/src/verify_cert_openssl_utils.cpp"
        "$SRC/utils/src/file_utils.cpp" "$SRC/utils/src/key_store_helper.cpp"
        "$SRC/utils/src/hap_signer_block_utils.cpp" "$SRC/utils/src/string_utils.cpp"
        "$SRC/utils/src/verify_hap_openssl_utils.cpp" "$SRC/utils/src/byte_array_utils.cpp"
        "$SRC/utils/src/hash_utils.cpp"
        "$SRC/zip/src/central_directory.cpp" "$SRC/zip/src/data_descriptor.cpp"
        "$SRC/zip/src/endof_central_directory.cpp" "$SRC/zip/src/random_access_file_input.cpp"
        "$SRC/zip/src/random_access_file_output.cpp" "$SRC/zip/src/zip64_end_of_central_directory.cpp"
        "$SRC/zip/src/zip64_end_of_central_directory_locator.cpp" "$SRC/zip/src/zip64_extended_info.cpp"
        "$SRC/zip/src/zip_entry.cpp" "$SRC/zip/src/zip_entry_data.cpp"
        "$SRC/zip/src/zip_entry_header.cpp" "$SRC/zip/src/zip_signer.cpp" "$SRC/zip/src/zip_utils.cpp"
        "$SRC/codesigning/datastructure/src/code_sign_block.cpp"
        "$SRC/codesigning/datastructure/src/code_sign_block_header.cpp"
        "$SRC/codesigning/datastructure/src/extension.cpp"
        "$SRC/codesigning/datastructure/src/fs_verity_info_segment.cpp"
        "$SRC/codesigning/datastructure/src/hap_info_segment.cpp"
        "$SRC/codesigning/datastructure/src/merkle_tree_extension.cpp"
        "$SRC/codesigning/datastructure/src/native_lib_info_segment.cpp"
        "$SRC/codesigning/datastructure/src/segment_header.cpp"
        "$SRC/codesigning/datastructure/src/sign_info.cpp"
        "$SRC/codesigning/datastructure/src/signed_file_pos.cpp"
        "$SRC/codesigning/datastructure/src/elf_sign_block.cpp"
        "$SRC/codesigning/datastructure/src/unzip_handle_param.cpp"
        "$SRC/codesigning/fsverity/src/fs_verity_descriptor.cpp"
        "$SRC/codesigning/fsverity/src/fs_verity_digest.cpp"
        "$SRC/codesigning/fsverity/src/fs_verity_generator.cpp"
        "$SRC/codesigning/fsverity/src/fs_verity_hash_algorithm.cpp"
        "$SRC/codesigning/fsverity/src/merkle_tree_builder.cpp"
        "$SRC/codesigning/fsverity/src/fs_verity_descriptor_with_sign.cpp"
        "$SRC/codesigning/utils/src/fs_digest_utils.cpp" "$SRC/codesigning/utils/src/cms_utils.cpp"
        "$SRC/codesigning/sign/src/bc_signeddata_generator.cpp"
        "$SRC/codesigning/sign/src/code_signing.cpp"
        "$SRC/codesigning/sign/src/verify_code_signature.cpp"
        "$SRC/common/src/byte_buffer_data_source.cpp" "$SRC/common/src/byte_buffer.cpp"
        "$SRC/common/src/file_data_source.cpp" "$SRC/common/src/random_access_file.cpp"
        "$SRC/common/src/digest_parameter.cpp" "$SRC/common/src/digest_common.cpp"
        "$SRC/common/src/localization_adapter.cpp" "$SRC/common/src/options.cpp"
        "$SRC/common/src/password_guard.cpp"
        "$SRC/hap/verify/src/verify_hap.cpp" "$SRC/hap/verify/src/verify_bin.cpp"
        "$SRC/hap/verify/src/verify_elf.cpp" "$SRC/hap/config/src/signer_config.cpp"
        "$SRC/hap/entity/src/content_digest_algorithm.cpp" "$SRC/hap/entity/src/param_constants.cpp"
        "$SRC/hap/entity/src/signature_algorithm_helper.cpp" "$SRC/hap/entity/src/block_data.cpp"
        "$SRC/hap/entity/src/block_head.cpp" "$SRC/hap/entity/src/sign_head.cpp"
        "$SRC/hap/entity/src/sign_block_info.cpp" "$SRC/hap/entity/src/sign_content_info.cpp"
        "$SRC/hap/entity/src/sign_block_data.cpp" "$SRC/hap/entity/src/signature_block_types.cpp"
        "$SRC/hap/entity/src/signing_block.cpp" "$SRC/hap/provider/src/local_sign_provider.cpp"
        "$SRC/hap/provider/src/remote_sign_provider.cpp" "$SRC/hap/provider/src/sign_provider.cpp"
        "$SRC/hap/sign/src/sign_hap.cpp" "$SRC/hap/sign/src/sign_bin.cpp"
        "$SRC/hap/sign/src/sign_elf.cpp" "$SRC/hap/utils/src/hap_utils.cpp"
        "$SRC/hap/utils/src/dynamic_lib_handle.cpp" "$SRC/hap/sign/src/bc_pkcs7_generator.cpp"
        "$SRC/hap/ticket/src/ticket_staple.cpp" "$SRC/hap/ticket/src/ticket_validate.cpp"
        "$SRC/profile/src/profile_info.cpp" "$SRC/profile/src/profile_verify.cpp"
        "$SRC/profile/src/pkcs7_data.cpp" "$SRC/profile/src/profile_sign_tool.cpp"
        "$SRC/cmd/src/cmd_util.cpp" "$SRC/cmd/src/params_run_tool.cpp"
        "$SRC/cmd/src/params_trust_list.cpp" "$SRC/cmd/src/params.cpp"
    )
    local CXXSRC=(
        "$SPEC/compat/hapsigntool/securec.cpp"
    )
    local CSRC=(
        "$SPEC/third_party/cJSON.c"
        "$SPEC/third_party/contrib/minizip/unzip.c"
        "$SPEC/third_party/contrib/minizip/ioapi.c"
    )
    local m
    for m in "${SRCS[@]}" "${CXXSRC[@]}" "${CSRC[@]}"; do
        [ -f "$m" ] || err "build：缺源文件 $m"
    done

    CC="${CROSS}gcc"
    CXX="${CROSS}g++"
    # -static/-no-pie：数据目录不允许可执行映射，这个程序由 elfloader 装进匿名内存再跳进去
    #   执行，静态 + 无解释器最省事，宿主机上也能直接用 qemu-aarch64 跑（不需要任何 .so）。
    # -fno-rtti：全树没有 dynamic_cast/typeid（与上游 GN 口径一致）。
    # -include host_compat_prefix.h：上游几个头依赖 OHOS 工具链的传递包含图才有的
    #   <vector>/<filesystem> 等，musl-gcc 的图谱里没有；只补声明不补行为。
    CFLAGS=(-O2 -g0 -w -static -fno-pie)
    CXXFLAGS=(-std=c++17 -fno-rtti -O2 -g0 -w -static -fno-pie
              "-D__FILE_NAME__=__FILE__"
              -include "$SPEC/compat/hapsigntool/host_compat_prefix.h")
    LDFLAGS=(-static -no-pie -L"$PREFIX/lib" -lssl -lcrypto -lz -lpthread -ldl)

    local NAMES=()
    local f
    for f in "${SRCS[@]}" "${CXXSRC[@]}"; do NAMES+=("cxx:$f"); done
    for f in "${CSRC[@]}"; do NAMES+=("cc:$f"); done

    compile_and_link "$BUILD/hapsigntool/obj" "$BUILD/hapsigntool/logs" "$out"
    log "build：$(du -h "$out" | cut -f1)  $out"
}

# ── 打包工具（packing_tool/frameworks）───────────────────────────────────
# 源清单逐条抄自 packing_tool/frameworks/BUILD.gn 的 ohos_executable("ohos_packing_tool")。
build_packing_tool() {
    local work="$BUILD/packing_tool/src"
    local out="$OUT/app_packing_tool"
    prepare_src "$UP_PACKING/packing_tool/frameworks" "$work" "packing_tool/frameworks"
    apply_patches "$work"
    local SRC="$work"
    local COMPAT="$SPEC/compat/packing_tool"
    local TP="$SPEC/third_party"
    local MINIZIP="$ZLIB_SRC/contrib/minizip"

    INCLUDES=(
        "-I$SRC/include" "-I$SRC/include/json" "-I$SRC/include/error" "-I$SRC/include/dedup"
        "-I$COMPAT"          # securec.h + nlohmann/json.hpp
        "-I$TP"              # cJSON.h
        "-I$ZLIB_SRC"        # "contrib/minizip/{zip,unzip}.h" 由 zlib 根解析
        "-I$MINIZIP"
        "-I$PREFIX/include"  # openssl
    )
    local SRCS=(
        "$SRC/src/app_packager.cpp" "$SRC/src/appqf_packager.cpp"
        "$SRC/src/dedup/device_calculator.cpp" "$SRC/src/dedup/exact_solver.cpp"
        "$SRC/src/dedup/greedy_solver.cpp" "$SRC/src/dedup/module_calculator.cpp"
        "$SRC/src/dedup/report_generator.cpp" "$SRC/src/dedup/so_deduplicator.cpp"
        "$SRC/src/error/error_msg.cpp" "$SRC/src/error/packing_tool_err_msg.cpp"
        "$SRC/src/error/scan_error_enum.cpp" "$SRC/src/fast_app_packager.cpp"
        "$SRC/src/general_normalize.cpp" "$SRC/src/hap_packager.cpp" "$SRC/src/hqf_packager.cpp"
        "$SRC/src/hqf_verify.cpp" "$SRC/src/hsp_packager.cpp"
        "$SRC/src/json/distro_filter.cpp" "$SRC/src/json/general_normalize_version_utils.cpp"
        "$SRC/src/json/hap_verify_info.cpp" "$SRC/src/json/hap_verify_utils.cpp"
        "$SRC/src/json/json_utils.cpp" "$SRC/src/json/module_json.cpp"
        "$SRC/src/json/module_json_fa.cpp" "$SRC/src/json/module_json_stage.cpp"
        "$SRC/src/json/module_json_utils.cpp" "$SRC/src/json/normalize_version_utils.cpp"
        "$SRC/src/json/pack_info.cpp" "$SRC/src/json/pack_info_utils.cpp"
        "$SRC/src/json/patch_json.cpp" "$SRC/src/json/patch_json_utils.cpp" "$SRC/src/json/pt_json.cpp"
        "$SRC/src/log.cpp" "$SRC/src/main.cpp" "$SRC/src/multiapp_packager.cpp"
        "$SRC/src/package_normalize.cpp" "$SRC/src/packager.cpp" "$SRC/src/res_packager.cpp"
        "$SRC/src/scan_statdulpicate.cpp" "$SRC/src/shell_command.cpp"
        "$SRC/src/skill_pack_helper.cpp" "$SRC/src/unzip_wrapper.cpp" "$SRC/src/utils.cpp"
        "$SRC/src/version_normalize.cpp" "$SRC/src/zip_utils.cpp" "$SRC/src/zip_wrapper.cpp"
        "$SRC/src/incremental_pack.cpp"
    )
    local CSRC=(
        "$TP/cJSON.c" "$MINIZIP/zip.c" "$MINIZIP/unzip.c" "$MINIZIP/ioapi.c"
    )
    local m
    for m in "${SRCS[@]}" "${CSRC[@]}"; do
        [ -f "$m" ] || err "build：缺源文件 $m"
    done

    CC="${CROSS}gcc"
    CXX="${CROSS}g++"
    # -fexceptions：上游 BUILD.gn 就开了（general_normalize.cpp 等大量 try/catch）。
    CFLAGS=(-O2 -g0 -w -static -fno-pie)
    CXXFLAGS=(-std=c++17 -fno-rtti -fexceptions -O2 -g0 -w -static -fno-pie
              -include "$COMPAT/host_compat_prefix.h")
    LDFLAGS=(-static -no-pie -L"$PREFIX/lib" -lcrypto -lz -lpthread -ldl)

    local NAMES=()
    local f
    NAMES+=("cxx:$COMPAT/securec.cpp")
    for f in "${SRCS[@]}"; do NAMES+=("cxx:$f"); done
    for f in "${CSRC[@]}"; do NAMES+=("cc:$f"); done

    compile_and_link "$BUILD/packing_tool/obj" "$BUILD/packing_tool/logs" "$out"
    log "build：$(du -h "$out" | cut -f1)  $out"
}

do_build() {
    [ -x "${CROSS}g++" ] || err "build：没有交叉 g++：${CROSS}g++"
    build_hap_sign_tool
    build_packing_tool
}

# ══════════════════════════════════════════════════════════════════
# javawrap：动态 musl 的 usr/bin/java（转发壳）
# ══════════════════════════════════════════════════════════════════
# 用 OHOS SDK 的 clang + --target=aarch64-linux-ohos 编成**动态** guest。理由见
# javawrap/javawrap.c 头注释：exec 委托只对动态 guest 生效（LD_PRELOAD 符号插入），
# 静态 guest 的 execv 会直接打到内核的 EACCES 上。
# -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0：OHOS 头会把 FD_SET/FD_CLR 展开成 musl 里没有的
#   __fd_chk，而 bundle 里的 ld-musl-aarch64.so.1 是 vanilla musl（同 build_devtools.sh）。
do_javawrap() {
    [ -x "$CLANG" ] || err "javawrap：缺 OHOS SDK clang：$CLANG"
    [ -d "$SYSROOT" ] || err "javawrap：缺 SDK sysroot：$SYSROOT"
    mkdir -p "$OUT"
    log "javawrap：clang --target=$TARGET（动态 musl）→ $OUT/java"
    "$CLANG" "${TRIPLE_FLAGS[@]}" \
        -O2 -g0 -Wall -Wextra \
        -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
        -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1 -Wl,-z,now \
        -o "$OUT/java" "$SPEC/javawrap/javawrap.c"
    "$CLANG_DIR/llvm-strip" --strip-all "$OUT/java" 2>/dev/null || true
    log "javawrap：$(du -h "$OUT/java" | cut -f1)  $OUT/java"
}

# ══════════════════════════════════════════════════════════════════
# pack：dist/pkgs/haptools.tar.zst（顶层只有 usr/bin/{三个文件}）
# ══════════════════════════════════════════════════════════════════
# 三条约束（照 scripts/pack_hdc.sh / pack_ohos_sdk_prune.sh）：
#   1) **不能有软链**：pkg 的 tar 解包器（programs/pkg/bsh_tar.c）只认普通文件/目录，
#      沙箱里也建不出软链。这里三个都是真文件，自检兜底。
#   2) **只有这三个**：两个工具是静态 guest，java 是动态 guest —— 它的解释器由 bundle libs
#      提供（procmgr 按 PT_INTERP 的 basename 找），包里不用也不能再塞一份 ld-musl。
#   3) **自检**：静态那对必须无 PT_INTERP / 无 DT_NEEDED；动态的 java NEEDED 必须都能
#      由应用自己提供 —— 免得打出"装上去才发现缺库"的包。
RE="${CLANG_DIR}/llvm-readelf"
[ -x "$RE" ] || RE=readelf
RE_STATIC="${CROSS}readelf"
[ -x "$RE_STATIC" ] || RE_STATIC=readelf

do_pack() {
    local b
    for b in hap-sign-tool app_packing_tool java; do
        [ -f "$OUT/$b" ] || err "pack：缺 $OUT/$b（先跑 build / javawrap）"
    done
    command -v zstd >/dev/null 2>&1 || err "pack：缺 zstd（apt install zstd）"

    log "pack：铺暂存树 → $STAGE"
    rm -rf "$STAGE"
    mkdir -p "$STAGE/usr/bin"
    for b in hap-sign-tool app_packing_tool java; do
        cp -p "$OUT/$b" "$STAGE/usr/bin/$b"
        chmod 0755 "$STAGE/usr/bin/$b"
    done

    log "pack：自检 —— 两个静态工具必须 Type=EXEC、无 PT_INTERP、无 DT_NEEDED"
    local b t prog rd
    for b in hap-sign-tool app_packing_tool; do
        t="$("$RE_STATIC" -h "$STAGE/usr/bin/$b" | sed -n 's/.*Type: *\([A-Z_]*\).*/\1/p')"
        [ "$t" = "EXEC" ] || err "pack：$b 不是 ET_EXEC（$t）—— 带了解释器/是 PIE"
        # 先整段读出再匹配：`readelf | grep -q` 在 set -o pipefail 下，grep 提前退出会把
        # readelf 打成 SIGPIPE(141)，整个管道就"失败"，错误反而被吞掉（pack_hdc 里踩过）。
        rd="$("$RE_STATIC" -l "$STAGE/usr/bin/$b")"
        case "$rd" in *INTERP*) err "pack：$b 有 PT_INTERP（不是纯静态）" ;; esac
        rd="$("$RE_STATIC" -d "$STAGE/usr/bin/$b" 2>/dev/null || true)"
        case "$rd" in *NEEDED*) err "pack：$b 有 DT_NEEDED（不是纯静态）" ;; esac
        log "        $b  OK（EXEC / 无 PT_INTERP / 无 DT_NEEDED）"
    done

    log "pack：自检 —— java 是动态 guest，NEEDED 必须由应用自己提供"
    local need nneed=0
    while read -r need; do
        [ -n "$need" ] || continue
        case "$need" in
            libc.so|libc.so.*|ld-musl-aarch64.so.1|libdl.so|libm.so|libpthread.so) ;;
            *) err "pack：java 需要 $need —— 本包没有，也不是 bundle libs 会提供的那几个" ;;
        esac
        nneed=$((nneed + 1))
    done < <("$RE" -d "$STAGE/usr/bin/java" 2>/dev/null | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF); print $NF}')
    log "        java  OK（$nneed 个 NEEDED，全在提供方）"

    log "pack：自检 —— 暂存树里不能有软链"
    if [ -n "$(find "$STAGE" -type l)" ]; then
        err "pack：暂存树里有软链，pkg 装不了"
    fi
    log "        通过：全是普通文件/目录"

    log "pack：打包（zstd -19 -T$JOBS）"
    mkdir -p "$(dirname "$OUT_PKG")"
    tar -C "$STAGE" -c usr | zstd -q -f -19 -T"$JOBS" -o "$OUT_PKG"
    [ -s "$OUT_PKG" ] || err "pack：包是空的"

    echo
    log "包里的内容："
    tar --zstd -tvf "$OUT_PKG" | sed 's/^/    /'
    echo
    log "$(numfmt --to=iec "$(du -sb "$STAGE" | cut -f1)")（未压缩） → $(numfmt --to=iec "$(stat -c%s "$OUT_PKG")")  $OUT_PKG"
    echo
    echo "index.json 需要的三项："
    echo "  \"file\"   : $(basename "$OUT_PKG")"
    echo "  \"size\"   : $(stat -c%s "$OUT_PKG")"
    echo "  \"sha256\" : $(sha256sum "$OUT_PKG" | cut -d' ' -f1)"
}

case "$PHASE" in
    src)      do_src ;;
    deps)     do_deps ;;
    build)    do_build ;;
    javawrap) do_javawrap ;;
    pack)     do_pack ;;
    all)      do_src; do_deps; do_build; do_javawrap; do_pack ;;
    *)        err "未知阶段：$PHASE（可用：src|deps|build|javawrap|pack|all）" ;;
esac
