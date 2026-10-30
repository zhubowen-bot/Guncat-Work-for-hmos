// harness.cpp — 宿主侧直接调用 IecExtractTar()，复刻 unpackNpm() 的调用协议。
//
// 被测实现是 common/archive_extract.cpp（设备 HAR 的 UnpackResource 也调它）。
// 这里刻意不做 rawfile 那一层：参数是普通文件路径，解包核心只认内存里的 tar。
//
// 用法：
//   iec_npm_unpack <npm.tar.gz> <dest>
//
// 返回值：
//   0  解包成功，并且写好了 <dest>/npm/.unpack-complete（内容 "ok\n"）
//   1  解包失败
//   2  参数/读文件/建目录失败
//
// 完成标记本来由 ArkTS 的 IecRuntime.unpackNpm() 在 unpackResource() 返回 0 后
// 写、失败后由 dropIncompleteNpm() 删。宿主没有 ArkTS，所以 harness 把这段
// 调用方协议原样复刻出来，失败路径的"不留标记/入口"才有意义。
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "common/archive_extract.h"
#include "logger/logger.h"

namespace {

bool Mkdirs(const std::string& path) {
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
            if (mkdir(current.c_str(), 0755) != 0 && errno != EEXIST) {
                std::fprintf(stderr, "mkdir %s: %s\n", current.c_str(),
                             std::strerror(errno));
                return false;
            }
        }
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return true;
}

bool ReadFile(const char* path, std::vector<unsigned char>* out) {
    FILE* f = std::fopen(path, "rb");
    if (!f) {
        std::fprintf(stderr, "open %s: %s\n", path, std::strerror(errno));
        return false;
    }
    if (std::fseek(f, 0, SEEK_END) != 0) {
        std::fclose(f);
        return false;
    }
    const long size = std::ftell(f);
    if (size < 0 || std::fseek(f, 0, SEEK_SET) != 0) {
        std::fclose(f);
        return false;
    }
    out->resize(static_cast<size_t>(size));
    const size_t got = out->empty() ? 0 : std::fread(out->data(), 1, out->size(), f);
    const bool ok = got == out->size();
    std::fclose(f);
    if (!ok) std::fprintf(stderr, "short read on %s\n", path);
    return ok;
}

bool WriteMarker(const std::string& path) {
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    const bool ok = std::fwrite("ok\n", 1, 3, f) == 3;
    const bool closed = std::fclose(f) == 0;
    return ok && closed;
}

void UnlinkQuiet(const std::string& path) {
    if (unlink(path.c_str()) != 0 && errno != ENOENT) {
        std::fprintf(stderr, "unlink %s: %s\n", path.c_str(),
                     std::strerror(errno));
    }
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: %s <npm.tar.gz> <dest>\n", argv[0]);
        return 2;
    }

    // 解包核心的日志默认会同时写 $HOME/logs；测试只需要自己的报错，
    // 调大日志量时用 IEC_NPM_TEST_VERBOSE=1 打开 stderr。
    Logger::GetInstance()->SetFile(false);
    Logger::GetInstance()->SetStderr(std::getenv("IEC_NPM_TEST_VERBOSE") != nullptr);

    const char* tar = argv[1];
    const std::string dest = argv[2];

    std::vector<unsigned char> data;
    if (!ReadFile(tar, &data)) return 2;
    if (!Mkdirs(dest)) return 2;

    const std::string npm = dest + "/npm";
    const std::string marker = npm + "/.unpack-complete";
    const std::string entry = npm + "/bin/npm-cli.js";

    if (IecExtractTar(data.data(), data.size(), dest.c_str()) != 0) {
        // 与 IecRuntime.dropIncompleteNpm() 一致：先删标记，再删入口。
        UnlinkQuiet(marker);
        UnlinkQuiet(entry);
        std::fprintf(stderr, "IecExtractTar failed for %s -> %s\n", tar, dest.c_str());
        return 1;
    }

    if (!Mkdirs(npm) || !WriteMarker(marker)) {
        std::fprintf(stderr, "cannot write completion marker %s\n", marker.c_str());
        return 2;
    }
    return 0;
}
