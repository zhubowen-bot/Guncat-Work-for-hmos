// tools/iec_native_host_selftest.cpp — 宿主机回归：exec 路由、cwd 校验、NCP 拒绝分类。
//
// 不需要设备、不需要 OHOS SDK。两件事在同一个进程里做：
//
//   1. 直接调用生产代码里的纯函数，把这几处“以后很容易改回去”的判据钉住：
//        - ResolveKind()：fork=0 时 #IECSOv2 启动器仍须判成 kSo；普通 ELF 不能被
//          当成启动器；脚本仍按 shebang 走。
//        - IsNcpPlatformRefusal()：只有三类平台级前缀算“设备拒绝”，请求级错误
//          （"only so file for now!" / "bad launcher ..."）不能把 NCP 路线熔断。
//   2. 真的拉起 dist/iec_server，用 exec_session 的公开 API 验证 cwd 校验：
//        目录存在但没有搜索(x)权限 → 必须拒绝；不存在、不是目录 → 拒绝；正常目录 → 通过。
//      （这条判据在 onExecute() 里，只有让真实服务收到一次 EXECUTE 请求才能验到。）
//
// 构建与运行见 scripts/test_iec_native_host.sh；失败行以 FAIL 开头，退出码非 0。
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "exec/caps.h"
#include "exec/elf.h"
#include "exec/exec_ncp_refusal.h"
#include "exec/exec_route.h"
#include "exec/exec_session.h"

