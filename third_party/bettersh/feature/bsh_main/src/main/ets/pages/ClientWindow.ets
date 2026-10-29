// ClientWindow.ets — Wayland 客户端窗口页面（AppRunnerAbility 内容）
//
// 职责：
//   1. XComponent 承载渲染：onSurfaceCreated 拿 surfaceId → createRenderer
//   2. 输入采集：鼠标/键盘/滚轮 → WaymonyService 注入（按 toplevelId 路由）
import { hilog } from '@kit.PerformanceAnalysisKit';
import { OH2EVDEV, MOD_ALT, MOD_CAPS, MOD_CTRL, MOD_NUM, MOD_SHIFT, MOD_SUPER, modMaskOf } from '../utils/KeyMap';
import { mapMouseButton } from '../utils/MouseMap';
import { WaymonyService } from '../service/WaymonyService';
import napi from 'libentry.so';

// 注：XComponentController / XComponentType / KeyType / MouseEvent 均为 ArkUI 全局声明，
// 无需（且不能）从 Kit 导入。

const TAG = 'BSH_CW';

// 这个类型直接用 libentry.so 声明的那个(types/libentry/Index.d.ts 的 ToplevelInfo)，
// 不要在本文件另写一份同形状的 interface：ArkTS 不允许结构类型(arkts-no-structural-typing)，
// 两份"长得一样"的 interface 之间赋值会直接编译不过。
class ToplevelController extends XComponentController {
  private tl: number = 0;

  /** 页面在 aboutToAppear 时把 toplevelId 传进来（onSurfaceCreated 可能晚于页面构建） */
  setToplevel(id: number): void {
    this.tl = id;
  }

  // SDK 6.1.1 回调签名：surfaceId 为 string，尺寸在 SurfaceRect 中
  onSurfaceCreated(surfaceId: string): void {
    if (this.tl <= 0) {
      hilog.warn(0x0000, TAG, 'surface created without toplevel');
      return;
    }
    const id: number = Number(surfaceId);
    hilog.info(0x0000, TAG, 'surface created tl=%{public}d surfaceId=%{public}s',
      this.tl, surfaceId);
    // 尺寸未知，先以默认视口创建（onSurfaceChanged 会带真实尺寸）
    napi.createRenderer(this.tl, id, 640, 480);
  }

  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    if (this.tl <= 0) return;
    const w = rect.surfaceWidth;
    const h = rect.surfaceHeight;
    hilog.info(0x0000, TAG, 'surface changed tl=%{public}d %{public}dx%{public}d', this.tl, w, h);
    napi.resizeRenderer(this.tl, w, h);
    WaymonyService.getInstance().hostResize(this.tl, w, h);
  }

  onSurfaceDestroyed(surfaceId: string): void {
    if (this.tl > 0) {
      napi.destroyRenderer(this.tl);
    }
  }
}

// 同 Index，@Entry 由 product 侧的薄页面提供（AppRunnerAbility loadContent('pages/ClientWindow')）
@Component
export struct ClientWindow {
  private xcController: ToplevelController = new ToplevelController();
  private toplevelId: number = 0;
  // 已按下的 evdev 键集合（计算修饰键掩码用）
  private pressedKeys: Set<number> = new Set();
  // XComponent 物理像素尺寸（onAreaChange 记录，坐标比例映射用，参照 example-harmonybox）
  private surfacePxW: number = 1;
  private surfacePxH: number = 1;

  aboutToAppear(): void {
    // toplevelId 由 AppRunnerAbility 经 WMS.pending 传入（loadContent 的 LocalStorage
    // 传参在页面 @LocalStorageProp 读取不可靠，改回 pending 机制）
    this.toplevelId = WaymonyService.getInstance().takePendingToplevel();
    this.xcController.setToplevel(this.toplevelId);
    if (this.toplevelId <= 0) {
      hilog.warn(0x0000, TAG, 'ClientWindow without toplevel, closing');
    }
    // 请求组件焦点（窗口显示后自动聚焦，键盘事件直达终端，无需先点击窗口）
    setTimeout(() => {
      focusControl.requestFocus('term-root');
      hilog.info(0x0000, TAG, 'requestFocus term-root tl=%{public}d', this.toplevelId);
    }, 300);
  }

  aboutToDisappear(): void {
    if (this.toplevelId > 0) {
      napi.destroyRenderer(this.toplevelId);
    }
  }

  private computeMods(): number {
    let mask = 0;
    this.pressedKeys.forEach((code: number) => {
      if (code === 42 || code === 54) mask |= MOD_SHIFT;
      if (code === 29 || code === 97) mask |= MOD_CTRL;
      if (code === 56 || code === 100) mask |= MOD_ALT;
      if (code === 125 || code === 126) mask |= MOD_SUPER;
      if (code === 58) mask |= MOD_CAPS;
      if (code === 69) mask |= MOD_NUM;
    });
    return mask;
  }

  private sendModifiers(): void {
    napi.sendModifiers(this.toplevelId, this.computeMods(), 0, 0, 0);
  }

