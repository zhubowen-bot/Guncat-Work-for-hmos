// python_entry.c — `python3` 在 shell 里的入口。
//
// 为什么需要它：shell 命令是 fork 出来的，而应用进程里已经有一个初始化好的
// CPython（run_python 用的 libpython3.12.so）。子进程继承了这份运行时，直接调
// Py_BytesMain 会在 pyinit_core_reconfigure 崩溃（拿不到 thread state）。
//
// 尝试过两种收尾方式（host 上用同样的 fork 场景验证）：
//   A. PyOS_AfterFork_Child() + Py_FinalizeEx() —— 子进程 SIGABRT
//      （PyMutex_Unlock: unlocking mutex that is not locked）
//   B. PyThreadState_New(PyInterpreterState_Main()) + PyThreadState_Swap()
//      + Py_FinalizeEx() —— 正常打印、退出码 0
// 这里用 B：先给当前线程挂一个 tstate，再让 CPython 自己收尾，最后重新初始化。
// fork 是写时复制，父进程的解释器不受影响。
//
// 入口符号是 iec_python_main，由 IEC launcher 调用；不导出 main，避免与其它命令 so 冲突。
#include <stddef.h>
#include <stdio.h>

extern int Py_IsInitialized(void);
extern int Py_FinalizeEx(void);
extern int Py_BytesMain(int argc, char** argv);
extern void* PyInterpreterState_Main(void);
extern void* PyThreadState_New(void* interp);
extern void* PyThreadState_Swap(void* tstate);

int iec_python_main(int argc, char** argv) {
    if (Py_IsInitialized()) {
        // fork 之后当前线程没有 tstate。先挂一个，FinalizeEx 才不会在
        // 解锁未持有的 mutex 时 abort。
        void* interp = PyInterpreterState_Main();
        void* tstate = interp != NULL ? PyThreadState_New(interp) : NULL;
        if (tstate != NULL) {
            PyThreadState_Swap(tstate);
        }
        Py_FinalizeEx();
        if (Py_IsInitialized()) {
            // 收尾失败时明确报错并返回非 0，而不是再进一次初始化然后崩溃
            // （崩溃在前一版会表现为退出码 0，调用方无法感知）。
            static const char msg[] =
                "python3: cannot reset the inherited interpreter; use run_python instead\n";
            fwrite(msg, 1, sizeof msg - 1, stderr);
            return 1;
        }
    }
    return Py_BytesMain(argc, argv);
}
