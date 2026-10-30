// exec/exec_ncp_refusal.h — which NCP failures say something about the device.
//
// SpawnNcp() can fail for two very different reasons, and only one of them is
// worth remembering:
//
//   * the platform itself refused to create a native child process (the API is
//     missing, or the application is not allowed to use it). Retrying on every
//     command would pay a per-command delay and a per-command warning for an
//     answer that cannot change, so the server latches it once;
//   * this particular request could not travel over the route (not a .so, a
//     malformed launcher). That says nothing about the next request, and latching
//     it would disable a working route for the rest of the process.
//
// The test for the first kind is here rather than inline in exec_server.cpp so a
// host test can pin the exact list of prefixes (scripts/test_iec_native_host.sh).
// The three strings are produced verbatim by exec_ncp.cpp; the caller must not
// reword them without updating both sides.
#pragma once

#include <cstring>
#include <string>

// True only when `error` is one of the platform-wide refusal texts. A request-level
// message such as "only so file for now!" or "bad launcher ..." is not one.
inline bool IsNcpPlatformRefusal(const std::string& error) {
    static const char* const kPlatformWide[] = {
        "start native child failed",
        "cannot register the exit callback",
        "the platform has no native child process API",
    };

    for (const char* prefix : kPlatformWide) {
        if (error.compare(0, std::strlen(prefix), prefix) == 0) return true;
    }
    return false;
}
