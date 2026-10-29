/* netif_shim.c —— 兜住 getifaddrs：沙箱里 netlink 的 raw socket 被拒
 *
 * 症状（STATUS §59 / §64）：VS Code / Electron 的 main 进程启动时
 *     os.networkInterfaces()            （node:os → libuv → uv_interface_addresses）
 *      └─ socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE) / bind  → EACCES(13)
 * 抛 SystemError[ERR_SYSTEM_ERROR] 到 `Js.startup` 的 await 链上 —— startup 的 promise
 * 直接 reject，工作台**从未下发到渲染器**，窗口永远停在 Chromium 交出的那一帧背景色。
 *
 * 修法：把 getifaddrs 换成一份自己造的假表。libuv 只拿它列网卡，够它不抛异常即可。
 * 但**只给 lo 不够** —— 紧接着 VS Code 会在同一个 NT() 里挑一张"非内部、且 MAC 非全零"
 * 的网卡做 machineId，拿不到就 `Error: Unable to retrieve mac address (unexpected format)`
 * 再抛一次（还是打在 Js.startup 上）。所以这里必须给一张带真 MAC 的 eth0。
 *
 * 为什么不是改 Chromium：uv_interface_addresses 是**静态链进** Electron 二进制的，
 * LD_PRELOAD 拦不到 libuv 内部；但它调的是 glibc 的 getifaddrs，这一层能拦。
 *
 * 用法：LD_PRELOAD=<本 .so>（vscode 的启动器里**追加**进 LD_PRELOAD；不设时行为完全不变）
 */
#define _GNU_SOURCE
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

/* 不用 <linux/if_arp.h> + <linux/if_packet.h>：它们会拽进 <linux/if.h>，
 * 和 <net/if.h> 的 IFF_* 枚举撞车（redeclaration of enumerator 'IFF_UP'）。
 * 这里要的只有两个常量和一个结构体，自己写，布局与内核一致。 */
#ifndef ARPHRD_ETHER
#define ARPHRD_ETHER 1
#endif
#ifndef AF_PACKET
#define AF_PACKET 17
#endif
struct bsh_sockaddr_ll {
    unsigned short sll_family;
    unsigned short sll_protocol;
    int sll_ifindex;
    unsigned short sll_hatype;
    unsigned char sll_pkttype;
    unsigned char sll_halen;
    unsigned char sll_addr[8];
};

/* 假 MAC：本地管理位（02:）开头，学 docker 的 veth，绝不像随机数那么可疑 */
static const unsigned char kMac[6] = { 0x02, 0x42, 0x0a, 0x00, 0x02, 0x02 };

static struct ifaddrs *g_head;

static struct ifaddrs *mk(const char *name, int family, unsigned flags,
                          unsigned ip, const unsigned char *mac) {
    size_t sa = sizeof(struct sockaddr_in);
    if (family == AF_INET6)     sa = sizeof(struct sockaddr_in6);
    else if (family == AF_PACKET) sa = sizeof(struct bsh_sockaddr_ll);

    struct ifaddrs *ifa = (struct ifaddrs *)calloc(1, sizeof(*ifa) + sa * 2 + 8);
    if (!ifa) return NULL;
    char *p = (char *)(ifa + 1);
    ifa->ifa_name = strdup(name);
    ifa->ifa_flags = flags;
    ifa->ifa_addr = (struct sockaddr *)p;

    if (family == AF_INET) {
        struct sockaddr_in *a = (struct sockaddr_in *)ifa->ifa_addr;
        struct sockaddr_in *m = (struct sockaddr_in *)(p + sa);
        a->sin_family = AF_INET;
        a->sin_addr.s_addr = htonl(ip);
        m->sin_family = AF_INET;
        m->sin_addr.s_addr = htonl(0xffffff00u);
        ifa->ifa_netmask = (struct sockaddr *)m;
    } else if (family == AF_INET6) {
        struct sockaddr_in6 *a = (struct sockaddr_in6 *)ifa->ifa_addr;
        struct sockaddr_in6 *m = (struct sockaddr_in6 *)(p + sa);
        a->sin6_family = AF_INET6;
        a->sin6_addr = in6addr_loopback;
        m->sin6_family = AF_INET6;
        m->sin6_addr = in6addr_any;
        ifa->ifa_netmask = (struct sockaddr *)m;
    } else {   /* AF_PACKET：libuv 就是从这里取 phys_addr（→ node 的 mac 字段） */
        struct bsh_sockaddr_ll *a = (struct bsh_sockaddr_ll *)ifa->ifa_addr;
        a->sll_family = AF_PACKET;
        a->sll_hatype = ARPHRD_ETHER;
        a->sll_halen = 6;
        if (mac) memcpy(a->sll_addr, mac, 6);
        ifa->ifa_netmask = NULL;
    }
    return ifa;
}

int getifaddrs(struct ifaddrs **out) {
    if (!out) return -1;
    if (!g_head) {
        struct ifaddrs *lo4 = mk("lo", AF_INET, IFF_LOOPBACK | IFF_UP | IFF_RUNNING,
                                 INADDR_LOOPBACK, NULL);
        struct ifaddrs *lo6 = mk("lo", AF_INET6, IFF_LOOPBACK | IFF_UP | IFF_RUNNING, 0, NULL);
        /* 没有 IFF_LOOPBACK ⇒ node 报 internal:false；AF_PACKET 那条提供 MAC。
         * 顺序无所谓（libuv 分两趟走），串成一条链即可。 */
        struct ifaddrs *e4 = mk("eth0", AF_INET,
                                IFF_UP | IFF_RUNNING | IFF_BROADCAST | IFF_MULTICAST,
                                0x0a00020fu /* 10.0.2.15 */, NULL);
        struct ifaddrs *e6 = mk("eth0", AF_PACKET,
                                IFF_UP | IFF_RUNNING | IFF_BROADCAST | IFF_MULTICAST, 0, kMac);
        struct ifaddrs *chain[4] = { lo4, lo6, e4, e6 };
        struct ifaddrs *prev = NULL;
        for (int i = 0; i < 4; i++) {
            if (!chain[i]) continue;
            if (prev) prev->ifa_next = chain[i];
            else g_head = chain[i];
            prev = chain[i];
        }
        if (!g_head) return -1;
    }
    *out = g_head;
    return 0;
}

void freeifaddrs(struct ifaddrs *ifa) {
    (void)ifa;   /* 表是常驻的，见上；不动它，重复 freeifaddrs 也安全 */
}
