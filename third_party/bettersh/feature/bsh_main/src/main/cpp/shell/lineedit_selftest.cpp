// shell/lineedit_selftest.cpp — LineEditor 的宿主单测（不需要终端）
//
// 为什么能这么测：LineEditor 只做"字节进 → 动作/输出出"，不碰 pty、不碰 NDK。于是
// 喂 `"\x1b[A"` 这样的序列就能断言"行内容/光标/该写出的字节"，不必架真终端 ——
// 设备上只剩"手感"要人工看（见 README 的验收清单）。
//
// 跑（宿主 g++，不需要设备；命令里的续行反斜杠别写进注释，否则 -Wcomment 报警）：
//   g++ -std=c++17 -O1 -g -Wall -Wextra -fsanitize=address,undefined
//       -Ifeature/bsh_main/src/main/cpp/shell
//       feature/bsh_main/src/main/cpp/shell/{lineedit,lexer,complete,rcfile}.cpp
//       feature/bsh_main/src/main/cpp/shell/lineedit_selftest.cpp -o /tmp/bsh_shell_tests
//   && /tmp/bsh_shell_tests
#include "lineedit.h"

#include "complete.h"
#include "lexer.h"
#include "rcfile.h"

#include <cstdio>
#include <string>

static int g_pass = 0, g_fail = 0;

static void Check(bool ok, const std::string& what, const std::string& got = "") {
    if (ok) { g_pass++; printf("  [PASS] %s\n", what.c_str()); return; }
    g_fail++;
    printf("  [FAIL] %s%s%s\n", what.c_str(), got.empty() ? "" : "  ← ", got.c_str());
}

// 把一串字节喂进去，返回最后一次的非 None 动作。
//
// 关键：**每喂一个字节就立刻取走该次 Feed 的回显**，模拟真调用方（shell.cpp 的
// `read(fd,&ch,1)` → `Feed(ch)` → 写 TakeEcho()）。echo_ 是"本次 Feed 的输出"，
// 不累加；想断言一整段输入的回显就把它汇总到 echo_out。
static bsh::LineEditor::Action FeedStr(bsh::LineEditor* ed, const std::string& s,
                                       std::string* echo_out = nullptr) {
    bsh::LineEditor::Action a = bsh::LineEditor::Action::None;
    for (unsigned char c : s) {
        bsh::LineEditor::Action x = ed->Feed(c);
        std::string e = ed->TakeEcho();
        if (echo_out) *echo_out += e;
        if (x != bsh::LineEditor::Action::None) a = x;
    }
    return a;
}

static void t_typing_and_submit() {
    printf("\n— 打字 / 回车 / 退格\n");
    bsh::LineEditor ed;
    std::string echo;
    Check(FeedStr(&ed, "echo hi", &echo) == bsh::LineEditor::Action::Echo,
          "普通字符走 Echo（不整行重绘）");
    Check(ed.Line() == "echo hi", "行内容", ed.Line());
    Check(echo == "echo hi", "回显字节", echo);

    ed.Feed(0x7f);                        // 退格
    Check(ed.Line() == "echo h", "退格删一个字符", ed.Line());
    std::string bs = ed.TakeEcho();       // 先取走：TakeEcho 有副作用，不能在同一表达式里调两次
    Check(bs == "\b \b", "退格回显是 \\b \\b", "[" + bs + "]");

    Check(FeedStr(&ed, "\r") == bsh::LineEditor::Action::Submit, "回车返回 Submit");
}

static void t_utf8() {
    printf("\n— UTF-8（多字节字符与宽度）\n");
    bsh::LineEditor ed;
    const std::string cn = "中";          // E4 B8 AD
    FeedStr(&ed, cn);
    Check(ed.Line() == cn, "三字节字符整体入行", ed.Line());
    ed.Feed(0x7f);
    Check(ed.Line().empty(), "退格删掉整个汉字（不是半个）", ed.Line());
    FeedStr(&ed, cn);
    ed.Feed(0x7f);
    Check(ed.Line().empty(), "再删一次仍然干净", ed.Line());

    // 宽字符回退列数：行 = "a中"，光标左移到 'a' 之后 → 要往回 2 列
    ed.Clear();
    FeedStr(&ed, "a中");
    std::string echo;
    FeedStr(&ed, "\x1b[D", &echo);
    Check(ed.Cursor() == 1, "左键按字符移动（不是按字节）",
          std::to_string(ed.Cursor()));
    Check(echo == "\x1b[2D", "宽字符左移 = CUB 2（不是 1）", echo);
}

