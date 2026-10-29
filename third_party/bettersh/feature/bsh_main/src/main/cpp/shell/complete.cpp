// shell/complete.cpp — 见 complete.h
#include "complete.h"

#include <algorithm>

namespace bsh {

const std::vector<std::string>& BuiltinNames() {
    // 与 shell.cpp 的 RunBuiltin 一一对应。加内建命令时两处都要改
    // （helper: RunBuiltin 里出现 `if (c == "xxx")` 的都算）。
    static const std::vector<std::string> kNames = {
        "echo", "help", "bshutil", "clear", "pwd", "cd",
        "export", "unset", "exit", "true", "false",
    };
    return kNames;
}

namespace {

std::string CommonPrefix(const std::string& a, const std::string& b) {
    size_t n = 0;
    while (n < a.size() && n < b.size() && a[n] == b[n]) n++;
    return a.substr(0, n);
}

bool StartsWith(const std::string& s, const std::string& p) {
    return s.size() >= p.size() && s.compare(0, p.size(), p) == 0;
}

}  // namespace

CompletionResult CompleteWord(const std::string& word, bool cmd_pos,
                              const std::string& bin_dir,
                              const DirLister& list_dir, bool list_all) {
    CompletionResult r;
    r.replacement = word;

    // 词里带 '/' → 一律按路径补全（哪怕在命令位，比如 ./hello）
    std::string dir, base;
    size_t slash = word.rfind('/');
    if (slash != std::string::npos) {
        dir = word.substr(0, slash + 1);     // 含尾随 '/'
        base = word.substr(slash + 1);
    } else {
        base = word;
    }

    std::vector<std::string> names;
    if (cmd_pos && slash == std::string::npos) {
        names = BuiltinNames();
        for (const std::string& n : list_dir(bin_dir)) names.push_back(n);
    } else {
        // 路径补全：目录名给 lister，"." 表示当前目录
        names = list_dir(dir.empty() ? "." : dir);
    }

    std::vector<std::string> hits;
    for (const std::string& n : names) {
        if (!n.empty() && n[0] == '.' && (base.empty() || base[0] != '.'))
            continue;                        // 隐藏文件：不主动补（除非用户自己打了 '.'）
        if (!StartsWith(n, base)) continue;
        hits.push_back(n);
    }
    std::sort(hits.begin(), hits.end());
    hits.erase(std::unique(hits.begin(), hits.end()), hits.end());

    if (hits.empty()) return r;              // 没得补：原样返回

    if (hits.size() == 1) {
        r.replacement = dir + hits[0];
        // 目录（带尾随 '/'）继续往下补；文件补完加个空格方便接着打
        if (r.replacement.empty() || r.replacement.back() != '/')
            r.replacement += ' ';
        return r;
    }

    // 多候选：先补公共前缀，第二次 TAB 才列清单
    std::string common = hits[0];
    for (const std::string& h : hits) common = CommonPrefix(common, h);
    r.replacement = dir + common;
    if (list_all) {
        r.candidates = hits;
        r.show_list = true;
    }
    return r;
}

}  // namespace bsh
