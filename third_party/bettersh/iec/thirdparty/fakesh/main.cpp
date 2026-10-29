// thirdparty/fakesh/main.cpp — A fake shell program to test the exec shim ability.
#include <iostream>
#include <string>

int main(int argc, char** argv) {
    printf("Hello, this is not real sh!\n");
    printf("Enter \'quit\' to exit.\n");

    // What it was started with, which is the only place a script's own name and the
    // arguments it was given can be seen once a shebang has been followed: this shell does
    // not read the script, so nothing else would ever print them.
    printf("started as (argc=%d):\n", argc);
    for (int i = 0; i < argc; i++) printf("  argv[%d]=%s\n", i, argv[i]);

    std::string line;
    while (std::getline(std::cin, line)) {
        if (line == "quit") {
            break;
        }
        std::cout << line << std::endl;
    }

    return 0;
}
