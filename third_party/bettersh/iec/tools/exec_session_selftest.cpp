// tools/exec_session_selftest.cpp — host-side acceptance for exec_session.
//
// Runs the real exec service (dist/iec_server) and drives it through the same
// API the HAR exposes to ArkTS: pipes, stdin, cwd, environment, deadline,
// cancellation, output cap, and the job-level kill. No device, no OHOS: the
// service is an ordinary host program here, which is what makes this testable at
// all.
//
// Build and run with scripts/test_exec_session.sh (it builds the server with the
// capability word this test needs).
#include "exec/exec_session.h"

#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool ok, const std::string& what) {
    g_checks++;
    if (!ok) {
        g_failures++;
        std::printf("FAIL  %s\n", what.c_str());
    } else {
        std::printf("ok    %s\n", what.c_str());
    }
}

int64_t NowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

struct Result {
    std::string out;
    std::string err;
    int         code = -1;
    bool        exited = false;
    bool        timed_out = false;
    size_t      out_dropped = 0;
    size_t      err_dropped = 0;
    std::string error;
};

// Polls until the session ends or the caller's bound passes, then drains what is
// left. This is the same loop an ArkTS caller would write around execPoll.
Result Run(const iec::ExecOptions& options, int wait_ms) {
    Result result;

    iec::ExecState state;
    const int id = iec::Start(options, &state, &result.error);
    if (id < 0) return result;

    const int64_t deadline = NowMs() + wait_ms;
    for (;;) {
        iec::ExecChunk chunk;
        iec::Poll(id, 1u << 20, 1u << 20, &chunk, &state);
        result.out += chunk.out;
        result.err += chunk.err;
        if (state.exited) {
            result.exited = true;
            result.code = state.exit_code;
            result.timed_out = state.timed_out;
            break;
        }
        if (NowMs() > deadline) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    // A last read so that output written just before the exit is not lost.
    for (int i = 0; i < 50; i++) {
        iec::ExecChunk chunk;
        iec::Poll(id, 1u << 20, 1u << 20, &chunk, &state);
        result.out += chunk.out;
        result.err += chunk.err;
        if (state.exited && chunk.out.empty() && chunk.err.empty() && state.out_eof &&
            state.err_eof)
            break;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    result.out_dropped = state.out_dropped;
    result.err_dropped = state.err_dropped;

    if (!iec::Release(id) && state.exited)
        std::printf("note: release refused for %d\n", id);
    return result;
}

bool WaitForSocket(const char* path, int timeout_ms) {
    const int64_t deadline = NowMs() + timeout_ms;
    while (NowMs() < deadline) {
        struct stat st {};
        if (stat(path, &st) == 0) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return false;
}

}  // namespace

int main(int argc, char** argv) {
    const char* server_path =
        argc > 1 ? argv[1] : "build-cmake/dist/iec_server";
    const char* sock = "/tmp/exec_service.sock";

    unlink(sock);
    unlink("/tmp/tty_service.sock");

    const pid_t server = fork();
    if (server == 0) {
        execl(server_path, server_path, static_cast<char*>(nullptr));
        std::perror("exec iec_server");
        _exit(127);
    }
    if (server < 0) {
        std::perror("fork");
        return 2;
    }

    if (!WaitForSocket(sock, 5000)) {
        std::printf("FAIL  the exec service did not come up at %s\n", sock);
        kill(server, SIGKILL);
        return 2;
    }

    // 1. stdout/stderr separation and the exit code.
    {
        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {"-c", "printf hello; printf err >&2; exit 7"};
        const Result r = Run(options, 5000);
        Check(r.exited && r.code == 7, "exit code is 7");
        Check(r.out == "hello", "stdout is separate and complete");
        Check(r.err == "err", "stderr is separate and complete (got \"" + r.err +
                                  "\")");
    }

    // 2. stdin written before the program is asked for it.
    {
        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {"-c", "cat"};
        options.stdin_data = "pipe me\n";
        const Result r = Run(options, 5000);
        Check(r.exited && r.code == 0, "cat exits 0");
        Check(r.out == "pipe me\n", "stdin reaches the program and closes");
    }

    // 3. stdin written by the caller while it runs.
    {
        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {"-c", "read x; echo got:$x"};
        options.keep_stdin_open = true;

        iec::ExecState state;
        std::string error;
        const int id = iec::Start(options, &state, &error);
        Check(id > 0, "keepStdinOpen start");

        long written = -1;
        for (int i = 0; i < 100 && written <= 0; i++) {
            written = iec::Write(id, "hi\n", 3);
            if (written <= 0)
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        Check(written == 3, "execWrite accepts the line");
        Check(iec::CloseStdin(id), "execCloseStdin");

        iec::Wait(id, 5000, &state);
        iec::ExecChunk chunk;
        iec::Poll(id, 1u << 20, 1u << 20, &chunk, &state);
        Check(state.exited && chunk.out == "got:hi\n", "the written line is echoed back");
        iec::Release(id);
    }

    // 4. cwd and environment.
    {
        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {"-c", "pwd; echo \"$FOO\""};
        options.cwd = "/tmp";
        options.env = {"FOO=bar"};
        const Result r = Run(options, 5000);
        Check(r.exited && r.code == 0, "cwd/env command exits 0");
        Check(r.out == "/tmp\nbar\n", "cwd and environment reach the program");
    }

    // 5. the deadline: a program that would run for 30 s ends in well under it.
    {
        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {"-c", "sleep 30"};
        options.timeout_ms = 300;

        const int64_t started = NowMs();
        const Result r = Run(options, 8000);
        const int64_t elapsed = NowMs() - started;
        Check(r.exited && r.timed_out, "deadline fires and is reported");
        Check(elapsed < 5000, "deadline ends the program promptly (" +
                                  std::to_string(elapsed) + " ms)");
        Check(r.code == 143 || r.code == 137 || r.code == 129,
              "the killed program reports a signal code (" +
                  std::to_string(r.code) + ")");
    }

    // 6. cancellation of a whole tree: two children and the shell that waits.
    {
        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {"-c", "sleep 20 & sleep 20 & wait"};

        iec::ExecState state;
        std::string error;
        const int id = iec::Start(options, &state, &error);
        Check(id > 0, "tree start");
        std::this_thread::sleep_for(std::chrono::milliseconds(200));

        Check(iec::Terminate(id, 100), "execTerminate is accepted");
        const int64_t started = NowMs();
        iec::Wait(id, 8000, &state);
        const int64_t elapsed = NowMs() - started;
        Check(state.exited, "the tree ends after cancellation (" +
                                std::to_string(elapsed) + " ms)");

        // Nothing of the job may be left alive in the service's table.
        const std::string table = iec::List();
        const size_t at = table.find("job " + state.job);
        bool clean = true;
        size_t pos = at;
        while (pos != std::string::npos) {
            const size_t eol = table.find('\n', pos);
            const std::string line = table.substr(pos, eol - pos);
            if (line.find("alive 1") != std::string::npos) clean = false;
            pos = (eol == std::string::npos) ? std::string::npos
                                             : table.find("job " + state.job, eol);
        }
        Check(clean, "no process of the job is left alive");
        iec::Release(id);
    }

    // 7. the output cap: more output than the cap is drained, not blocked on.
    {
        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {"-c", "yes 0123456789 | head -c 300000"};
        options.max_output_bytes = 64 * 1024;
        const Result r = Run(options, 10000);
        Check(r.exited && r.code == 0, "large writer exits 0");
        Check(r.out.size() == 64 * 1024,
              "output is capped at the requested size (got " +
                  std::to_string(r.out.size()) + " bytes)");
    }

    // 7b. The cap is a budget for the whole stream, not a high-water mark on the
    // buffer. Every burst is a full cap and the 100 ms gap makes the poll loop
    // drain in between, so a per-buffer cap would hand the caller four caps'
    // worth. This is the deterministic form of the fast-writer case above, whose
    // timing only sometimes lands between two fills of the buffer.
    {
        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {
            "-c",
            "for i in 1 2 3 4; do head -c 65536 /dev/zero; sleep 0.1; done"};
        options.max_output_bytes = 64 * 1024;
        const Result r = Run(options, 10000);
        Check(r.exited && r.code == 0, "burst writer exits 0");
        Check(r.out.size() == 64 * 1024,
              "draining between polls does not refill the cap (got " +
                  std::to_string(r.out.size()) + " bytes)");
        Check(r.out_dropped == 3 * 64 * 1024,
              "output beyond the cap is drained and counted (dropped " +
                  std::to_string(r.out_dropped) + " bytes)");
    }

    // 8. a missing program is a refusal, not a hang or a silent success.
    {
        iec::ExecOptions options;
        options.cmd = "definitely-not-a-real-program-xyz";
        iec::ExecState state;
        std::string error;
        const int id = iec::Start(options, &state, &error);
        Check(id < 0 && !error.empty(), "a missing program is refused with a message");
    }

    // The server blocks SIGTERM/SIGINT in its event loop on purpose (a second
    // signal must not cut a shutdown short), so teardown is SIGKILL: this process
    // owns both ends and nothing here needs an orderly stop.
    kill(server, SIGKILL);
    int status = 0;
    waitpid(server, &status, 0);

    std::printf("\n=== exec_session: %d checks, %d failed ===\n", g_checks,
                g_failures);
    return g_failures == 0 ? 0 : 1;
}
