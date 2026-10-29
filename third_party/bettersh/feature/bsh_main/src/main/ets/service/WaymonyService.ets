// WaymonyService.ets — toplevel ↔ 独立 Ability 窗口生命周期管理
//
// 每个 Wayland 客户端窗口 = 一个独立 AppRunnerAbility
// （multiton），startAbility 传参创建；窗口操作通过 Ability 的 mainWindow。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { setToplevelCallback, sendToplevelClose } from 'libentry.so';

const TAG = 'BSH_WS';

/** 宿主窗口显示缩放：默认 2 = 200%。
 *  SubWindow/XComponent 尺寸 = 客户端逻辑尺寸 × UI_SCALE，
 *  EGL 渲染器把 wl_shm 纹理拉伸到 surface 全尺寸，实现等比放大；
 *  输入坐标需 ÷ UI_SCALE 映射回客户端逻辑坐标。
 *
 *  这个值可以在终端里用 `bshutil set win-scale <n>` 改(存 native 的 bettersh.conf);
 *  改完经 ui 事件送到 WebTerminal,由 setUiScale 更新这里 —— 只影响**新开**的窗口。 */
export let UI_SCALE = 2;

export function setUiScale(v: number): void {
  if (v > 0) UI_SCALE = v;
}

const MIN_RESIZE_W = 200;   // resize 拖动最小尺寸（px）
const MIN_RESIZE_H = 120;
const RESIZE_CONFIGURE_MS = 80;  // resize 拖动期间回发 configure 的节流

interface CreatedJson {
  title?: string;
  w?: number;
  h?: number;
}

interface SizeJson {
  w?: number;
  h?: number;
}

interface TitleJson {
  title?: string;
}

interface ResizeJson {
  edges?: number;
}

interface RectLike {
  left: number;
  top: number;
  width: number;
  height: number;
}

interface WindowRecord {
  win: window.Window | null;       // AppRunnerAbility 的 mainWindow（异步注册）
  context: common.UIAbilityContext | null;  // 用于 terminateSelf
  lastW: number;
  lastH: number;
  destroyed: boolean;
}

/** xdg resize 跟手会话（ClientWindow.onMouse 查询 + 驱动） */
export interface ResizeSession {
  id: number;
  edges: number;
  startX: number;
  startY: number;
  startW: number;
  startH: number;
  startVpX: number;  // 按下时鼠标在组件内的 vp 坐标（由 ClientWindow 首次 Move 记录）
  startVpY: number;
  lastConfigure: number;
  lastActivity: number;  // 防残留：超时无活动自动清理
}

export class WaymonyWindowManager {
  private static instance: WaymonyWindowManager | null = null;

  static getInstance(): WaymonyWindowManager {
    if (!WaymonyWindowManager.instance) {
      WaymonyWindowManager.instance = new WaymonyWindowManager();
    }
    return WaymonyWindowManager.instance;
  }

  private ctx: common.UIAbilityContext | null = null;
  private windows: Map<number, WindowRecord> = new Map();
  private pendingToplevelId: number = 0;
  private resizeSession: ResizeSession | null = null;
  private eventSink: (id: number, event: string, json: string) => void =
    (id: number, event: string, json: string): void => {
      this.onToplevelEvent(id, event, json);
    };

  /** AppRunnerAbility loadContent 前注册当前 toplevelId（ClientWindow 取走即清） */
  setPendingToplevel(id: number): void {
    this.pendingToplevelId = id;
  }

  /** ClientWindow 页面在 aboutToAppear 时取走 toplevelId（取走即清，防多窗口串号） */
  takePendingToplevel(): number {
    const id = this.pendingToplevelId;
    this.pendingToplevelId = 0;
    return id;
  }

  getWindowCount(): number {
    return this.windows.size;
  }

  /** toplevel 是否仍存活（窗口销毁后的事件转发应短路，避免打到已释放的 compositor 资源） */
  isToplevelAlive(id: number): boolean {
    const rec = this.windows.get(id);
    return !!rec && !rec.destroyed;
  }

  /** 第一个存活的 toplevel id（主界面"关闭终端"用），无则 0 */
  getFirstAliveToplevel(): number {
    let first = 0;
    this.windows.forEach((rec, id) => {
      if (first === 0 && !rec.destroyed) first = id;
    });
    return first;
  }

  init(ctx: common.UIAbilityContext): void {
    this.ctx = ctx;
    this.start();
  }

  start(): void {
    setToplevelCallback(this.eventSink);
  }

