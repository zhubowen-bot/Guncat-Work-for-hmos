# 改编自 HiSH (MIT License, Copyright (c) 2025 hackeris) 的 deps/ 构建配方; 见 THIRD_PARTY_NOTICES.md
include ../utils/Makefrag

# 注: 原配方走 github.com 直链, 在受限网络(hosts 被改写)下不可达;
#     改用 codeload.github.com —— 同一份 tag 源码, 只是换了下载入口。
SOURCE_URL = https://codeload.github.com/facebook/zstd/tar.gz/refs/tags/v1.5.7
SOURCE_FILE = zstd-1.5.7.tar.gz
SOURCE_DIR = zstd-1.5.7
# avoid clashing existing build folder
BUILD_DIR = build-zstd
PATCH_SOURCE = cd temp/$(SOURCE_DIR) && cat ../../0001-qsort.diff | patch -Np1
CMAKE_LISTS_PATH = ../build/cmake
CMAKE_ARGS = -DCMAKE_INSTALL_PREFIX=$(PREFIX) -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=$(OHOS_ARCH) -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_SHARED=OFF -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_POSITION_INDEPENDENT_CODE=ON

$(eval $(call define_cmake_package))
