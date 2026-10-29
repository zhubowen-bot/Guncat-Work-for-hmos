// harness.c — 宿主测试用的小启动器。
//
// 只做两件事：调用 StartPyRunner() 把 runner 进程拉起来，然后原地不退，
// 让 runner 的 getppid() 检查认为父进程还活着。runner 自己 fork 后 setsid，
// 所以本进程退出不会连带杀掉它；测试结束由驱动脚本负责清理。
//
// 编译时由 run.py 传入 -DFAKE_SYSROOT=<临时目录>，socket 就落在那里。
#include "exec/py_runner.h"

#include <stdio.h>
#include <unistd.h>

int main(void) {
    if (!StartPyRunner()) {
        fprintf(stderr, "harness: StartPyRunner() failed\n");
        return 1;
    }
    for (;;) {
        pause();
    }
}