  stop(): void {
    this.resizeSession = null;
    // 关闭所有子窗口
    const ids: number[] = [];
    this.windows.forEach((rec, id) => {
      rec.destroyed = true;
      ids.push(id);
    });
    for (const id of ids) {
      this.destroyWindow(id);
    }
    this.windows.clear();
  }

  private onToplevelEvent(id: number, event: string, json: string): void {
    hilog.info(0x0000, TAG, 'toplevel event id=%{public}d event=%{public}s json=%{public}s',
      id, event, json);
    switch (event) {
      case 'created': {
        let w = 640;
        let h = 480;
        let title = 'Wayland Client';
        try {
          const j = JSON.parse(json) as CreatedJson;
          if (j.title) title = j.title;
          if (j.w && j.w > 0) w = j.w;
          if (j.h && j.h > 0) h = j.h;
        } catch (e) {
          // json 解析失败用默认值
        }
        this.createWindow(id, title, w, h);
        break;
      }
      case 'destroyed':
        this.destroyWindow(id);
        break;
      case 'title': {
        const j = JSON.parse(json) as TitleJson;
        const rec = this.windows.get(id);
        if (rec && j.title && rec.win) {
          rec.win.setWindowTitle(j.title).catch((): void => { /* ignore */ });
        }
        break;
      }
      case 'resize': {
        const j = JSON.parse(json) as SizeJson;
        const rec = this.windows.get(id);
        if (rec && j.w && j.h) {
          this.resizeWindow(id, j.w, j.h);
        }
        break;
      }
      case 'maximize': {
        const rec = this.windows.get(id);
        if (rec && rec.win) {
          rec.win.maximize().catch((): void => { /* ignore */ });
          // 显式回发 configure（maximized + 屏幕可用尺寸），让客户端立即按新尺寸重排
          try {
            const di = display.getDefaultDisplaySync();
            this.notifyConfigure(id, di.availableWidth, di.availableHeight);
          } catch (e) {
            hilog.warn(0x0000, TAG, 'maximize configure failed: %{public}s', JSON.stringify(e));
          }
        }
        break;
      }
      case 'unmaximize': {
        const rec = this.windows.get(id);
        if (rec && rec.win) {
          rec.win.restore().catch((): void => { /* ignore */ });
          this.notifyConfigure(id, rec.lastW, rec.lastH);
        }
        break;
      }
      case 'minimize': {
        const rec = this.windows.get(id);
        if (rec && rec.win) {
          rec.win.minimize().catch((): void => { /* ignore */ });
        }
        break;
      }
      case 'move': {
        // 客户端请求拖动（按住标题栏）→ 鸿蒙系统接管拖动手势
        const rec = this.windows.get(id);
        if (rec && rec.win) {
          rec.win.startMoving().catch((e: Error): void => {
            hilog.warn(0x0000, TAG, 'startMoving failed tl=%{public}d: %{public}s',
              id, JSON.stringify(e));
          });
        }
        break;
      }
      case 'resize_req': {
        // 客户端请求调整大小（拖边缘）→ 进入跟手会话（ClientWindow.onMouse 驱动）
        const j = JSON.parse(json) as ResizeJson;
        const rec = this.windows.get(id);
        if (rec && j.edges !== undefined) {
          this.beginResize(id, j.edges);
        }
        break;
      }
      default:
        break;
    }
  }

  private createWindow(id: number, title: string, w: number, h: number): void {
    // const ctx = WaymonyService.getInstance().getContext();
    if (!this.ctx) {
      hilog.error(0x0000, TAG, 'no context for ability launch');
      return;
    }
    // 显示尺寸 = 客户端逻辑尺寸 × UI_SCALE（200% 缩放）
    const totalW = Math.max(1, Math.round(w * UI_SCALE));
    const totalH = Math.max(1, Math.round(h * UI_SCALE));
    this.windows.set(id, { win: null, context: null, lastW: totalW, lastH: totalH, destroyed: false });
    const parameters: Record<string, Object> = {
      'toplevelId': id,
      'title': title,
      'w': w,
      'h': h,
    };
    const want: Want = {
      bundleName: this.ctx.abilityInfo.bundleName,
      // AppRunnerAbility 与实际调用方 EntryAbility 同属一个 entry 模块，而模块名随分包
      // 变（tablet / phone），所以取调用方自己的 moduleName，不能在共享层写死。
      moduleName: this.ctx.abilityInfo.moduleName,
      abilityName: 'AppRunnerAbility',
      parameters: parameters,
    };
    this.ctx.startAbility(want).then((): void => {
      hilog.info(0x0000, TAG, 'AppRunnerAbility started tl=%{public}d %{public}dx%{public}d (logical %{public}dx%{public}d)',
        id, totalW, totalH, w, h);
    }).catch((e: Error): void => {
      hilog.error(0x0000, TAG, 'startAbility failed tl=%{public}d: %{public}s', id, JSON.stringify(e));
      this.windows.delete(id);
    });
  }

