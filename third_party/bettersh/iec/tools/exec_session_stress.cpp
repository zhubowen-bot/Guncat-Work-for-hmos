// tools/exec_session_stress.cpp — host-side stress and lifetime test for
// exec_session.
//
// The functional acceptance test (tools/exec_session_selftest.cpp) proves that one
// session at a time behaves; this one asks what happens when many do, when two are
// cancelled while the rest keep writing, and whether the client side gives every
// descriptor and every session back. The questions are deliberately the ones a
// single-threaded test cannot ask:
//
//   * eight sessions at once, each writing more than the 64 KiB cap, every one
//     polled while it runs: the cap is a budget for the whole stream, so the bytes
//     a Poll() drains must not buy the writer more room;
//   * two of those eight are terminated mid-output; the other six must not notice;
//   * fifty rounds of start/run/release, looking at /proc/self/fd and VmRSS so a
//     descriptor or a buffer that is only leaked once per round is still visible;
//   * two hundred short sessions, which is where "Release drops it" has to be true
//     every time and not just on average;
//   * the 0/1/50 ms edges of the deadline, where "0 means no deadline" is as much
//     a boundary as the one-millisecond case;
//   * stdin whose reader goes away first: the feeder and Write() must report EPIPE,
//     not take the application down with SIGPIPE.
//
// Everything waits on a deadline and polls. There is no "sleep and hope": a slow
// machine makes a check take longer, not fail differently.
//
// Build and run with scripts/stress_exec_session.sh.
#include "exec/exec_session.h"

#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <numeric>
#include <random>
#include <string>
#include <thread>
#include <vector>

