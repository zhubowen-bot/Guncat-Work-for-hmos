// shell/complete.h — TAB 补全（宿主可单测）
//
// 为什么独立成文件：补全的"取候选 / 求公共前缀 / 决定要不要列清单"是纯逻辑，
// 只有"列目录"需要碰文件系统。把列目录做成注入的 DirLister，宿主单测就能用假目录
// 断言补全结果（见 lineedit_selftest.cpp），不必真建一套文件。
#pragma once

#include <functional>
#include <string>
#include <vector>

namespace bsh {

// 列某个目录下的条目名。**目录条目带尾随 '/'**（调用方据此决定补完是否还要加空格）。
// 调用方给 "." 表示当前目录。实现方按需过滤/截断。
using DirLister = std::function<std::vector<std::string>(const std::string& dir)>;

struct CompletionResult {
    std::string replacement;              // 该词应被替换成什么（含目录前缀，可能是原样）
    std::vector<std::string> candidates;  // 多候选时按字母序排列，供展示
    bool show_list = false;               // true = 调用方应把 candidates 打出来
};

// 内建命令名表（与 shell.cpp 的 RunBuiltin 保持一致；命令位补全用）
const std::vector<std::string>& BuiltinNames();

// word      光标前那个词
// cmd_pos   true = 这个词是命令行的第一个词（命令位）
// bin_dir   命令启动器文件所在目录（$SYSROOT/bin，命令位把这里面的名字补进来）
// list_all  true = 这是第二次 TAB（多候选时列出清单）
CompletionResult CompleteWord(const std::string& word, bool cmd_pos,
                              const std::string& bin_dir,
                              const DirLister& list_dir, bool list_all);

}  // namespace bsh
