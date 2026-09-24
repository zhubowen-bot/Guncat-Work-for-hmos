/**
 * 开屏飞入动效组件（与业务解耦的通用入口动效）
 *
 * 特性：
 * - aboutToAppear 自动触发，aboutToDisappear 自动停止
 * - 从中心到外围依次弹性飞入
 * - 支持 HMOS（从后方变小聚拢）与 iOS（从前方放大聚集）两种风格
 * - 使用 @State 数组驱动，不侵入内部组件样式
 * - 交错 setTimeout + animateTo，不用 Promise 串行
 * - 可选模糊渐变
 */
import { curves } from '@kit.ArkUI';

// ==== 动画状态（只跟动画有关） ====
export interface FlyItemState {
  scale: number;
  opacity: number;
  centerOffsetX: number;
  centerOffsetY: number;
  blur: number;
}

// ==== 元素定义（最终位置 + 业务数据） ====
export class FlyItemDef {
  x: number = 0;            // 最终 X 坐标（vpx，相对内容区域左上角）
  y: number = 0;            // 最终 Y 坐标（vpx，相对内容区域左上角）
  title: string = '';
  icon: Resource = $r('app.media.cat_avatar');
  isSymbol: boolean = false;
  isCenter: boolean = false;

  constructor(x: number, y: number, title: string, icon: Resource, isSymbol: boolean,
    isCenter: boolean = false) {
    this.x = x;
    this.y = y;
    this.title = title;
    this.icon = icon;
    this.isSymbol = isSymbol;
    this.isCenter = isCenter;
  }
}

@Component
export struct FlyInLaunchView {
  // ==== 可配置参数 ====
  @Prop style: string = 'harmony';       // 'harmony' | 'ios'
  @Prop showCenter: boolean = true;
  @Prop @Watch('onReplayTokenChange') replayToken: number = 0;
  @Prop cols: number = 3;
  @Prop rows: number = 3;
  @Prop itemSize: number = 72;
  @Prop spacing: number = 18;
  @Prop baseDelay: number = 32;         // 相邻元素飞入间隔
  @Prop duration: number = 420;         // 单个元素飞入时长
  @Prop blurEnabled: boolean = false;
  @Prop autoDismiss: boolean = true;    // 飞入结束后自动淡出
  @Prop dismissDelay: number = 500;     // 自动淡出前的停留时间
  private onFinish: () => void = (): void => {};

  // ==== 动画状态 ====
  @State itemDefs: FlyItemDef[] = [];
  @State itemStates: FlyItemState[] = [];
  @State introDone: boolean = false;

  private timers: number[] = [];
  private dismissTimer: number = -1;

  aboutToAppear(): void {
    this.buildItemDefs();
    this.startAnimation();
  }

  aboutToDisappear(): void {
    this.stopAllTimers();
  }

  private stopAllTimers(): void {
    for (let i: number = 0; i < this.timers.length; i++) {
      clearTimeout(this.timers[i]);
    }
    this.timers = [];
    if (this.dismissTimer !== -1) {
      clearTimeout(this.dismissTimer);
      this.dismissTimer = -1;
    }
  }

  onReplayTokenChange(): void {
    if (this.replayToken > 0) {
      this.startAnimation();
    }
  }

  private buildItemDefs(): void {
    const defs: FlyItemDef[] = [];
    const symbolIcons: Resource[] = [
      $r('sys.symbol.square_grid_2x2'),
      $r('sys.symbol.speaker_wave_3'),
      $r('sys.symbol.camera_fill'),
      $r('sys.symbol.paperplane'),
      $r('sys.symbol.mic_fill'),
      $r('sys.symbol.info_circle'),
      $r('sys.symbol.waveform'),
      $r('sys.symbol.dot_grid_2x2')
    ];
    let symbolIndex: number = 0;
    for (let r: number = 0; r < this.rows; r++) {
      for (let c: number = 0; c < this.cols; c++) {
        const x: number = c * (this.itemSize + this.spacing);
        const y: number = r * (this.itemSize + this.spacing);
        const isCenter: boolean =
          (r === Math.floor(this.rows / 2)) && (c === Math.floor(this.cols / 2));
        if (isCenter) {
          if (this.showCenter) {
            defs.push(new FlyItemDef(x, y, '', $r('app.media.cat_avatar'), false, true));
          }
        } else {
          const icon: Resource = symbolIcons[symbolIndex % symbolIcons.length];
          symbolIndex++;
          defs.push(new FlyItemDef(x, y, '', icon, true));
        }
      }
    }
    this.itemDefs = defs;
  }

  private totalWidth(): number {
    return this.cols * this.itemSize + (this.cols - 1) * this.spacing;
  }

  private totalHeight(): number {
    return this.rows * this.itemSize + (this.rows - 1) * this.spacing;
  }

  private centerX(): number {
    return this.totalWidth() / 2;
  }

  private centerY(): number {
    return this.totalHeight() / 2;
  }

  private offsetSign(): number {
    return this.style === 'ios' ? -1 : 1;
  }

  private initScale(): number {
    return this.style === 'ios' ? 1.8 : 0.2;
  }

  private distanceToCenter(def: FlyItemDef): number {
    const dx: number = (def.x + this.itemSize / 2) - this.centerX();
    const dy: number = (def.y + this.itemSize / 2) - this.centerY();
    return Math.sqrt(dx * dx + dy * dy);
  }

  private buildInitialState(index: number): FlyItemState {
    const def: FlyItemDef = this.itemDefs[index];
    const sign: number = this.offsetSign();
    const offsetX: number = (this.centerX() - def.x) * 0.65 * sign;
    const offsetY: number = (this.centerY() - def.y) * 0.65 * sign;
    return {
      scale: this.initScale(),
      opacity: 1,
      centerOffsetX: offsetX,
      centerOffsetY: offsetY,
      blur: this.blurEnabled ? 20 : 0
    };
  }

