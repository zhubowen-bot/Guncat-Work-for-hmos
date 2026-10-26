/* Guncat Work: 极简 libgfortran 运行时替身 —— 让 scipy 的 Fortran 扩展**不依赖 libgfortran**。
 *
 * 背景: Ubuntu 的 aarch64 libgfortran.a 是 glibc 版, 里面若干 TLS 变量用 initial-exec 模型,
 * musl 动态链接器无法解析("initial-exec TLS resolves to dynamic definition"), 导致
 * scipy.linalg / optimize / special / stats / sparse / signal / interpolate / integrate / spatial
 * 全部 import 失败 —— 只剩 fft/ndimage/constants 能用。
 *
 * 实测 scipy 的 113 个 .so 一共只引用 **16 个** gfortran 运行时符号, 而且绝大多数是
 * "把 PRINT/WRITE 变成调用"的 I/O 入口(数值路径根本不走)。于是这里全部给最小实现,
 * 配合把 Fortran 目标文件改用 OHOS clang 链接(见 tooling/python/build-scipy-ohos.sh 的 fc 包装器),
 * 就彻底不需要 libgfortran 了。
 *
 * 注意: 这些函数在 Fortran ABI 里接收 st_parameter_* 结构指针, 我们不需要解析它,
 * 用 void* 接住即可; 字符串类例程按 (长度, 指针) 取值。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

/* ---------- 字符串比较 / 长度 ---------- */
int _gfortran_compare_string(int len1, const char *s1, int len2, const char *s2)
{
    int n = len1 < len2 ? len1 : len2;
    int rc = 0;
    if (n > 0 && s1 && s2) {
        rc = memcmp(s1, s2, (size_t)n);
    }
    if (rc == 0 && len1 != len2) {
        rc = len1 < len2 ? -1 : 1;
    }
    return rc;
}

int _gfortran_string_len_trim(int len, const char *s)
{
    int n = len;
    if (!s) {
        return 0;
    }
    while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t')) {
        n--;
    }
    return n;
}

/* ---------- 终止 ---------- */
void _gfortran_stop_numeric(int code, int quiet)
{
    (void)quiet;
    if (code != 0) {
        fprintf(stderr, "Fortran STOP %d\n", code);
    }
    /* 不直接 exit: 让 Python 侧能拿到异常/错误信息, 由调用方决定。 */
}

void _gfortran_stop_string(const char *str, int len, int quiet)
{
    (void)quiet;
    if (str && len > 0) {
        fprintf(stderr, "Fortran STOP %.*s\n", len, str);
    }
}

/* ---------- 有格式 I/O: 数值计算不走这里, 空实现即可 ---------- */
void _gfortran_st_close(void *p) { (void)p; }
void _gfortran_st_open(void *p) { (void)p; }
void _gfortran_st_read(void *p) { (void)p; }
void _gfortran_st_read_done(void *p) { (void)p; }
void _gfortran_st_write(void *p) { (void)p; }
void _gfortran_st_write_done(void *p) { (void)p; }
void _gfortran_transfer_array(void *p, void *q, int kind, int type)
{
    (void)p; (void)q; (void)kind; (void)type;
}
void _gfortran_transfer_array_write(void *p, void *q, int kind, int type)
{
    (void)p; (void)q; (void)kind; (void)type;
}
void _gfortran_transfer_character_write(void *p, void *q, int len)
{
    (void)p; (void)q; (void)len;
}
void _gfortran_transfer_complex_write(void *p, void *q, int kind)
{
    (void)p; (void)q; (void)kind;
}
void _gfortran_transfer_integer_write(void *p, void *q, int kind)
{
    (void)p; (void)q; (void)kind;
}
void _gfortran_transfer_real_write(void *p, void *q, int kind)
{
    (void)p; (void)q; (void)kind;
}

/* Fortran 程序的 main() 会调这两个做初始化(argc/argv 与运行选项); 我们只保存指针。 */
static int g_argc = 0;
static char **g_argv = 0;

void _gfortran_set_args(int argc, char **argv)
{
    g_argc = argc;
    g_argv = argv;
}

void _gfortran_set_options(int num, const int *options)
{
    (void)num;
    (void)options;
}

/* 部分 glibc 目标文件(如 arpack)会引用 glibc 的 fork 处理器登记; musl 只有 pthread_atfork。
 * 放在这里是因为这些模块会 DT_NEEDED 我们这份 libgfortran.so.5, 从它解析最省事。 */
int __register_atfork(void (*prepare)(void), void (*parent)(void), void (*child)(void),
                      void *dso_handle)
{
    (void)dso_handle;
    return pthread_atfork(prepare, parent, child);
}