namespace {

int g_checks = 0;
int g_failures = 0;

int64_t NowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

void SleepMs(int ms) {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

void Check(bool ok, const std::string& what) {
    g_checks++;
    if (ok) {
        std::printf("ok    %s\n", what.c_str());
    } else {
        g_failures++;
        std::printf("FAIL  %s\n", what.c_str());
    }
}

// One session and everything this test has collected from it. Poll() consumes the
// bytes, so they are accumulated here; the state is the last one read.
struct Tracked {
    int            id = -1;
    size_t         out = 0;
    size_t         err = 0;
    iec::ExecState state;
};

// Polls one session and folds the chunk into the counters. Returns false when the
// id is no longer valid (a released session, or a bug that dropped it early).
bool PollInto(Tracked& t) {
    iec::ExecChunk chunk;
    iec::ExecState state;
    if (!iec::Poll(t.id, 1u << 20, 1u << 20, &chunk, &state)) return false;
    t.out += chunk.out.size();
    t.err += chunk.err.size();
    t.state = state;
    return true;
}

bool PollAll(std::vector<Tracked>& sessions) {
    bool ok = true;
    for (Tracked& t : sessions)
        if (t.id > 0 && !PollInto(t)) ok = false;
    return ok;
}

// The reader threads set the eof flags only after the pipe is empty, so both eof
// and exited together mean "there is nothing left to collect".
bool AllFinished(const std::vector<Tracked>& sessions) {
    for (const Tracked& t : sessions) {
        if (t.id <= 0) continue;
        if (!t.state.exited || !t.state.out_eof || !t.state.err_eof) return false;
    }
    return true;
}

bool WaitOneFinished(Tracked& t, int timeout_ms) {
    const int64_t deadline = NowMs() + timeout_ms;
    while (NowMs() < deadline) {
        if (!PollInto(t)) return false;
        if (t.state.exited && t.state.out_eof && t.state.err_eof) return true;
        SleepMs(1);
    }
    PollInto(t);
    return t.state.exited && t.state.out_eof && t.state.err_eof;
}

bool WaitAllFinished(std::vector<Tracked>& sessions, int timeout_ms) {
    const int64_t deadline = NowMs() + timeout_ms;
    while (NowMs() < deadline) {
        PollAll(sessions);
        if (AllFinished(sessions)) return true;
        SleepMs(1);
    }
    PollAll(sessions);
    return AllFinished(sessions);
}

// Best-effort teardown for a phase that failed early. The test must not leave an
// infinite writer behind for the next phase (or for the shell that ran the test).
void KillAndRelease(std::vector<Tracked>& sessions) {
    for (Tracked& t : sessions)
        if (t.id > 0 && !t.state.exited) iec::Terminate(t.id, 0);

    const int64_t deadline = NowMs() + 3000;
    while (NowMs() < deadline && !AllFinished(sessions)) {
        PollAll(sessions);
        SleepMs(1);
    }
    for (Tracked& t : sessions) {
        if (t.id > 0) iec::Release(t.id);
        t.id = -1;
    }
}

int FdCount() {
    DIR* dir = opendir("/proc/self/fd");
    if (dir == nullptr) return -1;

    int count = 0;
    while (dirent* entry = readdir(dir)) {
        if (std::strcmp(entry->d_name, ".") == 0 ||
            std::strcmp(entry->d_name, "..") == 0)
            continue;
        count++;
    }
    closedir(dir);
    return count;
}

bool WaitForFdAtMost(int limit, int timeout_ms) {
    const int64_t deadline = NowMs() + timeout_ms;
    while (NowMs() < deadline) {
        if (FdCount() <= limit) return true;
        SleepMs(5);
    }
    return FdCount() <= limit;
}

long RssKb() {
    std::ifstream status("/proc/self/status");
    std::string line;
    while (std::getline(status, line)) {
        if (line.compare(0, 6, "VmRSS:") != 0) continue;
        return std::atol(line.c_str() + 6);
    }
    return -1;
}

bool WaitForSocket(const char* path, int timeout_ms) {
    const int64_t deadline = NowMs() + timeout_ms;
    while (NowMs() < deadline) {
        struct stat st {};
        if (stat(path, &st) == 0) return true;
        SleepMs(20);
    }
    return false;
}

// 10 000 lines x 17 bytes ("0123456789abcdef\n") = 170 000 bytes, comfortably
// more than the 64 KiB minimum cap. The command is deliberately a plain shell
// loop: no external writer whose buffering would make the byte count depend on the
// host.
constexpr size_t kLongLines = 10000;
constexpr size_t kLongBytes = kLongLines * 17;
constexpr size_t kCap = 64u * 1024;
const char kLongCommand[] =
    "i=0; while [ $i -lt 10000 ]; do echo 0123456789abcdef; i=$((i+1)); done";

/* ------------------------------------------------------------------ */
/* 1. Eight concurrent writers and the whole-stream cap                */
/* ------------------------------------------------------------------ */
void PhaseConcurrentCap() {
    std::printf("\n== 1. 8 路并发、每路 >128 KiB 输出、整条流上限 ==\n");

    std::vector<Tracked> sessions(8);
    int started = 0;
    for (Tracked& t : sessions) {
        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {"-c", kLongCommand};
        options.max_output_bytes = kCap;
        std::string error;
        t.id = iec::Start(options, &t.state, &error);
        if (t.id > 0) {
            started++;
        } else {
            Check(false, "并发会话启动失败: " + error);
        }
    }
    Check(started == 8, "8 路会话全部启动");
    if (started != 8) {
        KillAndRelease(sessions);
        return;
    }

    const int64_t deadline = NowMs() + 20000;
    while (NowMs() < deadline) {
        PollAll(sessions);
        if (AllFinished(sessions)) break;
        SleepMs(1);
    }
    Check(AllFinished(sessions), "8 路都在 20s 内退出且输出读到 EOF");

    for (size_t i = 0; i < sessions.size(); i++) {
        const Tracked& t = sessions[i];
        const std::string which = "第 " + std::to_string(i + 1) + " 路";
        Check(t.state.exited && t.state.exit_code == 0,
              which + " 正常退出（code=" + std::to_string(t.state.exit_code) + "）");
        Check(t.out <= kCap, which + " 收到的 out 不超过 cap（" +
                                 std::to_string(t.out) + " <= " +
                                 std::to_string(kCap) + "）");
        Check(t.out == kCap, which + " 恰好收到 cap 字节（" +
                                 std::to_string(t.out) + "）");
        Check(t.out + t.state.out_dropped == kLongBytes,
              which + " out + dropped == 总产量（" + std::to_string(t.out) + " + " +
                  std::to_string(t.state.out_dropped) + " == " +
                  std::to_string(kLongBytes) + "）");
        Check(t.err == 0 && t.state.err_dropped == 0,
              which + " 没有 stderr 输出");
    }

    bool released = true;
    for (Tracked& t : sessions) released = iec::Release(t.id) && released;
    Check(released, "8 路 Release 全部成功");
    for (Tracked& t : sessions) t.id = -1;
}

/* ------------------------------------------------------------------ */
/* 2. Two of eight terminated while the rest keep writing              */
/* ------------------------------------------------------------------ */
void PhaseTerminateMidStream() {
    std::printf("\n== 2. 8 路无限输出，随机终止 2 路 ==\n");

    std::vector<Tracked> sessions(8);
    int started = 0;
    for (Tracked& t : sessions) {
        iec::ExecOptions options;
        options.cmd = "yes";
        options.args = {"0123456789abcdef"};
        options.max_output_bytes = kCap;
        std::string error;
        t.id = iec::Start(options, &t.state, &error);
        if (t.id > 0) {
            started++;
        } else {
            Check(false, "无限输出会话启动失败: " + error);
        }
    }
    Check(started == 8, "8 路无限输出会话全部启动");
    if (started != 8) {
        KillAndRelease(sessions);
        return;
    }

    // "Mid-output" is defined by bytes, not by a sleep: every session must have
    // produced at least 16 KiB and still be running.
    const int64_t produced_deadline = NowMs() + 10000;
    bool produced = false;
    while (NowMs() < produced_deadline) {
        produced = true;
        for (Tracked& t : sessions) {
            if (!PollInto(t)) produced = false;
            if (t.state.exited) produced = false;
            if (t.out + t.state.out_dropped < 16 * 1024) produced = false;
        }
        if (produced) break;
        SleepMs(1);
    }
    Check(produced, "终止前 8 路都在运行且各已产出 >= 16 KiB");
    if (!produced) {
        KillAndRelease(sessions);
        return;
    }

    // Fixed seed: "random pick" is about exercising a different pair run to run
    // only if the seed changes, but a deterministic test must not. The pair is
    // printed so a failure names it.
    std::mt19937 rng(20261030u);
    std::vector<int> order(sessions.size());
    std::iota(order.begin(), order.end(), 0);
    std::shuffle(order.begin(), order.end(), rng);
    const int pick_a = order[0];
    const int pick_b = order[1];
    std::printf("    选中第 %d 路 (id=%d) 与第 %d 路 (id=%d)\n", pick_a + 1,
                sessions[pick_a].id, pick_b + 1, sessions[pick_b].id);

    const bool accepted = iec::Terminate(sessions[pick_a].id, 0) &&
                          iec::Terminate(sessions[pick_b].id, 0);
    Check(accepted, "两路 Terminate(grace=0) 被接受");

    // How much each untouched session had produced before the kill; used below to
    // prove it kept producing afterwards.
    std::vector<size_t> produced_before(sessions.size(), 0);
    for (size_t i = 0; i < sessions.size(); i++)
        if (static_cast<int>(i) != pick_a && static_cast<int>(i) != pick_b)
            produced_before[i] = sessions[i].out + sessions[i].state.out_dropped;

    bool chosen_exited = false;
    bool others_survived = true;
    const int64_t kill_deadline = NowMs() + 5000;
    while (NowMs() < kill_deadline) {
        PollAll(sessions);
        chosen_exited = sessions[pick_a].state.exited && sessions[pick_b].state.exited;
        for (size_t i = 0; i < sessions.size(); i++) {
            if (static_cast<int>(i) == pick_a || static_cast<int>(i) == pick_b) continue;
            if (sessions[i].state.exited) others_survived = false;
        }
        if (chosen_exited) break;
        SleepMs(1);
    }
    Check(chosen_exited, "被终止的两路在 5s 内 Poll 到 exited");
    Check(others_survived, "终止期间其余 6 路没有退出");

    // The six must still be writing: their produced byte count (received plus
    // dropped) has to grow after the other two died. That is what "not affected"
    // means at the pipe level, and it does not depend on timing.
    bool grew = true;
    for (size_t i = 0; i < sessions.size(); i++) {
        if (static_cast<int>(i) == pick_a || static_cast<int>(i) == pick_b) continue;
        const size_t target = produced_before[i] + 1;
        const int64_t growth_deadline = NowMs() + 2000;
        bool this_grew = false;
        while (NowMs() < growth_deadline) {
            PollInto(sessions[i]);
            if (sessions[i].out + sessions[i].state.out_dropped >= target &&
                sessions[i].out + sessions[i].state.out_dropped > produced_before[i]) {
                this_grew = true;
                break;
            }
            if (sessions[i].state.exited) break;
            SleepMs(1);
        }
        if (!this_grew) {
            grew = false;
            std::printf("    第 %zu 路在另一路终止后没有继续产出\n", i + 1);
        }
    }
    Check(grew, "终止之后其余 6 路仍在继续产出");

    // End the six deliberately: whether a cancelled session reports a signal is
    // what this phase checks, not that an endless writer eventually exits by
    // itself.
    for (size_t i = 0; i < sessions.size(); i++) {
        if (static_cast<int>(i) == pick_a || static_cast<int>(i) == pick_b) continue;
        iec::Terminate(sessions[i].id, 0);
    }

    Check(WaitAllFinished(sessions, 5000), "8 路最终都结束并读到 EOF");

    for (size_t i = 0; i < sessions.size(); i++) {
        const Tracked& t = sessions[i];
        const std::string which = "第 " + std::to_string(i + 1) + " 路";
        Check(t.state.exited, which + " 已退出");
        Check(t.state.signal == SIGKILL && t.state.exit_code == 128 + SIGKILL,
              which + " 报 SIGKILL（signal=" + std::to_string(t.state.signal) +
                  ", code=" + std::to_string(t.state.exit_code) + "）");
        Check(!t.state.timed_out, which + " 不是超时（是主动 Terminate）");
        Check(t.out <= kCap, which + " out 不超过 cap");
    }
    for (size_t i = 0; i < sessions.size(); i++) {
        if (static_cast<int>(i) == pick_a || static_cast<int>(i) == pick_b) continue;
        Check(sessions[i].out == kCap && sessions[i].state.out_dropped > 0,
              "第 " + std::to_string(i + 1) + " 路在终止前已吃完 cap 并在丢弃");
    }

    bool released = true;
    for (Tracked& t : sessions) released = iec::Release(t.id) && released;
    Check(released, "被终止的会话 Release 全部成功");
    for (Tracked& t : sessions) t.id = -1;
}

/* ------------------------------------------------------------------ */
/* 3. Fifty rounds: descriptors and RSS must not walk upwards          */
/* ------------------------------------------------------------------ */
void PhaseFiftyRounds() {
    std::printf("\n== 3. 50 轮启动/结束/释放，观察 /proc/self/fd 与 RSS ==\n");

    constexpr int kRounds = 50;
    constexpr int kWarmup = 5;

    std::vector<int> fds;
    std::vector<long> rss;
    fds.reserve(kRounds);
    rss.reserve(kRounds);

    bool round_failed = false;
    int failed_round = -1;

    for (int round = 0; round < kRounds; round++) {
        const int before = FdCount();

        std::vector<Tracked> sessions(4);
        int started = 0;
        for (Tracked& t : sessions) {
            iec::ExecOptions options;
            options.cmd = "sh";
            options.args = {"-c", "printf x"};
            std::string error;
            t.id = iec::Start(options, &t.state, &error);
            if (t.id > 0) started++;
        }

        bool ok = started == 4 && WaitAllFinished(sessions, 5000);
        for (Tracked& t : sessions) {
            if (t.id <= 0) continue;
            if (!t.state.exited || t.state.exit_code != 0 || t.out != 1) ok = false;
        }
        for (Tracked& t : sessions) {
            if (t.id > 0 && !iec::Release(t.id)) ok = false;
            t.id = -1;
        }

        // A released session's reader closes its pipes after at most one 200 ms
        // poll pass. Wait for that instead of measuring while the threads are
        // still on their way out.
        const bool settled = WaitForFdAtMost(before + 1, 2000);
        if (!ok || !settled) {
            round_failed = true;
            if (failed_round < 0) failed_round = round;
        }

        fds.push_back(FdCount());
        rss.push_back(RssKb());
    }

    Check(!round_failed,
          "50 轮每轮都正常退出、Release，并回到起始 fd 数" +
              (failed_round < 0 ? std::string() :
               "（首个失败轮次 " + std::to_string(failed_round + 1) + "）"));

    int fd_baseline = 0;
    long rss_baseline = 0;
    for (int i = 0; i < kWarmup && i < kRounds; i++) {
        fd_baseline = std::max(fd_baseline, fds[i]);
        rss_baseline = std::max(rss_baseline, rss[i]);
    }

    int fd_growth = 0;
    for (int i = kWarmup; i < kRounds; i++) fd_growth = std::max(fd_growth, fds[i] - fd_baseline);
    Check(fd_growth <= 2, "fd 数不随轮次增长（基线 " + std::to_string(fd_baseline) +
                              "，最大增量 " + std::to_string(fd_growth) + "，允许 2）");

    long rss_growth = 0;
    for (int i = kWarmup; i < kRounds; i++) rss_growth = std::max(rss_growth, rss[i] - rss_baseline);
    Check(rss_growth <= 32 * 1024, "RSS 没有明显增长（基线 " + std::to_string(rss_baseline) +
                                        " KiB，最大增量 " + std::to_string(rss_growth) +
                                        " KiB，上限 32768）");

    std::printf("    fd: 第 1 轮 %d，第 %d 轮 %d；RSS: 起始 %ld KiB，结束 %ld KiB\n",
                fds.empty() ? -1 : fds.front(), kRounds, fds.empty() ? -1 : fds.back(),
                rss.empty() ? -1L : rss.front(), rss.empty() ? -1L : rss.back());
}

/* ------------------------------------------------------------------ */
/* 4. Two hundred short sessions                                       */
/* ------------------------------------------------------------------ */
void PhaseShortSessions() {
    std::printf("\n== 4. 200 次 /bin/true 的 Start/Release ==\n");

    constexpr int kRuns = 200;
    const int fd_before = FdCount();
    int failures = 0;
    std::string first_failure;

    for (int i = 0; i < kRuns; i++) {
        iec::ExecOptions options;
        options.cmd = "/bin/true";

        Tracked t;
        std::string error;
        t.id = iec::Start(options, &t.state, &error);
        if (t.id <= 0) {
            failures++;
            if (first_failure.empty()) first_failure = "Start: " + error;
            continue;
        }

        if (!WaitOneFinished(t, 5000)) {
            failures++;
            if (first_failure.empty()) first_failure = "第 " + std::to_string(i + 1) + " 次未在 5s 内结束";
            iec::Terminate(t.id, 0);
            WaitOneFinished(t, 3000);
        } else if (!t.state.exited || t.state.exit_code != 0 || t.state.timed_out) {
            failures++;
            if (first_failure.empty())
                first_failure = "第 " + std::to_string(i + 1) + " 次状态不对 (code=" +
                                std::to_string(t.state.exit_code) + ")";
        }

        if (!iec::Release(t.id)) {
            failures++;
            if (first_failure.empty()) first_failure = "Release 拒绝";
        }
        if (iec::Count() != 0) {
            failures++;
            if (first_failure.empty())
                first_failure = "Count() 残留 " + std::to_string(iec::Count());
        }
    }

    Check(failures == 0, "200 次 Start/Release 全部干净" +
                             (first_failure.empty() ? std::string() : "：" + first_failure));
    Check(iec::Count() == 0, "会话注册表为空（iec::Count() == 0）");

    const bool settled = WaitForFdAtMost(fd_before + 2, 3000);
    Check(settled, "200 次之后 fd 回到起始水平（" + std::to_string(fd_before) + " -> " +
                       std::to_string(FdCount()) + "，允许 2）");

    // List() is the *service's* process table, not this process's session
    // registry. It keeps a row per process it ever started because a late
    // OP_WAIT may still ask about a child that onTick() already reaped; dead rows
    // are history, not residue. What must be true is that none of them is alive.
    const std::string table = iec::List();
    Check(table.find("alive 1") == std::string::npos,
          "服务进程表里没有 alive=1 的残留进程");
    size_t rows = 0;
    for (char c : table)
        if (c == '\n') rows++;
    std::printf("    注: List() 保留 %zu 行历史进程记录（服务端设计如此），"
                "会话残留以 Count()==0 判定\n",
                rows);
}

/* ------------------------------------------------------------------ */
/* 5. The deadline edges: 0 / 1 / 50 ms                                */
/* ------------------------------------------------------------------ */
void PhaseTimeoutEdges() {
    std::printf("\n== 5. 超时边界 0ms / 1ms / 50ms，各 20 次 ==\n");

    struct Case {
        int         timeout_ms;
        bool        expect_timeout;
        const char* label;
    };
    const Case cases[] = {
        {0, false, "0ms（API 约定: 不设期限）"},
        {1, true, "1ms"},
        {50, true, "50ms"},
    };

    for (const Case& c : cases) {
        int failed = 0;
        int64_t slowest = 0;
        std::string first_failure;

        for (int i = 0; i < 20; i++) {
            iec::ExecOptions options;
            if (c.timeout_ms == 0) {
                options.cmd = "/bin/true";
            } else {
                options.cmd = "sh";
                options.args = {"-c", "sleep 30"};
            }
            options.timeout_ms = c.timeout_ms;

            const int64_t started = NowMs();
            Tracked t;
            std::string error;
            t.id = iec::Start(options, &t.state, &error);
            if (t.id <= 0) {
                failed++;
                if (first_failure.empty()) first_failure = "Start: " + error;
                continue;
            }

            const bool finished = WaitOneFinished(t, 2000);
            const int64_t elapsed = NowMs() - started;
            slowest = std::max(slowest, elapsed);

            bool ok = finished && elapsed <= 2000;
            if (c.expect_timeout) {
                ok = ok && t.state.timed_out && t.state.exited && t.state.signal > 0 &&
                     t.state.exit_code == 128 + t.state.signal;
            } else {
                ok = ok && !t.state.timed_out && t.state.exited &&
                     t.state.exit_code == 0 && t.state.signal == 0;
            }
            if (!ok) {
                failed++;
                if (first_failure.empty()) {
                    first_failure = "第 " + std::to_string(i + 1) + " 次: timed_out=" +
                                    std::to_string(t.state.timed_out) + " exited=" +
                                    std::to_string(t.state.exited) + " code=" +
                                    std::to_string(t.state.exit_code) + " signal=" +
                                    std::to_string(t.state.signal) + " elapsed=" +
                                    std::to_string(elapsed) + "ms";
                }
            }

            if (!iec::Release(t.id)) {
                failed++;
                if (first_failure.empty()) first_failure = "Release 拒绝";
            }
        }

        Check(failed == 0, std::string("20 次 ") + c.label +
                               " 全部在 2s 内结束且状态一致（最慢 " +
                               std::to_string(slowest) + "ms）" +
                               (first_failure.empty() ? std::string() : "：" + first_failure));
    }
}

/* ------------------------------------------------------------------ */
/* 6. stdin: a reader that goes away must not take the process with it */
/* ------------------------------------------------------------------ */
void PhaseStdinLifecycle() {
    std::printf("\n== 6. stdin 生命周期（对端提前关闭/退出）==\n");

    // A. The feeder writes a payload to a child that exits immediately without
    // reading it. The write finds a closed reader; without SIGPIPE ignored that
    // kills this process down inside a detached thread, which is the bug this
    // phase exists to keep fixed.
    int failures = 0;
    std::string first_failure;
    for (int i = 0; i < 20; i++) {
        iec::ExecOptions options;
        options.cmd = "/bin/true";
        options.stdin_data = std::string(256 * 1024, 'x');

        Tracked t;
        std::string error;
        t.id = iec::Start(options, &t.state, &error);
        if (t.id <= 0) {
            failures++;
            if (first_failure.empty()) first_failure = "Start: " + error;
            continue;
        }
        if (!WaitOneFinished(t, 5000) || t.state.exit_code != 0 || t.state.timed_out) {
            failures++;
            if (first_failure.empty())
                first_failure = "第 " + std::to_string(i + 1) + " 次未正常结束";
        }
        if (!iec::Release(t.id)) {
            failures++;
            if (first_failure.empty()) first_failure = "Release 拒绝";
        }
        if (iec::Count() != 0) {
            failures++;
            if (first_failure.empty()) first_failure = "会话残留";
        }
    }
    Check(failures == 0,
          "20 次 256 KiB stdin 写入 /bin/true（子进程不读即退出）后仍存活且干净" +
              (first_failure.empty() ? std::string() : "：" + first_failure));

    // B. The child is alive but has closed its stdin; Write() must answer -1
    // instead of dying on SIGPIPE. "ready" proves fd 0 is closed and the shell is
    // still in the sleep, so the write really hits a reader-less pipe.
    int write_failures = 0;
    std::string write_failure;
    for (int i = 0; i < 10; i++) {
        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {"-c", "exec 0<&-; echo ready; sleep 0.2"};
        options.keep_stdin_open = true;

        iec::ExecState state;
        std::string error;
        const int id = iec::Start(options, &state, &error);
        if (id <= 0) {
            write_failures++;
            if (write_failure.empty()) write_failure = "Start: " + error;
            continue;
        }

        std::string seen;
        bool ready = false;
        const int64_t ready_deadline = NowMs() + 2000;
        while (NowMs() < ready_deadline) {
            iec::ExecChunk chunk;
            iec::Poll(id, 1u << 20, 1u << 20, &chunk, &state);
            seen += chunk.out;
            if (seen.find("ready") != std::string::npos) { ready = true; break; }
            if (state.exited) break;
            SleepMs(1);
        }

        long written = -1;
        if (ready) written = iec::Write(id, "x", 1);
        if (!ready || written >= 0) {
            write_failures++;
            if (write_failure.empty())
                write_failure = "第 " + std::to_string(i + 1) + " 次: ready=" +
                                std::to_string(ready) + " write=" +
                                std::to_string(written);
        }

        const int64_t done_deadline = NowMs() + 3000;
        while (NowMs() < done_deadline && !state.exited) {
            iec::ExecChunk chunk;
            iec::Poll(id, 1u << 20, 1u << 20, &chunk, &state);
            if (!state.exited) SleepMs(1);
        }
        if (!state.exited || state.exit_code != 0) {
            write_failures++;
            if (write_failure.empty())
                write_failure = "第 " + std::to_string(i + 1) + " 次 shell 未正常结束";
        }
        if (!iec::Release(id)) {
            write_failures++;
            if (write_failure.empty()) write_failure = "Release 拒绝";
        }
    }
    Check(write_failures == 0,
          "10 次对已关闭 stdin 的 Write 返回失败而不是 SIGPIPE 杀进程" +
              (write_failure.empty() ? std::string() : "：" + write_failure));
}

}  // namespace

int main(int argc, char** argv) {
    const char* server_path = argc > 1 ? argv[1] : "build-cmake/dist/iec_server";
    const char* sock = "/tmp/exec_service.sock";

    unlink(sock);
    unlink("/tmp/tty_service.sock");

    const pid_t server = fork();
    if (server == 0) {
        // The service logs every request at INFO; two hundred sessions would bury
        // this test's own output. Keep only what the test prints.
        int null_fd = open("/dev/null", O_WRONLY);
        if (null_fd >= 0) {
            dup2(null_fd, STDOUT_FILENO);
            dup2(null_fd, STDERR_FILENO);
            if (null_fd > STDERR_FILENO) close(null_fd);
        }
        execl(server_path, server_path, static_cast<char*>(nullptr));
        _exit(127);
    }
    if (server < 0) {
        std::perror("fork");
        return 2;
    }

    if (!WaitForSocket(sock, 5000)) {
        std::printf("FAIL  the exec service did not come up at %s\n", sock);
        kill(server, SIGKILL);
        waitpid(server, nullptr, 0);
        return 2;
    }

    const int fd_baseline = FdCount();
    std::printf("服务已就绪: %s（测试进程起始 fd=%d, RSS=%ld KiB）\n", sock,
                fd_baseline, RssKb());

    PhaseConcurrentCap();
    PhaseTerminateMidStream();
    PhaseFiftyRounds();
    PhaseShortSessions();
    PhaseTimeoutEdges();
    PhaseStdinLifecycle();

    const bool settled = WaitForFdAtMost(fd_baseline + 2, 5000);
    Check(settled, "全部阶段结束后 fd 回到起始水平（" + std::to_string(fd_baseline) +
                       " -> " + std::to_string(FdCount()) + "）");
    Check(iec::Count() == 0, "全部阶段结束后没有未释放的会话");

    kill(server, SIGKILL);
    waitpid(server, nullptr, 0);

    std::printf("\n=== exec_session stress: %d checks, %d failed ===\n", g_checks,
                g_failures);
    return g_failures == 0 ? 0 : 1;
}
