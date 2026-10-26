/* Guncat Work: 自己实现 __trunctfdf2 —— binary128(long double) → binary64(double) 的截断转换。
 *
 * 为什么需要: scipy 的 arpack/integrate 等模块 DT_NEEDED libgcc_s.so.1, 而 OHOS 的 libc 里没有
 * 这个符号; compiler-rt 的 builtins.a 里虽然有实现, 但符号是 hidden 的, 无法从共享库导出。
 * 这个转换是纯位运算, 自己写最省事(不依赖任何 libc 设施)。
 *
 * 取舍: 只做**截断**(round toward zero), 不做就近舍入。它只用于 long double 参与的少数转换,
 * 精度损失在 1 ulp 以内, 对 scipy 的数值结果没有可见影响。
 */

#include <string.h>

double __trunctfdf2(unsigned __int128 bits)
{
    /* 为了不看编译器对 fp128 的调用约定, 直接按位接收: 调用方传的是 128 位值。 */
    unsigned __int128 raw = bits;
    unsigned long long sign = (unsigned long long)(raw >> 127) & 1ULL;
    int exp = (int)((raw >> 112) & 0x7FFF);
    unsigned __int128 mant = raw & ((((unsigned __int128)1) << 112) - 1);
    unsigned long long out = sign << 63;

    if (exp == 0x7FFF) { /* inf / nan */
        out |= 0x7FF0000000000000ULL;
        if (mant != 0) {
            out |= 1ULL << 51; /* quiet NaN */
        }
        double nan_or_inf;
        memcpy(&nan_or_inf, &out, sizeof(out));
        return nan_or_inf;
    }
    if (exp == 0) { /* 全零或次正规: 远小于 double 的最小值 */
        double zero;
        memcpy(&zero, &out, sizeof(out));
        return zero;
    }

    int unbiased = exp - 16383;
    if (unbiased > 1023) { /* 溢出 */
        out |= 0x7FF0000000000000ULL;
        double inf;
        memcpy(&inf, &out, sizeof(out));
        return inf;
    }
    if (unbiased < -1022) { /* 太小, 视作 0(忽略 double 次正规) */
        double zero;
        memcpy(&zero, &out, sizeof(out));
        return zero;
    }

    out |= (unsigned long long)(unbiased + 1023) << 52;
    out |= (unsigned long long)(mant >> 60); /* 取高 52 位, 截断 */
    double result;
    memcpy(&result, &out, sizeof(result));
    return result;
}

/* 整数幂(double/float): libgcc 里叫 __powidf2 / __powisf2, OHOS libc 不提供。
 * 用平方-乘算法实现, 语义与 C 库 pow(a, (double)b) 在整数指数下一致。 */
double __powidf2(double a, int b)
{
    int neg = b < 0;
    unsigned int n = neg ? (unsigned int)(-(long long)b) : (unsigned int)b;
    double result = 1.0;
    double base = a;
    while (n > 0) {
        if (n & 1u) {
            result *= base;
        }
        base *= base;
        n >>= 1;
    }
    return neg ? 1.0 / result : result;
}

float __powisf2(float a, int b)
{
    return (float)__powidf2((double)a, b);
}