  /** AppRunnerAbility.onWindowStageCreate 注册 mainWindow + context */
  attachAbilityWindow(id: number, win: window.Window, ctx: common.UIAbilityContext): void {
    const rec = this.windows.get(id);
    if (!rec || rec.destroyed) return;
    rec.win = win;
    rec.context = ctx;
    // 初始尺寸（Ability 窗口默认创建尺寸，按 200% 缩放设置）
    win.resize(rec.lastW, rec.lastH).then((): void => {
      win.moveWindowTo(80 + (id % 6) * 40, 80 + (id % 5) * 40).catch((): void => { /* ignore */ });
    }).catch((): void => { /* ignore */ });
    hilog.info(0x0000, TAG, 'ability window attached tl=%{public}d %{public}dx%{public}d', id, rec.lastW, rec.lastH);
  }

  detachAbilityWindow(id: number): void {
    const rec = this.windows.get(id);
    if (!rec) return;
    // 宿主窗口被用户关闭:给 guest 发 xdg close,客户端收到后自行退出
    // (客户端退出后服务端会再发 'destroyed',那时 rec 已移除,不会重复处理)
    if (!rec.destroyed) {
      rec.destroyed = true;
      sendToplevelClose(id);
    }
    rec.win = null;
    rec.context = null;
    this.windows.delete(id);
  }

  /** 客户端帧尺寸变化 → 调整窗口（×UI_SCALE；去抖：宿主尺寸未变则跳过） */
  private resizeWindow(id: number, w: number, h: number): void {
    const rec = this.windows.get(id);
    if (!rec || rec.destroyed) return;
    const totalW = Math.max(1, Math.round(w * UI_SCALE));
    const totalH = Math.max(1, Math.round(h * UI_SCALE));
    if (rec.lastW === totalW && rec.lastH === totalH) return;
    rec.lastW = totalW;
    rec.lastH = totalH;
    if (rec.win) {
      rec.win.resize(totalW, totalH).catch((): void => { /* ignore */ });
    }
    // 客户端主导的尺寸变化：不需要回发 configure（客户端已按自己尺寸渲染）
  }

  /**
   * 鸿蒙侧子窗口尺寸变化（XComponent onSurfaceChanged）。
   * 仅记录尺寸供去抖，【不发 configure】：客户端主导的尺寸变化已由 resizeWindow 同步窗口，
   * 这里再 configure 会让客户端重排出略有差异的尺寸 → surface 再变 → configure → 无限漂移回环。
   * configure 只由用户主动操作发出：resize 会话（onHostResizeDrag/onHostResizeEnd）、
   * maximize/unmaximize。
   */
  hostResize(id: number, w: number, h: number): void {
    const rec = this.windows.get(id);
    if (!rec || rec.destroyed) return;
    rec.lastW = w;
    rec.lastH = h;
  }

  /** 宿主尺寸 → 客户端逻辑尺寸（÷UI_SCALE）→ xdg configure */
  private notifyConfigure(id: number, hostW: number, hostH: number): void {
    // todo
    // WaymonyService.getInstance().notifyToplevelResize(id,
    //   Math.max(1, Math.round(hostW / UI_SCALE)),
    //   Math.max(1, Math.round(hostH / UI_SCALE)));
  }

  // ==== xdg resize 跟手会话 ====

  /** ClientWindow.onMouse 查询当前 resize 会话（匹配自己的 toplevelId 才跟手；超时自动清理） */
  getResizeSession(): ResizeSession | null {
    const s = this.resizeSession;
    if (s && Date.now() - s.lastActivity > 3000) {
      hilog.warn(0x0000, TAG, 'resize session stale, discarding tl=%{public}d', s.id);
      this.resizeSession = null;
      return null;
    }
    return s;
  }

