// bsh_tar.h — pkg/apt 用的最小 tar 解包器（只认普通文件、目录与链接）
//
// 为什么自己写而不是调 toybox 的 tar：pkg 是 CMake 编的命令 so，走 exec 委托要连带
// 把 shim 家族的 wrap 清单也编进来；而我们的包是自己打的、只用普通文件+目录，
// 解析 tar 本来就只有一百多行。少一层依赖，少一处出错的地方。
//
// 不支持（碰到就跳过）：设备节点、fifo、xattr、稀疏文件、压缩（调用方自己先解压）。
#pragma once

#include <stddef.h>

/* 每解出一个成员回调一次（relpath 相对 dest_root，用来记安装清单）。返回非 0 则中止。 */
typedef int (*bsh_tar_list_fn)(void* ctx, const char* relpath);

/* 解包时的可选钩子，三个都可以是 NULL。 */
struct bsh_tar_hooks {
    /* 普通文件 / 目录解出来时回调（记安装清单用）。返回非 0 则中止解包。 */
    int (*on_member)(void* ctx, const char* relpath);

    /* 链接成员（typeflag '2' 符号链接 / '1' 硬链接）回调：relpath 是成员路径，
     * target 是头里的 linkname（原样，可能是相对路径）。返回非 0 则中止。
     *
     * 为什么需要它：沙箱里 symlink(2) 被拒，软链解了等于没解。apt 靠这个回调把
     * 软链**代偿**成真文件或包装脚本（usr/bin/code → ../share/code/bin/code 这种）。
     * 不关心软链的调用方传 NULL 即可 —— 行为与"静默跳过"一致。 */
    int (*on_link)(void* ctx, const char* relpath, const char* target);

    /* 返回非 0 = 跳过这个成员（不落盘，也不回调 on_member）。apt 用它实现
     * "目标已存在就不覆盖"。NULL = 全都解。 */
    int (*skip)(void* ctx, const char* relpath);
};

/* 把 tar_path 解到 dest_root 下。成功返回 0；失败返回负值并写 err。
 * hooks 可以为 NULL（等价于三个钩子都为 NULL）。 */
int bsh_tar_extract_h(const char* tar_path, const char* dest_root,
                      const struct bsh_tar_hooks* hooks, void* ctx,
                      char* err, size_t errlen);

/* 只要 on_member 的简化入口（pkg 用）。 */
int bsh_tar_extract(const char* tar_path, const char* dest_root,
                    bsh_tar_list_fn fn, void* ctx,
                    char* err, size_t errlen);

/* 只把**一个**成员的普通文件内容读进内存（*buf 是 malloc 出来的，末尾补 '\0' 方便当
 * 文本用；*len 是不含补的那个字节的长度）。成员名比较时忽略前导 "./"。
 * 找到返回 0；没这个成员返回 1；出错返回负值。 */
int bsh_tar_extract_one(const char* tar_path, const char* member,
                        char** buf, size_t* len, char* err, size_t errlen);

/* 只列成员名（不落盘），给 pkg remove 用。 */
int bsh_tar_list(const char* tar_path, bsh_tar_list_fn fn, void* ctx,
                 char* err, size_t errlen);
