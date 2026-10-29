// programs/hello/hellobsh.cpp — so 化示例程序
// 约定:一个 .so = 一个程序,统一入口 int main(int, char**)。
// 编译为 libhellobsh.so 打进 HAP;shell 在命令表里查 so,
// dlopen 并调用其 main。
#include <cstdio>

int main(int argc, char** argv) {
    printf("Hello from BetterSH (libhellobsh.so)\n");
    if (argc > 1) {
        printf("argv:");
        for (int i = 1; i < argc; i++) printf(" %s", argv[i]);
        printf("\n");
    }
    return 0;
}
