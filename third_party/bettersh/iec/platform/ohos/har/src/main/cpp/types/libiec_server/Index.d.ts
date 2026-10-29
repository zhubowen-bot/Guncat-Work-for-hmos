// ArkTS declaration for libiec_server.so (must match the exports in napi_init.cpp).
export interface Caps {
  packed: number;
  chmod: number;
  fork: number;
  exec: number;
  jit: number;
  path: number;
}

export const hello: () => string;
export const setCaps: (cap: number) => Caps;
export const probeCaps: () => Caps;

// Starts the tty and exec services. Omitted or empty paths use the compiled-in
// defaults. Idempotent; false means a socket could not be created.
export const startIecServer: (ttyPath?: string, execPath?: string) => boolean;

// Stops both services and joins their threads. True when a running server was
// stopped, false when none was running.
export const stopIecServer: () => boolean;

// Writes the CA bundle embedded in the library to <dir>/cacert.pem. The default
// is <fake root>/usr/share/git-core. False means the file could not be written.
export const installCaBundle: (dir?: string) => boolean;

// Registers the application's resource manager. Must be called before any
// unpackResource() call; HAR rawfiles are merged into the same manager.
export const initIecResourceManager: (resourceManager: object) => boolean;

// Returns true when <fake root>/.rawfile-version contains exactly `version`.
export const checkRawfileVersionMarker: (version: string) => boolean;

// Writes `version` to <fake root>/.rawfile-version. 0 on success.
export const writeRawfileVersionMarker: (version: string) => number;

// mkdir -p. 0 on success, 1 on failure.
export const ensureDir: (path: string) => number;

// Writes an #IECSOv2 launcher file at `target`. 0 on success, 1 on failure.
// `primary` is the process relationship the launcher asks for: 0 = the server
// decides (also what an absent line means), 1 = fork, 2 = HarmonyOS native child
// process, 3 = in this process.
export const writeSoLauncher: (target: string, so: string, entry: string,
                               arity: number, primary?: number) => number;

// Extracts a tar stored in rawfile `name` into `dest`. 0 on success, 1 on
// failure. Symlinks become <name>.IEC_SYMLINK marker files.
export const unpackResource: (name: string, dest: string) => number;

// Writes `data` to `target` (parent directories must exist). 0 on success, 1 on
// failure.
export const writeTxtFile: (target: string, data: string) => number;

/* ------------------------------------------------------------------ */
/* Programmatic execution (exec_napi.cpp, exec/exec_session.cpp)       */
/* ------------------------------------------------------------------ */

export interface ExecStartOptions {
  /** The program: a bare name is looked up on PATH, a name with '/' is a path. */
  cmd: string;
  /** argv[1..]; argv[0] is cmd itself. */
  args?: string[];
  /** Working directory; empty means the fake root's home. */
  cwd?: string;
  /** Environment overrides, laid over this process's environment. */
  env?: Record<string, string>;
  /** true = `env` is the whole environment, not an overlay. */
  envReplace?: boolean;
  /** Written to stdin before anything is read; stdin is closed afterwards
   *  unless keepStdinOpen is true. */
  stdin?: string;
  keepStdinOpen?: boolean;
  /** Wall-clock deadline enforced by the engine, even if nobody is polling.
   *  0 or absent = none. On expiry the job is terminated and timedOut is set. */
  timeoutMs?: number;
  /** Bytes kept per stream (default 4 MiB, clamped to 64 KiB..64 MiB). Output
   *  beyond it is drained and dropped; the dropped count is reported. */
  maxOutputBytes?: number;
  /** Job id shared by every process of the tree. Generated when absent. */
  job?: string;
}

export interface ExecHandle {
  id: number;
  pid: number;
  job: string;
}

export interface ExecState {
  id: number;
  pid: number;
  job: string;
  running: boolean;
  exited: boolean;
  /** Exit code 0..255, or 128 + signal; -1 when the status was lost. */
  code: number;
  /** Signal that ended the program, or 0. */
  signal: number;
  timedOut: boolean;
  outEof: boolean;
  errEof: boolean;
  outDropped: number;
  errDropped: number;
}

export interface ExecPollResult extends ExecState {
  /** Bytes since the previous poll; consumed by this call. */
  out: string;
  err: string;
  encoding: string;
}

export interface ExecWaitResult {
  code: number;
  signal: number;
  timedOut: boolean;
  running: boolean;
}

/** Starts a program as a session. Throws when the service refuses to start it. */
export const execStart: (options: ExecStartOptions) => ExecHandle;

/** Consumes up to maxOut / maxErr bytes of output and reports the state.
 *  encoding: "utf8" (default) or "base64". */
export const execPoll: (id: number, maxOut?: number, maxErr?: number,
                        encoding?: string) => ExecPollResult;

/** Waits until the program ends or timeoutMs passes (0 = until it ends).
 *  This does not block the JS thread: it resolves on the NAPI worker pool. */
export const execWait: (id: number, timeoutMs?: number) => Promise<ExecWaitResult>;

/** Writes to stdin without blocking. Bytes accepted, 0 = full, -1 = closed. */
export const execWrite: (id: number, data: string) => number;

export const execCloseStdin: (id: number) => boolean;

/** Ends every process of the job: SIGTERM, then SIGKILL after graceMs. */
export const execTerminate: (id: number, graceMs?: number) => boolean;

/** One signal to the program and its process group, no escalation. */
export const execSignal: (id: number, signo: number) => boolean;

/** Frees a finished session. False while the program is still running. */
export const execRelease: (id: number) => boolean;

/** The service's process table, one text line per process (diagnostics). */
export const execList: () => string;

/** Live sessions known to this process. */
export const execCount: () => number;

/**
 * 清掉上一次运行遗留的命令进程（按 IEC_JOB 环境变量识别，同 uid、非本进程）。
 * 应用崩溃/被强停后子进程会被 init 收养，这个函数在启动时把它们杀掉。
 * 返回杀掉的进程数。
 */
export const execKillStale: () => number;
