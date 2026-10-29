// TerminalWindows.ets — 多终端窗口的登记：谁是新窗口、新窗口对应哪个会话
//
// 与 WaymonyService 那套（Wayland 客户端窗口）是同一个套路，但对象是**终端**：
// 每开一个新终端窗口就是一个 TerminalRunnerAbility（multiton）实例，它加载的是
// **同一个** pages/Index —— 页面靠"会话号 sid"区分自己是谁。
//
// sid 的分配在 native（bshTermAllocSession，见 shell.h）而不是在这里：那个号同时是
// bsh_tty / procmgr 前台表的下标，必须由持有那两张表的一侧发号。
import { common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bshTermAllocSession, bshTermStop } from 'libentry.so';

const TAG = 'BSH_TWin';

/** 主窗口（EntryAbility 那个）用的是固定会话号 0，与 native 的 kBshSid 对应。 */
export const MAIN_SESSION: number = 0;

/** 没有待处理会话时的哨兵。**不能用 0** —— 0 是主窗口的合法会话号，
 *  万一新窗口没拿到自己的号就会静默变成"第二个 bsh"，症状很怪。 */
const NO_PENDING: number = -1;

export class TerminalWindows {
  private static instance: TerminalWindows | null = null;

  static getInstance(): TerminalWindows {
    if (!TerminalWindows.instance) {
      TerminalWindows.instance = new TerminalWindows();
    }
    return TerminalWindows.instance;
  }

  private ctx: common.UIAbilityContext | null = null;
  /** 待认领的会话号（同 WaymonyService.setPendingToplevel 的做法：
   *  loadContent 的 LocalStorage 传参在页面里读不可靠，改成"由 Ability 先登记、
   *  页面 aboutToAppear 取走即清"，避免多窗口串号）。 */
  private pendingSid: number = NO_PENDING;
  /** 新窗口起来后要跑的那条命令(bshutil newtab -e),没有就是空串。 */
  private pendingExec: string = '';

  init(ctx: common.UIAbilityContext): void {
    this.ctx = ctx;
  }

  setPendingSession(sid: number, exec: string): void {
    this.pendingSid = sid;
    this.pendingExec = exec;
  }

  /** 取走"起来之后要跑的命令"(取走即清,同 pendingSid)。 */
  takePendingExec(): string {
    const e = this.pendingExec;
    this.pendingExec = '';
    return e;
  }

  /** 页面 aboutToAppear 取走自己的会话号；没有待认领的返回 NO_PENDING，
   *  调用方据此退回主窗口会话。 */
  takePendingSession(): number {
    const s = this.pendingSid;
    this.pendingSid = NO_PENDING;
    return s;
  }

  /** 新开一个终端窗口。成功返回会话号，0 表示没开成。
   *  失败时会把刚占的号还回去（不还的话 8 个槽用完就没法再开窗口了）。
   *
   *  返回 Promise 是为了让调用方（`bshutil newtab`）能把**真实结果**回给用户 ——
   *  startAbility 是异步的，直接返回号的话失败也会报"已开"。 */
  async newWindow(exec: string): Promise<number> {
    if (!this.ctx) {
      hilog.error(0x0000, TAG, 'no context for new terminal window');
      return 0;
    }
    const sid = bshTermAllocSession();
    if (sid <= 0) {
      hilog.error(0x0000, TAG, 'no free session slot');
      return 0;
    }
    const parameters: Record<string, Object> = { 'sessionId': sid, 'exec': exec };
    const want: Want = {
      bundleName: this.ctx.abilityInfo.bundleName,
      // 与 WaymonyService 同一条理由：TerminalRunnerAbility 跟调用方同属一个 entry
      // 模块，而模块名随分包变（tablet / phone），不能写死。
      moduleName: this.ctx.abilityInfo.moduleName,
      abilityName: 'TerminalRunnerAbility',
      parameters: parameters,
    };
    try {
      await this.ctx.startAbility(want);
      hilog.info(0x0000, TAG, 'TerminalRunnerAbility started sid=%{public}d', sid);
      return sid;
    } catch (e) {
      hilog.error(0x0000, TAG, 'startAbility failed sid=%{public}d: %{public}s',
        sid, JSON.stringify(e));
      this.release(sid);
      return 0;
    }
  }

  /** 起不来的号要还回去，否则槽会漏（native 那边 bshTermStop 对一个还没 start 的会话
   *  就是"把号放掉"——见 shell.cpp 的 StopSession）。 */
  private release(sid: number): void {
    this.pendingSid = NO_PENDING;
    try { bshTermStop(sid); } catch (e) { /* ignore */ }
    hilog.warn(0x0000, TAG, 'release session sid=%{public}d（not started）', sid);
  }

  /** 认领本窗口的会话号：新窗口由 TerminalRunnerAbility.onCreate 登记过 pending，这里取走；
   *  主窗口没有登记，落回 MAIN_SESSION。
   *
   *  与 native 的 bshTermAllocSession（newWindow 里那个）不是一回事：那边是**发一个新号**，
   *  这边只是把已经发出去的号交给窗口。取走即清，一个号只会被认领一次 —— 所以**只能有一个
   *  调用者**（当前是 WebTerminal.onPageEnd）；多一个调用者，后者会静默落到主会话 0 上。 */
  allocateSessionId(): number {
    const s = this.takePendingSession();
    return s > 0 ? s : MAIN_SESSION;
  }

  /** 窗口销毁时归还会话号：sid>0 的 tab 会话连 pty 一起停掉（native 的 StopSession 对
   *  "已占号未启动"同样是放号，所以起失败的窗口也能收尾）。主会话 0 不归这里管，显式跳过。
   *  不动 pendingSid：销毁过程中可能已有**下一个**窗口登记进来，清掉会把它的号偷走。 */
  releaseSessionId(id: number): void {
    if (id <= 0) return;
    try { bshTermStop(id); } catch (e) { /* ignore */ }
  }
}
