// bshutil/bshutil.cpp — 内置命令 bshutil 的实现
//
// 子命令分三类:
//   - 纯本地:help / conf / set / proclist / kill
//   - 通知 ArkTS 改界面:keys show|hide、set win-scale(改完顺手通知)
//   - 请 ArkTS 代劳的系统交互:picker
// 后两类经 ui_bus 发事件给 ArkTS;UI 没订阅(界面还没起来)时降级成 [warn] 并返回 1。
#include "bshutil.h"
#include "bsh_cfg.h"
#include "ui_bus.h"

#include "../procmgr/bsh_client.h"
#include "../procmgr/procmgr.h"
#include "common/bsh_rawfile.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <string>
#include <vector>

namespace {

void Out(int fd, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vdprintf(fd, fmt, ap);
    va_end(ap);
}

/* 保存配置,并把要给命令 so 看的项同步成环境变量。
 * 顺序无所谓(两者都取自内存里的同一份值),但必须在 spawn 之前 —— 子进程继承的是
 * 宿主当时的 environ,见 bsh_cfg_export_env 的注释。 */
static int SaveCfgAndExport(void) {
    int rc = bsh_cfg_save(bsh_cfg_path());
    if (rc == 0) bsh_cfg_export_env();
    return rc;
}

int Usage(int fd) {
    Out(fd,
        "bshutil — 改 BetterSH 自己的设置\n"
        "  bshutil conf                    打印当前设置\n"
        "  bshutil set exit-hint on|off    命令非 0 退出时是否提示 [exit N]\n"
        "  bshutil set elf-hint on|off     装载 ELF 时是否打印 [elf] 行\n"
        "  bshutil set win-scale <n>       Wayland 窗口缩放 0.25~4.0(新窗口生效)\n"
        "  bshutil set right-click menu|smart\n"
        "                                  右键行为:menu=弹出菜单(内有复制/粘贴),\n"
        "                                  smart=有选中就复制、没有就粘贴\n"
        "  bshutil keys show|hide          显示/隐藏底部虚拟按键栏(即时,不持久化)\n"
        "  bshutil newtab [-e <命令>]       新开一个终端窗口(独立会话,跑 mksh;-e 起来后跑一条命令)\n"
        "  bshutil picker                  选一个目录,取得它的访问权限\n"
        "  bshutil proclist                列出 procmgr 创建过的进程\n"
        "  bshutil kill <pid>              结束其中一个进程\n"
        "  bshutil rawfile list            列出 hap 里打包的全部 rawfile(路径 + 字节数)\n"
        "  bshutil rawfile get <名> <目标> 把某个 rawfile 拷到磁盘(目标可写相对路径)\n"
        "  bshutil caps                    打印宿主能力(fork/exec/jit;启动时探的)\n"
        "  bshutil set node-jitless <auto|on|off>\n"
        "                                  node 的 JIT 策略(auto=拿不到可执行内存就自动 --jitless)\n");
    return 0;
}

/* on/1/true 为真,off/0/false 为假,其余 -1 */
int OnOff(const char* v) {
    if (!v) return -1;
    if (!strcmp(v, "on") || !strcmp(v, "1") || !strcmp(v, "true")) return 1;
    if (!strcmp(v, "off") || !strcmp(v, "0") || !strcmp(v, "false")) return 0;
    return -1;
}

/* 请 ArkTS 做一件事;UI 没订阅时打 [warn] 并返回 1 */
int NotifyUi(int fd, const char* json, const char* ok_msg) {
    if (bsh_ui_notify(json) != 0) {
        Out(fd, "[warn] 界面还没订阅事件,这条设置没能生效\n");
        return 1;
    }
    Out(fd, "%s\n", ok_msg);
    return 0;
}

/* procmgr 的 LIST 响应是多行 "INFO pid=… alive=… code=… cmd=…"(见 ctrl_socket.cpp),
 * 这里把 INFO 前缀去掉转给终端 */
int ProcList(int fd) {
    char buf[32 * 1024];
    if (!bsh_procmgr_list(buf, sizeof buf)) {
        const char* e = bsh_client_last_error();
        Out(fd, "bshutil: %s\n", (e && *e) ? e : "procmgr 无响应");
        return 1;
    }
    int any = 0;
    char* p = buf;
    while (*p) {
        char* nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        if (len > 5 && strncmp(p, "INFO ", 5) == 0) {
            any = 1;
            Out(fd, "%.*s\n", (int)(len - 5), p + 5);
        }
        if (!nl) break;
        p = nl + 1;
    }
    if (!any) Out(fd, "(procmgr 尚未登记进程)\n");
    return 0;
}

/* 人类可读的总量(只有一处用,不值得做成通用件) */
const char* HumanSize(long long n, char* buf, size_t len) {
    static const char* kUnit[] = {"B", "KiB", "MiB", "GiB"};
    double d = (double)n;
    int i = 0;
    while (d >= 1024.0 && i < 3) { d /= 1024.0; i++; }
    if (i == 0) snprintf(buf, len, "%lld B", n);
    else        snprintf(buf, len, "%.1f %s", d, kUnit[i]);
    return buf;
}

/* 把**调用方**传来的相对路径补成绝对路径。服务端跑在主进程里,cwd 是应用启动目录,
 * 跟用户在终端里 cd 到哪没关系 —— 所以只能用客户端带过来的那个 cwd
 * (见 bshutil.h 的 bshutil_exec 说明)。空串 = 解不出来。 */
std::string AbsPath(const char* cwd, const char* p) {
    if (p[0] == '/') return p;
    if (cwd == nullptr || cwd[0] == '\0') return std::string();
    std::string s = cwd;
    if (s.back() != '/') s += '/';
    return s + p;
}

/* bshutil rawfile list | get <名> <目标>
 *
 * 读的是 hap 里**打包的** rawfile(不是解出来的 sysroot),所以只有主进程够得着
 * 那个 napi 资源管理器 —— 这条子命令存在的前提就是它跑在服务端。 */
int RawFileCmd(int fd, int argc, char* const argv[], const char* cwd) {
    if (argc < 3) {
        Out(fd, "bshutil: rawfile 需要 list 或 get\n");
        return 2;
    }
    const char* sub = argv[2];

    if (!strcmp(sub, "list")) {
        std::vector<bsh::RawFileEntry> v;
        if (!bsh::bsh_rawfile_list(&v)) {
            Out(fd, "bshutil: 拿不到应用的资源管理器(界面还没起来?)\n");
            return 1;
        }
        long long total = 0;
        for (const bsh::RawFileEntry& e : v) {
            Out(fd, "%10lld  %s\n", e.size, e.path.c_str());
            total += e.size;
        }
        char hb[32];
        Out(fd, "共 %zu 个文件 / %s\n", v.size(), HumanSize(total, hb, sizeof hb));
        return 0;
    }

    if (!strcmp(sub, "get")) {
        if (argc < 5) {
            Out(fd, "bshutil: rawfile get 需要 <rawfile 名> <目标路径>\n");
            return 2;
        }
        const char* name = argv[3];
        std::string dst = AbsPath(cwd, argv[4]);
        if (dst.empty()) {
            Out(fd, "bshutil: %s 是相对路径,但拿不到调用方的当前目录 —— 请写绝对路径\n",
                argv[4]);
            return 1;
        }
        int rc = bsh::bsh_rawfile_copy(name, dst.c_str(), /*overwrite=*/true);
        if (rc == -2) {
            Out(fd, "bshutil: 没有这个 rawfile: %s(用 `bshutil rawfile list` 看名字)\n",
                name);
            return 1;
        }
        if (rc < 0) {
            Out(fd, "bshutil: 写出 %s 失败: %s\n", dst.c_str(), strerror(errno));
            return 1;
        }
        struct stat st;
        char hb[32];
        const char* sz = (stat(dst.c_str(), &st) == 0) ? HumanSize(st.st_size, hb, sizeof hb)
                                                       : "?";
        Out(fd, "[ok] %s → %s (%s)\n", name, dst.c_str(), sz);
        return 0;
    }

    Out(fd, "bshutil: rawfile 需要 list 或 get\n");
    return 2;
}

/* 把一段文本转义成 JSON 字符串的值(引号/反斜杠/控制字符)。只有 newtab -e 用得上,
 * 而命令里带引号是常事(`bash -c "..."`),不转义就会拼出坏 JSON。 */
std::string JsonEscape(const char* s) {
    std::string o;
    for (const unsigned char* p = (const unsigned char*)s; p && *p; p++) {
        switch (*p) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n";  break;
            case '\r': o += "\\r";  break;
            case '\t': o += "\\t";  break;
            default:
                if (*p < 0x20) {
                    char b[8];
                    snprintf(b, sizeof b, "\\u%04x", *p);
                    o += b;
                } else {
                    o += (char)*p;
                }
        }
    }
    return o;
}

}  // namespace

