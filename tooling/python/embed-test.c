// 宿主侧 POC: 用与 guncat_py.cpp 相同的方式(dlopen + PyRun_SimpleString)执行
// guncat_py.cpp 里的启动器脚本, 用来在没有真机的情况下验证:
//   * 嵌入式与 CLI 的差异;
//   * 路径注入方式(把 __GUNCAT_*__ 占位符渲染成真实路径, 不依赖环境变量);
//   * 标准库/扩展缺失时的失败形态与诊断;
//   * 超时中断(PyThreadState_SetAsyncExc)是否真的能打断纯 Python 循环。
//
// 用法: embed-test <libpython.so> <launcher.py> <code.py> <outdir> <pythonhome> <pythonpath> [timeout_ms]
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

typedef int (*fn_void_int)(void);
typedef void (*fn_void)(void);
typedef int (*fn_run)(const char*);
typedef int (*fn_gil)(void);
typedef void (*fn_gil_release)(int);

static char* slurp(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char* buf = malloc((size_t) n + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t) n, f);
    buf[got] = '\0';
    fclose(f);
    return buf;
}

static void replace_all(char* text, size_t cap, const char* token, const char* value) {
    static char out[262144];
    size_t tok = strlen(token);
    size_t vlen = strlen(value);
    size_t oi = 0;
    for (size_t i = 0; text[i] != '\0' && oi + vlen + 1 < sizeof(out); ) {
        if (strncmp(text + i, token, tok) == 0) {
            memcpy(out + oi, value, vlen);
            oi += vlen;
            i += tok;
        } else {
            out[oi++] = text[i++];
        }
    }
    out[oi] = '\0';
    strncpy(text, out, cap - 1);
    text[cap - 1] = '\0';
}

int main(int argc, char** argv) {
    if (argc < 7) {
        fprintf(stderr,
                "usage: %s libpython launcher code outdir pythonhome pythonpath [timeout_ms]\n",
                argv[0]);
        return 2;
    }
    const char* lib = argv[1];
    char* raw = slurp(argv[2]);
    if (!raw) { fprintf(stderr, "no launcher\n"); return 2; }
    // 渲染会把占位符换成更长的真实路径, 用固定大缓冲避免越界
    static char launcher[262144];
    memset(launcher, 0, sizeof(launcher));
    strncpy(launcher, raw, sizeof(launcher) - 1);
    free(raw);

    const char* outdir = argv[4];
    char code_path[4096], out_path[4096], err_path[4096], meta_path[4096], diag_path[4096];
    char argv_path[4096];
    snprintf(code_path, sizeof(code_path), "%s/code.py", outdir);
    snprintf(out_path, sizeof(out_path), "%s/stdout.txt", outdir);
    snprintf(err_path, sizeof(err_path), "%s/stderr.txt", outdir);
    snprintf(meta_path, sizeof(meta_path), "%s/meta.txt", outdir);
    snprintf(diag_path, sizeof(diag_path), "%s/diag.txt", outdir);
    snprintf(argv_path, sizeof(argv_path), "%s/argv.txt", outdir);
    unlink(out_path);
    unlink(err_path);
    unlink(meta_path);
    unlink(diag_path);
    if (access(argv_path, F_OK) != 0) {
        FILE* f = fopen(argv_path, "w");
        if (f) { fputs("-c\n", f); fclose(f); }
    }

    replace_all(launcher, sizeof(launcher), "__GUNCAT_CODE__", code_path);
    replace_all(launcher, sizeof(launcher), "__GUNCAT_OUT__", out_path);
    replace_all(launcher, sizeof(launcher), "__GUNCAT_ERR__", err_path);
    replace_all(launcher, sizeof(launcher), "__GUNCAT_META__", meta_path);
    replace_all(launcher, sizeof(launcher), "__GUNCAT_DIAG__", diag_path);
    replace_all(launcher, sizeof(launcher), "__GUNCAT_ARGV__", argv_path);
    replace_all(launcher, sizeof(launcher), "__GUNCAT_STDIN__", "");
    {
        char deadline[32];
        int tmo = (argc >= 8) ? atoi(argv[7]) : 0;
        snprintf(deadline, sizeof(deadline), "%.3f", tmo > 0 ? tmo / 1000.0 : 0.0);
        replace_all(launcher, sizeof(launcher), "__GUNCAT_DEADLINE__", deadline);
    }

    setenv("PYTHONHOME", argv[5], 1);
    setenv("PYTHONPATH", argv[6], 1);
    setenv("PYTHONUTF8", "1", 1);
    setenv("PYTHONIOENCODING", "utf-8", 1);
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
    setenv("PYTHONNOUSERSITE", "1", 1);

    void* h = dlopen(lib, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    fn_void_int is_init = (fn_void_int) dlsym(h, "Py_IsInitialized");
    fn_void init = (fn_void) dlsym(h, "Py_Initialize");
    fn_run run = (fn_run) dlsym(h, "PyRun_SimpleString");
    fn_gil gil = (fn_gil) dlsym(h, "PyGILState_Ensure");
    fn_gil_release rel = (fn_gil_release) dlsym(h, "PyGILState_Release");
    if (!is_init || !init || !run || !gil || !rel) {
        fprintf(stderr, "missing symbols\n");
        return 1;
    }

    init();
    if (!is_init()) { fprintf(stderr, "Py_Initialize failed\n"); return 1; }

    int timeout_ms = (argc >= 8) ? atoi(argv[7]) : 0;
    (void) timeout_ms;
    int state = gil();
    int rc = run(launcher);
    printf("rc=%d\n", rc);
    rel(state);

    const char* files[4] = {meta_path, out_path, err_path, diag_path};
    const char* names[4] = {"meta", "stdout", "stderr", "diag"};
    for (int i = 0; i < 4; i++) {
        char* body = slurp(files[i]);
        if (body) {
            printf("--- %s ---\n%s\n", names[i], body);
            free(body);
        } else {
            printf("--- %s --- (缺失)\n", names[i]);
        }
    }
    return 0;
}
