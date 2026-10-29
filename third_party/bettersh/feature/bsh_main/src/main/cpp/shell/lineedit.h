// shell/lineedit.h — bsh 的行编辑器（历史 / 光标移动 / TAB 补全的落点）
//
// 为什么要单独一个类：bsh 的行编辑是**自己写的**（`BasicShell::Run()` 逐字节读 pty
// slave、自己回显），但之前只支持"在行尾打字 + 退格"—— 方向键被当控制字符丢掉（连
// "收到过 ESC" 都看不出来），TAB 被当成普通字符塞进行里。
//
// 拆出来的另一个理由：**它能在宿主上单测**。这个类不碰终端、不碰 NDK，只做
// "字节进 → 动作/输出出"，所以 lineedit_selftest.cpp 可以直接喂 `"\x1b[A"`、`"ec\t"`
// 这类序列断言行为（编译命令见那个文件的开头），不必架真终端。
//
// 与真 shell 的边界（刻意不做，写在这里免得后来人误会）：
//   - 历史不做 `!!` / `!n` / `^old^new` 展开；
//   - 不做 vi/emacs 模式的完整键位表，只做最常用的那几个（见 Feed 里的注释）；
//   - 宽字符按终端宽度 1 计（中日韩算作 2，见 CharWidth）—— 光标回退用得上；
//   - 行内不解析语法：引号/转义/变量展开都在分词器（shell.cpp 的 SplitLine）里做。
#pragma once

#include <string>
#include <vector>

namespace bsh {

class LineEditor {
public:
    // Feed 之后调用方该做的事；分成这几种是为了**少重绘**（每次按键整行重绘会闪）
    enum class Action {
        None,       // 什么都不用做（比如 ESC 序列才收了一半）
        Echo,       // 取 TakeEcho() 写出去即可（行尾追加、退格、左右移动）
        Redraw,     // 行或光标动得比较多 → 用 Render(prompt) 整行重画
        Submit,     // 回车：取 Line()，调用方执行完后 Clear()
        Complete,   // TAB：调用方做补全（WordForCompletion + ReplaceWord）
        Interrupt,  // Ctrl+C：调用方打印 ^C 并 Clear()
    };

    Action Feed(unsigned char c);

    // Action::Echo 时取出要写出的字节（一次 Feed 一次取，取完清空）
    std::string TakeEcho();

    const std::string& Line() const { return line_; }
    size_t Cursor() const { return pos_; }
    void SetCursor(size_t p);      // 由补全逻辑用（越界会被夹到合法位置）
    void Clear();                  // 清行与光标（不动历史）

    // 历史：提交时压栈（空行与"与上一条相同"都不记）
    void PushHistory(const std::string& cmd);
    const std::vector<std::string>& History() const { return hist_; }
    void ClearHistory();

    // 整行重绘：回车归零 + 清到行尾 + 提示符 + 行内容 + 光标回退
    // （不去算提示符宽度：提示符里可能有 ANSI 颜色，且我们只从行尾往回退）
    std::string Render(const std::string& prompt) const;

    // ---- TAB 补全用（第 3 步接入）----
    // 光标前那个"词"：以空格为界；命令位（行首词）与路径补全都用它
    std::string WordForCompletion() const;
    // 用补全结果替换那个词；同时把光标移到替换后的末尾。echo 追加要写出的字节
    void ReplaceWord(const std::string& replacement, std::string* echo);
    // 刚处理的这个 TAB 是不是**紧跟在另一个 TAB 后面**（决定要不要列候选清单）
    bool RepeatTab() const { return repeat_tab_; }

private:
    void InsertBytes(const std::string& s);    // 在光标处插入（自动处理 echo_）
    void EraseBeforeCursor(size_t nbytes);     // 删光标前 n 字节（退格/删词）
    void EraseAfterCursor(size_t nbytes);      // 删光标后 n 字节
    bool MoveCursorChars(int delta);           // 按**字符**左右移（UTF-8 感知）

    std::string line_;
    size_t pos_ = 0;                  // 字节位置
    std::string echo_;                // 本次 Feed 需要写出的字节
    std::string pending_;             // 半个 UTF-8 序列（等续字节到齐）
    int esc_ = 0;                     // 0=普通；1=刚见 ESC；2=见到 ESC [
    std::string esc_buf_;             // ESC 序列参数（如 "3" 之于 ESC[3~）
    bool last_tab_ = false;           // 上一次 Feed 是 TAB
    bool repeat_tab_ = false;         // 本次 Feed 是"连按的第二个 TAB"

    std::vector<std::string> hist_;
    int hist_idx_ = -1;               // -1 = 正编辑"草稿"；否则是 hist_ 的下标
    std::string draft_;               // 按 UP 之前手上那半截输入
};

}  // namespace bsh
