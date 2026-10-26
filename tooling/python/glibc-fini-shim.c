/* Guncat Work: 给 glibc 版 libgfortran 补三个 OHOS/musl 没有的收尾符号。
 *
 * 交叉编译 scipy 时, Fortran 代码要链 aarch64 的 libgfortran。Ubuntu 的这份是 glibc 版,
 * 其中有几个"进程退出/异常表登记"相关符号 musl 里没有(或语义不同):
 *   __at_fini / __register_frame_info / __deregister_frame_info
 * 它们只影响退出时的析构与展开表登记, 对数值计算毫无影响, 空实现即可。
 *
 * 注意: 这里**不要**再定义 _gfortran_* —— 那些由 libgfortran 自己提供,
 * 重复定义会让链接报 "multiple definition of `_gfortran_concat_string'"(踩过)。
 */

void __at_fini(void) { }

void __register_frame_info(const void *begin, void *object)
{
    (void)begin;
    (void)object;
}

void __deregister_frame_info(const void *begin)
{
    (void)begin;
}

