// common/bsh_rawfile.h — hap 内 rawfile(打包进应用资源)的统一访问口
//
// 为什么要有这一层:rawfile 的入口 NativeResourceManager 是 Ability 从 ArkTS 侧
// 初始化进来的**进程级单例**,原来是 shell/shell.cpp 里的一个全局变量 resMgr。
// 现在 bshutil 的常驻服务线程(bshutil/bsh_util_server.cpp)也要读 rawfile —— 两边
// 同在 libentry.so 里,但让谁去 extern 另一边的全局变量太隐晦,所以收成一个显式的
// 访问器 + 两个共用操作(list / copy):shell.cpp 的 UnpackRes / CopyRawFile 与
// bshutil 的 `rawfile` 子命令都走这里。
//
// ⚠ 命令 so(bshutil 客户端)在**子进程**里,拿不到这个 napi 对象 —— 所以
//   `bshutil rawfile` 是"客户端发请求、主进程的服务端来读"(见 bsh_util_proto.h)。
#pragma once

#include <string>
#include <vector>

struct NativeResourceManager;

namespace bsh {

/* 由 shell.cpp 的 initResourceManagerNAPI 登记;未登记时 getter 返回 nullptr。 */
void bsh_rawfile_set_manager(NativeResourceManager* mgr);
NativeResourceManager* bsh_rawfile_manager();

struct RawFileEntry {
    std::string path;   // 相对 rawfile 根的路径,如 "tools/hello.c"
    long long   size;   // 字节
};

/* 递归列出 rawfile 根下的全部**文件**(目录只是路径的一部分,不单独出条目),
 * 按路径排序。返回 false 表示拿不到资源管理器;此时 *out 已清空。 */
bool bsh_rawfile_list(std::vector<RawFileEntry>* out);

/* 把 rawName 的内容写到磁盘上的 dst。dst 必须是**绝对路径**(它跑在主进程里,
 * 主进程的 cwd 与用户在终端里 cd 到哪无关;相对路径由调用方先解析)。
 *   overwrite=false 且 dst 已存在 → 返回 1(跳过,不是错误)
 *   成功 0;失败为负: -1 参数/资源管理器不可用, -2 没这个 rawfile,
 *   -3 打不开目标文件, -4 读 rawfile 出错, -5 写目标出错 */
int bsh_rawfile_copy(const char* rawName, const char* dst, bool overwrite);

}  // namespace bsh
