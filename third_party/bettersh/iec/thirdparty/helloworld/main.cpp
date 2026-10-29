// thirdparty/helloworld/main.cpp — soization example program
#include <cstdio>

int main(int argc, char** argv) {
    printf("Hello from IEC! (libhello.so)\n");
    if (argc > 1) {
        printf("argv:");
        for (int i = 1; i < argc; i++) printf(" %s", argv[i]);
        printf("\n");
    }
    return 0;
}
