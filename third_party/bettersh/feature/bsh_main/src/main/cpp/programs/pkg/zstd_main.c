// zstd_main.c — `zstd` 命令（只做**解压**）。
//
// 为什么要有它：官方分发的 Ubuntu .deb 里，`data.tar` 绝大多数是 **zstd** 压的
// （实测我们那份 162 个依赖包：161 个 data.tar.zst、1 个 data.tar.xz）。要让
// `code --download` 在**设备上**把这些 .deb 解开，就得在设备上有一个 zstd 解压器 ——
// 而这个精简版 HAP 里没有 python3、没有 ar、toybox 也没有 zstd。
//
// 为什么不另起一个 .so：解压那一半 libzstd 已经被编进 libpkg.so 了（见本目录的
// CMakeLists —— 包按 tar.zst 发，pkg 必须能解），另建目标会把这半个 zstd 再编一遍，
// 白白多花编译时间和体积。所以跟 `pkg` 共用一个 so，只多一个入口符号，
// 在 procmgr/command_map.c 里登记成 `zstd`。
//
// 支持的用法（够用就好，不是完整 zstd CLI）：
//     zstd -d <输入.tar.zst> -o <输出.tar>
//     zstd -d -o <输出.tar> <输入.tar.zst>
//     zstd -d <输入.tar.zst>                 → 输出名由输入名去掉 .zst/.zstd 得来
//     zstd <输入>                            → 不带 -d 也当解压（我们没有压缩能力）
#include <stdio.h>
#include <string.h>

#include "bsh_zstd.h"

static const char kUsage[] =
    "用法: zstd -d [-o 输出] <输入.tar.zst>\n"
    "      （只支持解压；-o 省略时由输入名去掉 .zst/.zstd 得来）\n";

/* 由输入名推输出名：a.tar.zst → a.tar；a.zst → a；没有已知后缀就加 .out */
static int derive_out(const char* in, char* out, size_t n) {
    size_t l = strlen(in);
    if (l > 4 && strcmp(in + l - 4, ".zst") == 0) {
        if (l > 8 && strcmp(in + l - 8, ".tar.zst") == 0) {
            snprintf(out, n, "%.*s.tar", (int)(l - 8), in);
            return 0;
        }
        snprintf(out, n, "%.*s", (int)(l - 4), in);
        return 0;
    }
    if (l > 5 && strcmp(in + l - 5, ".zstd") == 0) {
        snprintf(out, n, "%.*s", (int)(l - 5), in);
        return 0;
    }
    if (l + 5 < n) {
        snprintf(out, n, "%s.out", in);
        return 0;
    }
    return -1;
}

int zstd_main(int argc, char** argv) {
    const char* in = NULL;
    const char* out = NULL;
    char outbuf[1024];

    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];
        if (strcmp(a, "-d") == 0 || strcmp(a, "--decompress") == 0) continue;
        if ((strcmp(a, "-o") == 0 || strcmp(a, "--output") == 0) && i + 1 < argc) {
            out = argv[++i];
            continue;
        }
        if (strcmp(a, "-c") == 0 || strcmp(a, "--stdout") == 0) {
            /* 不支持写 stdout：调用方（vscode-download.sh）用文件形式。
             * 这里明确报出来，别静默产出 0 字节。 */
            fprintf(stderr, "zstd: 不支持 -c（本实现只写文件）\n%s", kUsage);
            return 1;
        }
        if (strcmp(a, "-f") == 0 || strcmp(a, "--force") == 0) continue;
        if (a[0] == '-' && a[1] != '\0') {
            fprintf(stderr, "zstd: 不认识的选项 %s\n%s", a, kUsage);
            return 1;
        }
        if (in == NULL) { in = a; continue; }
        fprintf(stderr, "zstd: 多余的参数 %s\n%s", a, kUsage);
        return 1;
    }

    if (in == NULL) { fprintf(stderr, "%s", kUsage); return 1; }
    if (out == NULL) {
        if (derive_out(in, outbuf, sizeof outbuf) != 0) {
            fprintf(stderr, "zstd: 输入名太长，请用 -o 指定输出\n");
            return 1;
        }
        out = outbuf;
    }

    char err[256] = {0};
    if (bsh_zstd_decompress_file(in, out, err, sizeof err) != 0) {
        fprintf(stderr, "zstd: %s\n", err[0] ? err : "解压失败");
        return 1;
    }
    return 0;
}
