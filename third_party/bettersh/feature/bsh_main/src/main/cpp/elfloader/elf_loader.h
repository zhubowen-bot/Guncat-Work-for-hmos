// elf_loader.h — in-process ELF loader (no exec) used by ElfLoaderDemo.
//
// Reference / port basis:
//   Termony build-hnp/elf-loader -> https://github.com/MikhailProg/elf (loader.c)
//   plus Termony jit.patch: wrap mprotect(PROT_EXEC) with prctl('jit', ...)
//   (HarmonyOS W^X kernel allows executable anon mapping only around that
//   toggle).  The original loader replaces the process image and never
//   returns; this port instead runs the guest on a fresh stack and, for
//   freestanding guests that `ret`, control comes back to the host.
#ifndef ELF_LOADER_H
#define ELF_LOADER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Run an ELF image already resident in memory (buffer need not outlive the
 * call; segments are copied into freshly mapped pages).
 *   img/len : full ELF file bytes (EHDR..program headers..segments)
 *   argc/argv: guest argv; argv[0] is the guest name.
 * Returns: 0 on success (guest returned), -1 on load/run error.
 * The guest must be aarch64 and must eventually `ret` (freestanding, no
 * libc).  Guests that call exit_group terminate the whole host process. */
int elf_run_mem(const void *img, size_t len, int argc, char *const argv[]);

/* Map any aarch64 ELF image (ET_EXEC fixed or ET_DYN at a free address)
 * into fresh executable-capable anonymous memory.  Returns the runtime base
 * and the total span; caller owns the mapping and must munmap(base, span).
 * Used by the mini dynamic linker for arbitrary .so files. */
int elf_map_image(const void *img, size_t len, uintptr_t *base, size_t *span);

/* Custom guest auxv type carrying the ElfGuestBridge pointer (see below). */
#define AT_GUEST_BRIDGE 0x6c

/* Bridge of host functions offered to a running guest through auxv
 * AT_GUEST_BRIDGE: lets freestanding guests dlopen/dlsym arbitrary .so
 * images provided by the host (see elf_dl.cpp). */
struct ElfGuestBridge {
    void *(*dlopen_mem)(const void *img, size_t len, const char *name);
    void *(*dlsym)(void *handle, const char *name);
    const void *so_ptr; /* convenience: bytes of a demo .so to load */
    size_t so_len;
};

/* Like elf_run_mem, but if `bridge` is non-NULL its address is published to
 * the guest via an AT_GUEST_BRIDGE auxv entry. */
int elf_run_mem_ex(const void *img, size_t len, int argc, char *const argv[],
                   const struct ElfGuestBridge *bridge);

/* Mini dynamic linker entry points (elf_dl.cpp). */
void *elf_dlopen_mem(const void *img, size_t len, const char *name);
void *elf_dlsym(void *handle, const char *name);
/* handle 是不是 elf_dlopen_mem 发的（dlopen shim 用它分流：system handle vs 我们的） */
int elf_dl_owns_handle(void *handle);
/* 安装"首选符号解析器"：解析被装载对象的未定义符号时，先问它、再退回
 * dlsym(RTLD_DEFAULT)。宿主（把 elf_dl 链进去的那个命令 so）用它把解析范围
 * 限定在自己身上 —— 全局作用域里可能有**同名但不同实现**的符号（实测 node 的
 * napi_* 撞上鸿蒙 libace_napi.z.so，见 elf_dl.cpp 里 g_prefer_sym 的说明）。
 * 不装钩子 = 行为与从前完全一致。 */
void elf_dl_set_prefer_sym(void *(*fn)(const char *name));

/* Run a dynamically-linked ELF main in a forked child using the classic
 * interpreter hand-off: both main (ET_DYN) and its interpreter (ld-musl,
 * which is musl's libc.so itself) are mapped from memory, the guest stack /
 * auxv describe the MAIN image (AT_PHDR/AT_PHNUM/AT_PHENT/AT_ENTRY) with
 * AT_BASE = interpreter load base, and execution starts at the interpreter
 * entry so the real musl dynamic linker does relocations and calls main.
 * Returns child exit code, or -1 on failure. */
int elf_run_dyn_child(const void *main_img, size_t main_len,
                      const void *ldso_img, size_t ldso_len,
                      int argc, char *const argv[]);

/* Run a dynamically-linked ELF via interpreter hand-off in the CURRENT
 * process (for callers that are already a forked child). */
int elf_run_dyn_inproc(const void *main_img, size_t main_len,
                       const void *ldso_img, size_t ldso_len,
                       int argc, char *const argv[]);



/* Convenience: slurp `path` and run it. */
int elf_run_file(const char *path, int argc, char *const argv[]);

/* Stage-2 helpers: probe whether fork() is permitted by the sandbox.
 * Returns: 1 if a child forked and exited cleanly, 0 if not permitted,
 * -1 on other error.  Result is also logged to stdout/stderr. */
int elf_probe_fork(void);

/* Run an image inside a forked child (guest exit_group kills only the
 * child).  Returns child exit code (>=0), or -1 if fork/run failed. */
int elf_run_mem_in_child(const void *img, size_t len, int argc,
                         char *const argv[]);

/* Install the crash-reporting signal handlers (SIGSEGV/SIGBUS/SIGABRT/SIGILL) with a
 * dedicated signal stack.  The forked guest runners call this themselves; procmgr uses
 * this exported wrapper to arm it for **command so** children when BSH_FAULT_TRACE is
 * set — 那些子进程平时崩了只有一句 rc=139、一行输出都没有。
 * (名字不同是因为真正的实现在 elf_loader.cpp 的匿名 namespace 里,同名会撞。) */
void elf_arm_fault_handlers(void);

#ifdef __cplusplus
}
#endif

#endif /* ELF_LOADER_H */
