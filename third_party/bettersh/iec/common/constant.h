// common/constant.h — the facts that two or more components have to agree on.
//
// Everything here is written down once because a second copy is a copy that can drift:
// the socket the shims connect to is the socket main.cpp listens on, the name of the
// entry a qemu object is entered through is the name scripts/build_qemu.sh installs in
// it, and the paths below are the ones the objects were built into. Each one can be
// overridden from the command line, which is how a build for another machine -- where
// the objects live somewhere else entirely -- supplies its own.
#pragma once

/* OHOS defaults. The app sandbox has no writable /tmp, and its shared objects
 * live in the installed bundle rather than in a developer tree, so the
 * host-side paths used below cannot be reached on device. Each definition is
 * still inside #ifndef so a build can override it from the command line. */
#if defined(__OHOS__)

#define TTY_SOCK_PATH           "/data/storage/el2/base/files/iec-tty.sock"
#define EXEC_SOCK_PATH          "/data/storage/el2/base/files/iec-exec.sock"
#define PATH_QEMU_X86_64_SO     "/data/storage/el1/bundle/libs/arm64/libqemu-x86_64.so"
#define PATH_QEMU_AARCH64_SO    "/data/storage/el1/bundle/libs/arm64/libqemu-aarch64.so"
#define FAKE_SYSROOT            "/data/storage/el2/base/files"
#define IEC_LOG_DIR             "/data/storage/el2/base/files/logs"
#define IEC_DEFAULT_HOME        "/data/storage/el2/base/files/home"

#endif

/* Where the two services listen, and therefore where the shims look for them. */
#ifndef TTY_SOCK_PATH
#define TTY_SOCK_PATH "/tmp/tty_service.sock"
#endif

#ifndef EXEC_SOCK_PATH
#define EXEC_SOCK_PATH "/tmp/exec_service.sock"
#endif

/* The names the fake pty answers to. A program asks for its terminal by name and the shim
 * invents that name, so this is part of the illusion rather than a fact about the
 * filesystem. */
#ifndef PTMX_PATH
#define PTMX_PATH "/dev/ptmx"
#endif

#ifndef PTS_PREFIX
#define PTS_PREFIX "/dev/pts/"
#endif

#define PTS_PREFIX_LEN (sizeof PTS_PREFIX - 1)

/* The emulator objects, by absolute path: each is a shared object for one guest
 * architecture (libqemu-<guest>.so, named for the guest rather than for the host that
 * runs it), built by scripts/build_qemu.sh. The paths are where this tree builds them. */
#ifndef PATH_QEMU_X86_64_SO
#define PATH_QEMU_X86_64_SO "/workspace/dev/iec/dist/qemu/libqemu-x86_64.so"
#endif

#ifndef PATH_QEMU_AARCH64_SO
#define PATH_QEMU_AARCH64_SO "/workspace/dev/iec/dist/qemu/libqemu-aarch64.so"
#endif

/* What each of those calls itself, and the entry point the server calls inside it. The
 * entry is installed by the same script that builds the objects, so the two have to
 * agree: a mismatch is silent until something is started with it. */
#define QEMU_NAME_X86_64  "qemu-x86_64"
#define QEMU_NAME_AARCH64 "qemu-aarch64"
#define QEMU_ENTRY        "qemu_entry"

#ifndef FAKE_SYSROOT
#define FAKE_SYSROOT "/workspace/dev/iec/dist/fake_sysroot"
#endif

/* The runtime home, when the host does not export one. On OHOS it is the
 * application's own home under the fake root; a host build keeps it under the
 * fake sysroot next to the launchers. */
#ifndef IEC_DEFAULT_HOME
#define IEC_DEFAULT_HOME FAKE_SYSROOT "/home"
#endif
