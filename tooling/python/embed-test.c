// 宿主侧 POC: 用与 guncat_py.cpp 相同的方式(dlopen + PyRun_SimpleString)执行
// guncat_py.cpp 里的启动器脚本, 用来在没有真机的情况下验证:
//   * 嵌入式和 CLI 的差异(这里是嵌入式);
//   * 标准库只给 zip、扩展模块缺失时的失败形态(应当"没有产出结果文件");
//   * 诊断信息是否足够定位问题。
//
// 用法: embed-test <libpython.so> <launcher.py> <code.py> <outdir> <pythonhome> <pythonpath> [timeout_ms]
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
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

int main(int argc, char** argv) {
    if (argc < 7) {
        fprintf(stderr, "usage: %s libpython launcher code outdir pythonhome pythonpath\n", argv[0]);
        return 2;
    }
    const char* lib = argv[1];
    char* launcher = slurp(argv[2]);
    if (!launcher) { fprintf(stderr, "no launcher\n"); return 2; }

    const char* outdir = argv[4];
    char code_path[4096], out_path[4096], err_path[4096], meta_path[4096], diag_path[4096];
    snprintf(code_path, sizeof(code_path), "%s/code.py", outdir);
    snprintf(out_path, sizeof(out_path), "%s/stdout.txt", outdir);
    snprintf(err_path, sizeof(err_path), "%s/stderr.txt", outdir);
    snprintf(meta_path, sizeof(meta_path), "%s/meta.txt", outdir);
    snprintf(diag_path, sizeof(diag_path), "%s/diag.txt", outdir);
    unlink(out_path); unlink(err_path); unlink(meta_path); unlink(diag_path);

    setenv("PYTHONHOME", argv[5], 1);
    setenv("PYTHONPATH", argv[6], 1);
    setenv("PYTHONUTF8", "1", 1);
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
    setenv("PYTHONNOUSERSITE", "1", 1);
    setenv("GUNCAT_PY_CODE", code_path, 1);
    setenv("GUNCAT_PY_OUT", out_path, 1);
    setenv("GUNCAT_PY_ERR", err_path, 1);
    setenv("GUNCAT_PY_META", meta_path, 1);
    setenv("GUNCAT_PY_DIAG", diag_path, 1);

    void* h = dlopen(lib, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    fn_void_int is_init = (fn_void_int) dlsym(h, "Py_IsInitialized");
    fn_void init = (fn_void) dlsym(h, "Py_Initialize");
    fn_run run = (fn_run) dlsym(h, "PyRun_SimpleString");
    fn_gil gil = (fn_gil) dlsym(h, "PyGILState_Ensure");
    fn_gil_release rel = (fn_gil_release) dlsym(h, "PyGILState_Release");
    if (!is_init || !init || !run || !gil || !rel) { fprintf(stderr, "missing symbols\n"); return 1; }

    init();
    if (!is_init()) { fprintf(stderr, "Py_Initialize failed\n"); return 1; }
    int state = gil();
    int rc = run(launcher);
    rel(state);

    printf("rc=%d\n", rc);
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
