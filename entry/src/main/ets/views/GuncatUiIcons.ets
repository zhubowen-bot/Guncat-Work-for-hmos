// 交互模式 (Intelligent UI) 图标。
//
// 用 Unicode 字形而不是系统 SymbolGlyph: SymbolGlyph 的名字在不同 ROM 上可用集合不一致,
// 图标缺失时会渲染成空白(静默失败), 而字形在所有设备上都稳定。
// 名字取自组件清单里 `Icon(name)` 的取值域, 未知名字退回一个中性圆点。
@Component
export struct GuncatUiIcon {
  @Prop name: string = 'dot';
  // 不能叫 size: CustomComponent 已经内置了 size(value: SizeOptions) 属性, 同名会冲突
  @Prop iconSize: number = 14;
  @Prop color: string = '#8F8F8F';

  build() {
    Text(GuncatUiIcon.glyph(this.name))
      .fontSize(this.iconSize)
      .fontColor(this.color)
      .fontWeight(FontWeight.Medium)
      .textAlign(TextAlign.Center)
      .includeFontPadding(false)
  }

  static glyph(name: string): string {
    if (name === 'check' || name === 'success' || name === 'done') {
      return '✓';
    }
    if (name === 'close' || name === 'error' || name === 'delete') {
      return '✕';
    }
    if (name === 'add' || name === 'plus') {
      return '＋';
    }
    if (name === 'remove' || name === 'minus') {
      return '－';
    }
    if (name === 'arrow-right' || name === 'next') {
      return '→';
    }
    if (name === 'arrow-left' || name === 'back') {
      return '←';
    }
    if (name === 'arrow-up' || name === 'up' || name === 'trend-up') {
      return '↑';
    }
    if (name === 'arrow-down' || name === 'down' || name === 'trend-down') {
      return '↓';
    }
    if (name === 'chevron-up' || name === 'collapse') {
      return '⌃';
    }
    if (name === 'chevron-down' || name === 'expand') {
      return '⌄';
    }
    if (name === 'chart' || name === 'bar' || name === 'bar-chart') {
      return '▮';
    }
    if (name === 'line-chart' || name === 'trend') {
      return '◺';
    }
    if (name === 'pie' || name === 'pie-chart') {
      return '◔';
    }
    if (name === 'table' || name === 'grid') {
      return '▦';
    }
    if (name === 'list') {
      return '☰';
    }
    if (name === 'search' || name === 'find') {
      return '⌕';
    }
    if (name === 'star' || name === 'favorite') {
      return '★';
    }
    if (name === 'heart' || name === 'like') {
      return '♥';
    }
    if (name === 'share') {
      return '↗';
    }
    if (name === 'download' || name === 'save') {
      return '⤓';
    }
    if (name === 'edit' || name === 'write') {
      return '✎';
    }
    if (name === 'info' || name === 'note') {
      return 'ⓘ';
    }
    if (name === 'warning' || name === 'alert') {
      return '⚠';
    }
    if (name === 'clock' || name === 'time') {
      return '◷';
    }
    if (name === 'calendar' || name === 'date') {
      return '▤';
    }
    if (name === 'user' || name === 'person' || name === 'people') {
      return '◯';
    }
    if (name === 'home') {
      return '⌂';
    }
    if (name === 'settings' || name === 'config') {
      return '⚙';
    }
    if (name === 'sparkle' || name === 'ai' || name === 'magic') {
      return '✦';
    }
    if (name === 'refresh' || name === 'reload' || name === 'sync') {
      return '↻';
    }
    if (name === 'filter') {
      return '⧩';
    }
    if (name === 'sort' || name === 'order') {
      return '⇅';
    }
    if (name === 'money' || name === 'price' || name === 'cost') {
      return '¥';
    }
    if (name === 'tag') {
      return '⬢';
    }
    if (name === 'flag') {
      return '⚑';
    }
    if (name === 'target' || name === 'goal') {
      return '◎';
    }
    if (name === 'file' || name === 'document') {
      return '▤';
    }
    if (name === 'folder' || name === 'dir') {
      return '▰';
    }
    if (name === 'book' || name === 'read') {
      return '▭';
    }
    if (name === 'mail' || name === 'email') {
      return '✉';
    }
    if (name === 'phone' || name === 'call') {
      return '☎';
    }
    if (name === 'globe' || name === 'web' || name === 'link') {
      return '⊕';
    }
    if (name === 'location' || name === 'place' || name === 'map') {
      return '◉';
    }
    if (name === 'image' || name === 'photo' || name === 'picture') {
      return '▣';
    }
    if (name === 'play') {
      return '▶';
    }
    if (name === 'pause') {
      return '❙❙';
    }
    if (name === 'lock' || name === 'secure') {
      return '▣';
    }
    if (name === 'code') {
      return '◇';
    }
    if (name === 'cart' || name === 'buy') {
      return '▤';
    }
    if (name === 'box' || name === 'package' || name === 'product') {
      return '▢';
    }
    if (name === 'idea' || name === 'bulb' || name === 'insight') {
      return '✦';
    }
    if (name === 'question' || name === 'help') {
      return '？';
    }
    if (name === 'dot' || name === 'point') {
      return '·';
    }
    return '·';
  }
}
