// ShellResultFormat: shell 工具结果正文的纯函数拼装。
//
// 从这里拆出来的原因：状态行、二进制/截断/dropped 文案、stderr 段与空行规则
// 都是"给模型看的文本"，不该和 fileIo / 上下文 / spill 落盘混在一起。纯函数
// 可以在 Node 侧直接回归（test/guncat-harness），超时/信号/dropped/二进制这些
// 设备上不好复现的语义也能逐字断言。
//
// 约束：本文件不 import 任何 HarmonyOS API，也不读写文件；文案与换行必须与
// 拆分前 IecShellService 的内联实现逐字一致（test/guncat-harness 逐字断言）。

// 正文里输出被截断时附在末尾的说明。spillRel 非空表示完整内容已落盘；
// 为空表示落盘失败（或压根没落盘），两种文案不能混。
export function formatTruncationNote(spillRel: string, caveat: string): string {
  const extra: string = caveat === '' ? '' : '；' + caveat;
  if (spillRel !== '') {
    // 只承诺"已收到的内容"：被引擎 cap 丢掉的那部分不在这里，写"完整内容"是假话。
    return '\n\n[...输出已截断: 已收到的内容在工作区 ' + spillRel +
      extra + '；需要时用 read_file 读回]';
  }
  return '\n\n[...输出已截断; 落盘失败, 建议把输出重定向到文件后用 read_file 读' +
    extra + ']';
}

// 单条流（stdout 或 stderr）的正文：超过 headChars 只保留前 headChars 个字符；
// spillRel 非空说明这条流整体超限、调用方已把解码后的全文落盘。
export function formatStreamBody(text: string, spillRel: string, headChars: number,
  caveat: string): string {
  let head: string = text;
  let truncated: boolean = spillRel !== '';
  if (head.length > headChars) {
    head = head.substring(0, headChars);
    truncated = true;
  }
  if (!truncated) {
    return head;
  }
  return head + formatTruncationNote(spillRel, caveat);
}

// 输出里出现非法 UTF-8（解码成 U+FFFD）或 NUL 字节时的独立说明。
// binary=false 返回空串，调用方无需再判断。
export function formatBinaryNote(binary: boolean): string {
  if (!binary) {
    return '';
  }
  return '[...输出含二进制字节(非 UTF-8 或含 NUL)，文本视图里非法字节显示为 �' +
    '；二进制请重定向到文件（如 `cmd > out.bin`）再用 download_file 取，' +
    '或用 `base64` 转成文本]';
}

// 截断说明里的附加警告：.spill 落盘的是解码后的字符串，不是原始字节，
// 不能让"完整内容在工作区"这句话把模型引去读一份坏掉的文件。
export function formatBinaryCaveat(binary: boolean): string {
  if (!binary) {
    return '';
  }
  return '其中非 UTF-8 字节已替换为 �，落盘的是解码后的文本，不能当原始二进制用';
}

// 引擎输出上限丢掉的字节数。两个流都按 >0 才列出，无丢弃返回空串。
// 引擎 cap 丢弃的字节和壳层"截断到前 N 字符"是两个原因：前者连 .spill 里
// 都没有，后者 .spill 里有，所以必须分开说。
export function formatDropped(outDropped: number, errDropped: number): string {
  if (outDropped <= 0 && errDropped <= 0) {
    return '';
  }
  const streams: string[] = [];
  if (outDropped > 0) {
    streams.push('stdout ' + outDropped.toString() + ' 字节');
  }
  if (errDropped > 0) {
    streams.push('stderr ' + errDropped.toString() + ' 字节');
  }
  return '[引擎输出上限已丢弃 ' + streams.join('、') +
    '，这部分不在上面的文本/ .spill 文件里；要完整输出请重定向到文件后用 read_file 读回]';
}

// 常见信号的名字，只为了正文能写"被 SIGKILL(9) 终止"而不是裸的 137。
// 没列到的按编号输出，不猜。
export function signalName(signo: number): string {
  switch (signo) {
    case 1: return 'SIGHUP(1)';
    case 2: return 'SIGINT(2)';
    case 3: return 'SIGQUIT(3)';
    case 4: return 'SIGILL(4)';
    case 5: return 'SIGTRAP(5)';
    case 6: return 'SIGABRT(6)';
    case 7: return 'SIGBUS(7)';
    case 8: return 'SIGFPE(8)';
    case 9: return 'SIGKILL(9)';
    case 11: return 'SIGSEGV(11)';
    case 13: return 'SIGPIPE(13)';
    case 14: return 'SIGALRM(14)';
    case 15: return 'SIGTERM(15)';
    case 31: return 'SIGSYS(31)';
    default: return 'signal ' + signo.toString();
  }
}

// 状态行。引擎的 code 与 shell 的 $? 一致（正常退出是退出码，被信号杀是
// 128+signal），但只有数字的话，"被 SIGKILL 杀(137)"、"超时被杀(137)"、
// "启动/观测失败(-1)"在模型眼里是同一串数字。超时、信号、状态丢失分别写出来。
//
// startFailed 时当前实现直接返回 run.err（工具失败），不产生状态行，因此这里
// 返回空串，交给 composeShellResult 跳过 head；保持与拆分前完全一致。
export function formatStatusLine(code: number, signal: number, timedOut: boolean,
  startFailed: boolean, elapsedMs: number, cwdLabel: string): string {
  if (startFailed) {
    return '';
  }
  const seconds: string = (elapsedMs / 1000).toFixed(2);
  let status: string = '[exit ' + code.toString();
  if (timedOut) {
    status += ' · 超时终止';
  }
  if (signal > 0) {
    status += ' · 被信号 ' + signalName(signal) + ' 终止';
  }
  if (code < 0 && signal === 0 && !timedOut) {
    status += ' · 未观测到退出状态(会话丢失)';
  }
  status += ' · ' + seconds + 's · cwd ' + cwdLabel + ']';
  return status;
}

// composeShellResult 的附加说明。binary 在 stdout 正文之前，dropped 在整段
// 末尾（与拆分前的 parts.push 顺序一致）；空串表示不输出。
export interface ShellResultNotes {
  binary: string;
  dropped: string;
}

export interface ShellResultParts {
  head: string;
  body: string;
  err: string;
  notes: ShellResultNotes;
}

// 按固定顺序拼装：状态行 → 二进制说明 → stdout 正文 → stderr 段 → dropped。
// 空段直接跳过，段间恰好一个换行；正文内部的换行（截断说明前的 \n\n）保持原样，
// 所以空输出不会多出空行，stderr 的空白（\r、尾随空格）也不会被吃掉。
export function composeShellResult(parts: ShellResultParts): string {
  const lines: string[] = [];
  if (parts.head !== '') {
    lines.push(parts.head);
  }
  if (parts.notes.binary !== '') {
    lines.push(parts.notes.binary);
  }
  if (parts.body !== '') {
    lines.push(parts.body);
  }
  // 只含空白字符的 stderr 也是 stderr（进度条常用 \r 收尾）：判空只看空串，
  // 不做 trim。
  if (parts.err !== '') {
    lines.push('--- stderr ---');
    lines.push(parts.err);
  }
  if (parts.notes.dropped !== '') {
    lines.push(parts.notes.dropped);
  }
  return lines.join('\n');
}
