// loader.h — architecture selection and the public in-process loader API.
#ifndef ELF_LOADER_H
#define ELF_LOADER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- architecture detection shared by every translation unit ---- */
#if defined(__aarch64__)
#  define ELFLOADER_ARCH_ARM64 1
#  define ELFLOADER_EM_EXPECTED 183 /* EM_AARCH64 */
#elif defined(__x86_64__)
#  define ELFLOADER_ARCH_X86_64 1
#  define ELFLOADER_EM_EXPECTED 62  /* EM_X86_64  */
#else
#  error "unsupported host architecture"
#endif

/* ---- OHOS vs ordinary Linux ---- */
#if defined(__OHOS__) || defined(OHOS_PLATFORM)
#  define ELFLOADER_OHOS 1
#endif

int  elf_run_mem(const void *img, size_t len, int argc, char *const argv[]);
int  elf_map_image(const void *img, size_t len, uintptr_t *base, size_t *span);

#define AT_GUEST_BRIDGE 0x6c

struct ElfGuestBridge {
    void *(*dlopen_mem)(const void *img, size_t len, const char *name);
    void *(*dlsym)(void *handle, const char *name);
    const void *so_ptr;
    size_t so_len;
};

int  elf_run_mem_ex(const void *img, size_t len, int argc, char *const argv[],
                    const struct ElfGuestBridge *bridge);

void *elf_dlopen_mem(const void *img, size_t len, const char *name);
void *elf_dlsym(void *handle, const char *name);
int   elf_dl_owns_handle(void *handle);
void  elf_dl_set_prefer_sym(void *(*fn)(const char *name));

int  elf_run_dyn_child(const void *main_img, size_t main_len,
                       const void *ldso_img, size_t ldso_len,
                       int argc, char *const argv[]);
int  elf_run_dyn_inproc(const void *main_img, size_t main_len,
                        const void *ldso_img, size_t ldso_len,
                        int argc, char *const argv[]);

int  elf_run_file(const char *path, int argc, char *const argv[]);
int  elf_probe_fork(void);
int  elf_run_mem_in_child(const void *img, size_t len, int argc,
                          char *const argv[]);
void elf_arm_fault_handlers(void);

#ifdef __cplusplus
}
#endif
#endif
