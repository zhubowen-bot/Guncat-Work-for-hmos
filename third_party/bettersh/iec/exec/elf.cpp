// exec/elf.cpp — reading the header of a file the service has been asked to start.
#include "elf.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

// The part of the header both answers come from.
struct ElfHead {
    bool is_elf = false;
    bool little_endian = false;
    uint16_t machine = 0;
};

// One open and one read, and only for a regular file: the path is whatever the client
// asked for, and opening a fifo would block the thread serving the request.
ElfHead ReadHead(const std::string& path) {
    constexpr size_t kHeaderBytes = 64;   // e_machine sits at 18..19, with room to spare
    ElfHead head;
    struct stat st;
    unsigned char buf[kHeaderBytes];
    ssize_t n;
    int fd;

    if (stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) return head;
    fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return head;
    n = read(fd, buf, sizeof buf);
    close(fd);
    if (n < 20) return head;              // no room for e_machine

    if (buf[0] != 0x7f || buf[1] != 'E' || buf[2] != 'L' || buf[3] != 'F') return head;
    head.is_elf = true;
    if (buf[5] != 1) return head;         // 1 is ELFDATA2LSB; the rest of this reads LE
    head.little_endian = true;
    head.machine = static_cast<uint16_t>(buf[18] | (buf[19] << 8));
    return head;
}

}  // namespace

bool IsElfFile(const std::string& path) {
    return ReadHead(path).is_elf;
}

uint16_t ElfMachine(const std::string& path) {
    ElfHead head = ReadHead(path);
    return head.little_endian ? head.machine : 0;
}