  private startAnimation(): void {
    this.stopAllTimers();
    this.introDone = false;

    // 初始化每个元素的起始状态（聚拢/发散偏移、透明、缩放、模糊）
    const states: FlyItemState[] = [];
    for (let i: number = 0; i < this.itemDefs.length; i++) {
      states.push(this.buildInitialState(i));
    }
    this.itemStates = states;

    // 按欧氏距离从中心到外围排序，近的先飞
    const order: number[] = [];
    for (let i: number = 0; i < this.itemDefs.length; i++) {
      order.push(i);
    }
    order.sort((a: number, b: number): number => {
      return this.distanceToCenter(this.itemDefs[a]) - this.distanceToCenter(this.itemDefs[b]);
    });

    // 交错 setTimeout + animateTo 触发飞入
    for (let i: number = 0; i < order.length; i++) {
      const idx: number = order[i];
      const timer: number = setTimeout(() => {
        this.getUIContext()?.animateTo({
          duration: this.duration,
          curve: curves.springMotion()
        }, () => {
          const next: FlyItemState[] = this.itemStates.slice();
          next[idx] = {
            scale: 1,
            opacity: 1,
            centerOffsetX: 0,
            centerOffsetY: 0,
            blur: 0
          };
          this.itemStates = next;
        });
      }, i * this.baseDelay);
      this.timers.push(timer);
    }

    const totalTime: number = (this.itemDefs.length - 1) * this.baseDelay + this.duration;
    const fadeDelay: number = this.autoDismiss ? Math.max(totalTime + 80, this.dismissDelay) : totalTime + 60;
    this.dismissTimer = setTimeout(() => {
      // 先让周边元素淡出，中央图标保持可见
      this.getUIContext()?.animateTo({
        duration: 220,
        curve: Curve.EaseOut
      }, () => {
        const next: FlyItemState[] = this.itemStates.slice();
        for (let i: number = 0; i < this.itemDefs.length; i++) {
          if (!this.itemDefs[i].isCenter) {
            next[i] = {
              scale: 1,
              opacity: 0,
              centerOffsetX: 0,
              centerOffsetY: 0,
              blur: 0
            };
          }
        }
        this.itemStates = next;
      });

      // 周边元素淡出后，直接让宿主页面接管 hero 图标的一镜到底
      this.dismissTimer = setTimeout(() => {
        this.introDone = true;
        this.onFinish();
      }, 240);
    }, fadeDelay);
  }

  build() {
    Stack() {
      // 全屏背景
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.background'))

      // 飞入网格内容区域
      Stack() {
        ForEach(this.itemDefs, (def: FlyItemDef, index: number) => {
          this.FlyItem(def, index)
        }, (def: FlyItemDef, index: number) => `${index}`)
      }
      .width(this.totalWidth())
      .height(this.totalHeight())
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'))
    .hitTestBehavior(this.introDone ? HitTestMode.None : HitTestMode.Default)
    .zIndex(100)
    // 启动页铺满系统安全区，避免底部/顶部露出系统默认白块
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM, SafeAreaEdge.TOP])
  }

  @Builder
  FlyItem(def: FlyItemDef, index: number) {
    if (def.isCenter) {
      // 中央头像：geometryTransition 绑定在外层容器，与空状态容器结构一致，减少闪烁
      Column() {
        Image(def.icon)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      }
      .width(this.itemSize)
      .height(this.itemSize)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .position({ x: def.x, y: def.y })
      .translate({
        x: this.itemStates[index] !== undefined ? this.itemStates[index].centerOffsetX : 0,
        y: this.itemStates[index] !== undefined ? this.itemStates[index].centerOffsetY : 0
      })
      .scale({
        x: this.itemStates[index] !== undefined ? this.itemStates[index].scale : 1,
        y: this.itemStates[index] !== undefined ? this.itemStates[index].scale : 1
      })
      .opacity(this.itemStates[index] !== undefined ? this.itemStates[index].opacity : 0)
      .backgroundColor($r('app.color.brand_light'))
      .borderRadius(this.itemSize / 2)
      .shadow({ radius: 24, color: '#1A000000', offsetX: 0, offsetY: 8 })
      .clip(true)
      .geometryTransition('launch_icon')
      .id('launch_icon_source')
      .transition(TransitionEffect.OPACITY.animation({ duration: 0, curve: Curve.Linear }))
    } else {
      Column() {
        if (def.isSymbol) {
          SymbolGlyph(def.icon)
            .fontSize(this.itemSize * 0.42)
            .fontColor([$r('app.color.brand')])
        } else {
          Image(def.icon)
            .width(this.itemSize - 12)
            .height(this.itemSize - 12)
            .borderRadius((this.itemSize - 12) / 2)
            .objectFit(ImageFit.Cover)
            .backgroundColor($r('app.color.brand_light'))
        }
      }
      .width(this.itemSize)
      .height(this.itemSize)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .position({ x: def.x, y: def.y })
      .translate({
        x: this.itemStates[index] !== undefined ? this.itemStates[index].centerOffsetX : 0,
        y: this.itemStates[index] !== undefined ? this.itemStates[index].centerOffsetY : 0
      })
      .scale({
        x: this.itemStates[index] !== undefined ? this.itemStates[index].scale : 1,
        y: this.itemStates[index] !== undefined ? this.itemStates[index].scale : 1
      })
      .opacity(this.itemStates[index] !== undefined ? this.itemStates[index].opacity : 0)
    }
  }
}
