// bsh_deb.h — .deb（ar 归档）的最小解析器，给 apt 用
//
// .deb 就是一个 ar 归档，成员固定三个：
//     debian-binary        文本 "2.0\n"
//     control.tar.<压缩>   包名/版本/依赖等元数据（单个 ./control 文件）
//     data.tar.<压缩>      实际文件树
//
// 我们只做三件事：列成员、按名字找成员、把某个成员解成裸文件。压缩格式按成员名的
// 后缀判断（.zst 走 zstd、.gz 走 zlib、.xz 走 bsh_xz 里那份 xz-embedded）。
//
// 为什么自己写而不是用外部 ar：设备上没有 ar（toybox 也没有），而且 ar 格式本身
// 只有 60 字节头 + 数据 + 偶数对齐，一百行就能覆盖。
#pragma once

#include <stddef.h>

struct bsh_deb_member {
    char      name[64];      /* 成员名，已去掉尾部空白与 GNU 的 '/' 结尾 */
    long long offset;        /* 数据在 .deb 文件里的字节偏移 */
    long long size;          /* 数据字节数（不含 ar 的偶数对齐填充） */
};

/* 列出成员。返回成员总数（可能大于 max，此时只写了前 max 个）；
 * 失败返回负值并把原因写进 err。out 可以传 NULL（只数个数）。 */
int bsh_deb_members(const char* debpath, struct bsh_deb_member* out, int max,
                    char* err, size_t errlen);

/* 按精确名字找成员。找到返回 1 并填 *out；没有返回 0；出错返回负值。 */
int bsh_deb_find_member(const char* debpath, const char* name,
                        struct bsh_deb_member* out, char* err, size_t errlen);

/* 把成员解成**裸文件**（没有已知压缩后缀就原样复制）。成功返回 0。 */
int bsh_deb_unpack_member(const char* debpath, const struct bsh_deb_member* m,
                          const char* out_path, char* err, size_t errlen);

/* 解出 control 文件的**文本内容**（*buf 是 malloc 的，末尾补 '\0'）。
 * tmp_dir 用来放解 control.tar 时的临时文件（同分区越快）。 */
int bsh_deb_read_control(const char* debpath, const char* tmp_dir,
                         char** buf, size_t* len, char* err, size_t errlen);

/* 从 control 文本里取一个字段（"Package"、"Version"、"Depends"…），续行会拼成一行。
 * 找到返回 1 并写 out；没有该字段返回 0（out 置空）。 */
int bsh_deb_field(const char* control, const char* field, char* out, size_t outlen);
