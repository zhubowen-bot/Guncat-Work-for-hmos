/**
 * API 26 沉浸光感（immersive light sense）统一适配层。
 *
 * 背景：
 * - 从 API 26.0.0 起 ArkUI 提供沉浸式系统材质（uiMaterial），沉浸光感开启后由系统
 *   接管组件的背景色、边框、阴影等视觉属性。应用级开关在 entry/src/main/module.json5
 *   的 metadata「ohos.arkui.UIMaterial.state = enable」中配置。
 * - 材质等级（MaterialLevel：EXQUISITE / GENTLE / SMOOTH）由设备算力决定，应用侧
 *   只能读取、不能指定；高算力设备自动呈现完整的 EXQUISITE 效果，低算力设备由系统
 *   自动降级。因此这里不做「档位自适应（ADAPTIVE）」式的分级，只在应用侧按档位决定
 *   是否叠加交互形变、光感反馈与自动反色这类额外开销，低算力设备上保持轻量。
 * - compatibleSdkVersion 仍为 6.1.1(24)：按官方 ArkTS API 兼容性保护要求，所有
 *   API 26 接口都必须包在 `if (deviceInfo.apiAvailable('26.0.0'))` 字面量判断内，
 *   低版本设备返回 undefined，调用方按「无材质」处理，不产生崩溃。
 *
 * 用法（以组件级开启为例，应用级开关已覆盖的系统组件无需逐个设置）：
 *   .bindPopup(this.open, {
 *     builder: this.buildPopup,
 *     systemMaterial: ImmersiveLight.menuMaterial()
 *   })
 */
import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';

/**
 * 沉浸式系统材质的用途分类。不同用途对应官方推荐的材质样式（ImmersiveStyle）
 * 与交互参数，避免各调用点各写一套参数。
 */
export enum ImmersiveSurface {
  /** 标题栏 / 浮动工具栏：官方推荐 ULTRA_THIN，保持背景通透。 */
  BAR = 0,
  /** 选择、开关、滑条等控件：官方推荐 ULTRA_THIN，配合交互形变与光感反馈。 */
  CONTROL = 1,
  /** 菜单、气泡、半模态：官方推荐 THICK，与底层内容拉开层次。 */
  MENU = 2,
  /** 弹窗、Toast：官方推荐 ULTRA_THICK，保证弹窗内容可读。 */
  DIALOG = 3,
  /** 即时反馈 Toast：官方推荐 THICK。 */
  TOAST = 4
}

export class ImmersiveLight {
  /** 设备是否支持沉浸式系统材质的探测结果缓存：-1 未探测 / 0 不支持 / 1 支持。 */
  private static probeState: number = -1;
  /** 设备材质等级缓存（uiMaterial.MaterialLevel 的数值，避免模块加载期访问新接口）。 */
  private static deviceLevel: number = -1;

  /**
   * 当前设备是否支持沉浸式系统材质。需同时满足：系统 API >= 26、设备支持材质能力。
   * 应用级开关是否 enable 不影响本方法，只影响系统组件是否默认生效。
   */
  static isAvailable(): boolean {
    if (ImmersiveLight.probeState === -1) {
      ImmersiveLight.probe();
    }
    return ImmersiveLight.probeState === 1;
  }

  /**
   * 设备材质等级（对应 uiMaterial.MaterialLevel 的数值）：0 EXQUISITE / 1 GENTLE / 2 SMOOTH。
   * 未探测或不支持时返回 -1。仅供排查与调试使用，调用方不需要按等级写分支。
   */
  static level(): number {
    if (ImmersiveLight.probeState === -1) {
      ImmersiveLight.probe();
    }
    return ImmersiveLight.deviceLevel;
  }

  /** 标题栏 / 浮动工具栏材质。 */
  static barMaterial(): uiMaterial.Material | undefined {
    return ImmersiveLight.material(ImmersiveSurface.BAR);
  }

  /** 选择、开关、滑条等控件材质（带交互形变与光感反馈）。 */
  static controlMaterial(): uiMaterial.Material | undefined {
    return ImmersiveLight.material(ImmersiveSurface.CONTROL);
  }

  /** 菜单 / 气泡 / 半模态材质。 */
  static menuMaterial(): uiMaterial.Material | undefined {
    return ImmersiveLight.material(ImmersiveSurface.MENU);
  }

  /** 弹窗 / Toast 材质。 */
  static dialogMaterial(): uiMaterial.Material | undefined {
    return ImmersiveLight.material(ImmersiveSurface.DIALOG);
  }

