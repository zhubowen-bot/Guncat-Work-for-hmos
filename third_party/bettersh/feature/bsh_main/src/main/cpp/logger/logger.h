// logger/logger.h — 一个很薄的日志门面（printf 风格 + 输出目标可运行期切换）
//
// 两条诉求：
//   1) 像 printf 一样调用：
//        Logger* L = Logger::GetInstance();
//        L->LogI("session %d ready, pid=%d", sid, getpid());
//        L->LogE("dlopen %s failed: %s", path, dlerror());
//      方法带 format(printf) 属性 —— 参数写错在**编译期**就报。
//   2) 输出到哪儿**随时可改**：hilog / 本进程 stdout / 当前会话终端(tty) / 文件，
//      各一个开关（Set* 都是线程安全的，可以边跑边改）。
//
// 默认：只开 hilog + 文件（与最初的草稿一致）。
//   hilog —— 按级别走 OH_LOG_INFO/WARN/ERROR；终端里 `hilog | grep` 就能看。
//   stdout—— printf 到本进程 stdout/stderr（注意：**不是**会话的终端 pty）。
//   tty   —— 往"当前会话终端"写，需要先 SetTtyWriter() 注册写法（见下）。
//   file  —— 每进程一个文件，默认 $HOME/logs/bsh-<启动秒>.log。
//
// tty 为什么是回调：会话 pty 的 fd 在 shell 那侧（本模块不方便直接持有），
// 所以留一个 std::function，谁方便谁注册，例如 shell 里注册成写当前会话的 SlaveWrite。
#pragma once

#include <cstdarg>
#include <functional>
#include <mutex>
#include <string>

class Logger {
public:
    static Logger* GetInstance();

    void LogI(const char* fmt, ...) __attribute__((format(printf, 2, 3)));
    void LogW(const char* fmt, ...) __attribute__((format(printf, 2, 3)));
    void LogE(const char* fmt, ...) __attribute__((format(printf, 2, 3)));

    // ── 输出目标（线程安全，随时可改）──
    void SetHilog(bool on);
    void SetStdout(bool on);
    void SetTty(bool on);
    void SetFile(bool on);

    bool HilogEnabled() const;
    bool StdoutEnabled() const;
    bool TtyEnabled() const;
    bool FileEnabled() const;

    // tty 目标：注册"怎么往当前会话终端写"。入参是**已格式化好、带 [I]/[W]/[E] 前缀**的一行。
    // 要求：回调要轻，且**不要在回调里再调 Logger**（此时持着锁）。
    using TtyWriter = std::function<void(const std::string&)>;
    void SetTtyWriter(TtyWriter writer);

    // 文件路径（默认 $HOME/logs/bsh-<启动秒>.log）。传空串 = 保持当前值不动。
    void SetLogFilePath(const std::string& path);
    std::string LogFilePath() const;

private:
    Logger();
    Logger(const Logger&) = delete;
    Logger& operator=(const Logger&) = delete;

    void LogV(int level, const char* fmt, va_list ap);

    mutable std::mutex mu_;
    // level: 0=Info 1=Warn 2=Error（见 LogI/W/E）
    bool log_hilog_  = true;
    bool log_stdout_ = false;
    bool log_tty_    = false;
    bool log_file_   = true;

    std::string file_path_;
    TtyWriter   tty_writer_;
    unsigned long inited_timestamp_ = 0;
};
