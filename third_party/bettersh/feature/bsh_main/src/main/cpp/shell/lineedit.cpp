// shell/lineedit.cpp — 见 lineedit.h 的说明
#include "lineedit.h"

#include <cstdio>
#include <cstdlib>

namespace bsh {

namespace {

// 一个 UTF-8 码元的字节数（看首字节）。非法首字节当 1 字节处理，别把行搞死。
int Utf8Len(unsigned char c) {
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) return 2;
    if ((c & 0xF0) == 0xE0) return 3;
    if (c & 0xF8) return 4;
    return 1;
}

// 往左找到第 n 个字符的起始字节（n=1 就是"上一个字符的起点"）。
// 返回 0 表示已经到行首。UTF-8 的续字节形如 10xxxxxx。
size_t PrevChar(const std::string& s, size_t from) {
    size_t i = from;
    if (i == 0) return 0;
    i--;
    while (i > 0 && ((unsigned char)s[i] & 0xC0) == 0x80) i--;
    return i;
}

// 往后找到下一个字符的起点（到末尾返回 size()）。
size_t NextChar(const std::string& s, size_t from) {
    if (from >= s.size()) return s.size();
    size_t n = (size_t)Utf8Len((unsigned char)s[from]);
    size_t i = from + n;
    return i > s.size() ? s.size() : i;
}

// 终端显示宽度：中日韩等全角算 2，其余算 1。
// 为什么需要：光标回退（Render/左右移动）要说"退几列"，宽字符按 1 算会错位。
// 只覆盖最常见的区间，够用即可 —— 行编辑不需要完整的 wcwidth 表。
int CharWidth(unsigned char c) {
    if (c < 0x80) return (c < 0x20) ? 0 : 1;      // 控制字符不占位
    // 这里只需要判"是不是宽字符"，不解析完整码点：抓首字节的高位特征即可。
    // 宽字符（U+1100 起、U+2E80–U+A4CF、U+AC00–U+D7A3、U+F900–U+FAFF、U+FF00–U+FF60、
    // U+FFE0–U+FFE6、U+1F300 起）在这些 UTF-8 前缀里：
    //   U+1100–U+2FFF   → E1 84..E2 BF
    //   U+3000–U+9FFF   → E3 80..E9 BF
    //   U+A000–U+D7FF   → EA 80..ED 9F
    //   U+F900–U+FAFF   → EF A4..EF AB
    //   U+FF00–U+FF60   → EF BC..EF BD, EF BE 80..81
    //   U+1F300 起       → F0 9F 8C..
    // 简化：首字节 >= 0xE3 当宽（覆盖中日韩主体），< 0xE3 的按 1。
    // 例外：U+2018/U+2019 这类标点在 E2 段（窄），正好落在 <0xE3 一侧，对得上。
    return (c >= 0xE3) ? 2 : 1;
}

}  // namespace

void LineEditor::Clear() {
    line_.clear();
    pos_ = 0;
    pending_.clear();
    esc_ = 0;
    esc_buf_.clear();
    last_tab_ = false;
    repeat_tab_ = false;
    hist_idx_ = -1;
    draft_.clear();
}

void LineEditor::SetCursor(size_t p) { pos_ = p > line_.size() ? line_.size() : p; }

void LineEditor::PushHistory(const std::string& cmd) {
    if (cmd.empty()) return;
    if (!hist_.empty() && hist_.back() == cmd) return;   // 与上一条重复不记
    hist_.push_back(cmd);
}

void LineEditor::ClearHistory() {
    hist_.clear();
    hist_idx_ = -1;
    draft_.clear();
}

void LineEditor::InsertBytes(const std::string& s) {
    line_.insert(pos_, s);
    pos_ += s.size();
    if (pos_ == line_.size()) {
        echo_ += s;                 // 在行尾追加：直接回显这几个字节就够了
    } else {
        echo_.clear();              // 行中间插入：让调用方整行重绘
    }
}

