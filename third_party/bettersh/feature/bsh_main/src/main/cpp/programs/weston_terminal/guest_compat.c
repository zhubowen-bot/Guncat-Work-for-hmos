// programs/weston_terminal/guest_compat.c — guest 侧的两个小补丁 (todo)
//
// 为什么需要它：weston-terminal 从"命令 so"改成"guest 可执行"之后，运行期 libc 从
// OHOS libc 换成了随包的 musl。这两者的符号集合不一样，补两处缺口：
//
//   1) arc4random_buf —— musl 1.2.4 才加，我们是 1.2.2。libexpat 用它生成哈希盐
//      （fontconfig 解析配置时会走到），缺了就是运行期 "symbol not found"。
//      链接加 -Wl,--export-dynamic，所以这里定义一份也能喂给 app 目录里的 .so。
//   2) __register_frame_info / __deregister_frame_info / __at_fini —— OHOS 编出来的
//      .so 里是 **WEAK UND**，musl 的 ldso 会绑成 0，不需要我们提供；这里留个说明
//      免得以后有人看到 "undefined symbol" 又去补一遍。
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

void arc4random_buf(void *buf, size_t n)
{
    if (!buf || n == 0)
        return;
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0) {
        size_t off = 0;
        while (off < n) {
            ssize_t r = read(fd, (char *)buf + off, n - off);
            if (r <= 0) {
                if (r < 0) break;          /* EINTR 之类：不再纠缠，走退路 */
                break;
            }
            off += (size_t)r;
        }
        close(fd);
        if (off == n)
            return;
    }
    /* 退路：时间 + pid 起个 xorshift。这里只是"要个不一样的盐"，不担密码学强度。 */
    uint64_t x = (uint64_t)time(NULL) ^ ((uint64_t)getpid() << 32) ^ (uintptr_t)buf;
    char *p = (char *)buf;
    for (size_t i = 0; i < n; i++) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        p[i] = (char)(x >> 24);
    }
}
