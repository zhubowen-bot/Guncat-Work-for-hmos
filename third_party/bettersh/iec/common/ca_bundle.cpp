// common/ca_bundle.cpp — see common/ca_bundle.h.
#include "ca_bundle.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <string>

// Generated at build time from assets/cacert.pem. The header is in the CMake
// binary directory, which the HAR's target adds to its include path.
#include "cacert_pem.h"

namespace {

// mkdir -p. An existing component is not an error: the caller only needs the
// final directory to exist.
bool MakeDirs(const std::string& path) {
    if (path.empty()) return true;

    std::string current;
    size_t start = 0;
    if (path[0] == '/') {
        current = "/";
        start = 1;
    }

    while (start <= path.size()) {
        const size_t slash = path.find('/', start);
        const std::string part =
            path.substr(start, slash == std::string::npos ? std::string::npos
                                                           : slash - start);
        if (!part.empty()) {
            if (!current.empty() && current.back() != '/') current += '/';
            current += part;
            if (mkdir(current.c_str(), 0755) != 0 && errno != EEXIST) return false;
        }
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return true;
}

bool WriteAll(int fd, const unsigned char* data, size_t size) {
    size_t left = size;
    const unsigned char* p = data;

    while (left > 0) {
        const ssize_t n = write(fd, p, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        p += n;
        left -= static_cast<size_t>(n);
    }
    return true;
}

}  // namespace

bool IecInstallCaBundle(const char* dir) {
    if (dir == nullptr || dir[0] == '\0') return false;
    if (!MakeDirs(dir)) return false;

    const std::string path = std::string(dir) + "/cacert.pem";
    const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return false;

    const bool ok = WriteAll(fd, iec_cacert_pem, iec_cacert_pem_size);
    if (close(fd) != 0 || !ok) {
        unlink(path.c_str());
        return false;
    }
    return true;
}
