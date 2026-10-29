/* BOX64_OHOS_SO_ENTRY — patch 51
 *
 * Exported entry for HAP NAPI:
 *   pid_t pid = fork();
 *   if (pid == 0) {
 *       void* h = dlopen("libbox64.so", RTLD_NOW|RTLD_GLOBAL);
 *       int (*f)(int, const char**, const char**) = dlsym(h, "box64_run");
 *       _exit(f(argc, argv, env));
 *   }
 */
extern int  box64_main(int argc, const char** argv, const char** env);
extern void box64_install_sigsys_fallback(void);

__attribute__((visibility("default")))
int box64_run(int argc, const char** argv, const char** env)
{
    box64_install_sigsys_fallback();
    return box64_main(argc, argv, env);
}