extern "C" int bshutil_exec(int argc, char* const argv[], int out_fd, const char* cwd,
                            int sid) {
    if (argc < 2) return Usage(out_fd);
    const char* sub = argv[1];

    if (!strcmp(sub, "help") || !strcmp(sub, "-h") || !strcmp(sub, "--help"))
        return Usage(out_fd);

    if (!strcmp(sub, "conf")) {
        Out(out_fd, "exit-hint=%s\n", bsh_cfg_exit_hint() ? "on" : "off");
        Out(out_fd, "elf-hint=%s\n", bsh_cfg_elf_hint() ? "on" : "off");
        Out(out_fd, "win-scale=%.2f\n", bsh_cfg_win_scale());
        Out(out_fd, "right-click=%s\n", bsh_cfg_right_click() ? "smart" : "menu");
        Out(out_fd, "node-jitless=%s\n",
            bsh_cfg_node_jitless() == 1 ? "on" : (bsh_cfg_node_jitless() == 2 ? "off" : "auto"));
        Out(out_fd, "conf: %s\n", bsh_cfg_path());
        return 0;
    }

    if (!strcmp(sub, "set")) {
        if (argc < 4) {
            Out(out_fd, "bshutil: set 需要 <设置项> <值>\n");
            return 2;
        }
        const char* key = argv[2];
        const char* val = argv[3];

        if (!strcmp(key, "win-scale")) {
            double d = strtod(val, nullptr);
            if (!(d > 0)) {
                Out(out_fd, "bshutil: win-scale 需要 0.25~4.0 的数字\n");
                return 2;
            }
            bsh_cfg_set_win_scale(d);
            if (SaveCfgAndExport() != 0) {
                Out(out_fd, "bshutil: 配置写入失败\n");
                return 1;
            }
            /* 顺手告诉 ArkTS:已经开着的窗口不追溯,新开的才按新值拉伸 */
            char json[80];
            snprintf(json, sizeof json, "{\"op\":\"scale\",\"value\":%.2f}",
                     bsh_cfg_win_scale());
            bsh_ui_notify(json);   // 没订阅就算了,配置已经落盘
            Out(out_fd, "[ok] win-scale=%.2f(新开的窗口生效)\n", bsh_cfg_win_scale());
            return 0;
        }

        if (!strcmp(key, "node-jitless")) {
            int mode;
            if      (!strcmp(val, "auto") || !strcmp(val, "0")) mode = 0;
            else if (!strcmp(val, "on")   || !strcmp(val, "1")) mode = 1;
            else if (!strcmp(val, "off")  || !strcmp(val, "2")) mode = 2;
            else {
                Out(out_fd, "bshutil: node-jitless 需要 auto|on|off\n");
                return 2;
            }
            bsh_cfg_set_node_jitless(mode);
            if (SaveCfgAndExport() != 0) {
                Out(out_fd, "bshutil: 配置写入失败\n");
                return 1;
            }
            /* 每次起 node 由入口读一次配置,所以下一次运行就生效,不用重启会话 */
            Out(out_fd, "[ok] node-jitless=%s\n",
                mode == 1 ? "on" : (mode == 2 ? "off" : "auto"));
            return 0;
        }

        if (!strcmp(key, "right-click")) {
            int smart;
            if      (!strcmp(val, "menu")  || !strcmp(val, "0")) smart = 0;
            else if (!strcmp(val, "smart") || !strcmp(val, "1")) smart = 1;
            else {
                Out(out_fd, "bshutil: right-click 需要 menu|smart\n");
                return 2;
            }
            bsh_cfg_set_right_click(smart);
            if (SaveCfgAndExport() != 0) {
                Out(out_fd, "bshutil: 配置写入失败\n");
                return 1;
            }
            /* 立即生效:推给 ArkTS,终端页据此决定右键行为(仿 win-scale 的做法) */
            char json[80];
            snprintf(json, sizeof json, "{\"op\":\"rightclick\",\"mode\":\"%s\"}",
                     smart ? "smart" : "menu");
            bsh_ui_notify(json);   // 没订阅就算了,配置已经落盘
            Out(out_fd, "[ok] right-click=%s\n", smart ? "smart" : "menu");
            return 0;
        }

        int on = OnOff(val);
        if (on < 0) {
            Out(out_fd, "bshutil: 值需要 on|off\n");
            return 2;
        }
        if      (!strcmp(key, "exit-hint")) bsh_cfg_set_exit_hint(on);
        else if (!strcmp(key, "elf-hint"))  bsh_cfg_set_elf_hint(on);
        else {
            Out(out_fd, "bshutil: 未知设置项 %s\n", key);
            return 2;
        }
        if (SaveCfgAndExport() != 0) {
            Out(out_fd, "bshutil: 配置写入失败\n");
            return 1;
        }
        Out(out_fd, "[ok] %s=%s\n", key, on ? "on" : "off");
        return 0;
    }

    if (!strcmp(sub, "keys")) {
        if (argc < 3) {
            Out(out_fd, "bshutil: keys 需要 show|hide\n");
            return 2;
        }
        int show;
        if      (!strcmp(argv[2], "show")) show = 1;
        else if (!strcmp(argv[2], "hide")) show = 0;
        else {
            Out(out_fd, "bshutil: keys 需要 show|hide\n");
            return 2;
        }
        char json[64];
        snprintf(json, sizeof json, "{\"op\":\"keys\",\"show\":%s}",
                 show ? "true" : "false");
        char msg[96];
        snprintf(msg, sizeof msg, "[ok] 已请求%s底部按键栏(即时生效,不持久化)",
                 show ? "显示" : "隐藏");
        return NotifyUi(out_fd, json, msg);
    }

    if (!strcmp(sub, "picker")) {
        /* 拉起目录选择器取得该目录的访问权限。
         * sid 决定**在哪个窗口弹**:必须回给发起命令的那个会话,不然从新 tab 里敲
         * `bshutil picker` 会弹到主窗口上。 */
        char resp[512];
        if (bsh_ui_request(sid, "{\"op\":\"picker\"}", resp, sizeof resp, 300000) != 0) {
            Out(out_fd, "[warn] 界面没有响应(未订阅,或等待超时)\n");
            return 1;
        }
        Out(out_fd, "%s\n", resp);
        return 0;
    }

    if (!strcmp(sub, "newtab")) {
        /* 请 ArkTS 起一个**新的终端窗口**(TerminalRunnerAbility,multiton)。
         * 同样回给发起命令的那个会话所在窗口 —— 新窗口用哪个 Ability 的 context 起,
         * 由它决定。超时给 5s 就够:startAbility 本身是毫秒级的,给长了只会让 shell
         * 白等(而 bshutil 服务端是**串行**的,等太久会把后面的请求一起堵住)。
         *
         * `-e <命令>`:新窗口起来后在它那个会话里跑一条命令(同 `xterm -e`)。
         * 命令由新窗口的页面在 bshTermStart 之后写进自己会话的 pty —— 只有它知道
         * 自己拿到的是哪个会话号。用法上它也是"验证新会话真的通了"的唯一手段
         * (新窗口没法从外面敲键盘)。 */
        const char* exec = nullptr;
        if (argc >= 4 && (!strcmp(argv[2], "-e") || !strcmp(argv[2], "--exec")))
            exec = argv[3];
        else if (argc >= 3) {
            Out(out_fd, "bshutil: newtab can only use -e <command>\n");
            return 2;
        }
        char json[4096];
        if (exec)
            snprintf(json, sizeof json, "{\"op\":\"newtab\",\"exec\":\"%s\"}",
                     JsonEscape(exec).c_str());
        else
            snprintf(json, sizeof json, "{\"op\":\"newtab\"}");

        char resp[512];
        if (bsh_ui_request(sid, json, resp, sizeof resp, 5000) != 0) {
            Out(out_fd, "[warn] The interface is not responding (subscribed, or waiting timed out)\n");
            return 1;
        }
        Out(out_fd, "%s\n", resp);
        return 0;
    }

    if (!strcmp(sub, "proclist")) return ProcList(out_fd);

    if (!strcmp(sub, "rawfile")) return RawFileCmd(out_fd, argc, argv, cwd);

    if (!strcmp(sub, "caps")) {
        /* 只**打印**启动时那一次探测的结论(见 procmgr/caps.cpp),不重探 ——
         * 重探要再 execve 一次外部二进制,系统会弹确认框、还要等子进程。 */
        const bsh::procmgr::HostCapabilities& c = bsh::procmgr::Capabilities();
        Out(out_fd, "fork=%s\n", c.fork ? "yes" : "no");
        Out(out_fd, "exec=%s(errno=%d)\n", c.exec ? "yes" : "no", c.exec_errno);
        Out(out_fd, "jit=%s route=%s errno=%d\n",
            c.jit ? "yes" : "no", c.jit_route, c.jit_errno);
        return 0;
    }

    if (!strcmp(sub, "kill")) {
        if (argc < 3) {
            Out(out_fd, "bshutil: kill 需要 <pid>\n");
            return 2;
        }
        int pid = atoi(argv[2]);
        if (pid <= 0) {
            Out(out_fd, "bshutil: 无效 pid\n");
            return 2;
        }
        if (!bsh_procmgr_terminate(pid)) {
            const char* e = bsh_client_last_error();
            Out(out_fd, "bshutil: %s\n", (e && *e) ? e : "请求失败");
            return 1;
        }
        Out(out_fd, "[ok] 已请求结束 pid=%d\n", pid);
        return 0;
    }

    return Usage(out_fd);
}

extern "C" const char* bshutil_summary(void) {
    return "bshutil            改设置(conf / set / keys / picker / proclist / caps / rawfile)";
}
