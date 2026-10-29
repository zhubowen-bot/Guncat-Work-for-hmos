// python_entry.c — `python3` 在 shell 里的入口。
//
// 为什么需要它：shell 命令是 fork 出来的，而应用进程里已经有一个初始化好的
// CPython（run_python 用的 libpython3.12.so）。子进程继承了这个运行时，再直接
// 调 Py_BytesMain 会在 pyinit_core_reconfigure 里崩（读不到 thread state）。
//
// 这里在子进程里先把继承来的解释器收尾（PyOS_AfterFork_Child 修好 fork 后的
// 线程状态，Py_FinalizeEx 把运行时归零），再走正常的 Py_BytesMain 初始化。
// 这样父进程不受影响（fork 是写时复制），子进程拿到的是干净的解释器。
//
// 入口符号是 iec_python_main，由 IEC launcher 调用；不导出 main，避免和别的
// 命令 so 的符号混在一起。
#include <stddef.h>

extern int Py_IsInitialized(void);
extern void PyOS_AfterFork_Child(void);
extern int Py_FinalizeEx(void);
extern int Py_BytesMain(int argc, char** argv);

int iec_python_main(int argc, char** argv) {
    if (Py_IsInitialized()) {
        // fork 之后当前线程没有 tstate；先让 CPython 自己把 fork 后的状态修好，
        // 否则 Py_FinalizeEx 也会因为拿不到线程状态而失败。
        PyOS_AfterFork_Child();
        Py_FinalizeEx();
    }
    return Py_BytesMain(argc, argv);
}