  /** 即时反馈 Toast 材质（官方默认 THICK）。 */
  static toastMaterial(): uiMaterial.Material | undefined {
    return ImmersiveLight.material(ImmersiveSurface.TOAST);
  }

  /**
   * 环境诊断文本，供设置页「终端」展示：应用级开关状态 · 设备能力 · 材质等级。
   * 用来快速判断「看不到沉浸光感」是系统/设备原因还是界面原因。
   */
  static describe(): string {
    if (!deviceInfo.apiAvailable('26.0.0')) {
      return '系统低于 API 26，无沉浸光感';
    }
    let appState: string = '应用级默认';
    // 兼容性保护：API 26 接口都在字面量 if 内调用
    if (deviceInfo.apiAvailable('26.0.0')) {
      try {
        const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
        if (info.state === uiMaterial.MaterialState.ENABLE) {
          appState = '应用级已开启';
        } else if (info.state === uiMaterial.MaterialState.DISABLE) {
          appState = '应用级已关闭';
        }
      } catch (error) {
        appState = '应用级状态未知';
      }
    }
    if (!ImmersiveLight.isAvailable()) {
      return appState + ' · 设备不支持沉浸式材质';
    }
    let levelText: string = '未知';
    if (ImmersiveLight.deviceLevel === 0) {
      levelText = 'EXQUISITE(精致)';
    } else if (ImmersiveLight.deviceLevel === 1) {
      levelText = 'GENTLE(轻柔)';
    } else if (ImmersiveLight.deviceLevel === 2) {
      levelText = 'SMOOTH(流畅)';
    }
    return appState + ' · 设备支持 · 等级 ' + levelText;
  }

  /**
   * 按用途构建沉浸式系统材质。设备不支持或系统低于 API 26 时返回 undefined，
   * 调用方把 undefined 当作「不设置材质」即可（等于保留原有背景色/模糊/阴影）。
   */
  static material(surface: ImmersiveSurface): uiMaterial.Material | undefined {
    // 兼容性保护：字面量 if + 字面量版本号，低版本设备不会访问 API 26 接口。
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (ImmersiveLight.probeState === -1) {
        ImmersiveLight.probe();
      }
      if (ImmersiveLight.probeState !== 1) {
        return undefined;
      }
      // 官方推荐样式：导航/控件用薄材质，菜单与 Toast 用厚材质，弹窗用超厚材质。
      let style: uiMaterial.ImmersiveStyle = uiMaterial.ImmersiveStyle.REGULAR;
      if (surface === ImmersiveSurface.BAR || surface === ImmersiveSurface.CONTROL) {
        style = uiMaterial.ImmersiveStyle.ULTRA_THIN;
      } else if (surface === ImmersiveSurface.MENU || surface === ImmersiveSurface.TOAST) {
        style = uiMaterial.ImmersiveStyle.THICK;
      } else {
        style = uiMaterial.ImmersiveStyle.ULTRA_THICK;
      }
      // 材质自带阴影（官方默认 applyShadow = true），调用方不要再叠加自定义 shadow。
      let options: uiMaterial.ImmersiveOptions = { style: style, applyShadow: true };
      const level: uiMaterial.MaterialLevel = ImmersiveLight.deviceLevel as uiMaterial.MaterialLevel;
      if (level === uiMaterial.MaterialLevel.EXQUISITE &&
        (surface === ImmersiveSurface.BAR || surface === ImmersiveSurface.CONTROL)) {
        // 自动反色只在 THIN / ULTRA_THIN 且高算力设备上才有视觉差异。
        options.colorInvert = true;
      }
      if (level !== uiMaterial.MaterialLevel.SMOOTH && surface === ImmersiveSurface.CONTROL) {
        // 用材质的交互形变与点光源反馈替代控件默认的按压态，低算力设备不叠加。
        options.interactive = true;
        options.lightEffect = { color: Color.White };
      }
      return new uiMaterial.ImmersiveMaterial(options);
    }
    return undefined;
  }

  /** 探测设备能力与材质等级，结果缓存。所有 API 26 调用都在字面量 if 判断内。 */
  private static probe(): void {
    if (deviceInfo.apiAvailable('26.0.0')) {
      let available: boolean = false;
      try {
        available = uiMaterial.isImmersiveMaterialSupported();
      } catch (error) {
        available = false;
      }
      if (available) {
        try {
          ImmersiveLight.deviceLevel = uiMaterial.getGlobalMaterialLevel();
        } catch (error) {
          ImmersiveLight.deviceLevel = -1;
        }
        ImmersiveLight.probeState = 1;
        return;
      }
    }
    ImmersiveLight.probeState = 0;
    ImmersiveLight.deviceLevel = -1;
  }
}
