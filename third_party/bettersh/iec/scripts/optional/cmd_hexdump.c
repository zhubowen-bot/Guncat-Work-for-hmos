// cmd_hexdump.c — hexdump（IEC 命令 so）。
//
// 支持 -C（canonical）、-b、-c、-x、-d、-o、-n length、-s offset、多个文件/`-`。
// 默认按两字节十六进制（BSD hexdump 的默认格式）。
//
// 入口 iec_hexdump_main。
#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum mode { MODE_X, MODE_C, MODE_B, MODE_C_CHAR, MODE_D, MODE_O };

static void usage(void) {
    fprintf(stderr, "usage: hexdump [-C|-b|-c|-x|-d|-o] [-n length] [-s offset] [file ...]\n");
}

static void dump_canonical(const unsigned char* p, size_t n, unsigned long long off) {
    printf("%08llx  ", off);
    for (size_t i = 0; i < 16; i++) {
        if (i < n) printf("%02x", p[i]); else printf("  ");
        if (i % 2 == 1) putchar(' ');
    }
    printf(" |");
    for (size_t i = 0; i < n; i++) putchar(isprint(p[i]) ? p[i] : '.');
    printf("|\n");
}

static void dump_units(const unsigned char* p, size_t n, unsigned long long off, enum mode m) {
    printf("%07llx", off);
    const int width = (m == MODE_B || m == MODE_C_CHAR) ? 1 : 2;
    for (size_t i = 0; i < n; i += (size_t)width) {
        unsigned v = 0;
        for (int k = 0; k < width; k++) {
            const size_t idx = i + (size_t)k;
            v |= (idx < n ? (unsigned)p[idx] : 0u) << (8 * k);
        }
        switch (m) {
            case MODE_B: printf(" %03o", v & 0xff); break;
            case MODE_C_CHAR: {
                const unsigned char c = (unsigned char)(v & 0xff);
                if (c == '\n') printf("  \\n");
                else if (c == '\t') printf("  \\t");
                else if (c == '\r') printf("  \\r");
                else if (isprint(c)) printf("   %c", c);
                else printf(" %03o", c);
                break;
            }
            case MODE_D: printf(" %05u", v & 0xffff); break;
            case MODE_O: printf(" %06o", v & 0xffff); break;
            case MODE_X:
            default: printf(" %04x", v & 0xffff); break;
        }
    }
    printf("\n");
}

static int dump_stream(FILE* f, enum mode m, unsigned long long skip, unsigned long long limit) {
    unsigned char buf[65536];
    unsigned long long off = 0;
    size_t n = 0;
    int rc = 0;

    while (skip > 0) {
        const size_t want = skip > sizeof buf ? sizeof buf : (size_t)skip;
        n = fread(buf, 1, want, f);
        if (n == 0) return 0;
        skip -= n;
        off += n;
    }

    unsigned long long remaining = limit;
    while (remaining > 0) {
        size_t want = sizeof buf;
        if (remaining != ~0ULL && want > remaining) want = (size_t)remaining;
        n = fread(buf, 1, want, f);
        if (n == 0) {
            if (ferror(f)) rc = 1;
            break;
        }
        if (m == MODE_C) {
            for (size_t i = 0; i < n; i += 16) {
                const size_t chunk = (n - i) > 16 ? 16 : (n - i);
                dump_canonical(buf + i, chunk, off);
                off += chunk;
            }
        } else {
            const size_t unit = (m == MODE_B || m == MODE_C_CHAR) ? 1 : 2;
            for (size_t i = 0; i < n; i += 16 * unit) {
                const size_t chunk = (n - i) > 16 * unit ? 16 * unit : (n - i);
                dump_units(buf + i, chunk, off, m);
                off += chunk;
            }
        }
        if (remaining != ~0ULL) remaining -= n;
    }
    return rc;
}

int iec_hexdump_main(int argc, char** argv) {
    enum mode m = MODE_X;
    unsigned long long skip = 0;
    unsigned long long limit = ~0ULL;
    int i = 1;

    for (; i < argc; i++) {
        const char* a = argv[i];
        if (strcmp(a, "-C") == 0) m = MODE_C;
        else if (strcmp(a, "-b") == 0) m = MODE_B;
        else if (strcmp(a, "-c") == 0) m = MODE_C_CHAR;
        else if (strcmp(a, "-x") == 0) m = MODE_X;
        else if (strcmp(a, "-d") == 0) m = MODE_D;
        else if (strcmp(a, "-o") == 0) m = MODE_O;
        else if (strcmp(a, "-n") == 0 && i + 1 < argc) limit = strtoull(argv[++i], NULL, 0);
        else if (strcmp(a, "-s") == 0 && i + 1 < argc) skip = strtoull(argv[++i], NULL, 0);
        else if (strcmp(a, "-v") == 0) { /* 不做重复行折叠，-v 无影响 */ }
        else if (a[0] == '-' && a[1] != '\0' && strcmp(a, "-") != 0) {
            usage();
            return 1;
        } else {
            break;
        }
    }

    if (i >= argc) {
        return dump_stream(stdin, m, skip, limit);
    }
    int rc = 0;
    for (; i < argc; i++) {
        if (strcmp(argv[i], "-") == 0) {
            if (dump_stream(stdin, m, skip, limit) != 0) rc = 1;
            continue;
        }
        FILE* f = fopen(argv[i], "rb");
        if (f == NULL) {
            fprintf(stderr, "hexdump: %s: %s\n", argv[i], strerror(errno));
            rc = 1;
            continue;
        }
        if (dump_stream(f, m, skip, limit) != 0) rc = 1;
        fclose(f);
    }
    return rc;
}
