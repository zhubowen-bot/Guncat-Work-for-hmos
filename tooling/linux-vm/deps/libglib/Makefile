# 改编自 HiSH (MIT License, Copyright (c) 2025 hackeris) 的 deps/ 构建配方; 见 THIRD_PARTY_NOTICES.md
include ../utils/Makefrag

# 注: 原配方 `git clone gitlab.gnome.org/GNOME/glib`; 这里改用官方 release tarball,
#     避免 git 子模块与 gitlab 可达性问题。版本一致(2.82.0)。
SOURCE_URL = https://download.gnome.org/sources/glib/2.82/glib-2.82.0.tar.xz
SOURCE_FILE = glib-2.82.0.tar.xz
SOURCE_DIR = glib-2.82.0
# glib 在没有 libc 内建 libintl 时(如 musl)会回落到 proxy-libintl 子项目;
# meson 默认用 git 克隆, 受限网络下不可达 —— 这里直接把源码放进 subprojects/。
PROXY_LIBINTL_URL = https://codeload.github.com/frida/proxy-libintl/tar.gz/refs/tags/0.4

all: download/$(SOURCE_FILE)
	rm -rf temp build
	mkdir -p temp build
	cd temp && tar xf ../download/$(SOURCE_FILE)
	cd temp/$(SOURCE_DIR) && mkdir -p subprojects && \
		wget -q -O /tmp/proxy-libintl.tar.gz $(PROXY_LIBINTL_URL) && \
		rm -rf subprojects/proxy-libintl && mkdir -p subprojects/proxy-libintl && \
		tar xzf /tmp/proxy-libintl.tar.gz -C subprojects/proxy-libintl --strip-components=1
	cd temp/$(SOURCE_DIR) && rm -f cross.txt
	cd temp/$(SOURCE_DIR) && echo "[binaries]" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "c = '${OHOS_SDK_HOME}/native/llvm/bin/$(OHOS_ARCH)-unknown-linux-ohos-clang'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpp = '${OHOS_SDK_HOME}/native/llvm/bin/$(OHOS_ARCH)-unknown-linux-ohos-clang++'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "ar = '${OHOS_SDK_HOME}/native/llvm/bin/llvm-ar'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "ld = '${OHOS_SDK_HOME}/native/llvm/bin/ld.lld'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "strip = '${OHOS_SDK_HOME}/native/llvm/bin/llvm-strip'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "pkg-config = '$(shell which pkg-config)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "[host_machine]" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "system = 'linux'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpu_family = '$(OHOS_ARCH)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpu = '$(OHOS_ARCH)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "endian = 'little'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "[properties]" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "needs_exe_wrapper = true" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "[built-in options]" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "c_args = ['-I$(shell pwd)/../buildroot/include']" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "c_link_args = ['-L$(shell pwd)/../buildroot/lib']" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpp_args = ['-I$(shell pwd)/../buildroot/include']" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpp_link_args = ['-L$(shell pwd)/../buildroot/lib']" >> cross.txt
	cd temp/$(SOURCE_DIR) && PKG_CONFIG=$(shell which pkg-config) PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=$(shell pwd)/../buildroot/lib/pkgconfig:$(shell pwd)/../buildroot/share/pkgconfig meson --cross-file cross.txt --prefix=$(PREFIX) -Dselinux=disabled -Dinstalled_tests=false -Ddtrace=disabled -Dsystemtap=disabled -Dlibelf=disabled -Dlibmount=disabled -Dsysprof=disabled -Dtests=false -Ddefault_library=static build
	cd temp/$(SOURCE_DIR)/build && ninja
	mkdir -p ../buildroot
	cd temp/$(SOURCE_DIR)/build && DESTDIR=$(shell pwd)/build meson install --no-rebuild
	cp -rfv ./build/$(PREFIX)/. ../buildroot | tee file.lst

download/$(SOURCE_FILE):
	mkdir -p download
	cd download && wget --retry-connrefused --read-timeout=20 --timeout=15 $(SOURCE_URL)