static void t_history() {
    printf("\n— 上下键翻历史\n");
    bsh::LineEditor ed;
    ed.PushHistory("ls");
    ed.PushHistory("pwd");
    ed.PushHistory("pwd");                 // 与上一条重复：不记
    Check(ed.History().size() == 2, "重复命令不入历史",
          std::to_string(ed.History().size()));

    FeedStr(&ed, "echo ");                 // 正在打的半截
    FeedStr(&ed, "\x1b[A");
    Check(ed.Line() == "pwd", "上键 → 最近一条", ed.Line());
    FeedStr(&ed, "\x1b[A");
    Check(ed.Line() == "ls", "再上键 → 更早一条", ed.Line());
    FeedStr(&ed, "\x1b[A");
    Check(ed.Line() == "ls", "到最老还按上：不动", ed.Line());
    FeedStr(&ed, "\x1b[B");
    Check(ed.Line() == "pwd", "下键回退", ed.Line());
    FeedStr(&ed, "\x1b[B");
    Check(ed.Line() == "echo ", "下到底 → 恢复原来那半截输入", ed.Line());
    FeedStr(&ed, "\x1b[B");
    Check(ed.Line() == "echo ", "已在草稿：再按下不动", ed.Line());

    // 空历史时按上键应无动作
    bsh::LineEditor ed2;
    Check(FeedStr(&ed2, "\x1b[A") == bsh::LineEditor::Action::None,
          "没有历史时上键 = None");
}

static void t_cursor_and_edit() {
    printf("\n— 光标移动 / 行内编辑\n");
    bsh::LineEditor ed;
    FeedStr(&ed, "abcdef");
    std::string mv;
    FeedStr(&ed, "\x1b[D\x1b[D", &mv);            // 光标到 d 前（pos=4）
    Check(ed.Cursor() == 4, "左移两次", std::to_string(ed.Cursor()));
    Check(mv == "\x1b[1D\x1b[1D", "左移用 CUB 而不是整行重绘", mv);

    FeedStr(&ed, "X");                            // 行中间插入
    Check(ed.Line() == "abcdXef", "行中间插入", ed.Line());

    std::string r = ed.Render("$ ");
    Check(r == "\r\x1b[K$ abcdXef\x1b[2D", "Render：整行重画 + 光标回退 2 列", r);

    FeedStr(&ed, "\x1b[H");
    Check(ed.Cursor() == 0, "Home", std::to_string(ed.Cursor()));
    FeedStr(&ed, "\x1b[F");
    Check(ed.Cursor() == ed.Line().size(), "End", std::to_string(ed.Cursor()));

    FeedStr(&ed, "\x01");
    Check(ed.Cursor() == 0, "Ctrl+A = 行首", std::to_string(ed.Cursor()));
    FeedStr(&ed, "\x05");
    Check(ed.Cursor() == ed.Line().size(), "Ctrl+E = 行尾", std::to_string(ed.Cursor()));

    ed.Clear();
    FeedStr(&ed, "one two three");
    FeedStr(&ed, "\x17");                          // Ctrl+W 删一个词
    Check(ed.Line() == "one two ", "Ctrl+W 删前一个词", "[" + ed.Line() + "]");

    ed.Clear();
    FeedStr(&ed, "keep this");
    FeedStr(&ed, "\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D");   // 光标移到 "this" 中间（pos=4）
    FeedStr(&ed, "\x0b");                              // Ctrl+K 删到行尾
    Check(ed.Line() == "keep", "Ctrl+K 删到行尾", "[" + ed.Line() + "]");

    ed.Clear();
    FeedStr(&ed, "drop all");
    FeedStr(&ed, "\x15");                              // Ctrl+U 删到行首
    Check(ed.Line().empty(), "Ctrl+U 删到行首", "[" + ed.Line() + "]");
}

