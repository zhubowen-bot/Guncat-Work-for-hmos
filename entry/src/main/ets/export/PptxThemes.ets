// PptxThemes: Deck 的主题预设与颜色解析
// 8 套预设覆盖常见场景; themeOverride 可覆盖任意字段; 语义色与 hex 统一由 resolveColor 解析。
// 纯逻辑模块(无 HarmonyOS API 依赖)。
import { Deck, DeckThemeOverride } from './DeckModel';

// 解析后的完整主题色
export class ThemeColors {
  name: string = 'brand-blue';
  primary: string = '0A7AFF';   // 品牌主色(顶栏/项目符号/图表主系列)
  accent: string = '3DBE64';    // 强调色(图表第二系列/点缀)
  bg: string = 'FFFFFF';        // 页面底色
  surface: string = 'F2F6FC';   // 浅底(表格隔行/卡片)
  title: string = '1B2330';     // 标题色
  body: string = '333F50';      // 正文色
  sub: string = '6B7280';       // 次要文字
  faint: string = '9AA3AF';     // 弱化文字/页码
  onPrimary: string = 'FFFFFF'; // 主色整版页(cover/section)上的文字色
  series: string[] = [];        // 图表系列色板(6 色)
  dark: boolean = false;        // 深色主题(图表文字用浅色)
}

export class PptxThemes {
  static readonly PRESETS: string[] = ['brand-blue', 'midnight', 'forest', 'sunset',
    'violet', 'graphite', 'ivory', 'crimson'];

  static resolve(deck: Deck): ThemeColors {
    let c: ThemeColors = PptxThemes.preset(deck.theme);
    let o: DeckThemeOverride = deck.themeOverride;
    if (o.primary !== '') {
      c.primary = o.primary;
    }
    if (o.accent !== '') {
      c.accent = o.accent;
    }
    if (o.bg !== '') {
      c.bg = o.bg;
    }
    if (o.surface !== '') {
      c.surface = o.surface;
    }
    if (o.title !== '') {
      c.title = o.title;
    }
    if (o.body !== '') {
      c.body = o.body;
    }
    if (o.sub !== '') {
      c.sub = o.sub;
    }
    if (o.faint !== '') {
      c.faint = o.faint;
    }
    return c;
  }

