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

#ifndef FAKE_SYSROOT
#define FAKE_SYSROOT "/data/storage/el2/base/files"
#endif

// runner 是 StartPyRunner() fork 出来的唯一子进程。把它的 pid 写进
// <FAKE_SYSROOT>/runner.pid，run.py 的“runner 死后不留后代”断言就不必再靠
// 命令行匹配去猜哪个进程是 runner（harness/handler/解释器共用同一条 cmdline）。
static pid_t first_child_pid(void) {
    char path[128];
    snprintf(path, sizeof path, "/proc/self/task/%ld/children", (long)getpid());
    FILE* f = fopen(path, "r");
    if (f == NULL) return -1;
    long pid = -1;
    if (fscanf(f, "%ld", &pid) != 1) pid = -1;
    fclose(f);
    return (pid_t)pid;
}

int main(void) {
    if (!StartPyRunner()) {
        fprintf(stderr, "harness: StartPyRunner() failed\n");
        return 1;
    }
    char path[4096];
    snprintf(path, sizeof path, "%s/runner.pid", FAKE_SYSROOT);
    FILE* f = fopen(path, "w");
    if (f != NULL) {
        fprintf(f, "%ld\n", (long)first_child_pid());
        fclose(f);
    }
    for (;;) {
        pause();
    }
}
