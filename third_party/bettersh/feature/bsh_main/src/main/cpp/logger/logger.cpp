// logger/logger.cpp — 见 logger.h
#include "logger/logger.h"

#include <cstdio>
#include <ctime>
#include <sys/stat.h>

#include <hilog/log.h>

#include "common/bsh_paths.h"

namespace {

char LevelTag(int level) {
    if (level >= 2) return 'E';
    if (level == 1) return 'W';
    return 'I';
}

// 默认每进程一个日志文件：$HOME/logs/bsh-<启动秒>.log。
std::string DefaultLogPath(unsigned long ts) {
    const char* home = bsh_home_dir();
    if (!home || !home[0]) return std::string();
    return std::string(home) + "/logs/bsh-" + std::to_string(ts) + ".log";
}

}  // namespace

Logger::Logger() {
    inited_timestamp_ = (unsigned long)time(nullptr);
    file_path_ = DefaultLogPath(inited_timestamp_);
}

Logger* Logger::GetInstance() {
    static Logger s;   // 函数内静态：首次调用时构造，线程安全（C++11 起）
    return &s;
}

void Logger::LogI(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    LogV(0, fmt, ap);
    va_end(ap);
}

void Logger::LogW(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    LogV(1, fmt, ap);
    va_end(ap);
}

void Logger::LogE(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    LogV(2, fmt, ap);
    va_end(ap);
}

void Logger::LogV(int level, const char* fmt, va_list ap) {
    if (!fmt) return;

    char buf[2048];
    vsnprintf(buf, sizeof buf, fmt, ap);   // 超长会截断（够用即可）
    const std::string line(buf);

    std::lock_guard<std::mutex> lk(mu_);

    if (log_hilog_) {
        if (level >= 2)       OH_LOG_ERROR(LOG_APP, "%{public}s", line.c_str());
        else if (level == 1)  OH_LOG_WARN (LOG_APP, "%{public}s", line.c_str());
        else                  OH_LOG_INFO (LOG_APP, "%{public}s", line.c_str());
    }

    // stdout / tty / 文件额外加一个 [I]/[W]/[E] 前缀（hilog 自己带级别了）
    const std::string tagged = std::string("[") + LevelTag(level) + "] " + line;

    if (log_stdout_) {
        fputs(tagged.c_str(), stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }

    if (log_tty_ && tty_writer_) {
        tty_writer_(tagged);
    }

    if (log_file_ && !file_path_.empty()) {
        size_t slash = file_path_.find_last_of('/');
        if (slash != std::string::npos) {
            mkdir(file_path_.substr(0, slash).c_str(), 0755);   // 已存在时 EEXIST，忽略
        }
        if (FILE* f = fopen(file_path_.c_str(), "a")) {
            fputs(tagged.c_str(), f);
            fputc('\n', f);
            fclose(f);
        }
    }
}

void Logger::SetHilog(bool on)  { std::lock_guard<std::mutex> lk(mu_); log_hilog_  = on; }
void Logger::SetStdout(bool on) { std::lock_guard<std::mutex> lk(mu_); log_stdout_ = on; }
void Logger::SetTty(bool on)    { std::lock_guard<std::mutex> lk(mu_); log_tty_    = on; }
void Logger::SetFile(bool on)   { std::lock_guard<std::mutex> lk(mu_); log_file_   = on; }

bool Logger::HilogEnabled() const  { std::lock_guard<std::mutex> lk(mu_); return log_hilog_; }
bool Logger::StdoutEnabled() const { std::lock_guard<std::mutex> lk(mu_); return log_stdout_; }
bool Logger::TtyEnabled() const    { std::lock_guard<std::mutex> lk(mu_); return log_tty_; }
bool Logger::FileEnabled() const   { std::lock_guard<std::mutex> lk(mu_); return log_file_; }

void Logger::SetTtyWriter(TtyWriter writer) {
    std::lock_guard<std::mutex> lk(mu_);
    tty_writer_ = std::move(writer);
}

void Logger::SetLogFilePath(const std::string& path) {
    std::lock_guard<std::mutex> lk(mu_);
    if (!path.empty()) file_path_ = path;
}

std::string Logger::LogFilePath() const {
    std::lock_guard<std::mutex> lk(mu_);
    return file_path_;
}
