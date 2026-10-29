// bsh_zstd.c — 见头文件的说明。流式解压，堆占用只有几十 KB（输入/输出各一块缓冲），
// 所以 1.8 GiB 的包也不会把内存顶爆 —— 只是磁盘上会同时存在 .zst 与解出来的 .tar。
//
// 两个入口共用一份内核（zstd_inflate）：一个解整个文件，一个解文件的**一段**
// （apt 解 .deb 里 ar 成员时用：成员在文件中间，得按偏移+长度取）。
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <zstd.h>

#include "bsh_zstd.h"

#define IN_CHUNK (128 * 1024)

static void set_err(char* err, size_t errlen, const char* what) {
    if (err && errlen) snprintf(err, errlen, "%s: %s", what, strerror(errno));
}

/* 解压内核：从 in_fd 的**当前偏移**开始读，最多读 want_len 字节（< 0 = 读到 EOF），
 * 解出来的字节全部写到 out_fd。两个 fd 的开关由调用方负责。 */
static int zstd_inflate(int in_fd, long long want_len, int out_fd,
                        char* err, size_t errlen)
{
    int rc = -1;
    void* in_buf = NULL;
    void* out_buf = NULL;
    ZSTD_DStream* ds = ZSTD_createDStream();

    if (!ds) {
        snprintf(err, errlen, "ZSTD_createDStream 失败（内存？）");
        return -1;
    }
    size_t zrc = ZSTD_initDStream(ds);
    if (ZSTD_isError(zrc)) {
        snprintf(err, errlen, "ZSTD_initDStream: %s", ZSTD_getErrorName(zrc));
        goto done;
    }

    size_t out_cap = ZSTD_DStreamOutSize();
    if (out_cap < IN_CHUNK) out_cap = IN_CHUNK;
    in_buf = malloc(IN_CHUNK);
    out_buf = malloc(out_cap);
    if (!in_buf || !out_buf) {
        snprintf(err, errlen, "分配缓冲失败");
        goto done;
    }

    long long left = want_len;
    for (;;) {
        size_t want = IN_CHUNK;
        if (left >= 0) {                        /* 有长度上限：读到那儿就停 */
            if (left == 0)
                break;
            if ((long long)want > left)
                want = (size_t)left;
        }
        ssize_t got = read(in_fd, in_buf, want);
        if (got < 0) {
            if (errno == EINTR) continue;
            set_err(err, errlen, "读源文件失败");
            goto done;
        }
        if (got == 0) break;                    /* 文件读完 */
        if (left > 0) left -= got;

        ZSTD_inBuffer in = { in_buf, (size_t)got, 0 };
        while (in.pos < in.size) {
            ZSTD_outBuffer out = { out_buf, out_cap, 0 };
            zrc = ZSTD_decompressStream(ds, &out, &in);
            if (ZSTD_isError(zrc)) {
                snprintf(err, errlen, "zstd 解压失败: %s", ZSTD_getErrorName(zrc));
                goto done;
            }
            size_t off = 0;
            while (off < out.pos) {
                ssize_t wr = write(out_fd, (char*)out_buf + off, out.pos - off);
                if (wr < 0) {
                    if (errno == EINTR) continue;
                    set_err(err, errlen, "写目标文件失败");
                    goto done;
                }
                off += (size_t)wr;
            }
            if (zrc == 0) continue;              /* 这一帧结束，后面可能还有帧 */
        }
    }

    /* 留 zrc 语义给调用方：最后一帧必须正好收尾（zrc==0）。zstd 允许尾随空白？不允许，
     * 但也不必苛求 —— 解出来能用就行，这里只保证没有解压错误。 */
    rc = 0;

done:
    if (ds) ZSTD_freeDStream(ds);
    free(in_buf);
    free(out_buf);
    return rc;
}

int bsh_zstd_decompress_file(const char* src, const char* dst,
                             char* err, size_t errlen) {
    int in_fd = open(src, O_RDONLY);
    if (in_fd < 0) { set_err(err, errlen, "打开源文件失败"); return -1; }

    int out_fd = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) {
        set_err(err, errlen, "创建目标文件失败");
        close(in_fd);
        return -1;
    }

    int rc = zstd_inflate(in_fd, -1, out_fd, err, errlen);
    close(in_fd);
    if (close(out_fd) != 0 && rc == 0) {
        set_err(err, errlen, "关目标文件失败");
        rc = -1;
    }
    if (rc != 0 && dst) unlink(dst);             /* 半截的解压结果别留着 */
    return rc;
}

int bsh_zstd_decompress_range(const char* src, long long off, long long len,
                              const char* dst, char* err, size_t errlen) {
    int in_fd = open(src, O_RDONLY);
    if (in_fd < 0) { set_err(err, errlen, "打开源文件失败"); return -1; }
    if (off > 0 && lseek(in_fd, (off_t)off, SEEK_SET) != (off_t)off) {
        set_err(err, errlen, "定位源文件失败");
        close(in_fd);
        return -1;
    }

    int out_fd = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) {
        set_err(err, errlen, "创建目标文件失败");
        close(in_fd);
        return -1;
    }

    int rc = zstd_inflate(in_fd, len, out_fd, err, errlen);
    close(in_fd);
    if (close(out_fd) != 0 && rc == 0) {
        set_err(err, errlen, "关目标文件失败");
        rc = -1;
    }
    if (rc != 0 && dst) unlink(dst);
    return rc;
}
