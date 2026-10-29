// shell/lexer.h — 命令行分词 + 变量展开（宿主可单测的纯函数）
//
// 为什么要独立成文件：分词与 $VAR 展开必须**融在同一个循环里**（引号、转义、变量
// 三者的优先级互相影响：单引号内的 `$` 不展开、`\$` 是字面 `$`），所以不能做成
// "先扫一遍字符串再分词"。但这段逻辑又不能碰 NDK/pty —— 否则没法在宿主上断言。
// 于是把变量查表做成注入的 `lookup`，宿主单测给个假表即可（见 lineedit_selftest.cpp）。
#pragma once

#include <functional>
#include <string>
#include <vector>

namespace bsh {

// 变量查表：返回空串表示"未定义"（与 shell 语义一致：未定义 = 空）。
using VarLookup = std::function<std::string(const std::string& name)>;

// 按空白分词，遵守单/双引号与反斜杠转义，并做变量展开：
//   - `$NAME` / `${NAME}`：查表，未定义展开成空串；
//   - `$?`：上一条命令的退出码（由 last_rc 传入）；
//   - 单引号内一切原样（含 `$`）；双引号内照常展开，引号本身不进结果；
//   - `\$` 是字面 `$`；孤立的 `$`（后面不是名字也不是 `?`）保持字面。
std::vector<std::string> SplitLine(const std::string& line, int last_rc,
                                   const VarLookup& lookup);

}  // namespace bsh
