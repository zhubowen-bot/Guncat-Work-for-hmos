// types/libentry/Index.d.ts — libentry.so 的 ArkTS 声明
// 与 entry/src/main/cpp/napi_init.cpp 的导出保持一致。

/* ---------- 终端会话 ---------- */
// 会话号 sid:0 = 主窗口的 bsh;>0 = `bshutil newtab` 开出来的 tab。
// 每个会话有自己的 pty / termios / winsize / 前台进程(见 native 的 tty/bsh_tty.h)。
// 分配用 bshTermAllocSession(只占号),真正的 shell 在 bshTermStart 里起。
export const bshTermAllocSession: () => number;
export const bshTermStart: (sid: number, cb: (data: string) => void) => number;
export const bshTermInput: (sid: number, text: string) => number;
export const bshTermStop: (sid: number) => void;
export const bshTermResize: (sid: number, cols: number, rows: number) => void;
/** 往终端里回一句 [notice](ArkTS 侧替 native 做的事,如目录选择器的结果) */
export const bshShellNotice: (sid: number, text: string) => void;

/* ---------- 资源管理器 + 应用私有目录 ----------
 * filesDir 一并交进来：设备侧数据目录是 /data/storage/el2/base/haps/<模块名>/files，
 * 模块名随 product 变(tablet / phone)，native 侧不能在编译期写死它。
 * 详细见 feature/bsh_main/src/main/cpp/common/bsh_paths.h。 */
export const initResourceManager: (resourceManager: object, filesDir: string) => void;

/* ---------- bshutil 的事件通道 ----------
 * native 侧 bshutil 有些设置(虚拟按键栏显隐、窗口缩放、拉起目录选择器)需要
 * ArkTS 代劳,通过这里注册的回调推 JSON 事件过来:
 *   {"op":"keys","show":true|false}
 *   {"op":"scale","value":2.0}
 *   {"op":"picker","name":"picked"}
 */
export const bshUiSubscribe: (sid: number, cb: (json: string) => void) => void;

/** 回填一条"要回结果"的请求:事件里带 "req" 字段的那些(native 的 bshutil
 *  picker 会阻塞等它)。处理完调用,text 是给用户看的一句话。 */
export const bshUiResolve: (reqId: number, text: string) => void;

/* ---------- Wayland toplevel 信息 ---------- */
export interface ToplevelInfo {
  title: string;
  appId: string;
  w: number;
  h: number;
}

/* ---------- 窗口/渲染/输入聚合对象 ---------- */

/** toplevel 生命周期事件:event = "created" | "resize" | "destroyed" */
export const setToplevelCallback: (cb: (toplevelId: number, event: string, json: string) => void) => void;
/** 为 toplevel 绑定 XComponent surface 并创建 EGL 渲染器 */
export const createRenderer: (toplevelId: number, surfaceId: number, w: number, h: number) => boolean;
export const destroyRenderer: (toplevelId: number) => void;
export const resizeRenderer: (toplevelId: number, w: number, h: number) => void;
/** 窗口尺寸变化 → 回发 xdg configure 让客户端重排 */
export const notifyToplevelResize: (toplevelId: number, w: number, h: number) => void;
/** 请求客户端关闭窗口(xdg close) */
export const sendToplevelClose: (toplevelId: number) => void;
export const getToplevelInfo: (toplevelId: number) => ToplevelInfo;

/** 键盘(Linux evdev code;pressed=true 按下) */
export const sendKey: (toplevelId: number, code: number, pressed: boolean) => void;
/** 修饰键位掩码(depressed/latched/locked/group) */
export const sendModifiers: (toplevelId: number, d: number, l: number, lk: number, g: number) => void;
/** 指针移动(surface 局部像素坐标) */
export const sendMouseMove: (toplevelId: number, x: number, y: number) => void;
/** 指针按键(BTN_LEFT=0x110 等) */
export const sendMouseButton: (toplevelId: number, button: number, pressed: boolean) => void;
/** 滚轮(dx/dy 为离散轴值) */
export const sendMouseAxis: (toplevelId: number, dx: number, dy: number) => void;
/** 指针进入/离开 surface */
export const sendMouseEnterLeave: (toplevelId: number, inside: boolean) => void;