void LineEditor::EraseBeforeCursor(size_t nbytes) {
    if (pos_ == 0) return;
    size_t from = pos_ >= nbytes ? pos_ - nbytes : 0;
    bool at_end = (pos_ == line_.size());
    line_.erase(from, pos_ - from);
    pos_ = from;
    if (at_end) echo_ += "\b \b";   // 行尾退格：把那一格擦掉
    else        echo_.clear();      // 行中间删：整行重绘
}

void LineEditor::EraseAfterCursor(size_t nbytes) {
    if (pos_ >= line_.size()) return;
    size_t to = pos_ + nbytes;
    if (to > line_.size()) to = line_.size();
    line_.erase(pos_, to - pos_);
    echo_.clear();                  // 尾部变短 → 整行重绘
}

bool LineEditor::MoveCursorChars(int delta) {
    size_t old = pos_;
    if (delta < 0) {
        for (int i = 0; i < -delta && pos_ > 0; i++) pos_ = PrevChar(line_, pos_);
    } else {
        for (int i = 0; i < delta && pos_ < line_.size(); i++) pos_ = NextChar(line_, pos_);
    }
    if (pos_ == old) return false;
    if (echo_.empty()) {
        // 只是光标移动：算一下要退/进几列，直接发 CUB/CUF，省一次整行重绘
        int cols = 0;
        if (delta < 0)
            for (size_t i = pos_; i < old; i = NextChar(line_, i))
                cols += CharWidth((unsigned char)line_[i]);
        else
            for (size_t i = old; i < pos_; i = NextChar(line_, i))
                cols += CharWidth((unsigned char)line_[i]);
        if (cols > 0) {
            char buf[16];
            snprintf(buf, sizeof buf, "\x1b[%d%c", cols, delta < 0 ? 'D' : 'C');
            echo_ = buf;
        }
    }
    return true;
}

std::string LineEditor::TakeEcho() {
    std::string s;
    s.swap(echo_);
    return s;
}

std::string LineEditor::Render(const std::string& prompt) const {
    std::string out = "\r\x1b[K";     // 回车 + 清到行尾（整行重画，不算提示符宽度）
    out += prompt;
    out += line_;
    int back = 0;
    for (size_t i = pos_; i < line_.size(); i = NextChar(line_, i))
        back += CharWidth((unsigned char)line_[i]);
    if (back > 0) {
        char buf[16];
        snprintf(buf, sizeof buf, "\x1b[%dD", back);
        out += buf;
    }
    return out;
}

std::string LineEditor::WordForCompletion() const {
    size_t start = pos_;
    while (start > 0 && line_[start - 1] != ' ') start--;
    return line_.substr(start, pos_ - start);
}

void LineEditor::ReplaceWord(const std::string& replacement, std::string* echo) {
    size_t start = pos_;
    while (start > 0 && line_[start - 1] != ' ') start--;
    line_.replace(start, pos_ - start, replacement);
    pos_ = start + replacement.size();
    echo_.clear();
    if (echo) {
        // 调用方要完整重绘（补全可能改动了光标位置），这里把重绘序列给它
        echo->clear();
    }
}

