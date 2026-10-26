# 改编自 HiSH (MIT License, Copyright (c) 2025 hackeris) 的 deps/ 构建配方; 见 THIRD_PARTY_NOTICES.md
include ../utils/Makefrag

ifeq ($(OHOS_ARCH), aarch64)
LSE_FLAGS := -D__ARM_LSE_ATOMIC_INLINES
endif

QEMU_TCG_FLAGS := --enable-tcg
QEMU_SYSTEM_OUTPUT := libqemu-system-aarch64.so
ifeq ($(QEMU_TCI),1)
# 关键: 打开 TCG 解释器(TCI)。产物文件名带 -tci, 与 JIT 版区分。
QEMU_TCG_FLAGS += --enable-tcg-interpreter
QEMU_SYSTEM_OUTPUT := libqemu-system-aarch64-tci.so
endif

# 源码包: harmoninux/qemu 的 hish-libqemu 分支。原配方用 git clone + git worktree,
# 这里改为源码 tarball(受限网络下 github.com 不可达, codeload.github.com 可达)。
QEMU_SRC_URL ?= https://codeload.github.com/harmoninux/qemu/tar.gz/refs/heads/hish-libqemu
QEMU_SRC_FILE ?= qemu-hish-libqemu.tar.gz

all: download/$(QEMU_SRC_FILE)
	rm -rf temp build
	mkdir -p temp build
	cd temp && tar xzf ../download/$(QEMU_SRC_FILE)
	mv temp/qemu-hish-libqemu temp/qemu
	# 让 zlib / pcre2 静态链接: 产物只依赖 libc + libslirp, 不必往 HAP 里再塞第三方 .so,
	# 也避免应用 libs 目录里的同名库遮蔽系统库。
	sed -i 's|^Libs:.*|Libs: -L$${libdir} -l:libz.a|' ../buildroot/lib/pkgconfig/zlib.pc
	sed -i 's|^Libs:.*|Libs: -L$${libdir} -l:libpcre2-8.a|' ../buildroot/lib/pkgconfig/libpcre2-8.pc
	cd temp/qemu && \
	PKG_CONFIG=$(shell which pkg-config) \
	PKG_CONFIG_PATH= \
	PKG_CONFIG_LIBDIR=$(shell pwd)/../buildroot/lib/pkgconfig:$(shell pwd)/../buildroot/share/pkgconfig \
	PKG_CONFIG_buildroot_DIR=$(shell pwd)/../buildroot \
	CFLAGS="$(LSE_FLAGS) -D_UAPI_LINUX_VIRTIO_VSOCK_H -D_UAPI_LINUX_VIRTIO_TYPES_H -D_UAPI_LINUX_VIRTIO_RING_H -D_UAPI_LINUX_VIRTIO_PMEM_H -D_UAPI_LINUX_VIRTIO_NET_H -D_UAPI_LINUX_VIRTIO_IOMMU_H -D_UAPI_LINUX_VIRTIO_FS_H -D_UAPI_LINUX_VIRTIO_CONSOLE_H -D_UAPI_LINUX_VIRTIO_CONFIG_H -D_LINUX_SYSINFO_H -UHAVE_OPENAT2_H -D__user= -D__force= ${CFLAGS} -Wno-unused-command-line-argument -I$(shell pwd)/../buildroot/include/glib-2.0 -I$(shell pwd)/../buildroot/lib/glib-2.0/include -I$(shell pwd)/../buildroot/include/pixman-1 -L$(shell pwd)/../buildroot/lib" \
	./configure --target-list=aarch64-softmmu --cross-prefix= --host-cc=cc --disable-kvm --disable-xen --disable-rust --disable-docs --disable-werror \
	 $(QEMU_TCG_FLAGS) --enable-lto --enable-strip --with-coroutine=sigaltstack \
	 --enable-trace-backends=nop --disable-qom-cast-debug \
	 --disable-stack-protector \
	 --disable-bsd-user --disable-guest-agent --disable-gcrypt --disable-debug-info --disable-debug-tcg --enable-attr --disable-brlapi --disable-linux-aio \
	 --disable-bzip2 --disable-cap-ng --disable-curl --disable-glusterfs --disable-gnutls --disable-nettle --disable-gtk --disable-rdma --disable-libiscsi \
	 --disable-vnc-jpeg --disable-lzo --disable-curses --disable-libnfs --disable-numa --disable-opengl --disable-rbd --disable-vnc-sasl --disable-sdl \
	 --disable-seccomp --disable-smartcard --disable-snappy --disable-spice --disable-libusb --disable-usb-redir --disable-vde --disable-vhost-net --disable-virglrenderer \
	 --disable-vte --disable-xen-pci-passthrough --enable-tools --disable-libudev --disable-passt \
	 --enable-pixman --enable-vnc --enable-slirp --enable-virtfs
	cd temp/qemu && make libqemu-system-aarch64.so -j $(shell nproc)
	cd temp/qemu && make libqemu-img.so -j $(shell nproc)
	# 去掉调试符号(构建目录里保留的 .so 还带着 -g, 瘦身后体积约降到 1/3)
	$(STRIP) --strip-all temp/qemu/build/libqemu-system-aarch64.so
	$(STRIP) --strip-all temp/qemu/build/libqemu-img.so
	cp temp/qemu/pc-bios/efi-virtio.rom ./build
	cp temp/qemu/build/libqemu-system-aarch64.so ./build/$(QEMU_SYSTEM_OUTPUT)
	cp temp/qemu/build/libqemu-img.so ./build
	cp temp/qemu/build/subprojects/slirp/libslirp.so.0.4.0 ./build/libslirp.so.0
	cp temp/qemu/pc-bios/keymaps/en-us ./build/
	mkdir -p ../output
	cp -rv ./build/* ../output

download/$(QEMU_SRC_FILE):
	mkdir -p download
	cd download && wget --retry-connrefused --read-timeout=20 --timeout=15 -O $(QEMU_SRC_FILE) $(QEMU_SRC_URL)
