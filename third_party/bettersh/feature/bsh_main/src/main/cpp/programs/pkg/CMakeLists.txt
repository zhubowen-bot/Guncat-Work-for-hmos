# programs/pkg/CMakeLists.txt — pkg 命令 so（包管理器）
#
# 这里**连带 mbedTLS 一起编**：不另写 build_mbedtls.sh，mbedTLS 的源码直接在这个
# CMakeLists 里编成静态库、链进 libpkg.so。好处是它跟其它 native 目标用同一套
# OHOS clang + sysroot + 同一个 CMake configure，配置只写在这一处；坏处是 HAP 的
# native 构建从此依赖 thirdparty/mbedtls 已初始化（git submodule update --init）。
#
# mbedTLS 用**默认配置**（include/mbedtls/mbedtls_config.h）——先保证能过、功能齐；
# 要瘦身以后再加 MBEDTLS_CONFIG_FILE 指到本目录里的裁剪版配置。
#
# 依赖关系：feature/bsh_main/src/main/cpp/CMakeLists.txt 里 add_subdirectory(programs/pkg)。

# 仓库根：从 CMake 源根(=<模块>/src/main/cpp)逐级向上找含 thirdparty/ 的那一层。
# 不写死 `../../../../` 是因为分包后 CMake 源根多了一层(feature/bsh_main/...)，
# 写死的相对层数会因为挪模块而静默指错地方。
set(BSH_REPO_ROOT "${CMAKE_SOURCE_DIR}")
while(NOT EXISTS "${BSH_REPO_ROOT}/thirdparty")
    get_filename_component(BSH_REPO_ROOT "${BSH_REPO_ROOT}/.." ABSOLUTE)
    if(BSH_REPO_ROOT STREQUAL "/")
        message(FATAL_ERROR "从 ${CMAKE_SOURCE_DIR} 向上找不到含 thirdparty/ 的仓库根")
    endif()
endwhile()

set(MBEDTLS_DIR "${BSH_REPO_ROOT}/thirdparty/mbedtls")
if(NOT EXISTS "${MBEDTLS_DIR}/library/ssl_client.c")
    message(FATAL_ERROR
        "缺 mbedTLS 源码：${MBEDTLS_DIR}\n"
        "  先跑：git submodule update --init thirdparty/mbedtls")
endif()

file(GLOB MBEDTLS_SRC "${MBEDTLS_DIR}/library/*.c")

add_library(bsh_mbedtls STATIC ${MBEDTLS_SRC})
target_include_directories(bsh_mbedtls PUBLIC
    "${MBEDTLS_DIR}/include"
    "${MBEDTLS_DIR}/library")
# 第三方源码：不跟着本工程的告警口径走（默认 mbedTLS 有一堆 -Wunused 之类）
target_compile_options(bsh_mbedtls PRIVATE -w)
set_target_properties(bsh_mbedtls PROPERTIES POSITION_INDEPENDENT_CODE ON)

# ── zstd：只要**解压**那一半 ────────────────────────────────────────────
# 包按 tar.zst 发（1.8 GiB 的 SDK 树压到 242 MiB），而 bsh_tar 只认未压缩 tar，
# 所以先解成 .tar 再解包。只编 decompress + 少数 common：compress/dictBuilder/
# legacy/多线程一律不编（pool.c/threading.c 是 MT 才需要的，去掉能少两处报错）。
set(ZSTD_DIR "${BSH_REPO_ROOT}/thirdparty/zstd")
if(NOT EXISTS "${ZSTD_DIR}/lib/zstd.h")
    message(FATAL_ERROR
        "缺 zstd 源码：${ZSTD_DIR}\n"
        "  先跑：git submodule update --init thirdparty/zstd")
endif()

file(GLOB ZSTD_COMMON "${ZSTD_DIR}/lib/common/*.c")
file(GLOB ZSTD_DECOMP "${ZSTD_DIR}/lib/decompress/*.c")
list(REMOVE_ITEM ZSTD_COMMON
    "${ZSTD_DIR}/lib/common/pool.c"
    "${ZSTD_DIR}/lib/common/threading.c")

