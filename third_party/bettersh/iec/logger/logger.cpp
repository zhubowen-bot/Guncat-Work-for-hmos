// logger/logger.cpp — see logger/logger.h.
#include "logger/logger.h"

#include "common/constant.h"

#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <utility>
#include <sys/stat.h>
#include <unistd.h>

namespace {

char LevelTag(int level) {
    if (level >= 2) return 'E';
    if (level == 1) return 'W';
    return 'I';
}

// The directory comes from the compile-time IEC_LOG_DIR when the platform
// defines it, otherwise from $IEC_LOG_DIR or $HOME/logs. The file name is
// assembled at runtime from the pid and a timestamp.
std::string LogDirectory() {
#ifdef IEC_LOG_DIR
    return IEC_LOG_DIR;
#else
    const char* dir = getenv("IEC_LOG_DIR");
    if (dir && *dir) return dir;
    const char* home = getenv("HOME");
    if (home && *home) return std::string(home) + "/logs";
    return std::string();
#endif
}

std::string DefaultLogPath() {
    std::string base = LogDirectory();
    if (base.empty()) return std::string();
    while (base.size() > 1 && base.back() == '/') base.pop_back();

    char stamp[32];
    const time_t now = time(nullptr);
    struct tm tmv;
    localtime_r(&now, &tmv);
    if (strftime(stamp, sizeof stamp, "%Y%m%d-%H%M%S", &tmv) == 0) {
        std::snprintf(stamp, sizeof stamp, "%lu", (unsigned long)now);
    }

    return base + "/iec-" + std::to_string((long)getpid()) + "-" + stamp + ".log";
}

}  // namespace

Logger::Logger() : file_path_(DefaultLogPath()) {}

Logger* Logger::GetInstance() {
    static Logger instance;
    return &instance;
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
    vsnprintf(buf, sizeof buf, fmt, ap);
    const std::string tagged = std::string("[") + LevelTag(level) + "] " + buf;

    std::lock_guard<std::mutex> lk(mu_);

    if (log_stderr_) {
        fprintf(stderr, "%s\n", tagged.c_str());
        fflush(stderr);
    }

    if (custom_writer_) {
        try {
            custom_writer_(level, tagged);
        } catch (...) {
            // A sink must not take the process down.
        }
    }

    if (log_file_ && !file_path_.empty()) {
        const size_t slash = file_path_.find_last_of('/');
        if (slash != std::string::npos) {
            mkdir(file_path_.substr(0, slash).c_str(), 0755);  // EEXIST is fine
        }
        if (FILE* f = fopen(file_path_.c_str(), "a")) {
            fprintf(f, "%s\n", tagged.c_str());
            fclose(f);
        }
    }
}

void Logger::SetStderr(bool on) { std::lock_guard<std::mutex> lk(mu_); log_stderr_ = on; }
void Logger::SetFile(bool on)   { std::lock_guard<std::mutex> lk(mu_); log_file_ = on; }

void Logger::SetCustomWriter(CustomWriter writer) {
    std::lock_guard<std::mutex> lk(mu_);
    custom_writer_ = std::move(writer);
}

bool Logger::StderrEnabled() const { std::lock_guard<std::mutex> lk(mu_); return log_stderr_; }
bool Logger::FileEnabled() const   { std::lock_guard<std::mutex> lk(mu_); return log_file_; }

void Logger::SetLogFilePath(const std::string& path) {
    std::lock_guard<std::mutex> lk(mu_);
    if (!path.empty()) file_path_ = path;
}

std::string Logger::LogFilePath() const {
    std::lock_guard<std::mutex> lk(mu_);
    return file_path_;
}
