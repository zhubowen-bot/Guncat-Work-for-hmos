/*
 * Minimal <error.h> stub for OHOS musl.
 * Provides GNU error(3) / error_at_line(3) inline.
 */
#ifndef BOX64_OHOS_ERROR_H
#define BOX64_OHOS_ERROR_H

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <errno.h>

#ifdef __cplusplus
extern "C" {
#endif

extern unsigned int error_message_count;
extern int          error_one_per_line;
extern void       (*error_print_progname)(void);

static inline void error(int status, int errnum, const char *fmt, ...)
{
    va_list ap;
    fflush(stdout);
    if (error_print_progname) error_print_progname();
    else                      fputs("box64: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    if (errnum) fprintf(stderr, ": %s", strerror(errnum));
    fputc('\n', stderr);
    error_message_count++;
    if (status) exit(status);
}

static inline void error_at_line(int status, int errnum,
                                 const char *fname, unsigned int lineno,
                                 const char *fmt, ...)
{
    va_list ap;
    fflush(stdout);
    fprintf(stderr, "%s:%u: ", fname ? fname : "?", lineno);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    if (errnum) fprintf(stderr, ": %s", strerror(errnum));
    fputc('\n', stderr);
    error_message_count++;
    if (status) exit(status);
}

#ifdef __cplusplus
}
#endif

#endif /* BOX64_OHOS_ERROR_H */
