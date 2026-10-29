// cmd_hexdump.c — hexdump（IEC 命令 so）。
//
// 支持 -C（canonical）、-b、-c、-x、-d、-o、-n length、-s offset、多个文件/`-`。
// 默认按两字节十六进制（BSD hexdump 的默认格式）。
//
// 输出严格对齐 BSD/util-linux hexdump：
//   * 行首偏移；所有数据输出完后另起一行打印最终偏移（无数据时不打印）；
//   * 不满一行的部分行用空格补齐到整行宽度（-C 补到第 60 列再出 |文本|）；
//   * 相邻且内容完全相同的 16 字节整块折叠为一行 "*"（-v 关闭折叠）；
//   * 多个文件按一条字节流拼接，偏移与 16 字节分组都跨文件连续。
//
// 入口 iec_hexdump_main。
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum mode { MODE_X, MODE_C, MODE_B, MODE_C_CHAR, MODE_D, MODE_O };

#define BLOCK 16      /* 每个显示行固定对应 16 字节输入 */
#define LINE_WIDTH 71 /* 单元模式的整行宽度：7 位偏移 + 16×4 或 8×8 */

struct dumper {
    enum mode mode;
    int verbose; /* -v：关闭重复块折叠 */
    unsigned long long off;
    unsigned long long skip;
    unsigned long long remaining;
    unsigned char pend[BLOCK];
    size_t pend_len;
    unsigned char prev[BLOCK];
    int have_prev;
    int folded;
};

static void usage(void) {
    fprintf(stderr, "usage: hexdump [-C|-b|-c|-x|-d|-o] [-n length] [-s offset] [file ...]\n");
}

/* 只用 ASCII 可打印区，避免受 locale 影响（系统 hexdump 在 C locale 下同此行为）。 */
static int is_print(unsigned char c) {
    return c >= 0x20 && c < 0x7f;
}

static void emit_canonical(const unsigned char* p, size_t n, unsigned long long off) {
    size_t i;
    printf("%08llx  ", off);
    for (i = 0; i < BLOCK; i++) {
        if (i < n) {
            printf("%02x", p[i]);
        } else {
            printf("  ");
        }
        putchar(' ');
        if (i == 7) putchar(' '); /* 两半之间多一个空格 */
    }
    putchar(' ');
    putchar('|');
    for (i = 0; i < n; i++) putchar(is_print(p[i]) ? (int)p[i] : '.');
    printf("|\n");
}

static void emit_units(const unsigned char* p, size_t n, unsigned long long off, enum mode m) {
    const size_t width = (m == MODE_B || m == MODE_C_CHAR) ? 1 : 2;
    int col = printf("%07llx", off);
    size_t i;

    for (i = 0; i < BLOCK; i += width) {
        unsigned v = 0;
        size_t k;
        if (i >= n) {
            /* 整单元缺失：补空格（-x 的最后一个单元只缺一半时仍按 0 补齐显示） */
            const int pad = (width == 1) ? 4 : 8;
            int j;
            for (j = 0; j < pad; j++) putchar(' ');
            col += pad;
            continue;
        }
        for (k = 0; k < width; k++) {
            const size_t idx = i + k;
            v |= (idx < n ? (unsigned)p[idx] : 0u) << (8 * k);
        }
        switch (m) {
            case MODE_B:
                col += printf(" %03o", v & 0xff);
                break;
            case MODE_C_CHAR: {
                const unsigned char c = (unsigned char)(v & 0xff);
                if (c == '\0') col += printf("  \\0");
                else if (c == '\a') col += printf("  \\a");
                else if (c == '\b') col += printf("  \\b");
                else if (c == '\t') col += printf("  \\t");
                else if (c == '\n') col += printf("  \\n");
                else if (c == '\v') col += printf("  \\v");
                else if (c == '\f') col += printf("  \\f");
                else if (c == '\r') col += printf("  \\r");
                else if (is_print(c)) col += printf("   %c", c);
                else col += printf(" %03o", c);
                break;
            }
            case MODE_D:
                col += printf("   %05u", v & 0xffff);
                break;
            case MODE_O:
                col += printf("  %06o", v & 0xffff);
                break;
            case MODE_X:
            default:
                col += printf("    %04x", v & 0xffff);
                break;
        }
    }
    while (col < LINE_WIDTH) {
        putchar(' ');
        col++;
    }
    putchar('\n');
}

