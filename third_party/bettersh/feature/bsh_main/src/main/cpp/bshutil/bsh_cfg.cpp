// bshutil/bsh_cfg.cpp — 应用设置的实现
#include "bsh_cfg.h"

#include <atomic>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace {

/* 配置标量用 atomic:bshutil 服务端线程改它们(见 bshutil/bsh_util_server.cpp),
 * 而 shell 线程每次执行命令都读 exit-hint —— 两个线程共享这一份,普通全局是数据竞争。 */
std::atomic<int>    g_exit_hint{1};
std::atomic<int>    g_elf_hint{1};
std::atomic<double> g_win_scale{2.0};
std::atomic<int>    g_right_click{0};   /* 0=menu, 1=smart */
std::atomic<int>    g_node_jitless{0};  /* 0=auto, 1=on, 2=off */
char   g_path[512] = {0};

/* on/1/true/yes 为真;off/0/false/no 为假;其余返回 -1(让调用方报用法错) */
int ParseOnOff(const char* v) {
    if (!v) return -1;
    if (!strcmp(v, "on") || !strcmp(v, "1") || !strcmp(v, "true") ||
        !strcmp(v, "yes"))
        return 1;
    if (!strcmp(v, "off") || !strcmp(v, "0") || !strcmp(v, "false") ||
        !strcmp(v, "no"))
        return 0;
    return -1;
}

/* 右键行为:menu/0 → 0(菜单),smart/1 → 1(智能)。其余 -1(用法错)。
 * 顺带认一下 0/1,方便脚本里写 set right-click 1。 */
int ParseRightClick(const char* v) {
    if (!v) return -1;
    if (!strcmp(v, "menu") || !strcmp(v, "0")) return 0;
    if (!strcmp(v, "smart") || !strcmp(v, "1")) return 1;
    return -1;
}

/* node jitless 策略:auto/0 → 0,on/1 → 1,off/2 → 2。其余 -1(用法错)。 */
int ParseJitless(const char* v) {
    if (!v) return -1;
    if (!strcmp(v, "auto") || !strcmp(v, "0")) return 0;
    if (!strcmp(v, "on")   || !strcmp(v, "1")) return 1;
    if (!strcmp(v, "off")  || !strcmp(v, "2")) return 2;
    return -1;
}

const char* JitlessName(int m) {
    return m == 1 ? "on" : (m == 2 ? "off" : "auto");
}

/* 去掉首尾空白(就地去),便于人肉编辑的配置文件 */
char* Trim(char* s) {
    while (*s == ' ' || *s == '\t') s++;
    char* e = s + strlen(s);
    while (e > s && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' ' || e[-1] == '\t'))
        *--e = '\0';
    return s;
}
}  // namespace

extern "C" {

int bsh_cfg_load(const char* path) {
    if (!path || !*path) return -1;
    snprintf(g_path, sizeof g_path, "%s", path);

    FILE* f = fopen(path, "r");
    if (!f) return 0;   // 没有配置文件 = 全用默认值
    char line[512];
    while (fgets(line, sizeof line, f)) {
        char* s = Trim(line);
        if (!*s || *s == '#') continue;
        char* eq = strchr(s, '=');
        if (!eq) continue;
        *eq = '\0';
        char* key = Trim(s);
        char* val = Trim(eq + 1);

        if (!strcmp(key, "exit-hint")) {
            int v = ParseOnOff(val);
            if (v >= 0) g_exit_hint = v;
        } else if (!strcmp(key, "elf-hint")) {
            int v = ParseOnOff(val);
            if (v >= 0) g_elf_hint = v;
        } else if (!strcmp(key, "win-scale")) {
            double d = strtod(val, nullptr);
            if (d > 0) {
                if (d < 0.25) d = 0.25;
                if (d > 4.0) d = 4.0;
                g_win_scale = d;
            }
        } else if (!strcmp(key, "right-click")) {
            int v = ParseRightClick(val);
            if (v >= 0) g_right_click = v;
        } else if (!strcmp(key, "node-jitless")) {
            int v = ParseJitless(val);
            if (v >= 0) g_node_jitless = v;
        }
        /* 不认识的键忽略(但 save 只写已知项,见下面的说明) */
    }
    fclose(f);
    return 0;
}

int bsh_cfg_save(const char* path) {
    if (!path || !*path) return -1;
    snprintf(g_path, sizeof g_path, "%s", path);
    FILE* f = fopen(path, "w");
    if (!f) return -1;
    fprintf(f, "# BetterSH 设置(bshutil 写;可以直接手改,重启会话生效)\n");
    fprintf(f, "exit-hint=%s\n", g_exit_hint.load() ? "on" : "off");
    fprintf(f, "elf-hint=%s\n", g_elf_hint.load() ? "on" : "off");
    /* 注意:读原子量给可变参数(fprintf)必须显式 load(),类类型不能直接进 ... */
    fprintf(f, "win-scale=%.2f\n", g_win_scale.load());
    fprintf(f, "right-click=%s\n", g_right_click.load() ? "smart" : "menu");
    fprintf(f, "node-jitless=%s\n", JitlessName(g_node_jitless.load()));
    fclose(f);
    return 0;
}

int bsh_cfg_exit_hint(void) { return g_exit_hint.load(); }
void bsh_cfg_set_exit_hint(int on) { g_exit_hint.store(on ? 1 : 0); }

int bsh_cfg_elf_hint(void) { return g_elf_hint.load(); }
void bsh_cfg_set_elf_hint(int on) { g_elf_hint.store(on ? 1 : 0); }

double bsh_cfg_win_scale(void) { return g_win_scale.load(); }
void bsh_cfg_set_win_scale(double s) {
    if (s < 0.25) s = 0.25;
    if (s > 4.0) s = 4.0;
    g_win_scale.store(s);
}

int bsh_cfg_right_click(void) { return g_right_click.load(); }
void bsh_cfg_set_right_click(int smart) { g_right_click.store(smart ? 1 : 0); }

void bsh_cfg_export_env(void) {
    setenv("BSH_NODE_JITLESS", JitlessName(g_node_jitless.load()), 1);
}

int  bsh_cfg_node_jitless(void) { return g_node_jitless.load(); }
void bsh_cfg_set_node_jitless(int mode) {
    if (mode < 0 || mode > 2) mode = 0;
    g_node_jitless.store(mode);
}

const char* bsh_cfg_path(void) { return g_path; }

}  // extern "C"
