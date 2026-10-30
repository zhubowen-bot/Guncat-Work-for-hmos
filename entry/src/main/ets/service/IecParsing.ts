// IecParsing: IEC 运行时里与 HarmonyOS 无关的纯解析/校验规则。
//
// 为什么单独抽出来：
//   `toybox` applet 清单解析、显式命令过滤、cwd 相对路径校验原本内联在
//   IecRuntime.ets / IecShellService.ets 里，只有真机跑得到。Node 单测
//   （test/guncat-harness）与宿主 toybox 交叉验证（third_party/bettersh/iec/
//   tests/toybox_parse）只能各抄一份规则，规则一改就漂移。
//   这里保持**纯 TS、零 HarmonyOS import**，让两侧都直接跑同一份真实现。
//
// 约束：本文件的行为必须与抽取前逐字一致（含长度上限、toybox 跳过的位置），
// 改规则时同步更新 test/guncat-harness/test-core.mjs 的断言。

// 与 `toybox` 无参输出解析共用：token 只能是小写字母/数字/下划线。
const APPLET_RE: RegExp = /^[a-z0-9_]+$/;
// 原实现是 `part.length < 32`；保留这个上限，别把异常长 token 当 applet。
const APPLET_MAX_LEN: number = 32;

// 解析 `toybox` 无参输出（多列排版，`[`/`]` 是 applet 名本身）。
//
// 规则（与 IecRuntime.listToyboxApplets 抽取前一致）：
//   1. `[`/`]` 替换成空格；
//   2. 按空白分词；
//   3. 只留 0 < 长度 < 32 且匹配 ^[a-z0-9_]+$ 的 token；
//   4. 去掉 `toybox` 自身（原 writeToyboxApplets 循环里跳过）；
//   5. 去重且保序（同名 applet 只注册一次 launcher）。
//
// 注意 nbd-client / nbd-server 会被第 3 条丢掉：这是既有行为，不是解析 bug，
// 带连字符的 applet 在 ArkTS 侧本来也注册不了。
export function parseAppletList(raw: string): string[] {
  const cleaned: string = raw.replace(/[\[\]]/g, ' ');
  const parts: string[] = cleaned.split(/\s+/);
  const names: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (const part of parts) {
    if (part.length === 0 || part.length >= APPLET_MAX_LEN) {
      continue;
    }
    if (!APPLET_RE.test(part)) {
      continue;
    }
    if (part === 'toybox') {
      continue;
    }
    if (seen.has(part)) {
      continue;
    }
    seen.add(part);
    names.push(part);
  }
  return names;
}

// 模拟 writeToyboxApplets 的写入循环：空串、`toybox` 本体、显式注册过的命令
// （nc / hexdump / diff / jq / sh / mksh …）都不写回 libtoybox.so。
// 显式 launcher 优先，绝不能被同名 toybox applet 覆盖。
export function filterExplicit(applets: string[], explicit: Set<string>): string[] {
  const kept: string[] = [];
  for (const name of applets) {
    if (name === '' || name === 'toybox') {
      continue;
    }
    if (explicit.has(name)) {
      continue;
    }
    kept.push(name);
  }
  return kept;
}

// 复刻 IecShellService 的 cwd 校验（抽取前 isSafeRel 逐字搬）：
// 只接受工作区内的相对路径，拒绝以 `/` 开头、含 `..`、含 `:` 的输入。
//
// 空串在这里返回 true：调用方（IecShellService.run）在 cwd 为空时根本不校验，
// 语义是"没给 cwd，用工作区根"。Windows 反斜杠也不拒绝——设备侧路径分隔符只有
// `/`，反斜杠只是普通文件名字符；保持原行为，避免改变工具协议。
export function isSafeRelPath(p: string): boolean {
  if (p.startsWith('/') || p.indexOf('..') !== -1 || p.indexOf(':') !== -1) {
    return false;
  }
  return true;
}

// 工具没有给 stdin 时，把 fd0 固定到 /dev/null 再执行命令。
//
// 为什么需要：IEC 会话的 stdin 是管道，管道读端只有在写端关闭后才看得到 EOF。
// 工具层本来就会在 stdin 为空时关掉写端，但只要有任意一层（旧运行核、中间
// 进程、pipeline 里的后台进程）还攥着写端，`cat` / `head` / `python3` 这类
// "先读完 stdin 再干活"的程序就会一直等，直到工具 60 秒超时——用户看到的是
// "命令根本不启动"。显式重定向到 /dev/null 后，无论上层有没有关写端，命令
// 都只会读到 EOF，行为与"没有标准输入"一致。
//
// 用 `[ -r /dev/null ]` 兜一层：真机沙箱理论上总有 /dev/null，但万一没有，
// 也不能让 `exec` 的重定向失败把整条命令带走；条件不成立时保持原状执行。
// 这段前缀不改变命令本身的退出码/输出，只多一行内建 `test`（mksh 内建，无进程开销）。
export function withStdinClosed(command: string, stdin: string): string {
  if (stdin !== '') {
    return command;
  }
  return 'if [ -r /dev/null ]; then exec 0</dev/null; fi\n' + command;
}
