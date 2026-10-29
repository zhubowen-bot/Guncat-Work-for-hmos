# CMakeLists.txt — build the two artifacts needed to exercise the services.
#
# This is the test build, not a replacement for the Makefile: it produces
#   dist/iec_server          the tty + exec servers
#   dist/libiec_preload.so   the client-side shim in LD_PRELOAD form
# both under the CMake binary directory, so they can be copied to a test host
# or device together. `libiec_preload.so` is deliberately named differently
# from the Makefile's `libiec.so`: a stale artifact from the other build system
# cannot be picked up by accident.
#
#   cmake -S . -B build-cmake
#   cmake --build build-cmake -j
#
# The fake root and the qemu objects are data, not build outputs. Their paths
# are compiled into the server; override them for an installed tree with
#   -DIEC_FAKE_SYSROOT=... -DIEC_QEMU_DIR=...
cmake_minimum_required(VERSION 3.16)
project(iec VERSION 0.1.0 LANGUAGES C CXX ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Keep the two test artifacts together, mirroring the Makefile's dist/.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/dist")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/dist")

set(IEC_FAKE_SYSROOT "${CMAKE_CURRENT_SOURCE_DIR}/dist/fake_sysroot"
    CACHE PATH "Where absolute paths are rewritten when the PATH capability is 0")
set(IEC_QEMU_DIR "${CMAKE_CURRENT_SOURCE_DIR}/dist/qemu"
    CACHE PATH "Directory holding libqemu-<guest>.so")
set(IEC_PINNED_CAPS "0x11000"
    CACHE STRING "Capability word pinned by main.cpp; e.g. 0x11032 to exercise kLoader")

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
    set(IEC_GUEST_SWITCH loader/guest_switch_x86_64.S)
else()
    set(IEC_GUEST_SWITCH loader/guest_switch_aarch64.S)
endif()

set(IEC_INCLUDES
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/common"
    "${CMAKE_CURRENT_SOURCE_DIR}/loader")

# ── caps ──────────────────────────────────────────────────────────────────
# A separate object so the OHOS HAR can reuse it without pulling in either the
# server or the preload shim. Logger rides along because caps logs its result.
add_library(iec_caps STATIC exec/caps.cpp logger/logger.cpp)
target_include_directories(iec_caps PUBLIC ${IEC_INCLUDES})
target_compile_definitions(iec_caps PRIVATE _GNU_SOURCE)
target_compile_options(iec_caps PRIVATE -Wall)
set_target_properties(iec_caps PROPERTIES POSITION_INDEPENDENT_CODE ON)

# ── server ────────────────────────────────────────────────────────────────
add_executable(iec_server
    main.cpp
    tty/tty_server.cpp
    exec/exec_server.cpp
    exec/exec_ncp.cpp
    exec/path_resolver.cpp
    fs/resolver.c
    exec/exec_loader.cpp
    loader/loader.cpp
    ${IEC_GUEST_SWITCH}
    exec/exec_so.cpp
    exec/exec_qemu.cpp
    exec/exec_shebang.cpp
    exec/elf.cpp
    common/proc.c
    common/sock_server.cpp)

target_include_directories(iec_server PRIVATE ${IEC_INCLUDES})
target_compile_definitions(iec_server PRIVATE
    _GNU_SOURCE
    IEC_PINNED_CAPS=${IEC_PINNED_CAPS}
    "FAKE_SYSROOT=\"${IEC_FAKE_SYSROOT}\""
    "PATH_QEMU_X86_64_SO=\"${IEC_QEMU_DIR}/libqemu-x86_64.so\""
    "PATH_QEMU_AARCH64_SO=\"${IEC_QEMU_DIR}/libqemu-aarch64.so\"")
target_compile_options(iec_server PRIVATE -Wall)
target_link_libraries(iec_server PRIVATE iec_caps dl pthread)

# ── preload shim ──────────────────────────────────────────────────────────
# tty/shim.c, exec/shim.c and fs/shim.c are the client side; rpc.c and
# sock_client.c are shared by all of them, and must be compiled in: an
# LD_PRELOAD object cannot expect the host to provide them.
add_library(iec_preload SHARED
    tty/shim.c
    exec/shim.c
    fs/shim.c
    misc/getpass.c
    misc/account.c
    common/rpc.c
    common/sock_client.c)

target_include_directories(iec_preload PRIVATE ${IEC_INCLUDES})
target_compile_definitions(iec_preload PRIVATE
    INT_PRELOAD
    IEC_SHIM_MERGED_OPEN
    _GNU_SOURCE)
target_compile_options(iec_preload PRIVATE -Wall)
target_link_libraries(iec_preload PRIVATE dl)

set_target_properties(iec_preload PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "iec_preload")
