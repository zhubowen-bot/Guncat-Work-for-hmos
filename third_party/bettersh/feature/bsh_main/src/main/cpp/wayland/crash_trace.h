// crash_trace.h —— host 侧崩溃取证（把现场写进资源根下 hdc 读得到的文件）
//
// 由来与理由见 crash_trace.cpp 的文件头。这里只暴露一个入口：
// 在 WaylandServer::Start() 里调一次（幂等）。
#ifndef BSH_WAYLAND_CRASH_TRACE_H
#define BSH_WAYLAND_CRASH_TRACE_H

void InstallHostCrashTrace(void);

#endif  // BSH_WAYLAND_CRASH_TRACE_H
