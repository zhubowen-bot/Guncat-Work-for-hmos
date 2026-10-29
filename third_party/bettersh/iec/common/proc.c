// common/proc.c — see common/proc.h.
#include "proc.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

pid_t iec_parent_pid(pid_t pid) {
    char path[64];
    char buf[1024];
    char *p;
    long ppid;

    snprintf(path, sizeof path, "/proc/%d/stat", (int)pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = '\0';

    /* "<pid> (<comm>) <state> <ppid> ...". The command name can contain ')' and
     * spaces, so the last ')' is the one that closes it; the fields after it are
     * single-token and follow in order. */
    p = strrchr(buf, ')');
    if (p == NULL || p[1] == '\0') return 0;
    p++;
    while (*p == ' ') p++;
    if (*p == '\0') return 0;
    p++;                                   /* the state field */
    while (*p == ' ') p++;
    ppid = strtol(p, NULL, 10);
    return ppid > 0 ? (pid_t)ppid : 0;
}
