// ssh/pwshim.c — 给 dropbear 补 passwd 数据库
//
// 沙箱的 /etc/passwd 只有 root/shell 这类系统账号,**没有当前应用 uid 的条目**
// (P0 实测:getpwuid(getuid()) 返回 NULL)。后果:
//   - 服务端 dropbear 的 fill_passwd() 拿不到 pw_name,checkusername() 一律拒绝登录;
//   - 客户端打 "Warning: failed to identify current user. Trying anyway."。
//
// 做法是**符号遮蔽**,不改 dropbear 源码:本文件定义 getpwuid / getpwnam,以及
// 身份切换的 seteuid / setegid(见文末:沙箱对切身份的调用会直接杀掉进程),
// 链接时配合 -Bsymbolic-functions,dropbear 各目标文件里对这些符号的调用会绑到
// 这里的实现。命令 so 现在是 RTLD_GLOBAL 加载的(见 procmgr.cpp 里那段说明,
// 为 box64 的符号解析必须如此),但一个子进程只跑一个命令 so,所以遮蔽仍局限在
// 该进程内,不影响别的命令。
//
// 规则(刻意保守):
//   - getpwuid(uid):只有 uid == getuid() 才给合成条目,其余返回 NULL;
//   - getpwnam(name):只有名字等于约定用户名(默认 "user",可用 BSH_SSH_USER 覆盖)
//     才给合成条目,其余返回 NULL。
// 于是 dropbear「非 root 运行时只允许登录到 server 自身 uid」的既有判断继续成立:
// 拿 root 来登仍然被它自己拒掉。
//
// 注意 pw_shell 必须是**裸名字** sh,不能写 /bin/sh:
//   - dropbear 的 run_command() 用 execv(不做 PATH 搜索),裸名字正好落到
//     BetterSH 的 exec 委托 → procmgr 命令表 → libmksh.so;
//   - 本沙箱里 /bin 是 EACCES(P0 实测)。
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "common/bsh_paths.h"

#define BSH_SSH_DEFAULT_USER "user"

static const char* BshUserName(void) {
    const char* u = getenv("BSH_SSH_USER");
    return (u && *u) ? u : BSH_SSH_DEFAULT_USER;
}

static const char* BshHomeDir(void) {
    const char* h = getenv("HOME");
    return (h && *h) ? h : bsh_home_dir();
}

/* pw_shell 用**裸名字** sh(不是 /bin/sh):
 *   - exec 侧:run_shell_command() 最终就是按这个串 exec,裸名字正好落到
 *     BetterSH 的 exec 委托 → procmgr 命令表 → libmksh.so(本沙箱 /bin 是 EACCES);
 *   - 白名单侧:dropbear 的 checkusername() 会拿 getusershell() 的清单校验它,
 *     而 getusershell() 读的 /etc/shells 在本沙箱不存在,会回退到编译期常量
 *     COMPAT_USER_SHELLS —— 构建脚本已在 localoptions.h 里把那个常量设成同一个
 *     名字,两边天然一致。 */
#define BSH_SSH_SHELL "sh"

static struct passwd* BshFillPasswd(struct passwd* pw) {
    pw->pw_name   = (char*)BshUserName();
    pw->pw_passwd = (char*)"x";
    pw->pw_uid    = getuid();
    pw->pw_gid    = getgid();
    pw->pw_gecos  = (char*)"";
    pw->pw_dir    = (char*)BshHomeDir();
    pw->pw_shell  = (char*)BSH_SSH_SHELL;
    return pw;
}

struct passwd* getpwuid(uid_t uid) {
    static struct passwd pw;
    if (uid != getuid()) return NULL;
    return BshFillPasswd(&pw);
}

struct passwd* getpwnam(const char* name) {
    static struct passwd pw;
    if (!name || strcmp(name, BshUserName()) != 0) return NULL;
    return BshFillPasswd(&pw);
}

/* ---- seteuid/setegid:沙箱不允许,也完全不需要 ----
 * dropbear 读 authorized_keys 时要"以被认证用户的身份"临时切一下再切回来
 * (svr-authpubkey.c 的 checkpubkey()):
 *     origuid=getuid(); origgid=getgid();
 *     setegid(pw_gid); seteuid(pw_uid);   ...读文件...   seteuid(origuid); setegid(origgid);
 * 我们的合成条目里 pw_uid/pw_gid 就是进程自己(见 BshFillPasswd),这两步本来就是
 * 空操作。真正的问题是**沙箱对切换身份的调用不给返回值的机会**:实测进程会在这里
 * 直接消失 —— 不可捕获的强杀,连崩溃处理器都没机会留痕(定位过程见 docs/ssh-port.md)。
 * 所以短路掉:目标就是当前身份才返回成功,别的一律失败(不假装能提权)。
 * 同类调用还出现在 svr-agentfwd.c(agent 转发)与 svr-auth.c 的 utmp 组切换,一并覆盖。 */
int seteuid(uid_t uid) { return (uid == geteuid()) ? 0 : -1; }
int setegid(gid_t gid) { return (gid == getegid()) ? 0 : -1; }
