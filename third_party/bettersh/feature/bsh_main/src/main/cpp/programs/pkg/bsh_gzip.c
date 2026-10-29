// bsh_gzip.c — 见头文件。只有一个函数，用 zlib 的 inflate（gzip 容器模式）。
//
// 不用 zlib 的 gzopen/gzread：那个 API 只认"一整个文件"，而 apt 需要解文件里的一段
// （虽然索引本身是独立文件，off=0 —— 但保持与 bsh_zstd_decompress_range 同一形状，
// 调用方不用为两种压缩分别记两套参数）。
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <zlib.h>

#include "bsh_gzip.h"

#define IN_CHUNK (128 * 1024)

int bsh_gzip_decompress_range(const char* src, long long off, long long len,
                              const char* dst, char* err, size_t errlen)
{
    int rc = -1, in_fd = -1, out_fd = -1, zs_init = 0;
    unsigned char* in_buf = NULL;
    unsigned char* out_buf = NULL;
    z_stream zs;

    memset(&zs, 0, sizeof zs);

    in_fd = open(src, O_RDONLY);
    if (in_fd < 0) {
        snprintf(err, errlen, "打开源文件失败: %s", strerror(errno));
        return -1;
    }
    if (off > 0 && lseek(in_fd, (off_t)off, SEEK_SET) != (off_t)off) {
        snprintf(err, errlen, "定位源文件失败: %s", strerror(errno));
        goto done;
    }
    out_fd = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) {
        snprintf(err, errlen, "创建目标文件失败: %s", strerror(errno));
        goto done;
    }

    /* 15+16 = gzip 容器（不是裸 deflate，也不带 zlib 头） */
    if (inflateInit2(&zs, 15 + 16) != Z_OK) {
        snprintf(err, errlen, "inflateInit2 失败");
        goto done;
    }
    zs_init = 1;

    in_buf = malloc(IN_CHUNK);
    out_buf = malloc(IN_CHUNK);
    if (!in_buf || !out_buf) {
        snprintf(err, errlen, "分配缓冲失败");
        goto done;
    }

    long long left = len;
    int eof = 0;
    while (!eof) {
        size_t want = IN_CHUNK;
        if (left >= 0) {
            if (left == 0) break;               /* 已到调用方给的边界 */
            if ((long long)want > left) want = (size_t)left;
        }
        ssize_t got = read(in_fd, in_buf, want);
        if (got < 0) {
            if (errno == EINTR) continue;
            snprintf(err, errlen, "读源文件失败: %s", strerror(errno));
            goto done;
        }
        if (got == 0) break;                    /* 输入没了 */
        if (left > 0) left -= got;

        zs.next_in = in_buf;
        zs.avail_in = (uInt)got;
        while (zs.avail_in > 0) {
            zs.next_out = out_buf;
            zs.avail_out = IN_CHUNK;
            int zr = inflate(&zs, Z_NO_FLUSH);
            if (zr != Z_OK && zr != Z_STREAM_END && zr != Z_BUF_ERROR) {
                snprintf(err, errlen, "gzip 解压失败: %s", zs.msg ? zs.msg : "?");
                goto done;
            }
            size_t produced = IN_CHUNK - zs.avail_out;
            size_t o = 0;
            while (o < produced) {
                ssize_t wr = write(out_fd, out_buf + o, produced - o);
                if (wr < 0) {
                    if (errno == EINTR) continue;
                    snprintf(err, errlen, "写目标文件失败: %s", strerror(errno));
                    goto done;
                }
                o += (size_t)wr;
            }
            if (zr == Z_STREAM_END) { eof = 1; break; }
            if (zr == Z_BUF_ERROR && zs.avail_in == 0) break;   /* 等更多输入 */
        }
    }
    rc = 0;

done:
    if (zs_init) inflateEnd(&zs);
    if (in_fd >= 0) close(in_fd);
    if (out_fd >= 0 && close(out_fd) != 0 && rc == 0)
        rc = -1;
    free(in_buf);
    free(out_buf);
    if (rc != 0 && dst) unlink(dst);
    return rc;
}
