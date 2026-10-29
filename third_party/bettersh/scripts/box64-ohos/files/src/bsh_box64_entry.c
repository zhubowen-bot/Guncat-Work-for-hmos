/* BetterSH: procmgr 的入口包装。静态文件，见 scripts/box64-ohos/files/src/。
 * procmgr 的入口约定是 int(*)(int,char**)；box64 的入口 box64_run 是三参数
 * (argc, argv, env)，这里把宿主 environ 补成第三个参数。
 *
 * visibility 必须显式给：box64 的 CMakeLists 里有一句全局
 *   add_definitions(-std=gnu11 -funwind-tables -fvisibility=hidden)
 * 它会盖掉 patch 53 在 target 上设的 C_VISIBILITY_PRESET default，于是本 .so
 * 只导出显式标注 default 的符号。补丁集里的 box64_run 就是靠这个属性导出来的
 * （src/box64_so_entry.c，patch 51），本函数同理。漏了它 procmgr 的 dlsym 会
 * 报 "dlsym(bsh_box64_entry) failed: undefined symbol"。 */
extern char** environ;
extern int box64_run(int argc, char** argv, char** env);

__attribute__((visibility("default")))
int bsh_box64_entry(int argc, char** argv) {
    return box64_run(argc, argv, environ);
}
