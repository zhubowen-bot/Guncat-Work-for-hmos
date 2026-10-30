# Programmatic execution (`exec/exec_session.cpp`)

The exec service was built for the shell: a program *replaces* the caller, its
stdio is the terminal, and the only thing the caller wants back is the exit
status. A caller that runs commands on behalf of somebody else — an agent, a task
runner, a UI that shows output while it appears — needs the other shape:

* a child of its own, not a replacement,
* pipes it can read at its own pace,
* a deadline that is enforced even if the caller stops polling,
* a handle that cancels the whole process tree.

`exec_session.cpp` is that shape, implemented as a client of the same exec
service the `execve` shim talks to. Both routes therefore start programs the same
way and agree on PATH, the fake root, and what an exit status means; only the
plumbing around the process differs.

```
ArkTS                       exec_session.cpp                 exec_server.cpp
execStart({...})  ───────►   three pipes + OP_EXECUTE   ───►  fork / NCP
                             ◄─── pid                          dup2 onto 0,1,2
execPoll(id)      ───────►   read(stdout/stderr)               program runs
execWait(id)      ───────►   OP_WAIT (poll)              ───►  waitpid(pid)
execTerminate(id) ───────►   OP_TERMINATE_JOB            ───►  SIGTERM → SIGKILL
```

## API

From ArkTS, the functions are re-exported by the HAR (`import { execStart } from
'iec'`). The declarations are in
`platform/ohos/har/src/main/cpp/types/libiec_server/Index.d.ts`.

```ts
const handle = execStart({
  cmd: 'git',
  args: ['status', '--porcelain'],
  cwd: '/data/storage/el2/base/files/home/project',
  env: { GIT_TERMINAL_PROMPT: '0' },
  timeoutMs: 30_000,
});

const first = execPoll(handle.id, 64 * 1024, 64 * 1024);   // { out, err, running, … }
const done  = await execWait(handle.id, 30_000);            // { code, signal, timedOut }
execRelease(handle.id);
```

| Function | Purpose |
| --- | --- |
| `execStart(options)` | Starts a program. Returns `{ id, pid, job }`; throws when the service refuses. |
| `execPoll(id, maxOut?, maxErr?, encoding?)` | Returns the bytes that arrived since the previous poll, plus the state. `encoding` is `"utf8"` (default) or `"base64"`. |
| `execWait(id, timeoutMs?)` | Promise that resolves when the program ends or the caller's bound passes. Runs on the NAPI worker pool; never blocks the JS thread. |
| `execWrite(id, data)` | Non-blocking write to stdin. Bytes accepted, `0` when the pipe is full, `-1` when stdin is closed. |
| `execCloseStdin(id)` | How a program that reads to EOF is told there is no more. |
| `execTerminate(id, graceMs?)` | Cancels the whole job: SIGTERM, SIGKILL after `graceMs` (default 800). |
| `execSignal(id, signo)` | One signal to the program and its process group, no escalation. |
| `execRelease(id)` | Frees a finished session. Refused while the program runs. |
| `execList()` | The service's process table as text (diagnostics). |

### Semantics that matter

* **argv.** `argv[0]` is `cmd`; `args` become `argv[1..]`. There is deliberately no
  way to pass a different `argv[0]` — a caller that wants one is asking for a
  shell, and `sh -c` can do it.
* **cwd.** Empty means the fake root's home (`IEC_DEFAULT_HOME`), falling back to
  `/` when that directory does not exist. A directory that cannot be entered is
  refused by the service (`ENOENT`) instead of being silently ignored.
* **env.** Overlaid on this process's environment by default (`envReplace: true`
  makes it the whole environment). `PATH` and `HOME` are filled in when absent.
  `IEC_JOB` is always set by the engine and cannot be overridden.
* **stdin.** `stdin` is fed by a detached thread, so `execStart` can return while
  a large payload is still being written; when `keepStdinOpen` is not set the
  write end is closed after the payload. Later writes go through `execWrite`.
* **timeout.** Enforced by a thread inside the engine, not by the caller. A
  command that outlives its deadline is terminated and `timedOut` is set — even
  if the app stopped polling, which is exactly the case the caller cannot cover.
* **output cap.** `maxOutputBytes` (default 4 MiB, clamped to 64 KiB..64 MiB) is
  the total the caller may receive per stream over the session's life. Beyond it
  the bytes are still read and dropped — a pipe that is not drained would block
  the program — and `outDropped`/`errDropped` say how much was lost. Draining the
  buffer early with `execPoll` does not restore the budget: a command that keeps
  writing still stops at the cap. For larger output, redirect to a file and read
  it.
* **exit status.** `code` is 0..255, or 128 + signal with `signal` set. `-1`
  means the status was lost (the service went away), which is distinct from every
  status a program can produce.
* **jobs.** Every process of the tree carries `IEC_JOB=<id>` in its environment,
  and because a program's own exec calls send their environment, the id travels
  down without the service having to reconstruct a process tree (it cannot: an
  exec is filed as if the caller had been replaced). `execTerminate` ends every
  process of the job, including ones that changed process group.
* **lifetime.** A session is a process-wide id. `Release` refuses a running
  program because dropping its pipes would leave it writing into a closed
  descriptor with nobody to collect its status: terminate first, then release.

### Concurrency

Each session owns three pipes and up to five small threads (one stdin feeder when
input is supplied, two readers, one waiter, one deadline thread when a timeout is
set). Sessions are independent; `execStart` from several ArkTS
tasks at once is safe. `execCount()` reports how many are alive, and an app that
runs many commands should release finished ones — the buffers are per session and
are only freed on release.

## Integration

1. The HAR must have started the services: `startIecServer()` from the
   application's ability (BetterSH already does this in `EntryAbility`).
2. Import the functions from `'iec'` (they are re-exported by `Index.ets`).
3. Prefer `sh -c "<command line>"` when the input is a command *line* rather than
   an argv: that is where pipes, redirection, globbing and `&&` live. The engine
   itself does not parse a shell line, by design.

## Limits

* No pty: a program that insists on a terminal will see a pipe. Use the terminal
  session for those.
* `NUL` cannot appear in an argument, an environment entry, or a job id (the wire
  format is NUL-terminated strings).
* Static guests cannot be instrumented (the same limitation the shim has).
* On the native-child-process route (`PrimaryLaunchKind::kNcp`) the pid is
  platform-owned; the job id still covers it because it travels in the
  environment and the service records it at creation.
* The status of a native child that dies of a signal is reported as an exit code
  (the platform callback does not distinguish them); see `exec_ncp.cpp`.

## Test

```sh
./scripts/test_exec_session.sh
```

Builds `dist/iec_server` with the capability word a host needs
(`0x11202`: fork + real `execve`, no fake root) and runs
`tools/exec_session_selftest.cpp` against it: 21 checks covering stdout/stderr
separation, both stdin paths, cwd/environment, deadline, tree cancellation,
output cap, and the refused-program path.