  private onMouseEvent(e: MouseEvent): void {
    if (this.toplevelId <= 0) return;
    const wm = WaymonyService.getInstance();
    // 窗口已销毁（客户端断开/关闭）后不再转发：native 侧资源已释放，避免竞态崩溃
    if (!wm.isToplevelAlive(this.toplevelId)) return;
    const session = wm.getResizeSession();
    hilog.info(0x0000, TAG, 'mouse tl=%{public}d action=%{public}d x=%{public}d y=%{public}d resize=%{public}d',
      this.toplevelId, e.action, Math.round(e.windowX), Math.round(e.windowY),
      session && session.id === this.toplevelId ? 1 : 0);
    // ── xdg resize 跟手模式（参照 example-harmonybox AppRunner）──
    if (session && session.id === this.toplevelId) {
      if (session.startVpX < 0) {
        session.startVpX = e.x;
        session.startVpY = e.y;
      }
      if (e.action === MouseAction.Move || e.action === MouseAction.Hover) {
        const dxPx = vp2px(e.x - session.startVpX);
        const dyPx = vp2px(e.y - session.startVpY);
        wm.onHostResizeDrag(dxPx, dyPx);
      } else if (e.action === MouseAction.Release) {
        wm.onHostResizeEnd();
      }
      return;
    }

    // 坐标映射：
    //   vp2px(ev.x) 组件内坐标 → 物理 px；× (bufW / surfacePxW) 按比例映射到客户端 buffer 坐标系。
    //   buffer 为全尺寸（含 CSD 阴影/标题栏），weston 的 frame 命中判定自然正确。
    const info = napi.getToplevelInfo(this.toplevelId);   // 类型来自 libentry.so 的声明
    const bufW = info.w;
    const bufH = info.h;
    if (bufW <= 0 || bufH <= 0 || this.surfacePxW <= 0 || this.surfacePxH <= 0) return;
    const x = Math.round(vp2px(e.x) * bufW / this.surfacePxW);
    const y = Math.round(vp2px(e.y) * bufH / this.surfacePxH);
    switch (e.action) {
      case MouseAction.Press:
        // 先补发 motion（weston 用最后一次 motion 坐标处理点击）。
        // 注意：不能在这里发 enter——DispatchMouseEnter(0,0) 会把 weston 的 focus
        // 设到窗口左上角（frame 区域），随后 button 发给 frame 被吞掉，点击无响应。
        // enter 只由 onHover(true) 触发（参照 example-harmonybox）。
        napi.sendMouseMove(this.toplevelId, x, y);
        napi.sendMouseButton(this.toplevelId, mapMouseButton(e.button), true);
        break;
      case MouseAction.Release:
        napi.sendMouseButton(this.toplevelId, mapMouseButton(e.button), false);
        break;
      case MouseAction.Move:
      case MouseAction.Hover:
        napi.sendMouseMove(this.toplevelId, x, y);
        break;
      default:
        break;
    }
    // 注：V1 未桥接鼠标滚轮（ArkUI MouseEvent 无滚轮增量字段），见 ARCHITECTURE.md 已知限制
  }

  private onHoverChange(isHover: boolean): void {
    if (this.toplevelId <= 0) return;
    const wm = WaymonyService.getInstance();
    if (!wm.isToplevelAlive(this.toplevelId)) return;
    if (!isHover) {
      // 鼠标移出窗口：结束可能的 resize 会话（防止 Release 丢失导致会话残留，
      // 残留会让后续所有鼠标事件被当成缩放拖动）
      const session = wm.getResizeSession();
      if (session && session.id === this.toplevelId) {
        wm.onHostResizeEnd();
      }
    }
    napi.sendMouseEnterLeave(this.toplevelId, isHover);
  }

  private handleKeyEvent(e: KeyEvent): void {
    if (this.toplevelId <= 0) return;
    if (!WaymonyService.getInstance().isToplevelAlive(this.toplevelId)) return;
    const code = OH2EVDEV[e.keyCode];
    if (code === undefined) return;
    const pressed = e.type === KeyType.Down;

    if (pressed) {
      this.pressedKeys.add(code);
    } else {
      this.pressedKeys.delete(code);
    }
    napi.sendKey(this.toplevelId, code, pressed);
    // 修饰键变化时更新掩码（modMaskOf 判断本键是否修饰键）
    if (modMaskOf(e.keyCode) !== 0) {
      this.sendModifiers();
    }
  }

  build() {
    Column() {
      XComponent({
        type: XComponentType.SURFACE,
        controller: this.xcController,
      })
        .onLoad(() => {
          hilog.info(0x0000, TAG, 'XComponent loaded tl=%{public}d', this.toplevelId);
        })
        .width('100%')
        .height('100%')
    }
    .id('term-root')
    .width('100%')
    .height('100%')
    .focusable(true)
    .defaultFocus(true)
    .onAreaChange((_o: Area, n: Area): void => {
      this.surfacePxW = vp2px(n.width as number);
      this.surfacePxH = vp2px(n.height as number);
    })
    .onMouse((e: MouseEvent): void => this.onMouseEvent(e))
    .onHover((isHover: boolean): void => this.onHoverChange(isHover))
    .onKeyEvent((e: KeyEvent): boolean => {
      this.handleKeyEvent(e);
      return false;
    })
  }
}
