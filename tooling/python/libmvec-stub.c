/* Guncat Work: libmvec 替身 —— glibc 的向量数学库在 musl 上不存在。
 *
 * scipy 的部分 Fortran 目标文件被 glibc 的 gfortran 驱动加上了 `-lmvec`, 于是运行时要求
 * libmvec.so.1; 实际用到的只是几个向量化的初等函数(如 `_ZGVnN2v_sin`)。
 * 这里用标量函数逐个实现, 语义完全一致(只是没有 SIMD 加速)。
 *
 * 命名规则(GNU vector ABI):
 *   _ZGVnN2v_sin   double[2] 输出/输入
 *   _ZGVnN4v_sinf  float[4]
 *   _ZGVnN2vv_pow  double[2], 两个输入向量
 */

#include <math.h>

#define VEC2(name, fn) \
    void _ZGVnN2v_##name(double *out, const double *in) \
    { \
        out[0] = fn(in[0]); \
        out[1] = fn(in[1]); \
    }

#define VEC4(name, fn) \
    void _ZGVnN4v_##name##f(float *out, const float *in) \
    { \
        out[0] = fn##f(in[0]); \
        out[1] = fn##f(in[1]); \
        out[2] = fn##f(in[2]); \
        out[3] = fn##f(in[3]); \
    }

VEC2(sin, sin)
VEC2(cos, cos)
VEC2(tan, tan)
VEC2(asin, asin)
VEC2(acos, acos)
VEC2(atan, atan)
VEC2(exp, exp)
VEC2(log, log)
VEC2(sqrt, sqrt)
VEC2(fabs, fabs)

VEC4(sin, sin)
VEC4(cos, cos)
VEC4(exp, exp)
VEC4(log, log)
VEC4(sqrt, sqrt)

/* 两个输入向量的版本(如 pow) */
void _ZGVnN2vv_pow(double *out, const double *a, const double *b)
{
    out[0] = pow(a[0], b[0]);
    out[1] = pow(a[1], b[1]);
}

void _ZGVnN2vv_atan2(double *out, const double *a, const double *b)
{
    out[0] = atan2(a[0], b[0]);
    out[1] = atan2(a[1], b[1]);
}
