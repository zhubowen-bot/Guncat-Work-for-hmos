/* dlopen_probe.c — 两条验收标准的自证程序。
 *
 *  1) /proc/self/maps 里**不该**再有这几个库的"文件映射"行 —— 打过补丁的 ld.so
 *     把 PT_LOAD 读进匿名页(pread + mprotect),地址空间里不再有 file-backed 的
 *     可执行映射,这是"不再弹『是否运行 xxx』"的判据;
 *  2) 整个 glibc 运行时和这个 .so 都躺在 $HOME(noexec)下,照样跑得动。
 *
 * 用法: dlopen_probe [要 dlopen 的库] [传给 greet 的名字]
 * 退出码 7 与 hello 对齐。
 */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int maps_hits(const char *needle)
{
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) return -1;
    char line[1024];
    int n = 0;
    while (fgets(line, sizeof line, f)) {
        if (!strstr(line, needle)) continue;
        n++;
        /* 只打印命中行(去掉换行),一眼能看出是文件映射还是匿名 */
        line[strcspn(line, "\n")] = '\0';
        printf("       [maps hit] %s\n", line);
    }
    fclose(f);
    return n;
}

int main(int argc, char **argv)
{
    const char *lib = argc > 1 ? argv[1] : "./libgreet.so";
    const char *who = argc > 2 ? argv[2] : "ohos";

    printf("[probe] pid=%d argv0=%s\n", (int)getpid(), argv[0]);

    FILE *st = fopen("/proc/self/status", "r");
    if (st) {
        char line[256];
        while (fgets(line, sizeof line, st))
            if (!strncmp(line, "Seccomp:", 8)) {
                line[strcspn(line, "\n")] = '\0';
                printf("[probe] %s\n", line);
            }
        fclose(st);
    }

    /* 1) 文件映射检查:命中数 0 = 全是匿名页 */
    const char *files[] = { "libc.so.6", "ld-linux-aarch64.so.1", "libgreet.so" };
    for (unsigned i = 0; i < sizeof files / sizeof files[0]; i++) {
        int n = maps_hits(files[i]);
        printf("[probe] maps \"%s\": %d hit(s) -> %s\n", files[i], n,
               n == 0 ? "anonymous (good)" : n < 0 ? "no /proc/self/maps"
                                                   : "FILE-BACKED (bad)");
    }

    /* 2) dlopen:库在 $HOME(noexec),不在系统目录也不在 bundle libs */
    void *h = dlopen(lib, RTLD_NOW);
    if (!h) {
        printf("[probe] dlopen(%s) FAILED: %s\n", lib, dlerror());
        fflush(stdout);
        return 1;
    }
    int (*greet)(const char *) = (int (*)(const char *))dlsym(h, "greet");
    if (!greet) {
        printf("[probe] dlsym(greet) FAILED: %s\n", dlerror());
        fflush(stdout);
        return 2;
    }
    int rc = greet(who);
    printf("[probe] dlopen+dlsym OK, greet() returned %d\n", rc);
    fflush(stdout);
    return 7;
}
