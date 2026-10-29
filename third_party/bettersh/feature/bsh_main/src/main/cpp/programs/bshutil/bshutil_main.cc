// programs/bshutil/bshutil_main.cc — bshutil 命令 so 的入口(薄客户端)
//
// bshutil 的逻辑不在这个 so 里,而在主进程的常驻服务线程里(见
// bshutil/bsh_util_server.h 的"为什么不能只做成普通命令 so")。这里只做三件事:
// 把 argv 交给服务端、把回来的输出写到自己的 stdout、按回来的退出码退出。
//
// 于是它对调用方就是一个普通程序:重定向/管道/退出码都由它自己的 stdio 决定,
// 从 bsh 敲和从 mksh 敲没有区别。
#include "bsh_util_client.h"

#include <stdio.h>
#include <unistd.h>

extern "C" int bshutil_main(int argc, char** argv) {
    int rc = bsh_util_call(argc, argv, STDOUT_FILENO);
    if (rc < 0) {
        /* 唯一由这个 so 自己产生的输出:服务端没起来/连不上 */
        fprintf(stderr, "bshutil: %s\n", bsh_util_client_last_error());
        return 1;
    }
    fflush(nullptr);   // 与 procmgr 调用入口后的约定一致,保证输出落到 fd
    return rc;
}