static void t_esc_robustness() {
    printf("\n— 异常序列 / 其它按键\n");
    bsh::LineEditor ed;
    FeedStr(&ed, "ab");
    FeedStr(&ed, "\x1b[Z");                 // 未知 CSI：忽略
    Check(ed.Line() == "ab", "未知 ESC 序列被忽略", ed.Line());
    FeedStr(&ed, "\x1b");                   // 孤立的 ESC（后面没字节）
    Check(ed.Line() == "ab", "孤立 ESC 不会污染行", ed.Line());
    ed.Feed('x');                            // ESC 后跟普通字符：整体忽略
    Check(ed.Line() == "ab", "ESC + 普通字符 = 忽略两个", ed.Line());
    FeedStr(&ed, "\x1b[3~");                // Delete
    Check(ed.Line() == "ab", "行尾按 Delete 无变化", ed.Line());
    FeedStr(&ed, "\x1b[H");
    FeedStr(&ed, "\x1b[3~");
    Check(ed.Line() == "b", "行首按 Delete 删一个字符", ed.Line());

    Check(FeedStr(&ed, "\t") == bsh::LineEditor::Action::Complete, "TAB → Complete");
    Check(!ed.RepeatTab(), "第一个 TAB：不列候选");
    FeedStr(&ed, "\t");
    Check(ed.RepeatTab(), "连按第二个 TAB：RepeatTab 为真（列候选用）");
    FeedStr(&ed, "x");
    Check(!ed.RepeatTab(), "打过别的键后不再是连按");
    bsh::LineEditor ed2;
    Check(FeedStr(&ed2, "\x03") == bsh::LineEditor::Action::Interrupt, "Ctrl+C → Interrupt");
    Check(ed2.Line().empty(), "Ctrl+C 清行");
}

static void t_completion_word() {
    printf("\n— 补全取词（第 3 步用）\n");
    bsh::LineEditor ed;
    FeedStr(&ed, "cd vim-run");
    Check(ed.WordForCompletion() == "vim-run", "取光标前那个词",
          ed.WordForCompletion());
    FeedStr(&ed, "x");
    Check(ed.WordForCompletion() == "vim-runx", "再打字词跟着变",
          ed.WordForCompletion());
    std::string echo;
    ed.ReplaceWord("vim-runtime/", &echo);
    Check(ed.Line() == "cd vim-runtime/", "替换词", ed.Line());
    Check(ed.Cursor() == ed.Line().size(), "光标在替换后末尾",
          std::to_string(ed.Cursor()));
    ed.Clear();
    FeedStr(&ed, "echo  ");
    FeedStr(&ed, "\x1b[D");                 // 光标退回空格前
    Check(ed.WordForCompletion() == "", "空词（光标前是空格）",
          "[" + ed.WordForCompletion() + "]");
}

// ---- 分词 / 变量展开（shell/lexer.cpp）----
static bsh::VarLookup FakeEnv() {
    return [](const std::string& n) -> std::string {
        if (n == "HOME") return "/home/u";
        if (n == "P") return "/data/x";
        return "";                       // 未定义 → 空串（与 shell 语义一致）
    };
}

static std::string Join(const std::vector<std::string>& v) {
    std::string s;
    for (size_t i = 0; i < v.size(); i++) { if (i) s += '|'; s += v[i]; }
    return s;
}

