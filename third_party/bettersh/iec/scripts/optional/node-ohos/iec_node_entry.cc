// iec_node_entry.cc — C entry points exported by libnode.so.
//
// The IEC exec service loads a command object and calls a C symbol. Node's
// entry point is C++ (`node::Start(int, char**)`, exported by the shared
// library), so this file provides the fixed names:
//
//   iec_node_main  run node
//   iec_npm_main   run npm: [node, <sysroot>/npm/bin/npm-cli.js, args...]
//   iec_npx_main   the same for npx
//
// It is deliberately self-contained: it includes no IEC header and links no
// IEC object, only libc. Configuration travels through the environment, the
// same channel the command objects already use:
//
//   IEC_NODE_JITLESS=on|off|auto
//       `on` adds --jitless --no-expose-wasm, `off` does not, and `auto` (or
//       unset) probes whether writable-executable memory is available.
//       The old BSH_NODE_JITLESS name is still accepted for a transition.
//
//   IEC_SYSROOT
//       where npm/ lives. BSH_SYSROOT is accepted as a fallback.

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <sys/mman.h>
#include <sys/prctl.h>

namespace node {
int Start(int argc, char* argv[]);
}

namespace {

// V8 needs a page that is written and then made executable. On HarmonyOS that
// requires the JitFort ACL:
//     prctl(0x6a6974, 0, 0)  open
//     mmap/mprotect(PROT_EXEC)
//     prctl(0x6a6974, 0, 1)  close
// This is the same sandwich the V8 patch adds. The probe deliberately checks
// the final mapping result, not just the prctl return value.
bool JitWritableExecutableAvailable()
{
    const long kJitPrctlOpt = 0x6a6974L;   // ASCII "jit"
    void *p;
    int rc = -1;

    prctl(kJitPrctlOpt, 0, 0, 0, 0);
    p = mmap(nullptr, 4096, PROT_READ | PROT_WRITE,
             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p != MAP_FAILED) {
        rc = mprotect(p, 4096, PROT_READ | PROT_WRITE | PROT_EXEC);
        munmap(p, 4096);
    }
    prctl(kJitPrctlOpt, 0, 1, 0, 0);
    return rc == 0;
}

const char *Env(const char *name, const char *legacy)
{
    const char *v = getenv(name);
    if (v && *v) return v;
    v = getenv(legacy);
    return (v && *v) ? v : NULL;
}

bool NeedJitless()
{
    const char *v = Env("IEC_NODE_JITLESS", "BSH_NODE_JITLESS");
    if (v && !strcmp(v, "on")) return true;
    if (v && !strcmp(v, "off")) return false;
    return !JitWritableExecutableAvailable();
}

// Build the command line for a JS entry point.
//
// Two details are not stylistic:
//
// 1. argv[0] is "node", not an absolute path. Node uses it as
//    process.argv[0], and npm starts lifecycle scripts through
//    process.execPath; the bare name therefore comes back to the IEC
//    launcher. The exec-path patch in patches/0002 also uses argv[0] because
//    uv_exepath() would otherwise report the host's appspawn.
//
// 2. The argument strings must be one contiguous block, with argv[0] first.
//    libuv's uv_setup_args() computes
//        pt.cap = argv[i - 1] + size - argv[0]
//    and treats that as the writable length of the process title. With one
//    heap allocation per std::string, the difference is the distance between
//    two unrelated heap blocks; uv_set_process_title() then memsets across
//    the heap and crashes. The block below makes the difference equal to the
//    real block size.
int RunNodeCli(const char *cli_rel, int argc, char **argv)
{
    static std::vector<char> arg_block;
    static std::vector<char *> arg_av;
    const char *root = Env("IEC_SYSROOT", "BSH_SYSROOT");
    std::string base;
    std::vector<std::string> parts;
    bool jitless = NeedJitless();
    size_t total = 0;

    if (root && *root) {
        base = root;
    } else {
        const char *home = getenv("HOME");
        base = (home && *home) ? home : ".";
    }

    parts.push_back("node");
    if (jitless) {
        parts.push_back("--jitless");
        parts.push_back("--no-expose-wasm");
    }
    if (cli_rel) parts.push_back(base + cli_rel);
    for (int i = 1; i < argc; i++)
        parts.push_back(argv[i] ? argv[i] : "");

    for (const std::string &s : parts) total += s.size() + 1;
    arg_block.assign(total, '\0');
    arg_av.assign(parts.size() + 1, nullptr);

    {
        size_t off = 0;
        for (size_t i = 0; i < parts.size(); i++) {
            if (!parts[i].empty())
                memcpy(&arg_block[off], parts[i].data(), parts[i].size());
            arg_av[i] = &arg_block[off];
            off += parts[i].size() + 1;
        }
        arg_av[parts.size()] = nullptr;
    }

    return node::Start(static_cast<int>(parts.size()), arg_av.data());
}

}  // namespace

extern "C" int iec_node_main(int argc, char **argv)
{
    return RunNodeCli(nullptr, argc, argv);
}

extern "C" int iec_npm_main(int argc, char **argv)
{
    return RunNodeCli("/npm/bin/npm-cli.js", argc, argv);
}

extern "C" int iec_npx_main(int argc, char **argv)
{
    return RunNodeCli("/npm/bin/npx-cli.js", argc, argv);
}
