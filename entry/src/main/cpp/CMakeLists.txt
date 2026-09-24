# Guncat Work: run_js 工具的 native 实现(JSVM-API 沙箱)
# JSVM-API 是 C 接口(libjsvm.so), 用于在应用内嵌一个标准 JS 引擎执行动态代码。
cmake_minimum_required(VERSION 3.5.0)
project(guncatjs)

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
