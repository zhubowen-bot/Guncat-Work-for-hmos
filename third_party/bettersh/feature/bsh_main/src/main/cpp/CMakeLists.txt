# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(BetterSH)
enable_language(ASM)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH})

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# 内嵌 Wayland compositor(server 端编进 libentry):取自 Waymony 原生栈。
# 依赖 entry/libs/arm64-v8a/libwayland-server.so(scripts/build_wayland.sh 产出)。
set(WL_SRC
    wayland/wayland_server.cpp
    wayland/crash_trace.cpp
    wayland/xdg_shell.cpp
    wayland/data_device.cpp
    wayland/egl_renderer.cpp
    wayland/plugin_manager.cpp
    wayland/input_napi.cpp
    wayland/ws_napi.cpp
    wayland/protocol/xdg-shell-protocol.c
    wayland/protocol/viewporter-protocol.c)
set(WL_LIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/arm64-v8a)

add_library(entry SHARED
    napi_init.cpp
    bsh/terminal_napi.cpp
    common/bsh_rawfile.cpp
    logger/logger.cpp
    tty/softpty.cpp
    tty/bsh_tty.cpp
    shell/shell.cpp
    shell/lineedit.cpp
    shell/lexer.cpp
    shell/complete.cpp
    shell/rcfile.cpp
    procmgr/procmgr.cpp
    procmgr/command_map.c
    procmgr/ctrl_socket.cpp
    procmgr/caps.cpp
    bshutil/bshutil.cpp
    bshutil/bsh_cfg.cpp
    bshutil/ui_bus.cpp
    bshutil/bsh_util_server.cpp
    ${WL_SRC})
target_include_directories(entry PRIVATE
    ${NATIVERENDER_ROOT_PATH}/wayland
    ${NATIVERENDER_ROOT_PATH}/wayland/include
    ${NATIVERENDER_ROOT_PATH}/wayland/protocol)
target_link_libraries(entry PUBLIC libace_napi.z.so librawfile.z.so libhilog_ndk.z.so)
target_link_libraries(entry PUBLIC
    ${WL_LIB_DIR}/libwayland-server.so
    libnative_window.so
    libEGL.so
    libGLESv3.so
    dl)

# ELFloader:在无 exec 沙箱内直接装载执行 arm64(musl)ELF(来自 ElfLoaderDemo)。
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    set(ELF_GUEST_SWITCH elfloader/guest_switch.S)
endif()
add_library(bsh_elfloader STATIC
    elfloader/elf_loader.cpp
    elfloader/elf_dl.cpp
    ${ELF_GUEST_SWITCH})
target_compile_options(bsh_elfloader PRIVATE -fPIC)
target_include_directories(bsh_elfloader PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(entry PUBLIC bsh_elfloader)

# control socket 客户端:宿主 shell 与各命令 so 共用。命令 so 由 scripts/build_*.sh
# 手工链接(link 这一个 .o),不是 CMake 目标。
add_library(bsh_client STATIC procmgr/bsh_client.c)
target_compile_options(bsh_client PRIVATE -fPIC)
target_include_directories(bsh_client PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(entry PUBLIC bsh_client)

# so 化示例程序:独立 .so,产出到 entry/libs/arm64-v8a(随 HAP 打包),
# shell 以命令表 dlopen 运行
add_library(hellobsh SHARED programs/hellobsh/hellobsh.cpp)

# bshutil 命令 so:只是一层客户端,逻辑在主进程的常驻服务线程里
# (bshutil/bsh_util_server.cpp)。客户端源码与入口同目录;它要的 sock 路径/帧格式
# 来自 bshutil/bsh_util_proto.h,所以这里要给出 cpp 根作为 include 路径。
# 服务端的那份客户端 .c 也编进 entry(启动自检用),见上面的 entry 源列表。
add_library(bshutil SHARED
    programs/bshutil/bshutil_main.cc
    programs/bshutil/bsh_util_client.c)
target_include_directories(bshutil PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

# Wayland 冒烟客户端(wldemo) 验证 fd 交付/帧捕获
add_library(wldemo SHARED
    programs/wldemo/wldemo.c
    wayland/protocol/xdg-shell-protocol.c)
target_include_directories(wldemo PRIVATE
    ${NATIVERENDER_ROOT_PATH}/wayland
    ${NATIVERENDER_ROOT_PATH}/wayland/include
    ${NATIVERENDER_ROOT_PATH}/wayland/protocol)
target_link_libraries(wldemo PRIVATE ${WL_LIB_DIR}/libwayland-client.so)

# 终端接线：terminal.cpp + IEC 的 tty/exec warp shim，编成独立的 libterminal.so。
# 链接期 --wrap 把 forkpty / exec 家族改写成 shim 入口，shim 再经 UDS 交给 App 内的
# IEC 服务（EntryAbility 里 startIecServer() 拉起）。libentry 用
# dlopen("libterminal.so") 加载它，所以这里不直接链进 entry。
set(IEC_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../iec)
set(IEC_WRAP_NAMES
    open close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
    tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
    openpty login_tty forkpty
    execve execv execvp execvpe execl execlp execle)
set(IEC_WRAP_FLAGS "")
foreach(name ${IEC_WRAP_NAMES})
    list(APPEND IEC_WRAP_FLAGS "-Wl,--wrap=${name}")
endforeach()

add_library(terminal SHARED
    bsh/terminal.cpp
    ${IEC_ROOT}/tty/shim.c
    ${IEC_ROOT}/exec/shim.c
    ${IEC_ROOT}/common/rpc.c
    ${IEC_ROOT}/common/sock_client.c)
target_include_directories(terminal PRIVATE
    ${IEC_ROOT}
    ${IEC_ROOT}/common)
target_compile_definitions(terminal PRIVATE INT_WARP _GNU_SOURCE)
set_target_properties(terminal PROPERTIES
    C_STANDARD 11
    C_STANDARD_REQUIRED ON)
target_link_options(terminal PRIVATE ${IEC_WRAP_FLAGS})
target_link_libraries(terminal PRIVATE dl pthread)

# pkg 命令 so（包管理器）：下载走 mbedTLS、解包走自带的 tar 实现，不依赖宿主进程。
# mbedTLS 的源码也在这个子目录的 CMakeLists 里一起编（见 programs/pkg/CMakeLists.txt）。
add_subdirectory(programs/pkg)
