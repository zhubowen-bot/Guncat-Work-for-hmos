cmake_minimum_required(VERSION 3.16)
project(qtwl_demo LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Widgets)

add_library(qtwl-demo main.cpp)

if(NOT DEFINED WAYMONY_SYSX)
    set(WAYMONY_SYSX "${CMAKE_CURRENT_SOURCE_DIR}/../../build/sysroot-ext-arm64-v8a/usr")
endif()
target_include_directories(qtwl-demo PRIVATE ${WAYMONY_SYSX}/include)
target_link_libraries(qtwl-demo PRIVATE Qt6::Widgets
    ${WAYMONY_SYSX}/lib/aarch64-linux-ohos/libwayland-client.so)
