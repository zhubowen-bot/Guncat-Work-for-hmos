// procmgr/command_map.h — 命令表(procmgr 的决策数据)
//
// 每个条目:命令名 → 目标 so + 入口符号。procmgr 用它决定"这个名字怎么起进程":
// 命中 → dlopen 该 so 并调入口符号;未命中 → 按路径当 ELF 交 elfloader。
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct CommandEntry {
    const char* cmd;     // 目标命令字符串
    const char* so;      // 目标共享库(bundle libs 里的文件名)
    const char* entry;   // 入口符号(通常 "main";toybox 用 bsh_toybox_main)
};

// 按命令名查表;未注册返回 NULL。
const struct CommandEntry* cmd_lookup(const char* name);

// 枚举命令名(procmgr 决策时的遍历入口,也是生成启动器的名单来源)。
size_t cmd_name_count(void);
const char* cmd_name_at(size_t i);

// 取第 i 个条目的**完整内容**(生成启动器要用到 so 与 entry,不只是名字)。
// 越界返回 NULL。
const struct CommandEntry* cmd_entry_at(size_t i);

// 启动器文件（"#BSHSO" 格式）—— 命令集从编译期数据变成磁盘上的数据：
//
//   #BSHSO
//   <so_dir>/<so>          绝对路径
//   <entry>                入口符号
//   2                      2 = int(*)(int,char**)；3 = int(*)(int,char**,char**)
//
// procmgr 的 Resolve() 见到这种文件就照它说的 dlopen + dlsym + 调用；
// shell.cpp 在会话启动时用 cmd_make_launchers() 从**本表**生成一遍（表暂时保留，
// 只当生成器用；判据是 $SYSROOT/bin/sh 在不在，见 shell.cpp）。
// 手工放一个启动器就能加命令，不必重编 procmgr。
#define BSH_LAUNCHER_MAGIC "#BSHSO"

// 在 dir 下为表中每个条目写一个启动器（已存在的同名文件会被覆盖）。
// so_dir 一般给 BSH_BUNDLE_LIBS —— 启动器里要写绝对路径。返回写了几个。
int cmd_make_launchers(const char* dir, const char* so_dir);

// path 是不是启动器文件(只看首行，读不满就返回 0)。
int cmd_is_launcher(const char* path);

#ifdef __cplusplus
}
#endif