static void t_expand() {
    printf("\n— 分词 / 变量展开（lexer）\n");
    auto L = [](const std::string& s, int rc = 0) {
        return Join(bsh::SplitLine(s, rc, FakeEnv()));
    };

    Check(L("echo $HOME") == "echo|/home/u", "$NAME 展开", L("echo $HOME"));
    Check(L("echo ${HOME}/x") == "echo|/home/u/x", "${NAME} 展开", L("echo ${HOME}/x"));
    Check(L("echo $NOPE.") == "echo|.", "未定义变量 → 空串", L("echo $NOPE."));
    Check(L("echo $?", 7) == "echo|7", "$? = 上一条退出码", L("echo $?", 7));
    Check(L("echo 'a $HOME b'") == "echo|a $HOME b", "单引号内不展开", L("echo 'a $HOME b'"));
    Check(L("echo \"$HOME\"") == "echo|/home/u", "双引号内展开、引号不进结果",
          L("echo \"$HOME\""));
    Check(L("echo \\$HOME") == "echo|$HOME", "\\$ 是字面 $", L("echo \\$HOME"));
    Check(L("echo a$") == "echo|a$", "孤立 $ 保持字面", L("echo a$"));
    Check(L("echo $HOME/x") == "echo|/home/u/x", "展开结果与后续字符合成一个词",
          L("echo $HOME/x"));
    Check(L("  echo   hi ") == "echo|hi", "多余空白折叠", L("  echo   hi "));
    Check(L("").empty(), "空行 → 无词");
    Check(L("echo '未闭合") == "echo|'未闭合", "未闭合引号容错保留（原行为）",
          L("echo '未闭合"));
}

// ---- TAB 补全（shell/complete.cpp）----
static std::vector<std::string> FakeDir(const std::string& dir) {
    if (dir == "/bin") return {"vim", "vip", "weston-terminal", "wldemo"};
    return {"docs/", "hello.txt", "hi.c", "hush", ".hidden"};
}

static void t_completion() {
    printf("\n— TAB 补全（complete）\n");

    {   // 命令位：唯一命中内建 → 补完加空格
        auto r = bsh::CompleteWord("ec", true, "/bin", FakeDir, false);
        Check(r.replacement == "echo ", "命令位唯一命中补空格", "[" + r.replacement + "]");
    }
    {   // 命令位：/bin 多命中 → 补公共前缀；第二次 TAB 列清单
        auto r = bsh::CompleteWord("v", true, "/bin", FakeDir, false);
        Check(r.replacement == "vi", "多候选补公共前缀", "[" + r.replacement + "]");
        Check(!r.show_list, "第一次 TAB 不列清单");
        auto r2 = bsh::CompleteWord("v", true, "/bin", FakeDir, true);
        Check(r2.show_list && r2.candidates.size() == 2, "第二次 TAB 列清单",
              std::to_string(r2.candidates.size()));
        if (r2.candidates.size() == 2)
            Check(r2.candidates[0] == "vim" && r2.candidates[1] == "vip", "候选按字母序",
                  Join(r2.candidates));
    }
    {   // 路径：唯一命中文件 → 加空格
        auto r = bsh::CompleteWord("hel", false, "/bin", FakeDir, false);
        Check(r.replacement == "hello.txt ", "唯一文件补空格", "[" + r.replacement + "]");
    }
    {   // 路径：唯一命中目录 → 补 '/'，不加空格
        auto r = bsh::CompleteWord("doc", false, "/bin", FakeDir, false);
        Check(r.replacement == "docs/", "唯一目录补 '/'", "[" + r.replacement + "]");
    }
    {   // 路径：带目录前缀
        auto r = bsh::CompleteWord("docs/h", false, "/bin", FakeDir, true);
        Check(r.replacement == "docs/h", "目录前缀保留", "[" + r.replacement + "]");
        Check(r.show_list && r.candidates.size() == 3, "目录内多候选列清单",
              std::to_string(r.candidates.size()));
    }
    {   // 隐藏文件：不主动补，用户自己打了 '.' 才给
        auto r = bsh::CompleteWord("", false, "/bin", FakeDir, true);
        Check(r.candidates.size() == 4, "空词不列隐藏文件（4 个可见项）",
              std::to_string(r.candidates.size()));
        auto r2 = bsh::CompleteWord(".", false, "/bin", FakeDir, false);
        Check(r2.replacement == ".hidden ", "打了 '.' 才补隐藏文件",
              "[" + r2.replacement + "]");
    }
    {   // 没得补：原样返回
        auto r = bsh::CompleteWord("zzz", false, "/bin", FakeDir, true);
        Check(r.replacement == "zzz" && !r.show_list, "无命中则原样",
              "[" + r.replacement + "]");
    }
}

