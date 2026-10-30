// wrap.c — 宿主测试用的 main 转发壳。
//
// cmd_nc.c 只导出 iec_nc_main（设备侧由 launcher dlopen 后按入口符号调用），
// 宿主上编成普通可执行文件时需要一个 main。命令行与设备侧完全一致：
//   cc -o nc cmd_nc.c wrap.c
extern int iec_nc_main(int, char**);

int main(int argc, char** argv) { return iec_nc_main(argc, argv); }
