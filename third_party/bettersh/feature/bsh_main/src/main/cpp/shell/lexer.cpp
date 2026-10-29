// shell/lexer.cpp — 见 lexer.h
#include "lexer.h"

#include <cctype>

namespace bsh {

std::vector<std::string> SplitLine(const std::string& line, int last_rc,
                                   const VarLookup& lookup) {
    std::vector<std::string> out;
    std::string cur;
    char q = 0;          // 0 = 无引号；'\'' 或 '"'
    bool esc = false;    // 上一个字符是待生效的反斜杠

    for (size_t i = 0; i < line.size(); i++) {
        char c = line[i];

        if (esc) { cur += c; esc = false; continue; }

        // 单引号内一切原样：反斜杠与 `$` 都不特殊
        if (q == '\'') {
            if (c == '\'') q = 0;
            else cur += c;
            continue;
        }

        if (c == '\\') { esc = true; continue; }   // 引号外与双引号内都当转义
        if (c == '"') { q = q ? 0 : '"'; continue; }
        if (c == '\'') { q = '\''; continue; }

        if (c == '$') {
            if (i + 1 < line.size() && line[i + 1] == '?') {   // $? = 上一条退出码
                cur += std::to_string(last_rc);
                i++;
                continue;
            }
            size_t j = i + 1;
            bool braced = false;
            if (j < line.size() && line[j] == '{') { braced = true; j++; }
            std::string name;
            while (j < line.size() &&
                   (isalnum((unsigned char)line[j]) || line[j] == '_'))
                name += line[j++];
            if (braced) {
                if (j < line.size() && line[j] == '}') j++;
                else { cur += '$'; continue; }   // `${` 没闭合：按字面处理
            }
            if (name.empty()) { cur += '$'; continue; }   // 孤立的 `$`
            cur += lookup(name);                          // 未定义 → 空串
            i = j - 1;
            continue;
        }

        if (c == ' ' || c == '\t') {
            if (!cur.empty()) { out.push_back(cur); cur.clear(); }
        } else {
            cur += c;
        }
    }
    if (esc) cur += '\\';                 // 行尾单个反斜杠：当字面
    if (q) cur.insert(0, 1, q);           // 未闭合引号：容错保留
    if (!cur.empty()) out.push_back(cur);
    return out;
}

}  // namespace bsh