  // 取预设(未知主题名回退 brand-blue)
  private static preset(name: string): ThemeColors {
    let c: ThemeColors = new ThemeColors();
    c.series = [];
    let n: string = name.trim().toLowerCase();
    if (n === 'midnight') {
      c.name = n;
      c.primary = '38BDF8';
      c.accent = 'A78BFA';
      c.bg = '0B1220';
      c.surface = '16213A';
      c.title = 'F1F5F9';
      c.body = 'CBD5E1';
      c.sub = '94A3B8';
      c.faint = '64748B';
      c.onPrimary = '0B1220';
      c.dark = true;
      PptxThemes.setSeries(c, ['38BDF8', 'A78BFA', 'F472B6', '34D399', 'FBBF24', '64748B']);
      return c;
    }
    if (n === 'forest') {
      c.name = n;
      c.primary = '1E7A55';
      c.accent = 'E9A23B';
      c.bg = 'FFFFFF';
      c.surface = 'EFF6F1';
      c.title = '15271F';
      c.body = '2F4038';
      c.sub = '5C7267';
      c.faint = '93A69B';
      PptxThemes.setSeries(c, ['1E7A55', 'E9A23B', '5CA97C', 'B4632C', '4E8FB0', '9AA37E']);
      return c;
    }
    if (n === 'sunset') {
      c.name = n;
      c.primary = 'E8590C';
      c.accent = 'FAB005';
      c.bg = 'FFFBF7';
      c.surface = 'FFF1E6';
      c.title = '3A2A1E';
      c.body = '4E3B2C';
      c.sub = '8A7A6C';
      c.faint = 'B9A898';
      PptxThemes.setSeries(c, ['E8590C', 'FAB005', 'C92A2A', '343A40', '1C7ED6', 'F76707']);
      return c;
    }
    if (n === 'violet') {
      c.name = n;
      c.primary = '7048E8';
      c.accent = '22B8CF';
      c.bg = 'FFFFFF';
      c.surface = 'F4F1FB';
      c.title = '241B3E';
      c.body = '3D3552';
      c.sub = '7A7291';
      c.faint = 'A9A3BD';
      PptxThemes.setSeries(c, ['7048E8', '22B8CF', 'BE4BDB', '3B5BDB', 'F59F00', '868E96']);
      return c;
    }
    if (n === 'graphite') {
      c.name = n;
      c.primary = '343A40';
      c.accent = 'E03131';
      c.bg = 'FFFFFF';
      c.surface = 'F1F3F5';
      c.title = '212529';
      c.body = '343A40';
      c.sub = '868E96';
      c.faint = 'ADB5BD';
      PptxThemes.setSeries(c, ['343A40', 'E03131', '495057', '15AABF', 'F59F00', '868E96']);
      return c;
    }
    if (n === 'ivory') {
      c.name = n;
      c.primary = '2B4C7E';
      c.accent = 'C92A2A';
      c.bg = 'FDFCF8';
      c.surface = 'F4F1E8';
      c.title = '2B2B2B';
      c.body = '3F3F3F';
      c.sub = '8C8578';
      c.faint = 'B5AE9F';
      PptxThemes.setSeries(c, ['2B4C7E', 'C92A2A', '3B7A57', 'B7791F', '6B4F9E', '8C8578']);
      return c;
    }
    if (n === 'crimson') {
      c.name = n;
      c.primary = 'C92A2A';
      c.accent = '1C7ED6';
      c.bg = 'FFFFFF';
      c.surface = 'FDF0F0';
      c.title = '341A1A';
      c.body = '4A2F2F';
      c.sub = '8F6F6F';
      c.faint = 'B99C9C';
      PptxThemes.setSeries(c, ['C92A2A', '1C7ED6', 'F59F00', '343A40', '0CA678', 'E64980']);
      return c;
    }
    // brand-blue(默认)
    c.name = 'brand-blue';
    PptxThemes.setSeries(c, ['0A7AFF', '3DBE64', 'F5A623', '8E9BFF', '34C3C9', 'A0AEC6']);
    return c;
  }

  private static setSeries(c: ThemeColors, colors: string[]): void {
    for (let i: number = 0; i < colors.length; i++) {
      c.series.push(colors[i]);
    }
  }

  // 语义色/ hex -> 6 位 hex(非法回退 fallback)
  // 语义色: primary accent bg surface title body sub faint onPrimary white dark light
  static resolveColor(c: ThemeColors, spec: string, fallback: string): string {
    let s: string = spec.trim().replace('#', '');
    if (s === '') {
      return fallback;
    }
    let lower: string = s.toLowerCase();
    if (lower === 'primary') {
      return c.primary;
    }
    if (lower === 'accent') {
      return c.accent;
    }
    if (lower === 'bg') {
      return c.bg;
    }
    if (lower === 'surface') {
      return c.surface;
    }
    if (lower === 'title') {
      return c.title;
    }
    if (lower === 'body') {
      return c.body;
    }
    if (lower === 'sub') {
      return c.sub;
    }
    if (lower === 'faint') {
      return c.faint;
    }
    if (lower === 'onprimary') {
      return c.onPrimary;
    }
    if (lower === 'white') {
      return 'FFFFFF';
    }
    if (lower === 'dark') {
      return '111111';
    }
    if (lower === 'light') {
      return 'F5F5F5';
    }
    if (/^[0-9A-Fa-f]{6}$/.test(s) || /^[0-9A-Fa-f]{8}$/.test(s)) {
      return s.substring(0, 6).toUpperCase();
    }
    if (/^[0-9A-Fa-f]{3}$/.test(s)) {
      return (s.charAt(0) + s.charAt(0) + s.charAt(1) + s.charAt(1) + s.charAt(2) + s.charAt(2)).toUpperCase();
    }
    return fallback;
  }
}
