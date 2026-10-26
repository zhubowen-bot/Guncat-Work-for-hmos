# 改编自 HiSH (MIT License, Copyright (c) 2025 hackeris) 的 deps/ 构建配方; 见 THIRD_PARTY_NOTICES.md
include ../utils/Makefrag

export CFLAGS := $(CFLAGS) -fPIC

SOURCE_URL = https://cairographics.org/releases/pixman-0.42.2.tar.gz
SOURCE_FILE = pixman-0.42.2.tar.gz
SOURCE_DIR = pixman-0.42.2
CONFIG_ARGS = --host=$(OHOS_ARCH)-linux --prefix=$(PREFIX) --enable-static --disable-shared --disable-gtk --disable-libpng --disable-arm-neon --disable-arm-a64-neon

$(eval $(call define_autotools_package))
