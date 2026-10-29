/* dlhost.c — "动态链接了 .so 的可执行文件"，用来验 exec 一个依赖库的动态程序
 *
 * 与 dlopen 那一步分工：
 *   本程序**不用 dlfcn** —— libtgreet-<combo>.so 是链接期写进 DT_NEEDED 的，
 *   运行期装载/重定位由 guest 的动态链接器（我们 bundle 里的 ld-linux/ld-musl，
 *   x86 下是 box64 自己的加载器）完成。于是"exec 一个新程序"这条路上，
 *   "解释器能不能起"与"它能不能把 .so 找出来"两件事被一起验了。
 *
 * 怎么让链接器在运行期找到库：构建脚本给 <combo> 主程序 exec 它时会把本目录塞进
 * LD_LIBRARY_PATH（见 main.c 的 t_exec_dyn_with_so），链接期还写了 RPATH=$ORIGIN 兜底。
 *
 * 退出码 = greet() 的返回值（固定 42），调用方（父进程 waitpid）按它判成功。
 */
#include <stdio.h>
#include <unistd.h>

int greet(const char *who);      /* 库里导出的函数，链接期解析 —— 故意不走 dlsym */
extern int tgreet_yes;           /* 库里导出的数据 */

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("[dlhost] pid=%d argc=%d argv0=%s\n", (int)getpid(), argc,
           argc > 0 && argv[0] ? argv[0] : "(none)");
    printf("[dlhost] tgreet_yes=%d（库里数据符号，经动态链接取到）\n", tgreet_yes);
    int r = greet("dlhost");
    printf("[dlhost] greet() → %d\n", r);
    fflush(stdout);
    return r;
}
