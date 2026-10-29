// main.c — standalone entry point: ./loader <guest-elf> [args...]
//
// Behaviour:
//   argv[0] = "loader" (the host)
//   argv[1] = guest ELF path
//   argv[2..] = the guest's argv[1..] (argv[0] is the guest path's basename)
//
// Environment:
//   ELFLOADER_IN_CHILD=1   run the guest in a forked child (exit_group stays there)
//   ELFLOADER_DYN=<ldso>   treat the guest as dynamic; use this ld.so/libc.so
//   ELFLOADER_TRACE=1      print diagnostics

#include "loader.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static int slurp(const char *path, void **out, size_t *outlen) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return -1; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        fprintf(stderr, "stat %s failed\n", path); close(fd); return -1;
    }
    size_t n = (size_t)st.st_size;
    void *buf = malloc(n);
    if (!buf) { close(fd); return -1; }
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, (char*)buf + got, n - got);
        if (r <= 0) break;
        got += (size_t)r;
    }
    close(fd);
    if (got != n) { free(buf); fprintf(stderr, "short read %s\n", path); return -1; }
    *out = buf; *outlen = n;
    return 0;
}

static const char *base_name(const char *p) {
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
            "usage: %s <guest-elf> [args...]\n"
            "env:\n"
            "  ELFLOADER_IN_CHILD=1   run guest in a forked child\n"
            "  ELFLOADER_DYN=<ldso>   treat guest as dynamic; use this ld.so/libc.so\n",
            argv[0]);
        return 2;
    }

    const char *guest_path = argv[1];
    void *img = NULL; size_t img_len = 0;
    if (slurp(guest_path, &img, &img_len) != 0) return 1;

    /* Build the guest argv: argv[0] is the guest path's basename. */
    int gargc = argc - 1;
    char **gargv = (char**)calloc((size_t)gargc + 1, sizeof(char*));
    if (!gargv) { free(img); return 1; }
    gargv[0] = (char*)base_name(guest_path);
    for (int i = 2; i < argc; i++) gargv[i - 1] = argv[i];
    gargv[gargc] = NULL;

    const char *ldso = getenv("ELFLOADER_DYN");
    const char *in_child = getenv("ELFLOADER_IN_CHILD");

    int rc;
    if (ldso && *ldso) {
        void *ldso_img = NULL; size_t ldso_len = 0;
        if (slurp(ldso, &ldso_img, &ldso_len) != 0) { free(img); free(gargv); return 1; }
        rc = elf_run_dyn_child(img, img_len, ldso_img, ldso_len, gargc, gargv);
        free(ldso_img);
    } else if (in_child && in_child[0] == '1') {
        rc = elf_run_mem_in_child(img, img_len, gargc, gargv);
    } else {
        rc = elf_run_mem(img, img_len, gargc, gargv);
    }

    free(gargv);
    free(img);
    return rc < 0 ? 1 : rc;
}
