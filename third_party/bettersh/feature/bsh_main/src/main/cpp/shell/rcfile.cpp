// shell/rcfile.cpp — .bshrc 的读取与托管块重写（见 rcfile.h）
//
// 注释只做**整行**，不做行尾。理由：行尾注释要额外定义三件事 —— 引号里的 '#' 算不算、
// 转义过的 '\#' 算不算、`$VAR` **展开之后**出现的 '#' 算不算 —— 每一条都能吵起来，
// 而收益只是少打几个字符。整行注释够用了。
#include "rcfile.h"

#include <cstdio>

namespace bsh {

namespace {

// 行尾 \r 去掉（CRLF 容错）；顺带把内容里的 \r 也当行分隔处理（老 Mac 换行，罕见但便宜）
std::string StripCr(std::string s) {
    while (!s.empty() && (s.back() == '\r' || s.back() == '\n')) s.pop_back();
    return s;
}

bool IsBlankOrComment(const std::string& s) {
    size_t i = 0;
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) i++;
    if (i >= s.size()) return true;   // 全空白
    return s[i] == '#';               // 整行注释
}

bool Contains(const std::string& hay, const char* needle) {
    return hay.find(needle) != std::string::npos;
}

// 把全文按 '\n' 切开（保留每行的 \r，交给调用方决定要不要去）
std::vector<std::string> SplitLines(const std::string& text) {
    std::vector<std::string> out;
    std::string cur;
    for (char c : text) {
        if (c == '\n') { out.push_back(cur); cur.clear(); }
        else          { cur += c; }
    }
    if (!cur.empty()) out.push_back(cur);   // 末行没有换行
    return out;
}

}  // namespace

std::vector<std::string> LoadRcLines(const std::string& path) {
    std::vector<std::string> out;
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return out;                     // 没有这个文件 = 没有额外配置，不是错误
    std::string text;
    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) text.append(buf, n);
    fclose(f);

    for (std::string& raw : SplitLines(text)) {
        std::string line = StripCr(raw);
        if (IsBlankOrComment(line)) continue;
        out.push_back(line);
    }
    return out;
}

std::string ApplyManagedBlock(const std::string& existing,
                              const std::vector<std::string>& block) {
    std::vector<std::string> lines = SplitLines(existing);

    // 1) 找成对的定界行（用子串匹配，见 rcfile.h 的说明）
    size_t begin = lines.size(), end = lines.size();
    for (size_t i = 0; i < lines.size(); i++) {
        if (begin == lines.size() && Contains(lines[i], kManagedBeginMark)) { begin = i; continue; }
        if (begin != lines.size() && Contains(lines[i], kManagedEndMark))   { end = i; break; }
    }
    bool have_pair = (begin != lines.size() && end != lines.size() && end > begin);

    // 2) 拼新的托管块（含定界行）
    std::vector<std::string> fresh;
    fresh.push_back(std::string("# ") + kManagedBeginMark +
                    " · 这些由 BetterSH 每次会话按当前配置重写，改这里会被覆盖 >>>");
    for (const std::string& l : block) fresh.push_back(l);
    fresh.push_back(std::string("# ") + kManagedEndMark + " <<<");

    // 3) 替换 / 追加
    std::vector<std::string> out;
    if (have_pair) {
        out.insert(out.end(), lines.begin(), lines.begin() + begin);
        out.insert(out.end(), fresh.begin(), fresh.end());
        out.insert(out.end(), lines.begin() + end + 1, lines.end());
    } else {
        out = lines;
        while (!out.empty() && out.back().empty()) out.pop_back();   // 别在末尾堆空行
        if (!out.empty()) out.push_back("");
        out.insert(out.end(), fresh.begin(), fresh.end());
        out.push_back("");
    }

    // 4) 重新拼成文本，保证以单个换行结尾
    std::string text;
    for (const std::string& l : out) { text += l; text += '\n'; }
    return text;
}

}  // namespace bsh
