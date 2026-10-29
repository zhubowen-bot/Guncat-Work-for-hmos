// misc/uname.c — report "Linux" from uname(2) inside the sandbox.
//
// The kernel reports "HarmonyOS", which makes tools that branch on
// uname().sysname take a non-Linux path. The measured case is hvigor's
// @ohos/hvigor-common:
//
//     isLinux() { return os.type() === 'Linux'; }    // os.type() -> uname()
//     getLibimageTranscoderShared() {
//         return isWindows() ? '...dll'
//              : isLinux()   ? '...so'
//                            : '...dylib';
//     }
//
// CompileResource then tries to dlopen a .dylib that does not exist.
//
// Only sysname is changed. release/version/machine/nodename describe the
// actual host and are left alone. IEC_UNAME_REAL=1 bypasses the wrapper for
// diagnostics.
//
// This object is linked only into the command objects that need it; it is not
// part of the shared shim list.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>

extern int __real_uname(struct utsname *buf);

int __wrap_uname(struct utsname *buf)
{
    int rc = __real_uname(buf);
    const char *real;

    if (rc != 0 || buf == NULL) return rc;

    real = getenv("IEC_UNAME_REAL");
    if (real && *real && real[0] != '0') return rc;

    strncpy(buf->sysname, "Linux", sizeof(buf->sysname) - 1);
    buf->sysname[sizeof(buf->sysname) - 1] = '\0';
    return rc;
}
