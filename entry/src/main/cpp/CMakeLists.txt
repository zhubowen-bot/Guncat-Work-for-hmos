# Guncat Work 原生模块
#   1) guncatjs: run_js 工具(JSVM-API 沙箱), 内嵌标准 JS 引擎执行动态代码
#   2) guncatvm: shell 工具的 Linux VM 桥, dlopen QEMU(TCI 解释执行)并在同进程跑虚拟机
cmake_minimum_required(VERSION 3.5.0)
project(guncat_native)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH})

# libguncatjs.so: ArkTS 侧 import guncatjs from 'libguncatjs.so'
add_library(guncatjs SHARED
    napi_init.cpp
    jsvm_sandbox.cpp)

# libace_napi.z.so: Node-API(ArkTS 与 C++ 交互)
# libjsvm.so: JSVM-API(标准 JS 引擎)
# libhilog_ndk.z.so: 日志
target_link_libraries(guncatjs PUBLIC
    libace_napi.z.so
    libjsvm.so
    libhilog_ndk.z.so)

# libguncatvm.so: ArkTS 侧 import guncatvm from 'libguncatvm.so'
# QEMU 运行库(libs/<abi>/libqemu-system-aarch64-tci.so)在运行期 dlopen, 不参与链接
add_library(guncatvm SHARED
    vm/guncat_vm.cpp)

target_link_libraries(guncatvm PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libdl.so)