add_library(bsh_zstd STATIC ${ZSTD_COMMON} ${ZSTD_DECOMP})
target_include_directories(bsh_zstd PUBLIC
    "${ZSTD_DIR}/lib"
    "${ZSTD_DIR}/lib/common")
target_compile_definitions(bsh_zstd PRIVATE ZSTD_LEGACY_SUPPORT=0 ZSTD_DISABLE_ASM)
# ZSTD_DISABLE_ASM：x86_64 上 zstd 的快解路径要 huf_decompress_amd64.S，而我们只 glob
# 了 *.c（aarch64 用不到那段汇编）。要支持 NATIVE_ARCH=x86_64 的 HAP，要么把 .S 也编进去
# （还得 enable_language(ASM)），要么关掉快解路径 —— 这里选后者：解压慢百分之几，
# 但少一个"换个架构就链接失败"的坑。
target_compile_options(bsh_zstd PRIVATE -w)
set_target_properties(bsh_zstd PROPERTIES POSITION_INDEPENDENT_CODE ON)

# ── zlib：只要 **inflate** 那一半 ────────────────────────────────────────
# apt 要读 Ubuntu 的包索引 Packages.gz（索引只提供 .gz 与 .xz，没有 zst），所以得有
# 一个 gzip 解压器。thirdparty/zlib 本来就在仓库里（好几个构建脚本在用），直接编进来
# 比引一套 liblzma 便宜得多（那要新加一个 submodule）。
# 只挑 inflate 需要的 6 个 .c：gzip 模式下 windowBits 会带 16，inflate 内部要用
# crc32/adler32 校验，所以这两个也得进来；gz* 那套文件读写 API 我们不用。
set(ZLIB_DIR "${BSH_REPO_ROOT}/thirdparty/zlib")
if(NOT EXISTS "${ZLIB_DIR}/zlib.h")
    message(FATAL_ERROR "缺 zlib 源码：${ZLIB_DIR}")
endif()

add_library(bsh_zlib STATIC
    "${ZLIB_DIR}/adler32.c"
    "${ZLIB_DIR}/crc32.c"
    "${ZLIB_DIR}/inffast.c"
    "${ZLIB_DIR}/inflate.c"
    "${ZLIB_DIR}/inftrees.c"
    "${ZLIB_DIR}/zutil.c")
target_include_directories(bsh_zlib PUBLIC "${ZLIB_DIR}")
target_compile_options(bsh_zlib PRIVATE -w)
set_target_properties(bsh_zlib PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(pkg SHARED
    pkg_main.c
    bsh_http.c
    bsh_tar.c
    bsh_zstd.c
    bsh_json.c
    # `zstd` 命令（只做解压）跟 pkg 共用这个 so：解压那半个 libzstd 已经在这儿了，
    # 另建目标会把它再编一遍。见 zstd_main.c 的说明。
    zstd_main.c
    # ── apt（见 apt_main.c）────────────────────────────────────────────
    # 同样是**共用**这个 so：apt 需要的 mbedTLS / bsh_http / bsh_tar / bsh_zstd /
    # bsh_json 全都已经链在这里了，新加的只有 zlib（上面的 bsh_zlib）与下面四个源。
    # 另建 libapt.so 意味着 mbedTLS + zstd 再编一份（约 +500 KB HAP）。
    apt_main.c
    bsh_deb.c
    bsh_gzip.c
    bsh_pkgindex.c
    bsh_depends.c
    # xz 解压：代码是从 toybox 的 xzcat.c 提取的 xz-embedded（public domain，
    # 见 bsh_xz.c 的文件头）。个别老 .deb 两个成员都是 .xz，没有它那个包装不上。
    bsh_xz.c)
target_include_directories(pkg PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_SOURCE_DIR}")            # common/bsh_paths.h
# bsh_xz.c 是第三方提取的代码（toybox/kernel 风格），不跟着本工程的告警口径走
set_source_files_properties(bsh_xz.c PROPERTIES COMPILE_OPTIONS "-w")
target_link_libraries(pkg PRIVATE bsh_mbedtls bsh_zstd bsh_zlib)
