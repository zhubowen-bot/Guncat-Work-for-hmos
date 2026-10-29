// exec/exec_loader.cpp — the kLoader route.
//
// The caller is already a child of the server (see StartByKind), so mapping
// and entering the image here is safe: a guest's exit_group ends only this
// child. Dynamic images are entered through their PT_INTERP; static images
// are entered at their own entry.
#include "exec_loader.h"

#include "../loader/loader.h"

#include <elf.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <string>
#include <vector>

extern char** environ;

namespace {

bool Slurp(const std::string& path, std::vector<unsigned char>* out) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        close(fd);
        return false;
    }

    const size_t len = (size_t)st.st_size;
    out->resize(len);
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, out->data() + got, len - got);
        if (n <= 0) break;
        got += (size_t)n;
    }
    close(fd);
    if (got != len) {
        out->clear();
        return false;
    }
    return true;
}

// The interpreter named by PT_INTERP, or empty when the image is static.
std::string ReadInterp(const std::string& path) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return std::string();

    Elf64_Ehdr eh;
    if (read(fd, &eh, sizeof eh) != (ssize_t)sizeof eh ||
        memcmp(eh.e_ident, ELFMAG, SELFMAG) != 0 ||
        eh.e_phentsize != sizeof(Elf64_Phdr) || eh.e_phnum == 0) {
        close(fd);
        return std::string();
    }

    std::vector<Elf64_Phdr> ph(eh.e_phnum);
    if (lseek(fd, (off_t)eh.e_phoff, SEEK_SET) < 0 ||
        read(fd, ph.data(), ph.size() * sizeof(Elf64_Phdr)) !=
            (ssize_t)(ph.size() * sizeof(Elf64_Phdr))) {
        close(fd);
        return std::string();
    }

    std::string interp;
    for (const Elf64_Phdr& p : ph) {
        if (p.p_type != PT_INTERP || p.p_filesz == 0 || p.p_filesz > 4096) continue;
        std::vector<char> buf((size_t)p.p_filesz + 1, '\0');
        if (lseek(fd, (off_t)p.p_offset, SEEK_SET) < 0 ||
            read(fd, buf.data(), (size_t)p.p_filesz) != (ssize_t)p.p_filesz) {
            break;
        }
        interp.assign(buf.data(), strnlen(buf.data(), (size_t)p.p_filesz));
        break;
    }
    close(fd);
    return interp;
}

}  // namespace

pid_t SpawnLoader(const SpawnRequest& req) {
    if (!req.cwd.empty() && chdir(req.cwd.c_str()) != 0) {
        static const char msg[] = "[exec] chdir failed, started in default path\n";
        if (write(STDERR_FILENO, msg, sizeof msg - 1)) {}
    }

    std::vector<char*> argv;
    argv.reserve(req.argv.size() + 1);
    for (const std::string& s : req.argv) argv.push_back(const_cast<char*>(s.c_str()));
    argv.push_back(nullptr);

    std::vector<char*> envp;
    envp.reserve(req.env.size() + 1);
    for (const std::string& s : req.env) envp.push_back(const_cast<char*>(s.c_str()));
    envp.push_back(nullptr);
    environ = envp.data();

    const int argc = (int)req.argv.size();

    // A dynamic image is entered through its interpreter: map both images and
    // start at the interpreter's entry, which relocates the main image and
    // calls its entry. A static image is entered directly.
    const std::string interp = ReadInterp(req.path);
    if (!interp.empty()) {
        std::vector<unsigned char> main_img, ldso_img;
        if (Slurp(req.path, &main_img) && Slurp(interp, &ldso_img)) {
            const int rc = elf_run_dyn_inproc(main_img.data(), main_img.size(),
                                              ldso_img.data(), ldso_img.size(),
                                              argc, argv.data());
            if (rc < 0) return -1;
            fflush(nullptr);
            _exit(rc & 0xff);
        }
        fprintf(stderr, "[exec] loader: cannot read %s or its interpreter %s\n",
                req.path.c_str(), interp.c_str());
    }

    const int rc = elf_run_file(req.path.c_str(), argc, argv.data());
    if (rc < 0) return -1;
    fflush(nullptr);
    _exit(rc & 0xff);
}