LineEditor::Action LineEditor::Feed(unsigned char c) {
    echo_.clear();                  // echo_ 只表示"本次 Feed 该写出的字节"
    bool was_tab = last_tab_;
    last_tab_ = false;
    repeat_tab_ = false;

    // ── UTF-8 续字节：等齐了再整体入行（否则退格会拆散一个汉字） ──
    if (!pending_.empty()) {
        pending_ += (char)c;
        if (pending_.size() >= (size_t)Utf8Len((unsigned char)pending_[0])) {
            std::string seq;
            seq.swap(pending_);
            InsertBytes(seq);
            return echo_.empty() ? Action::Redraw : Action::Echo;
        }
        return Action::None;
    }

    // ── ESC 序列：CSI 是 ESC [ <参数> <终止字母> ──
    if (esc_ == 2) {
        if (c >= '0' && c <= '9') { esc_buf_ += (char)c; return Action::None; }
        esc_ = 0;
        // 参数按数值解析（ESC[3~ 的 "3" 是字符，直接和整数比会永远不成立）
        int param = esc_buf_.empty() ? 0 : atoi(esc_buf_.c_str());
        esc_buf_.clear();
        switch (c) {
        case 'A': {                    // 上：历史往前
            if (hist_.empty()) return Action::None;
            if (hist_idx_ == -1) { draft_ = line_; hist_idx_ = (int)hist_.size() - 1; }
            else if (hist_idx_ > 0) hist_idx_--;
            line_ = hist_[hist_idx_];
            pos_ = line_.size();
            return Action::Redraw;
        }
        case 'B': {                    // 下：历史往后，到底回到草稿
            if (hist_idx_ == -1) return Action::None;
            if (hist_idx_ + 1 < (int)hist_.size()) { hist_idx_++; line_ = hist_[hist_idx_]; }
            else { hist_idx_ = -1; line_ = draft_; }
            pos_ = line_.size();
            return Action::Redraw;
        }
        case 'C': return MoveCursorChars(1) ? (echo_.empty() ? Action::Redraw : Action::Echo)
                                            : Action::None;
        case 'D': return MoveCursorChars(-1) ? (echo_.empty() ? Action::Redraw : Action::Echo)
                                             : Action::None;
        case 'H': pos_ = 0; return Action::Redraw;                    // Home
        case 'F': pos_ = line_.size(); return Action::Redraw;         // End
        case '~':                                                     // ESC[3~ = Delete
            if (param == 3) { EraseAfterCursor(NextChar(line_, pos_) - pos_);
                              return Action::Redraw; }
            return Action::None;
        default: return Action::None;                                 // 别的键忽略
        }
    }
    if (esc_ == 1) {
        if (c == '[') { esc_ = 2; esc_buf_.clear(); return Action::None; }
        if (c == 'O') { esc_ = 2; esc_buf_.clear(); return Action::None; }   // SS3（部分终端的 H/F）
        esc_ = 0;
        return Action::None;                                              // ESC 后跟别的：整体忽略
    }

    switch (c) {
    case 0x1b: esc_ = 1; return Action::None;                 // ESC
    case '\r': case '\n': return Action::Submit;
    case 0x09: last_tab_ = true; repeat_tab_ = was_tab;
               return Action::Complete;                       // TAB
    case 0x03: Clear(); return Action::Interrupt;             // Ctrl+C
    case 0x7f: case 0x08:                                     // 退格
        EraseBeforeCursor(NextChar(line_, PrevChar(line_, pos_)) - PrevChar(line_, pos_));
        return echo_.empty() ? Action::Redraw : Action::Echo;
    case 0x01: pos_ = 0; return Action::Redraw;               // Ctrl+A 行首
    case 0x05: pos_ = line_.size(); return Action::Redraw;    // Ctrl+E 行尾
    case 0x0b: EraseAfterCursor(line_.size() - pos_); return Action::Redraw;  // Ctrl+K
    case 0x15: {                                              // Ctrl+U 删到行首
        size_t n = pos_;
        line_.erase(0, n);
        pos_ = 0;
        echo_ = "\r\x1b[K";                                   // 从光标处往回清
        return Action::Redraw;                                // 提示符要重画，交给调用方
    }
    case 0x17: {                                              // Ctrl+W 删前一个词
        size_t end = pos_;
        size_t i = pos_;
        while (i > 0 && line_[i - 1] == ' ') i--;
        while (i > 0 && line_[i - 1] != ' ') i--;
        line_.erase(i, end - i);
        pos_ = i;
        return Action::Redraw;
    }
    default: break;
    }

    if (c < 0x20) return Action::None;            // 其余控制字符忽略
    if ((c & 0xC0) == 0x80) return Action::None;  // 孤立续字节（不该出现）
    if (c < 0x80) {                               // ASCII 单字节
        InsertBytes(std::string(1, (char)c));
        last_tab_ = false;
        return echo_.empty() ? Action::Redraw : Action::Echo;
    }
    // 多字节字符的首字节：先攒着，等续字节到齐（见上面 pending_ 分支）
    pending_ = std::string(1, (char)c);
    return Action::None;
}

}  // namespace bsh
