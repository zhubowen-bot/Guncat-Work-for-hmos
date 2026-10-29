// service/UIBus.ets — bshutil 的 UI 事件总线（native → ArkTS）
//
// bshutil 有些事自己做不了（拉系统选择器、改 ArkUI 状态、开新窗口），经 native 的
// ui_bus 推 JSON 过来（见 cpp/bshutil/ui_bus.h）。这里集中处理：
//   keys       —— 显示/隐藏底部虚拟键栏(bshutil keys show|hide)
//   scale      —— 窗口缩放(bshutil set win-scale);只影响新开的窗口
//   rightclick —— 右键行为(bshutil set right-click menu|smart),转给页面
//   picker     —— 拉起系统目录选择器
//   newtab     —— 新开一个终端窗口
// 订阅成功时 native 会先补推 scale 与 rightclick，所以启动就能与配置一致。
//
// 页面只做两件事：就绪时 register(host)，销毁时 unregister(sid)。那些"只有页面才能做"
// 的动作（改键栏显隐 / 右键模式 / 往 WebView 注 JS）通过 host 回调回去。keys/scale/
// rightclick 是 native **广播**给所有窗口的，每个窗口各自收到一份、各自处理。
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { picker } from '@kit.CoreFileKit';
import { bshUiSubscribe, bshUiResolve, bshShellNotice } from 'libentry.so';
import { setUiScale } from './WaymonyService';
import { TerminalWindows } from './TerminalWindows';

const TAG = 'BSH_UIBus';

/** bshutil 从 native 推来的设置事件(见 bshutil/ui_bus.h) */
interface UiEvent {
  op: string;
  show?: boolean;   // op=keys
  value?: number;   // op=scale
  mode?: string;    // op=rightclick:"menu" | "smart"
  exec?: string;    // op=newtab:新窗口起来后要跑的命令(暂未接入)
  req?: number;     // 有值时表示这是"要回结果"的请求,处理完用 bshUiResolve(req, …) 回执
}

/** 页面交给 UIBus 的回调：事件里那些"只有页面才能做"的部分 */
export interface UiHost {
  /** 本窗口会话号 */
  sid: number;
  /** 虚拟键栏显隐；recoverBar=false 表示连恢复条一起收掉（bshutil keys hide） */
  setKeys: (show: boolean, recoverBar: boolean) => void;
  /** 右键模式 'menu' | 'smart'，页面据此决定是否盖那层 ArkUI 菜单宿主 */
  setRightClick: (mode: string) => void;
  /** 往该页面的 WebView 注入 JS */
  runJs: (js: string) => void;
}

export class UIBus {
  private static instance: UIBus | null = null;
  static getInstance(): UIBus {
    if (!UIBus.instance) {
      UIBus.instance = new UIBus();
    }
    return UIBus.instance;
  }

  private ctx: common.UIAbilityContext | null = null;
  private hosts: Map<number, UiHost> = new Map();

  init(ctx: common.UIAbilityContext): boolean {
    this.ctx = ctx;
    return true;
  }

  /** 页面就绪后登记并订阅 native 事件（sid 必须已认领）。 */
  register(host: UiHost): void {
    this.hosts.set(host.sid, host);
    try {
      bshUiSubscribe(host.sid, (json: string): void => { this.handle(host.sid, json); });
    } catch (e) {
      hilog.error(0x0000, TAG, 'subscribe failed sid=%{public}d: %{public}s', host.sid, JSON.stringify(e));
    }
  }

  /** 页面销毁时摘掉自己。native 侧的订阅没法从 ArkTS 主动注销（libentry 没导出
   *  bshUiUnsubscribe），残留的 tsfn 由 native 的 finalize 兜底；这里只管别再路由到死页面。 */
  unregister(sid: number): void {
    this.hosts.delete(sid);
  }

  private notice(sid: number, text: string): void {
    try { bshShellNotice(sid, text); } catch (e) { /* ignore */ }
  }

  private handle(sid: number, json: string): void {
    let ev: UiEvent = { op: '' };
    try { ev = JSON.parse(json) as UiEvent; } catch (e) { return; }
    const host = this.hosts.get(sid);
    if (ev.op === 'keys' && typeof ev.show === 'boolean') {
      if (host) {
        // 命令隐藏 = 彻底隐藏(连恢复条也不留),要靠 `bshutil keys show` 回来;
        // 显示时恢复条一起复位,下次界面按钮隐藏它才又出现。
        host.setKeys(ev.show, ev.show);
      }
    } else if (ev.op === 'scale' && typeof ev.value === 'number') {
      setUiScale(ev.value);
    } else if (ev.op === 'rightclick' && typeof ev.mode === 'string') {
      const mode = ev.mode === 'smart' ? 'smart' : 'menu';
      if (host) {
        host.setRightClick(mode);
        host.runJs('window.setRightClickMode(' + JSON.stringify(mode) + ')');
      }
    } else if (ev.op === 'picker') {
      // 带 req 的是"要回结果"的同步请求(native 阻塞等回执);不带的走终端提示
      this.runPicker(sid, ev.req);
    } else if (ev.op === 'newtab') {
      // ⚠ 带命令的 newtab(-e)暂时不接入：这里只开窗口，不把 ev.exec 写进会话。
      this.openNewTab(sid, ev.req).catch((e: Error): void => {
        hilog.error(0x0000, TAG, 'newtab failed %{public}s', JSON.stringify(e));
      });
    }
  }

  /** 系统目录选择器。带 req 的是 native 阻塞等的同步请求,处理完 bshUiResolve 放行;
   *  不带的只往终端回一句 notice。FOLDER 模式视设备/系统版本而定,不支持时兜成可读结果。 */
  private async runPicker(sid: number, reqId?: number): Promise<void> {
    const done = (text: string): void => {
      if (reqId !== undefined) {
        try { bshUiResolve(reqId, text); } catch (e) { /* ignore */ }
      } else {
        this.notice(sid, text);
      }
    };
    if (!this.ctx) {
      done('picker: 没有可用的 context');
      return;
    }
    try {
      const dv = new picker.DocumentViewPicker(this.ctx);
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      opt.selectMode = picker.DocumentSelectMode.FOLDER;
      const uris = await dv.select(opt);
      if (!uris || uris.length === 0) {
        done('picker: 已取消');
        return;
      }
      const uri = uris[0];
      // 裁掉 URI 前缀(file://docs/… 之类),从 /storage 开始显示
      const si = uri.indexOf('/storage');
      const path = si >= 0 ? uri.substring(si) : uri;
      done('已成功获取 ' + path + ' 的访问权限');
    } catch (e) {
      done('picker: 失败(该设备不支持目录选择,或用户中止) ' + JSON.stringify(e));
    }
  }

  private async openNewTab(sid: number, reqId?: number): Promise<void> {
    const newSid = await TerminalWindows.getInstance().newWindow('');
    const msg = newSid > 0 ? `New session started (Session ${newSid})`
                           : 'Failed to start new terminal window (no available session slot, or startAbility rejected)';
    if (reqId !== undefined) {
      try { bshUiResolve(reqId, msg); } catch (e) { /* ignore */ }
    } else {
      this.notice(sid, msg);
    }
  }
}
