/* shmprobe —— guest 里到底能不能建共享内存？
 * Chromium 的 Mojo 通道 / 渲染器的帧传输都走 base::SharedMemory，
 * 它的 Linux 实现顺序是：memfd_create → shm_open(/dev/shm) → /tmp。
 * 这里把三条都试一遍，把 errno 原样打出来。 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001
#endif

int main(void) {
    int rc;

    errno = 0;
    rc = memfd_create("bsh-shm-probe", MFD_CLOEXEC);
    printf("memfd_create          -> %d  errno=%d(%s)\n", rc, errno, strerror(errno));
    if (rc >= 0) { ftruncate(rc, 4096); void*p=mmap(0,4096,PROT_READ|PROT_WRITE,MAP_SHARED,rc,0);
                   printf("  mmap MAP_SHARED     -> %p errno=%d(%s)\n", p, errno, strerror(errno));
                   if (p!=MAP_FAILED) munmap(p,4096); close(rc); }

    errno = 0;
    rc = shm_open("/bsh-shm-probe", O_CREAT|O_RDWR|O_EXCL, 0600);
    printf("shm_open(/dev/shm)    -> %d  errno=%d(%s)\n", rc, errno, strerror(errno));
    if (rc >= 0) { close(rc); shm_unlink("/bsh-shm-probe"); }

    errno = 0;
    rc = open("/dev/shm/bsh-probe", O_CREAT|O_RDWR, 0600);
    printf("open(/dev/shm/...)    -> %d  errno=%d(%s)\n", rc, errno, strerror(errno));
    if (rc >= 0) { close(rc); unlink("/dev/shm/bsh-probe"); }

    errno = 0;
    rc = open("/tmp/bsh-probe", O_CREAT|O_RDWR, 0600);
    printf("open(/tmp/...)        -> %d  errno=%d(%s)\n", rc, errno, strerror(errno));
    if (rc >= 0) { close(rc); unlink("/tmp/bsh-probe"); }

    errno = 0;
    void* a = mmap(0, 65536, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_ANONYMOUS, -1, 0);
    printf("anon MAP_SHARED       -> %p  errno=%d(%s)\n", a, errno, strerror(errno));
    if (a != MAP_FAILED) munmap(a, 65536);

    printf("done\n");
    return 0;
}