static void emit_block(struct dumper* d, size_t n) {
    if (n == BLOCK && d->have_prev && !d->verbose && memcmp(d->prev, d->pend, BLOCK) == 0) {
        if (!d->folded) {
            printf("*\n");
            d->folded = 1;
        }
    } else {
        if (d->mode == MODE_C) {
            emit_canonical(d->pend, n, d->off);
        } else {
            emit_units(d->pend, n, d->off, d->mode);
        }
        d->folded = 0;
        if (n == BLOCK) {
            memcpy(d->prev, d->pend, BLOCK);
            d->have_prev = 1;
        }
    }
    d->off += n;
    d->pend_len = 0;
}

static void feed(struct dumper* d, const unsigned char* p, size_t n) {
    while (n > 0) {
        size_t take = BLOCK - d->pend_len;
        if (take > n) take = n;
        memcpy(d->pend + d->pend_len, p, take);
        d->pend_len += take;
        p += take;
        n -= take;
        if (d->pend_len == BLOCK) emit_block(d, BLOCK);
    }
}

static void finish(struct dumper* d) {
    if (d->pend_len > 0) emit_block(d, d->pend_len);
    if (d->off > 0) {
        if (d->mode == MODE_C) {
            printf("%08llx\n", d->off);
        } else {
            printf("%07llx\n", d->off);
        }
    }
}

static int dump_file(FILE* f, struct dumper* d) {
    unsigned char buf[65536];
    int rc = 0;

    while (d->skip > 0) {
        const size_t want = d->skip > sizeof buf ? sizeof buf : (size_t)d->skip;
        const size_t n = fread(buf, 1, want, f);
        if (n == 0) {
            if (ferror(f)) rc = 1;
            return rc;
        }
        d->skip -= n;
        d->off += n;
    }

    while (d->remaining > 0) {
        size_t want = sizeof buf;
        size_t n;
        if (d->remaining < (unsigned long long)want) want = (size_t)d->remaining;
        n = fread(buf, 1, want, f);
        if (n == 0) {
            if (ferror(f)) rc = 1;
            break;
        }
        feed(d, buf, n);
        d->remaining -= n;
    }
    return rc;
}

int iec_hexdump_main(int argc, char** argv) {
    struct dumper d;
    int i = 1;
    int rc = 0;

    memset(&d, 0, sizeof d);
    d.mode = MODE_X;
    d.remaining = ~0ULL;

    for (; i < argc; i++) {
        const char* a = argv[i];
        if (strcmp(a, "-C") == 0) d.mode = MODE_C;
        else if (strcmp(a, "-b") == 0) d.mode = MODE_B;
        else if (strcmp(a, "-c") == 0) d.mode = MODE_C_CHAR;
        else if (strcmp(a, "-x") == 0) d.mode = MODE_X;
        else if (strcmp(a, "-d") == 0) d.mode = MODE_D;
        else if (strcmp(a, "-o") == 0) d.mode = MODE_O;
        else if (strcmp(a, "-n") == 0 && i + 1 < argc) d.remaining = strtoull(argv[++i], NULL, 0);
        else if (strcmp(a, "-s") == 0 && i + 1 < argc) d.skip = strtoull(argv[++i], NULL, 0);
        else if (strcmp(a, "-v") == 0) d.verbose = 1;
        else if (a[0] == '-' && a[1] != '\0' && strcmp(a, "-") != 0) {
            usage();
            return 1;
        } else {
            break;
        }
    }

    /* -n 0 表示不读取任何输入：util-linux/BSD 连文件都不打开，也不因 -s 推进
     * 偏移或打印最终偏移行（`hexdump -n 0 -s 5 file` 输出为空、退出 0）。
     * 必须在打开/跳过之前返回，否则 -s 会把 off 推高并多打一行最终偏移。 */
    if (d.remaining == 0) return 0;

    if (i >= argc) {
        rc = dump_file(stdin, &d);
        finish(&d);
        return rc;
    }

    for (; i < argc; i++) {
        if (strcmp(argv[i], "-") == 0) {
            if (dump_file(stdin, &d) != 0) rc = 1;
        } else {
            FILE* f = fopen(argv[i], "rb");
            if (f == NULL) {
                fprintf(stderr, "hexdump: %s: %s\n", argv[i], strerror(errno));
                rc = 1;
                continue;
            }
            if (dump_file(f, &d) != 0) rc = 1;
            fclose(f);
        }
        if (d.remaining == 0) break; /* -n 已读满，后续文件不再参与 */
    }
    finish(&d);
    return rc;
}
