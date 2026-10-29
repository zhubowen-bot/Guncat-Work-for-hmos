// common/bsh_rawfile.cpp — 见 bsh_rawfile.h
#include "common/bsh_rawfile.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>

#include "rawfile/raw_dir.h"
#include "rawfile/raw_file.h"
#include "rawfile/raw_file_manager.h"

namespace bsh {
namespace {

NativeResourceManager* g_mgr = nullptr;

/* GetRawFileName 给的到底是"相对 rawfile 根"的路径还是"相对本目录"的名字,文档
 * 说可以直接喂给 OpenRawFile(那就是相对根),但两种实现的设备上都可能碰到。这里
 * 做一次归一:名字已经以本目录前缀开头(且紧接着 '/' 这个边界)就原样用,否则拼上
 * 本目录。两种语义都能走通。 */
std::string Join(const std::string& dir, const char* name) {
    if (dir.empty()) return name;
    if (strncmp(name, dir.c_str(), dir.size()) == 0 && name[dir.size()] == '/') return name;
    return dir + "/" + name;
}

void Walk(const std::string& dir, std::vector<RawFileEntry>* out) {
    RawDir* d = OH_ResourceManager_OpenRawDir(g_mgr, dir.c_str());
    if (d == nullptr) return;
    int n = OH_ResourceManager_GetRawFileCount(d);
    for (int i = 0; i < n; i++) {
        const char* name = OH_ResourceManager_GetRawFileName(d, i);
        if (name == nullptr) break;
        std::string full = Join(dir, name);
        if (OH_ResourceManager_IsRawDir(g_mgr, full.c_str())) {
            Walk(full, out);          // 目录:只是路径的一部分,进去继续
            continue;
        }
        /* 不是目录就当文件打开取大小。打不开的(既不是目录也不是可读文件)跳过 ——
         * 与其把噪点列出来,不如少一条。 */
        RawFile* f = OH_ResourceManager_OpenRawFile(g_mgr, full.c_str());
        if (f == nullptr) continue;
        long sz = OH_ResourceManager_GetRawFileSize(f);
        OH_ResourceManager_CloseRawFile(f);
        out->push_back({full, (long long)sz});
    }
    OH_ResourceManager_CloseRawDir(d);
}

}  // namespace

void bsh_rawfile_set_manager(NativeResourceManager* mgr) { g_mgr = mgr; }
NativeResourceManager* bsh_rawfile_manager() { return g_mgr; }

bool bsh_rawfile_list(std::vector<RawFileEntry>* out) {
    out->clear();
    if (g_mgr == nullptr) return false;
    Walk("", out);
    std::sort(out->begin(), out->end(),
              [](const RawFileEntry& a, const RawFileEntry& b) { return a.path < b.path; });
    return true;
}

int bsh_rawfile_copy(const char* rawName, const char* dst, bool overwrite) {
    if (g_mgr == nullptr || rawName == nullptr || dst == nullptr) return -1;

    struct stat st;
    if (!overwrite && stat(dst, &st) == 0) return 1;

    RawFile* rf = OH_ResourceManager_OpenRawFile(g_mgr, rawName);
    if (rf == nullptr) return -2;
    int fd = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        OH_ResourceManager_CloseRawFile(rf);
        return -3;
    }

    char buf[65536];
    int rc = 0;
    for (;;) {
        int n = OH_ResourceManager_ReadRawFile(rf, buf, sizeof buf);
        if (n < 0) { rc = -4; break; }
        if (n == 0) break;
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(fd, buf + off, (size_t)(n - off));
            if (w < 0 && errno == EINTR) continue;
            if (w <= 0) { rc = -5; break; }
            off += w;
        }
        if (rc != 0) break;
    }
    close(fd);
    OH_ResourceManager_CloseRawFile(rf);

    /* 半截文件会骗过下次 overwrite=false 的"已存在就跳过",所以失败就删掉 */
    if (rc != 0) unlink(dst);
    return rc;
}

}  // namespace bsh
