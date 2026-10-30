# CMake for the OHOS HAR: builds libiec_server.so from the capability probes
# and the tty/exec server sources in the repository root.
cmake_minimum_required(VERSION 3.5.0)
project(iec_har LANGUAGES C CXX ASM)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Reuse the root project's modules instead of copying them into the HAR. Only
# iec_caps is linked from there; EXCLUDE_FROM_ALL keeps the standalone server
# and the preload shim out of the HAP. The service sources are listed below
# because the executable target beside them owns main() and cannot be linked.
set(IEC_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../..")
add_subdirectory("${IEC_ROOT}" "${CMAKE_CURRENT_BINARY_DIR}/iec_root" EXCLUDE_FROM_ALL)

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
    set(IEC_GUEST_SWITCH "${IEC_ROOT}/loader/guest_switch_x86_64.S")
else()
    set(IEC_GUEST_SWITCH "${IEC_ROOT}/loader/guest_switch_aarch64.S")
endif()

# The CA bundle is embedded into the library as a generated header. Shipping it
# as a raw resource would leave a second extraction path in the app; this way
# the only copy is the one compiled in, and IecInstallCaBundle() writes it where
# git expects it.
find_program(IEC_PYTHON NAMES python3 python)
if(NOT IEC_PYTHON)
    message(FATAL_ERROR "python3 is required to embed assets/cacert.pem")
endif()
set(IEC_CA_SOURCE "${IEC_ROOT}/assets/cacert.pem")
set(IEC_EMBED_TOOL "${IEC_ROOT}/tools/embed_file.py")
set(IEC_CA_HEADER "${CMAKE_CURRENT_BINARY_DIR}/generated/cacert_pem.h")
add_custom_command(
    OUTPUT "${IEC_CA_HEADER}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/generated"
    COMMAND "${IEC_PYTHON}" "${IEC_EMBED_TOOL}" "${IEC_CA_SOURCE}"
            "${IEC_CA_HEADER}" iec_cacert_pem
    DEPENDS "${IEC_CA_SOURCE}" "${IEC_EMBED_TOOL}"
    COMMENT "Embedding assets/cacert.pem into cacert_pem.h")

add_library(iec_har SHARED
    napi_init.cpp
    exec_napi.cpp
    "${IEC_ROOT}/common/archive_extract.cpp"
    "${IEC_ROOT}/common/ca_bundle.cpp"
    "${IEC_CA_HEADER}"
    "${IEC_ROOT}/tty/tty_server.cpp"
    "${IEC_ROOT}/exec/exec_server.cpp"
    "${IEC_ROOT}/exec/exec_route.cpp"
    "${IEC_ROOT}/exec/exec_session.cpp"
    "${IEC_ROOT}/exec/py_runner.cpp"
    "${IEC_ROOT}/exec/exec_ncp.cpp"
    "${IEC_ROOT}/exec/path_resolver.cpp"
    "${IEC_ROOT}/exec/exec_loader.cpp"
    "${IEC_ROOT}/exec/exec_so.cpp"
    "${IEC_ROOT}/exec/exec_qemu.cpp"
    "${IEC_ROOT}/exec/exec_shebang.cpp"
    "${IEC_ROOT}/exec/elf.cpp"
    "${IEC_ROOT}/fs/resolver.c"
    "${IEC_ROOT}/loader/loader.cpp"
    "${IEC_GUEST_SWITCH}"
    "${IEC_ROOT}/common/proc.c"
    "${IEC_ROOT}/common/rpc.c"
    "${IEC_ROOT}/common/sock_client.c"
    "${IEC_ROOT}/common/sock_server.cpp")

target_include_directories(iec_har PRIVATE
    "${IEC_ROOT}"
    "${IEC_ROOT}/common"
    "${IEC_ROOT}/loader"
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_BINARY_DIR}/generated")
# common/constant.h supplies the sandbox paths under __OHOS__, so no host paths
# are defined here.
target_compile_definitions(iec_har PRIVATE _GNU_SOURCE)

set_target_properties(iec_har PROPERTIES OUTPUT_NAME iec_server)

target_link_libraries(iec_har PUBLIC
    libace_napi.z.so libhilog_ndk.z.so librawfile.z.so
    iec_caps dl pthread)

add_library(ncploader SHARED
    ncploader/main.cpp
)

# The entry the platform calls in a native child process. It lives in a library of
# its own so the child loads nothing else: the point of the route is a process with
# no earlier copy of the object in its symbol scope.
target_include_directories(ncploader PRIVATE "${IEC_ROOT}")
target_compile_definitions(ncploader PRIVATE _GNU_SOURCE)
set_target_properties(ncploader PROPERTIES OUTPUT_NAME ncploader)
target_link_libraries(ncploader PRIVATE dl)
