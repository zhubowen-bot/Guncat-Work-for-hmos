// client_main.c — 给 python_entry.c 补一个 main，供宿主测试直接执行。
//
// python_entry.c 导出的是 iec_python_main(argc, argv)，设备上由 IEC launcher
// 调用；宿主上没有 launcher，所以这里原样转发。
//
// 额外留了一个纯粹用于测试错误路径的开关：环境变量 IEC_TEST_ARGC0=1 时
// 用 argc=0 调用，模拟协议里 runner 必须拒绝的那种请求。它不影响正常调用。
#include <stdlib.h>

int iec_python_main(int argc, char** argv);

int main(int argc, char** argv) {
    const char* argc0 = getenv("IEC_TEST_ARGC0");
    if (argc0 != NULL && argc0[0] == '1') {
        return iec_python_main(0, argv);
    }
    // 本程序自己的 argv[0] 是 py_client；python_entry 的 argv[0] 必须是
    // "python3"（设备上由 launcher 这么传），所以整体左移一位。
    if (argc < 1) {
        return iec_python_main(0, argv);
    }
    return iec_python_main(argc - 1, argv + 1);
}
