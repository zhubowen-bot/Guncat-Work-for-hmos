// scripts/libarchive-ohos/zip_entry.c — a small `zip` command built on libarchive.
//
// Usage:
//   zip [-r] [-q] [-0] [-j] archive.zip file...
//
//   -r  recurse into directories
//   -q  quiet
//   -0  store without compression
//   -j  junk paths (use the basename for entries)
//
// The command is linked into libzipcmd.so with the IEC shims, so the archive
// file and the input paths go through __wrap_open/stat/symlink. Reading an
// .IEC_SYMLINK marker yields the stored target and writes a zip symlink entry.
//
// This is deliberately a subset of Info-ZIP's UI. The companion `unzip` command
// is the upstream libarchive bsdunzip front end.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <archive.h>
#include <archive_entry.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int g_quiet;

static void complain(const char* path, const char* what)
{
    if (!g_quiet) fprintf(stderr, "zip: %s: %s\n", path, what);
}

static const char* BaseName(const char* path)
{
    const char* slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

// Strip leading "/" and "./" so an absolute input does not create an absolute
// member name in the archive.
static int ArchiveName(const char* path, char* out, size_t outsz)
{
    while (path[0] == '/') path++;
    while (path[0] == '.' && path[1] == '/') path += 2;
    if (!*path) return -1;
    const int n = snprintf(out, outsz, "%s", path);
    return (n < 0 || (size_t)n >= outsz) ? -1 : 0;
}

static int WriteEntry(struct archive* a, const char* fs_path,
                      const char* arc_path, const struct stat* st,
                      const char* symlink_target)
{
    struct archive_entry* e = archive_entry_new();
    if (!e) return -1;

    archive_entry_set_pathname(e, arc_path);
    archive_entry_set_filetype(e, st->st_mode & S_IFMT);
    archive_entry_set_perm(e, st->st_mode & 07777);
    archive_entry_set_mtime(e, st->st_mtime, 0);
    archive_entry_set_uid(e, st->st_uid);
    archive_entry_set_gid(e, st->st_gid);

    if (symlink_target) {
        archive_entry_set_size(e, 0);
        archive_entry_set_symlink(e, symlink_target);
    } else if (S_ISREG(st->st_mode)) {
        archive_entry_set_size(e, st->st_size);
    } else {
        archive_entry_set_size(e, 0);
    }

    int r = archive_write_header(a, e);
    if (r != ARCHIVE_OK) {
        complain(fs_path, archive_error_string(a));
        archive_entry_free(e);
        return -1;
    }

    if (S_ISREG(st->st_mode)) {
        const int fd = open(fs_path, O_RDONLY);
        if (fd < 0) {
            complain(fs_path, strerror(errno));
            archive_entry_free(e);
            return -1;
        }
        char buf[64 * 1024];
        int ok = 0;
        for (;;) {
            const ssize_t n = read(fd, buf, sizeof buf);
            if (n < 0) {
                if (errno == EINTR) continue;
                complain(fs_path, strerror(errno));
                break;
            }
            if (n == 0) {
                ok = 1;
                break;
            }
            if (archive_write_data(a, buf, (size_t)n) < 0) {
                complain(fs_path, archive_error_string(a));
                break;
            }
        }
        close(fd);
        if (!ok) {
            archive_entry_free(e);
            return -1;
        }
    }

    r = archive_write_finish_entry(a);
    archive_entry_free(e);
    if (r != ARCHIVE_OK) {
        complain(fs_path, archive_error_string(a));
        return -1;
    }
    return 0;
}

static int AddPath(struct archive* a, const char* fs_path,
                   const char* arc_hint, int recurse, int junk)
{
    struct stat st;
    char arc[PATH_MAX];

    if (junk) {
        if (ArchiveName(BaseName(fs_path), arc, sizeof arc) != 0) return -1;
    } else if (arc_hint) {
        const int n = snprintf(arc, sizeof arc, "%s", arc_hint);
        if (n < 0 || (size_t)n >= sizeof arc) return -1;
    } else if (ArchiveName(fs_path, arc, sizeof arc) != 0) {
        return -1;
    }

    if (lstat(fs_path, &st) != 0) {
        complain(fs_path, strerror(errno));
        return -1;
    }

    if (S_ISLNK(st.st_mode)) {
        char target[PATH_MAX];
        const ssize_t n = readlink(fs_path, target, sizeof target - 1);
        if (n < 0) {
            complain(fs_path, strerror(errno));
            return -1;
        }
        target[n] = '\0';
        return WriteEntry(a, fs_path, arc, &st, target);
    }

    if (S_ISDIR(st.st_mode)) {
        if (!recurse) {
            complain(fs_path, "is a directory (use -r)");
            return -1;
        }

        char dir_arc[PATH_MAX];
        const int dan = snprintf(dir_arc, sizeof dir_arc, "%s", arc);
        if (dan < 0 || (size_t)dan >= sizeof dir_arc) return -1;

        // A directory member ends with '/'.
        size_t alen = strlen(arc);
        if (alen + 1 < sizeof arc) {
            arc[alen++] = '/';
            arc[alen] = '\0';
        }
        if (WriteEntry(a, fs_path, arc, &st, NULL) != 0) return -1;

        DIR* d = opendir(fs_path);
        if (!d) {
            complain(fs_path, strerror(errno));
            return -1;
        }
        int rc = 0;
        struct dirent* de;
        while ((de = readdir(d)) != NULL) {
            if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;

            char child_fs[PATH_MAX];
            char child_arc[PATH_MAX];
            const int n1 = snprintf(child_fs, sizeof child_fs, "%s/%s",
                                    fs_path, de->d_name);
            const int n2 = snprintf(child_arc, sizeof child_arc, "%s/%s",
                                    dir_arc, de->d_name);
            if (n1 < 0 || (size_t)n1 >= sizeof child_fs ||
                n2 < 0 || (size_t)n2 >= sizeof child_arc) {
                rc = -1;
                break;
            }
            if (AddPath(a, child_fs, child_arc, recurse, junk) != 0) rc = -1;
        }
        closedir(d);
        return rc;
    }

    if (S_ISREG(st.st_mode)) return WriteEntry(a, fs_path, arc, &st, NULL);

    complain(fs_path, "unsupported file type");
    return -1;
}

int main(int argc, char** argv)
{
    int recurse = 0, junk = 0, store = 0;
    int i = 1;

    for (; i < argc; i++) {
        if (argv[i][0] != '-' || argv[i][1] == '\0') break;
        if (!strcmp(argv[i], "--")) {
            i++;
            break;
        }
        if (!strcmp(argv[i], "-r")) recurse = 1;
        else if (!strcmp(argv[i], "-q")) g_quiet = 1;
        else if (!strcmp(argv[i], "-j")) junk = 1;
        else if (!strcmp(argv[i], "-0")) store = 1;
        else {
            fprintf(stderr, "zip: unknown option %s\n", argv[i]);
            return 2;
        }
    }

    if (i + 1 >= argc) {
        fprintf(stderr, "usage: zip [-rq0j] archive.zip file...\n");
        return 2;
    }

    const char* archive_path = argv[i++];

    struct archive* a = archive_write_new();
    if (!a) return 1;
    archive_write_set_format_zip(a);
    archive_write_set_format_option(a, "zip", "compression",
                                    store ? "store" : "deflate");

    if (archive_write_open_filename(a, archive_path) != ARCHIVE_OK) {
        fprintf(stderr, "zip: %s: %s\n", archive_path, archive_error_string(a));
        archive_write_free(a);
        return 1;
    }

    int rc = 0;
    for (; i < argc; i++) {
        if (AddPath(a, argv[i], NULL, recurse, junk) != 0) rc = 1;
    }

    archive_write_close(a);
    archive_write_free(a);
    return rc;
}
