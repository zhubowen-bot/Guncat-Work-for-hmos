/*
 * Minimal config.h for musl-obstack and musl-fts on OHOS musl.
 * Hand-written substitute for what autotools' configure would produce.
 */
#ifndef BOX64_OHOS_MIN_CONFIG_H
#define BOX64_OHOS_MIN_CONFIG_H

/* --- standard headers --- */
#define HAVE_STDLIB_H        1
#define HAVE_STRING_H        1
#define HAVE_STRINGS_H       1
#define HAVE_UNISTD_H        1
#define HAVE_INTTYPES_H      1
#define HAVE_STDINT_H        1
#define HAVE_ERRNO_H         1
#define HAVE_FCNTL_H         1
#define HAVE_LIMITS_H        1
#define HAVE_MEMORY_H        1
#define HAVE_SYS_PARAM_H     1
#define HAVE_SYS_STAT_H      1
#define HAVE_SYS_TYPES_H     1
#define HAVE_DIRENT_H        1

/* --- functions / fields available on OHOS musl aarch64 --- */
#define HAVE_FSTATAT         1
#define HAVE_OPENAT          1
#define HAVE_FCHDIR          1
#define HAVE_DIRFD           1
#define HAVE_DIRENT_D_TYPE   1
#define HAVE_GETPAGESIZE     1
#define HAVE_MEMCPY          1
#define HAVE_MEMMOVE         1

/* --- generic macros some upstream projects expect --- */
#define STDC_HEADERS         1
#define _ALL_SOURCE          1

/* --- package strings (referenced by some upstream code) --- */
#define PACKAGE              "box64-ohos"
#define PACKAGE_NAME         "box64-ohos"
#define PACKAGE_VERSION      "1.0"
#define VERSION              "1.0"

#endif /* BOX64_OHOS_MIN_CONFIG_H */
