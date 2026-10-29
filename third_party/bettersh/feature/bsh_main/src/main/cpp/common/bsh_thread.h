// bsh_thread.h —— 用**指定栈大小**起线程（本工程 native 侧统一用这个，别直接 std::thread）
//
// 为什么需要：本工程的 native 代码链的是 **musl**，而 musl 的默认线程栈只有 **128KB**
// （glibc 那边是 8MB，差 64 倍）。平时够用，一遇到"别人的大客户端"就撑爆 ——
// 实测把 Electron（VS Code）当 Wayland 客户端接进来，它绑完 xdg_wm_base /
// wl_data_device_manager、刚断开一路连接，WaylandServer::Loop 那条线程直接 SIGSEGV，
// faultlog 的原话是：
//
//     Reason:Signal:SIGSEGV(SEGV_ACCERR)@0x0000005b37341fd0
//     current thread stack low address = 0x0000005b37342000,
//     probably caused by stack-buffer-overflow
//
// 崩的正是那条 128KB 的线程（hilog 里 BSH_WaylandServer 的日志与崩溃同 tid）。
// 交给 fork 的子进程也吃同一份栈：`fork()` 只保留**调用线程**，所以从 128KB 的
// ctrl-socket 处理线程 fork 出去的子进程，一开始也只有 128KB 可用。
//
// 虚拟内存不要钱：统一给 8MB。这里不做"按需精算"，因为省下的只是地址空间，
// 而算错的代价是整段进程崩掉、且现场极难定位。
#ifndef BSH_THREAD_H
#define BSH_THREAD_H

#include <pthread.h>
#include <stddef.h>

#include <new>
#include <utility>

namespace bsh {

// 8MB：与 glibc 的默认线程栈同量级。
inline constexpr size_t kThreadStackBytes = 8u << 20;

namespace detail {

template <typename F>
struct ThreadCtx {
    F fn;
    static void* Tramp(void* p) {
        ThreadCtx* c = static_cast<ThreadCtx*>(p);
        c->fn();
        delete c;
        return nullptr;
    }
};

template <typename F>
pthread_t Create(F&& fn, size_t stack) {
    ThreadCtx<F>* ctx = new (std::nothrow) ThreadCtx<F>{ std::forward<F>(fn) };
    if (!ctx) return 0;

    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0) { delete ctx; return 0; }
    pthread_attr_setstacksize(&attr, stack);

    pthread_t th = 0;
    int rc = pthread_create(&th, &attr, &ThreadCtx<F>::Tramp, ctx);
    pthread_attr_destroy(&attr);
    if (rc != 0) { delete ctx; return 0; }
    return th;
}

}  // namespace detail

// 起一条大栈线程，返回句柄（调用方负责 pthread_join）；失败返回 0。
template <typename F>
pthread_t StartThread(F&& fn, size_t stack = kThreadStackBytes) {
    return detail::Create(std::forward<F>(fn), stack);
}

// 同上，但立刻 detach（大多数场景：线程跑完就没了，没人 join）。
template <typename F>
bool StartThreadDetached(F&& fn, size_t stack = kThreadStackBytes) {
    pthread_t th = detail::Create(std::forward<F>(fn), stack);
    if (!th) return false;
    pthread_detach(th);
    return true;
}

}  // namespace bsh

#endif  // BSH_THREAD_H
