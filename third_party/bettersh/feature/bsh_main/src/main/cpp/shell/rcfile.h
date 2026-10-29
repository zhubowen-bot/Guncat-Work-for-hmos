// shell/rcfile.h — .bshrc 的读取与"托管块"重写（纯逻辑，宿主可单测）
//
// 为什么单独成文件：这两件事都不碰 NDK/pty，放这儿就能用 lineedit_selftest.cpp 那套
// 宿主单测直接断言（不用设备）。shell.cpp 只负责"什么时候调"。
#pragma once

#include <string>
#include <vector>

namespace bsh {

/* 托管块定界。匹配用**子串**（不是整行相等），这样以后改提示文案不会让老文件里的块
 * 变成"孤儿"——认不出来就会再追加一块，越滚越多。 */
inline const char* const kManagedBeginMark = ">>> BetterSH managed";
inline const char* const kManagedEndMark   = "<<< BetterSH managed";

/* 逐行读出**可执行**的行：
 *   - 去掉行尾 \r（设备上文本文件可能是 CRLF）；
 *   - 跳过空白行；
 *   - 跳过**整行**注释：前导空白之后第一个字符是 '#'。
 * 不做行尾注释 —— `echo a#b` 里的 '#' 是普通字符（见 rcfile.cpp 顶部的说明）。 */
std::vector<std::string> LoadRcLines(const std::string& path);

/* 把 existing（旧文件全文，可为空）里的托管块换成 block，返回新全文。
 *   - 找到成对的定界行 → 连定界在内整段替换；
 *   - 只有其一 / 都没有 → 在文件末尾追加一整块（前面补一个空行分隔）；
 *   - 块外（用户自己写的那些行）原样保留，连空行都不动。
 * 幂等：ApplyManagedBlock(ApplyManagedBlock(x, b), b) == ApplyManagedBlock(x, b)。 */
std::string ApplyManagedBlock(const std::string& existing,
                              const std::vector<std::string>& block);

}  // namespace bsh
