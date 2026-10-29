// bshutil/bsh_cfg.h — 应用设置(进程内全局 + $HOME/bettersh.conf)
//
// 存法刻意保持"人能直接改":纯 key=value 文本,一行一项,# 开头是注释。
// 会话启动时 load 一次,bshutil set 之后 save;读取方直接问下面的 getter。
//
// 默认值 = 原来的行为(exit-hint/elf-hint 开、win-scale 2.0),所以没写过配置
// 文件的用户看到的现象与以前完全一致。
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* 载入配置。文件不存在、读不到都算成功(用默认值),返回 0;只有参数非法才返回 -1。 */
int bsh_cfg_load(const char* path);
/* 全量重写配置文件(只写已知的几项)。失败返回 -1。 */
int bsh_cfg_save(const char* path);

/* 命令以非 0 退出时是否打印 [exit N]。默认 1(开)。 */
int  bsh_cfg_exit_hint(void);
void bsh_cfg_set_exit_hint(int on);

/* elfloader 装载 guest 时是否打印 [elf] 信息行。默认 1(开)。 */
int  bsh_cfg_elf_hint(void);
void bsh_cfg_set_elf_hint(int on);

/* Wayland 窗口缩放倍数。默认 2.0;set 时夹到 [0.25, 4.0]。 */
double bsh_cfg_win_scale(void);
void   bsh_cfg_set_win_scale(double s);

/* 终端里点右键的行为。取值只有两种:
 *   0 = menu  —— 弹出右键菜单,菜单里有"复制/粘贴"(默认,与加入本项之前一致)
 *   1 = smart —— 像 Windows:有选中就把选中内容放进剪贴板,没有就直接粘贴
 * 默认 0。名字(menu/smart)只在配置文件与 bshutil 输出里用,内部就是这个 int。 */
int  bsh_cfg_right_click(void);
void bsh_cfg_set_right_click(int smart);

/* node 的 JIT 策略(见 node/bsh_node_entry.cc)。取值:
 *   0 = auto(默认)—— 起 node 前先试一次"prctl 夹层 + mprotect(RWX)",拿不到可执行
 *                     内存就自动加 --jitless(= V8 的纯解释器模式);
 *   1 = on          —— 无条件加 --jitless;
 *   2 = off         —— 不加(拿不到可执行内存时 node 会自己崩,用于复现/压测)。
 * 配置文件里写 auto / on / off。 */
int  bsh_cfg_node_jitless(void);
void bsh_cfg_set_node_jitless(int mode);

/* 把配置里"需要给命令 so 看"的项导出成环境变量。
 *
 * 目前只有 BSH_NODE_JITLESS(node-jitless 的 auto/on/off,见 node/bsh_node_entry.cc)。
 * 为什么走环境变量而不是让命令 so 自己读配置文件:
 *   1) 环境变量是本项目"宿主 → 命令 so"的既有通道(BSH_TTY_STDIO / BSH_WL_FD 都是
 *      这么传的),命令 so 因此可以**不依赖我们的任何头文件与源码**,自包含;
 *   2) 配置只有一份事实源($HOME/bettersh.conf 由宿主解析),命令 so 不用各自再解析
 *      一遍配置文件,也就不会出现"两份 bsh_cfg"的怪状态。
 * 注意时机:子进程是 fork 出来的,继承的是**宿主当时的 environ**,所以必须在
 * spawn 之前调 —— 会话启动加载完配置后一次、`bshutil set` 改完一次。 */
void bsh_cfg_export_env(void);

/* 最近一次 load/save 用的路径(给 `bshutil conf` 显示用);未设过则为空串。 */
const char* bsh_cfg_path(void);

#ifdef __cplusplus
}
#endif
