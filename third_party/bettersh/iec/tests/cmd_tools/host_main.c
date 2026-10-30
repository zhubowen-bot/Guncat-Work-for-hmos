// host_main.c — 宿主测试用的 main 壳。
//
// 三个命令的源码（cmd_nc.c / cmd_hexdump.c / cmd_diff.c）只导出 iec_xxx_main，
// 没有 main（设备上由 IEC launcher 调用）。宿主测试用 -DENTRY=iec_xxx_main 编译
// 本文件，把 main 转发给对应入口。
int ENTRY(int argc, char** argv);

int main(int argc, char** argv) {
    return ENTRY(argc, argv);
}
