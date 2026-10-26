include ../utils/Makefrag

# 注: 原配方走 github.com 直链, 受限网络下不可达, 改走 codeload.github.com。
SOURCE_URL = https://codeload.github.com/PCRE2Project/pcre2/tar.gz/refs/tags/pcre2-10.45
SOURCE_FILE = pcre2-10.45.tar.gz
# codeload 的 tag 包解出来是 <repo>-<tag>, 即 pcre2-pcre2-10.45
SOURCE_DIR = pcre2-pcre2-10.45
CMAKE_ARGS = -DPCRE2_BUILD_PCRE2_32=ON -DCMAKE_INSTALL_PREFIX=$(PREFIX) -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=$(OHOS_ARCH) -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_POSITION_INDEPENDENT_CODE=ON

$(eval $(call define_cmake_package))
