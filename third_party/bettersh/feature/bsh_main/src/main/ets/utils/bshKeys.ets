// entry/src/main/ets/utils/bshKeys.ets
// 虚拟按键 → 写入 pty 的字节序列(xterm 通用 CSI/SS3)。
export class BSH_KEYS {
  static readonly ESC: string = '\x1b';
  static readonly TAB: string = '\t';
  static readonly ENTER: string = '\r';
  static readonly PGUP: string = '\x1b[5~';
  static readonly HOME: string = '\x1b[H';
  static readonly UP: string = '\x1b[A';
  static readonly UP_APP: string = '\x1bOA';
  static readonly END: string = '\x1b[F';
  static readonly PGDN: string = '\x1b[6~';
  static readonly LEFT: string = '\x1b[D';
  static readonly LEFT_APP: string = '\x1bOD';
  static readonly DOWN: string = '\x1b[B';
  static readonly DOWN_APP: string = '\x1bOB';
  static readonly RIGHT: string = '\x1b[C';
  static readonly RIGHT_APP: string = '\x1bOC';
  static readonly F1: string = '\x1bOP';
  static readonly F2: string = '\x1bOQ';
  static readonly F3: string = '\x1bOR';
  static readonly F4: string = '\x1bOS';
  static readonly F5: string = '\x1b[15~';
  static readonly F6: string = '\x1b[17~';
  static readonly F7: string = '\x1b[18~';
  static readonly F8: string = '\x1b[19~';
  static readonly F9: string = '\x1b[20~';
  static readonly F10: string = '\x1b[21~';
  static readonly F11: string = '\x1b[23~';
  static readonly F12: string = '\x1b[24~';
}

export class VKeyMetrics {
  margin: number = 1;
  padding: number = 2;
  height: number = 28;
  width: number = 42;
  fontSize: number = 10;
  radius: number = 5;
}

export function getVKeyMetrics(deviceType: string): VKeyMetrics {
  const m = new VKeyMetrics();
  if (deviceType !== 'phone') {
    m.margin = 2;
    m.padding = 4;
    m.height = 28;
    m.width = 60;
    m.fontSize = 14;
    m.radius = 5;
  }
  return m;
}
