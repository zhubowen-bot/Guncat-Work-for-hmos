/* Guncat Work: 交叉编译 libgfortran 的最小替身(shim)
 *
 * 背景: OpenBLAS 的 LAPACK 部分是 Fortran, 用 aarch64-linux-gnu-gfortran 交叉编译。
 * 但 OHOS 上没有 libgfortran, 而 Ubuntu 的 aarch64 libgfortran.a 是 **glibc 版**:
 * 它引用 __ctype_b_loc / __register_frame_info 这类 glibc 专有符号, 还会带进静态 TLS 的 async.o,
 * 直接链进共享库会失败。
 *
 * 好消息: LAPACK + BLAS 实际只用到 **两个** gfortran 运行时符号:
 *   - _gfortran_concat_string  字符参数拼接(极少数例程的报错路径)
 *   - _gfortran_etime          计时(ETIME 例程)
 * 其余(格式化 I/O、异步 I/O、STOP 处理)都用不到。于是这里手写这两个,
 * 既避开 glibc 依赖, 又把体积从 20MB+ 压到几乎为零。
 */

#include <stddef.h>
#include <string.h>
#include <time.h>

/* GNU Fortran 的 concat 语义: 把两个字符参数拼进 dest, 参数以 (长度, 指针) 成对给出。
 * 调用约定: _gfortran_concat_string(int len_dest, char *dest, int len_a, char *a, int len_b, char *b)
 * 源串不足部分用空格补齐(与 libgfortran 一致)。 */
void _gfortran_concat_string(int len_dest, char *dest, int len_a, const char *a,
                             int len_b, const char *b)
{
    int pos = 0;
    int i;
    if (!dest) {
        return;
    }
    for (i = 0; i < len_a && pos < len_dest; i++) {
        dest[pos++] = a ? a[i] : ' ';
    }
    for (i = 0; i < len_b && pos < len_dest; i++) {
        dest[pos++] = b ? b[i] : ' ';
    }
    while (pos < len_dest) {
        dest[pos++] = ' ';
    }
}

/* ETIME: 返回自进程启动以来的秒数; 调用方通常只关心返回值。 */
float _gfortran_etime(float *tarray)
{
    static int started = 0;
    static clock_t t0;
    clock_t now = clock();
    if (!started) {
        started = 1;
        t0 = now;
    }
    float elapsed = (float)((double)(now - t0) / (double)CLOCKS_PER_SEC);
    if (tarray) {
        tarray[0] = elapsed;
        tarray[1] = 0.0f;
    }
    return elapsed;
}

/* glibc 专有的收尾/展开表登记符号: musl 侧要么没有、要么行为不同。
 * 它们只影响"进程退出时跑析构"与"异常展开表登记", 对数值计算没有任何作用,
 * 给空实现即可(共享库由应用托管, 退出时由应用自己收尾)。 */
void __at_fini(void) { }
void __register_frame_info(const void *begin, void *object) { (void)begin; (void)object; }
void __deregister_frame_info(const void *begin) { (void)begin; }