  private beginResize(id: number, edges: number): void {
    // 防残留：上一个会话未正常结束（Release 丢失）时先清理
    if (this.resizeSession) {
      hilog.warn(0x0000, TAG, 'beginResize while session active, discarding old tl=%{public}d',
        this.resizeSession.id);
      this.resizeSession = null;
    }
    const rec = this.windows.get(id);
    if (!rec || rec.destroyed) return;
    try {
      let r: RectLike;
      if (rec.win) {
        const wr = rec.win.getWindowProperties().windowRect;
        r = { left: wr.left, top: wr.top, width: wr.width, height: wr.height };
      } else {
        r = { left: 0, top: 0, width: rec.lastW, height: rec.lastH };
      }
      this.resizeSession = {
        id,
        edges,
        startX: r.left, startY: r.top,
        startW: r.width, startH: r.height,
        startVpX: -1, startVpY: -1,   // 由 ClientWindow 首次 Move 填充
        lastConfigure: 0,
        lastActivity: Date.now(),
      };
      hilog.info(0x0000, TAG, 'resize begin tl=%{public}d edges=%{public}d rect=%{public}d,%{public}d %{public}dx%{public}d',
        id, edges, r.left, r.top, r.width, r.height);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'beginResize failed: %{public}s', JSON.stringify(e));
      this.resizeSession = null;
    }
  }

  /** ClientWindow 跟手回调：dxPx/dyPx 为鼠标相对起点的位移（px） */
  onHostResizeDrag(dxPx: number, dyPx: number): void {
    const s = this.resizeSession;
    if (!s) return;
    s.lastActivity = Date.now();
    const rec = this.windows.get(s.id);
    if (!rec || rec.destroyed) return;

    let newX = s.startX, newY = s.startY;
    let newW = s.startW, newH = s.startH;
    // edges 位图（xdg_resize_edge）：1=top 2=bottom 4=left 8=right
    if ((s.edges & 1) !== 0) { newY = s.startY + dyPx; newH = s.startH - dyPx; }
    if ((s.edges & 2) !== 0) { newH = s.startH + dyPx; }
    if ((s.edges & 4) !== 0) { newX = s.startX + dxPx; newW = s.startW - dxPx; }
    if ((s.edges & 8) !== 0) { newW = s.startW + dxPx; }

    if (newW < MIN_RESIZE_W) {
      if ((s.edges & 4) !== 0) newX = s.startX + s.startW - MIN_RESIZE_W;
      newW = MIN_RESIZE_W;
    }
    if (newH < MIN_RESIZE_H) {
      if ((s.edges & 1) !== 0) newY = s.startY + s.startH - MIN_RESIZE_H;
      newH = MIN_RESIZE_H;
    }

    const win = rec.win;
    if (!win) return;
    win.resize(newW, newH).then((): void => {
      win.moveWindowToGlobal(newX, newY).catch((): void => { /* ignore */ });
    }).catch((e: Error): void => {
      hilog.warn(0x0000, TAG, 'resize drag failed: %{public}s', JSON.stringify(e));
    });

    // 80ms 节流回发 configure（客户端按新逻辑尺寸重排）
    const now = Date.now();
    if (now - s.lastConfigure >= RESIZE_CONFIGURE_MS) {
      s.lastConfigure = now;
      this.notifyConfigure(s.id, newW, newH);
    }
  }

  /** 拖拽结束：用最终窗口尺寸补一次 configure，清会话 */
  onHostResizeEnd(): void {
    const s = this.resizeSession;
    this.resizeSession = null;
    if (!s) return;
    const rec = this.windows.get(s.id);
    if (!rec || rec.destroyed || !rec.win) return;
    try {
      const r = rec.win.getWindowProperties().windowRect;
      this.notifyConfigure(s.id, r.width, r.height);
      hilog.info(0x0000, TAG, 'resize end tl=%{public}d final=%{public}dx%{public}d',
        s.id, r.width, r.height);
    } catch (e) { /* ignore */ }
  }

  private destroyWindow(id: number): void {
    const rec = this.windows.get(id);
    if (!rec) return;
    // 终止对应的 AppRunnerAbility 实例（context.terminateSelf）
    if (!rec.destroyed) {
      rec.destroyed = true;
      // 通知 guest 客户端关闭(xdg_toplevel.close),否则终端不会自动恢复
      sendToplevelClose(id);
      if (rec.context) {
        rec.context.terminateSelf().catch((): void => { /* ignore */ });
      }
    }
    this.windows.delete(id);
    // WaymonyService.getInstance().destroyRenderer(id);
    hilog.info(0x0000, TAG, 'toplevel destroyed tl=%{public}d', id);
  }
}

export { WaymonyWindowManager as WaymonyService };
