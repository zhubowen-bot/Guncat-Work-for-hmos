# Guncat Work 原生模块
#   1) guncatjs: run_js 工具(JSVM-API 沙箱), 内嵌标准 JS 引擎执行动态代码
#   2) guncatpy: run_python 工具, dlopen libpython3.12.so
# shell 工具已改为 IEC 原生执行核（third_party/bettersh/iec 的 HAR），不再有 QEMU 桥。
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

# libguncatpy.so: ArkTS 侧 import guncatpy from 'libguncatpy.so'
# 原生 Python 工具: 运行期 dlopen libpython3.12.so(不参与链接),
# 因此 x86_64 模拟器构建也能编译通过, 运行期再报"本机不支持"。
add_library(guncatpy SHARED
    python/guncat_py.cpp)

target_link_libraries(guncatpy PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libdl.so)