namespace {

int g_checks = 0;
int g_failures = 0;
int g_skips = 0;

void Check(bool ok, const std::string& what) {
    g_checks++;
    if (!ok) {
        g_failures++;
        std::printf("FAIL  %s\n", what.c_str());
    } else {
        std::printf("ok    %s\n", what.c_str());
    }
}

// 宿主环境构造不出某个场景时的明确跳过（例如以 root 跑，CAP_DAC_OVERRIDE 会绕过
// 目录的 mode 位）；跳过不影响退出码，但一定打印原因，避免看起来像“测过了”。
void Skip(const std::string& why) {
    g_skips++;
    std::printf("SKIP  %s\n", why.c_str());
}

int64_t NowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

bool WriteFile(const std::string& path, const std::string& data) {
    FILE* f = std::fopen(path.c_str(), "wb");
    if (f == nullptr) return false;
    const bool ok = std::fwrite(data.data(), 1, data.size(), f) == data.size();
    std::fclose(f);
    return ok;
}

std::string TempDir() {
    char tmpl[] = "/tmp/iec-native-host.XXXXXX";
    char* dir = mkdtemp(tmpl);
    return dir == nullptr ? std::string() : std::string(dir);
}

// 一个“看起来像可执行 ELF”的 64 字节文件头：magic 正确、e_machine 是本机架构。
// ResolveKind() 只读头部，所以不需要拼出能真正加载的完整 ELF。
std::string ElfHeaderBytes() {
    std::string bytes(64, '\0');
    bytes[0] = '\x7f';
    bytes[1] = 'E';
    bytes[2] = 'L';
    bytes[3] = 'F';
    bytes[4] = 2;   // ELFCLASS64
    bytes[5] = 1;   // ELFDATA2LSB
    bytes[6] = 1;   // EV_CURRENT
    bytes[18] = static_cast<char>(HOST_ARCH & 0xff);
    bytes[19] = static_cast<char>((HOST_ARCH >> 8) & 0xff);
    return bytes;
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

/* ------------------------------------------------------------------ */
/* 1. ResolveKind                                                      */
/* ------------------------------------------------------------------ */

// 能力字打包格式见 exec/caps.h：ncp<<20 | chmod<<16 | fork<<12 | exec<<8 | jit<<4 | path。
// 0x11202 = chmod 1、fork 1、exec 2、path 2（宿主上 fork/execve 都可用）。
// 0x10102 = chmod 1、fork 0、exec 1、path 2（无 fork 设备；launcher 必须仍能识别）。
constexpr uint64_t kCapsWithFork = 0x11202;
constexpr uint64_t kCapsNoFork = 0x10102;

void TestResolveKind(const std::string& dir) {
    const std::string launcher = dir + "/launcher";
    const std::string elf = dir + "/plain-elf";
    const std::string script = dir + "/script.sh";

    // 启动器是纯文本，不需要可执行位：识别只看第一行。
    Check(WriteFile(launcher, "#IECSOv2\n/tmp/libdoesnotexist.so\nentry\n2\n0\n"),
          "构造 #IECSOv2 启动器文件");
    Check(WriteFile(elf, ElfHeaderBytes()), "构造普通 ELF 头");
    Check(WriteFile(script, "#!/bin/sh\necho hi\n"), "构造 shebang 脚本");

    // 本轮修复的回归点：启动器识别不能依赖 fork。旧代码把 IsSoLauncher() 放在
    // `caps.fork == 1` 分支里，fork=0 的设备会把它判成 kUnexecutable，命令全起不来。
    setCaps(kCapsNoFork);
    Check(ResolveKind(launcher) == LaunchKind::kSo,
          "fork=0 时 #IECSOv2 启动器仍判为 kSo（不能被 fork 门控）");

    setCaps(kCapsWithFork);
    Check(ResolveKind(launcher) == LaunchKind::kSo, "fork=1 时启动器判为 kSo");

    // 普通 ELF 不能因为“文件开头可读”被误判成启动器；fork=1、exec=2 时应走 kExec。
    Check(ResolveKind(elf) == LaunchKind::kExec, "普通 ELF 判为 kExec，而不是 kSo");

    // 无 fork 时普通 ELF 会落到 qemu 路线（现有行为）；这里只钉住“不是 kSo”。
    setCaps(kCapsNoFork);
    Check(ResolveKind(elf) != LaunchKind::kSo, "fork=0 时普通 ELF 也不会被误判成 kSo");

    // shebang 仍按原逻辑：fork 可用时走 kShebang，fork 不可用时维持原有结果。
    setCaps(kCapsWithFork);
    Check(ResolveKind(script) == LaunchKind::kShebang, "shebang 脚本判为 kShebang");
    setCaps(kCapsNoFork);
    Check(ResolveKind(script) == LaunchKind::kUnexecutable,
          "fork=0 时 shebang 维持原逻辑（kUnexecutable）");

    // 不存在的路径不能意外落到某个路线。
    Check(ResolveKind(dir + "/no-such-file") == LaunchKind::kUnexecutable,
          "不存在的路径判为 kUnexecutable");
}

/* ------------------------------------------------------------------ */
/* 2. NCP 拒绝分类                                                     */
/* ------------------------------------------------------------------ */

void TestNcpRefusal() {
    const char* platform[] = {
        "start native child failed: 16010004, pid -1",
        "cannot register the exit callback: 16010004",
        "the platform has no native child process API",
    };
    for (const char* text : platform)
        Check(IsNcpPlatformRefusal(text), std::string("平台级拒绝判真: ") + text);

    // 这两条描述的是“这一次请求”，不是设备。把它们也当成平台拒绝，会让一次
    // 非 .so 请求永久关掉整条 NCP 路线。
    Check(!IsNcpPlatformRefusal("only so file for now!"),
          "only so file for now! 不熔断");
    Check(!IsNcpPlatformRefusal("bad launcher /tmp/x: the first line is not #IECSOv2"),
          "bad launcher ... 不熔断");
    Check(!IsNcpPlatformRefusal(""), "空错误串不熔断");
    Check(!IsNcpPlatformRefusal("not a HarmonyOS build"), "非 OHOS 构建的错误串不熔断");
}

/* ------------------------------------------------------------------ */
/* 3. cwd 校验（真的服务 + 公开 API）                                   */
/* ------------------------------------------------------------------ */

// 发一次 Start，预期被服务拒绝。若没拒绝（回归了），也要把会话收干净再判失败。
void ExpectStartRefused(const iec::ExecOptions& options, const std::string& what) {
    iec::ExecState state;
    std::string error;
    const int id = iec::Start(options, &state, &error);
    if (id >= 0) {
        iec::Wait(id, 5000, &state);
        iec::Release(id);
    }
    if (id < 0) {
        std::printf("      拒绝原因: %s\n", error.c_str());
    }
    Check(id < 0 && !error.empty(), what + "（必须拒绝且给出原因）");
}

void TestCwdValidation() {
    const std::string base = TempDir();
    if (base.empty()) {
        Check(false, "mkdir -p 临时目录");
        return;
    }

    // 没有搜索权限的目录：stat() 能成功、S_ISDIR 为真，但 chdir()/access(X_OK) 会被拒。
    // 这正是本轮加 access(X_OK) 要挡的情况。
    const std::string no_search = base + "/no-search";
    const bool made = mkdir(no_search.c_str(), 0700) == 0;
    Check(made, "创建无搜索权限目录");
    if (made && geteuid() != 0) {
        chmod(no_search.c_str(), 0);
        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {"-c", "pwd"};
        options.cwd = no_search;
        ExpectStartRefused(options, "cwd 目录存在但无 x 权限被拒绝");
        chmod(no_search.c_str(), 0700);   // 先恢复，否则后面 rmdir 删不掉
    } else if (made) {
        Skip("cwd 无搜索权限场景：以 root 运行，CAP_DAC_OVERRIDE 会绕过目录 mode 位，"
             "宿主构造不出来");
    }

    // 不存在的目录。
    {
        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {"-c", "pwd"};
        options.cwd = base + "/does-not-exist";
        ExpectStartRefused(options, "不存在的 cwd 被拒绝");
    }

    // 存在但不是目录。
    {
        const std::string file = base + "/a-regular-file";
        Check(WriteFile(file, "not a directory\n"), "构造普通文件作为 cwd");
        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {"-c", "pwd"};
        options.cwd = file;
        ExpectStartRefused(options, "不是目录的 cwd 被拒绝");
    }

    // 正常目录：必须能起来，并且真的在新 cwd 里执行（/bin/pwd 打印物理路径）。
    {
        const std::string good = base + "/good";
        const bool ok = mkdir(good.c_str(), 0700) == 0;
        Check(ok, "创建正常 cwd 目录");
        if (ok) {
            iec::ExecOptions options;
            options.cmd = "/bin/pwd";
            options.cwd = good;
            iec::ExecState state;
            std::string error;
            const int id = iec::Start(options, &state, &error);
            Check(id > 0, "正常目录的 cwd 被接受" +
                              (id < 0 ? (": " + error) : std::string()));
            if (id > 0) {
                iec::Wait(id, 5000, &state);
                std::string out;
                for (;;) {
                    iec::ExecChunk chunk;
                    iec::Poll(id, 1u << 20, 1u << 20, &chunk, &state);
                    out += chunk.out;
                    if (state.exited && chunk.out.empty() && state.out_eof) break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(5));
                }
                Check(state.exited && state.exit_code == 0 && out == good + "\n",
                      "程序在请求的 cwd 中执行（pwd 输出 " +
                          std::string(out.empty() ? "<空>" : out.substr(0, out.size() - 1)) +
                          "）");
                iec::Release(id);
            }
        }
    }

    // 子进程必须拿回 SIGPIPE 的默认处置。会话的 stdin feeder 在**应用进程**里
    // 忽略 SIGPIPE（写无读者管道不能杀整个应用），而 execve 不会复位被忽略的
    // 信号；exec_server 的复位循环若不显式恢复 SIGPIPE，所有命令都会继承
    // “忽略”，`kill -PIPE $$` 杀不死自己，`yes | head` 这类管道语义也会变。
    {
        // 先触发一次带 stdin 的 Start，让会话实现把 SIGPIPE 设为忽略；接下来
        // 的子进程才是“继承 SIG_IGN”的被测对象。
        iec::ExecOptions warm;
        warm.cmd = "/bin/true";
        warm.stdin_data = std::string(4096, 'x');
        iec::ExecState warm_state;
        std::string warm_error;
        const int warm_id = iec::Start(warm, &warm_state, &warm_error);
        Check(warm_id > 0, "SIGPIPE 用例预热（带 stdin 的 Start）");
        if (warm_id > 0) {
            iec::Wait(warm_id, 5000, &warm_state);
            iec::Release(warm_id);
        }

        iec::ExecOptions options;
        options.cmd = "sh";
        options.args = {"-c", "kill -PIPE $$; echo survived"};
        iec::ExecState state;
        std::string error;
        const int id = iec::Start(options, &state, &error);
        Check(id > 0, "SIGPIPE 用例启动" +
                          (id < 0 ? (": " + error) : std::string()));
        if (id > 0) {
            iec::Wait(id, 5000, &state);
            std::string out;
            for (;;) {
                iec::ExecChunk chunk;
                iec::Poll(id, 1u << 20, 1u << 20, &chunk, &state);
                out += chunk.out;
                if (state.exited && chunk.out.empty() && state.out_eof) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            Check(state.signal == SIGPIPE,
                  "命令收到 SIGPIPE 并按默认处置终止（signal=" +
                      std::to_string(state.signal) + "）");
            Check(out.find("survived") == std::string::npos,
                  "没有继承“忽略 SIGPIPE”的旧行为（无 survived 输出）");
            iec::Release(id);
        }
    }

    // 恢复权限并删除临时树。
    chmod(no_search.c_str(), 0700);
    std::string cmd = "rm -rf '" + base + "'";
    if (std::system(cmd.c_str()) != 0)
        std::printf("note: 临时目录未删净: %s\n", base.c_str());
}

}  // namespace

int main(int argc, char** argv) {
    const char* server_path =
        argc > 1 ? argv[1] : "build-cmake/dist/iec_server";
    const char* sock = "/tmp/exec_service.sock";

    const std::string dir = TempDir();
    if (dir.empty()) {
        std::printf("FAIL  创建临时目录失败\n");
        return 1;
    }

    TestResolveKind(dir);
    TestNcpRefusal();

    // cwd 校验必须经过真实服务：请求解析和拒绝都在 onExecute() 里。
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
        std::printf("FAIL  exec 服务未在 %s 起来（服务器二进制: %s）\n", sock, server_path);
        kill(server, SIGKILL);
        waitpid(server, nullptr, 0);
        return 2;
    }

    TestCwdValidation();

    // 服务端故意屏蔽 SIGTERM/SIGINT，收尾只能 SIGKILL；这里两边都属于本测试。
    kill(server, SIGKILL);
    int status = 0;
    waitpid(server, &status, 0);

    {
        std::string cmd = "rm -rf '" + dir + "'";
        if (std::system(cmd.c_str()) != 0)
            std::printf("note: 临时目录未删净: %s\n", dir.c_str());
    }

    std::printf("\n=== iec native host: %d checks, %d failed, %d skipped ===\n",
                g_checks, g_failures, g_skips);
    return g_failures == 0 ? 0 : 1;
}
