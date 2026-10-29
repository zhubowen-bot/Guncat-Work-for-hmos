#ifndef RESOLVER_H
#define RESOLVER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define IEC_SYMLINK_SUFFIX ".IEC_SYMLINK"

/* Directory mapping entry: logical prefix from -> real prefix to (both must be canonical absolute paths) */
typedef struct {
    const char *from;
    const char *to;
} iec_map_t;

typedef struct {
    const char      *cwd;        /* Logical working directory (participates in mapping and link resolution); NULL means use getcwd() */
    const char      *path_env;   /* ':'-separated; NULL means use getenv("PATH") */
    int              max_links;  /* <=0 means the default of 40 */
    const iec_map_t *maps;       /* Directory mapping table; may be NULL */
    size_t           nmaps;
    char            *errmsg;     /* Optional: receives a diagnostic message on failure */
    size_t           errmsg_size;
} iec_opts_t;

/*
 * Resolve a command, relative path, or absolute path to a real physical path.
 * Returns 0 on success; on failure returns -errno:
 *   -EINVAL -ENOENT -ENOTDIR -ELOOP -ENAMETOOLONG -ERANGE etc.
 */
int iec_resolve(const char *input, const iec_opts_t *opts,
                char *out, size_t out_size);

/* Path resolution only; does not search PATH */
int iec_resolve_path(const char *path, const iec_opts_t *opts,
                     char *out, size_t out_size);

/*
 * Helper: parse a text-form mapping table (modifies buf in place).
 * Format: "/bin->/sandbox/bin; /lib -> /sandbox/lib"
 *   Separators may be ';' or newline; whitespace is allowed around each entry; entries starting with '#' are ignored.
 * Parsed maps[i] point inside buf, so buf must outlive maps.
 * Returns the number of parsed entries; returns -EINVAL on malformed input, -ENOSPC when cap is exceeded.
 */
int iec_parse_maps(char *buf, iec_map_t *maps, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* RESOLVER_H */