// ── .bshrc：注释/空行/CRLF 的读取，以及托管块替换 ──────────────────────────
static void t_rcfile() {
    const std::string p = "/tmp/bsh_rcfile_selftest.rc";
    auto write = [&](const std::string& s) {
        FILE* f = fopen(p.c_str(), "wb");
        if (f) { fwrite(s.data(), 1, s.size(), f); fclose(f); }
    };

    {   // 读：空行、整行注释（含前导空白）、CRLF
        write("# 整行注释\r\n"
              "   # 前面有空白也算注释\r\n"
              "\r\n"
              "export A=1\r\n"
              "export B=2\n"
              "   \t \n");
        auto v = bsh::LoadRcLines(p);
        Check(v.size() == 2, "注释/空行被跳过，只剩 2 行",
              "size=" + std::to_string(v.size()));
        Check(v.size() == 2 && v[0] == "export A=1" && v[1] == "export B=2",
              "CRLF 的 \\r 被去掉",
              v.empty() ? "" : "[" + v[0] + "]");
    }
    {   // 行尾注释**不**处理：'#' 是普通字符
        write("echo a#b\n");
        auto v = bsh::LoadRcLines(p);
        Check(v.size() == 1 && v[0] == "echo a#b", "行尾 # 不当注释",
              v.empty() ? "" : "[" + v[0] + "]");
    }
    {   // 文件不存在 = 空，不是错误
        auto v = bsh::LoadRcLines("/tmp/bsh_rcfile_selftest_missing.rc");
        Check(v.empty(), "文件不存在返回空", "size=" + std::to_string(v.size()));
    }

    const std::vector<std::string> blk = {"export A=1", "", "export B=2"};
    {   // 没有块 → 追加；用户自己的行保留
        std::string out = bsh::ApplyManagedBlock("export MINE=9\n", blk);
        Check(out.find("export MINE=9") != std::string::npos, "追加时保留用户的行");
        Check(out.find("export B=2") != std::string::npos, "追加时写入托管块");
        Check(out.find(bsh::kManagedBeginMark) != std::string::npos &&
              out.find(bsh::kManagedEndMark) != std::string::npos, "两个定界都在");
    }
    {
        std::string once  = bsh::ApplyManagedBlock("export MINE=9\n", blk);
        std::string twice = bsh::ApplyManagedBlock(once, blk);
        Check(once == twice, "反复 Apply 结果不变（幂等）");
    }
    {   // 换了默认值 → 只换块内，用户行不动
        std::string a = bsh::ApplyManagedBlock("export MINE=9\n", blk);
        std::string b = bsh::ApplyManagedBlock(a, {"export A=1", "export C=3"});
        Check(b.find("export MINE=9") != std::string::npos, "换块时用户的行还在");
        Check(b.find("export C=3") != std::string::npos &&
              b.find("export B=2") == std::string::npos, "旧块内容被换掉");
    }
    {   // 用户手改了块内的行 → 会被刷回（预期行为，文件里写了"改这里会被覆盖"）
        std::string a = bsh::ApplyManagedBlock("", blk);
        size_t pos = a.find("export A=1");
        if (pos != std::string::npos) a.replace(pos, 10, "export A=999");
        std::string b = bsh::ApplyManagedBlock(a, blk);
        Check(b.find("export A=1") != std::string::npos &&
              b.find("999") == std::string::npos, "块内被手改的内容会被刷回");
    }
    remove(p.c_str());
}

int main() {
    printf("=== bsh 宿主单测（行编辑器 / 分词展开 / 补全 / .bshrc）===\n");
    t_typing_and_submit();
    t_utf8();
    t_history();
    t_cursor_and_edit();
    t_esc_robustness();
    t_completion_word();
    t_expand();
    t_completion();
    t_rcfile();
    printf("\n=== 合计 PASS=%d FAIL=%d ===\n", g_pass, g_fail);
    return g_fail > 0 ? 1 : 0;
}
