// 交互模式消息体: 把一条 assistant 消息切成「普通 Markdown 片段 + guncat-ui 交互界面块」。
// 约定(与 GuncatUiPrompt 对模型的要求一致):
// - 只有**能成功解析**的 guncat-ui 块才会被原生渲染, 并从 Markdown 正文中移除;
// - JSON 非法 / 尚未闭合的块不删除原文, 避免用户看到「内容凭空消失」;
// - 闭合但非法的块按普通代码块渲染(交给 Markdown 库), 保持可读可复制。
import {
  GuncatUiBlocks,
  GuncatUiFragment,
  GuncatUiProgress,
  GuncatUiParseResult,
  GuncatUiSpec
} from '../common/GuncatUiSpec';

// 片段类型
export class GuncatUiSegType {
  static readonly TEXT: string = 'text';
  static readonly UI: string = 'ui';
}

export class GuncatUiSeg {
  type: string = GuncatUiSegType.TEXT;
  text: string = '';
  // 文本片段的渲染 key: 内容变化时递增, 父组件据此强制重建 RichTextView。
  // 真机事故: 卡片后面的正文只显示一两个字, 刷新后才完整 —— 渲染库复用了同一个
  // RichTextView 实例而没有重新排版尾部文本, 所以尾部文本必须有独立且可变的 key。
  renderKey: number = 0;
  // UI 片段: 完整闭合为 true, 流式中间态为 false
  complete: boolean = true;
  // 未闭合但产出已结束(输出被截断/中断): 按"未完成"静态渲染, 不再显示"生成中"
  truncated: boolean = false;
  spec: GuncatUiSpec | null = null;
  error: string = '';
  // 块内原文(解析失败时兜底展示; 未闭合时供"查看原始输出"用)
  raw: string = '';
}

export class GuncatUiParts {
  segments: GuncatUiSeg[] = [];
  // 存在至少一个已解析成功的界面块(用于决定是否隐藏原始围栏文本)
  hasUi: boolean = false;

  static build(content: string, finalized: boolean = false): GuncatUiParts {
    let parts: GuncatUiParts = new GuncatUiParts();
    if (content === '' || content.indexOf(GuncatUiBlocks.OPEN) < 0) {
      if (content !== '') {
        let seg: GuncatUiSeg = new GuncatUiSeg();
        seg.text = content;
        parts.segments.push(seg);
      }
      return parts;
    }
    let fragments: GuncatUiFragment[] = GuncatUiBlocks.split(content);
    for (let i: number = 0; i < fragments.length; i++) {
      let f: GuncatUiFragment = fragments[i];
      if (!f.fence) {
        if (f.text !== '') {
          let textSeg: GuncatUiSeg = new GuncatUiSeg();
          textSeg.text = f.text;
          parts.segments.push(textSeg);
        }
        continue;
      }
      if (f.complete) {
        let result: GuncatUiParseResult = GuncatUiBlocks.parseComplete(f.text);
        if (result.spec !== null) {
          let uiSeg: GuncatUiSeg = new GuncatUiSeg();
          uiSeg.type = GuncatUiSegType.UI;
          uiSeg.complete = true;
          uiSeg.spec = result.spec;
          uiSeg.raw = f.text;
          parts.segments.push(uiSeg);
          parts.hasUi = true;
        } else {
          // 闭合但解析失败: 做一次"结构化救助"(逐字段回退 → 控件/标题级救助)。
          // **guncat-ui 块永不退回普通代码块**(那等于把一条长 JSON 贴在聊天里, 又被截断又难读):
          // 救出内容就正常渲染, 救不出也渲染成"无内容 + 原始输出"的卡片。
          let salvaged: GuncatUiParseResult = GuncatUiBlocks.salvageBlockBody(f.text);
          let rescuedSeg: GuncatUiSeg = new GuncatUiSeg();
          rescuedSeg.type = GuncatUiSegType.UI;
          rescuedSeg.complete = true;
          rescuedSeg.truncated = true;
          rescuedSeg.spec = salvaged.spec;
          rescuedSeg.raw = f.text;
          rescuedSeg.error = salvaged.error;
          parts.segments.push(rescuedSeg);
          parts.hasUi = true;
        }
      } else {
        // 未闭合: 渐进渲染, 禁用交互。finalized 表示本轮产出已结束(输出被截断/中断),
        // 此时按"未完成"静态渲染, 绝不停在"生成中"的空骨架上。
        let progress: GuncatUiProgress | null = GuncatUiBlocks.progress(content);
        let uiSeg2: GuncatUiSeg = new GuncatUiSeg();
        uiSeg2.type = GuncatUiSegType.UI;
        uiSeg2.complete = false;
        uiSeg2.truncated = finalized;
        uiSeg2.raw = f.text;
        if (progress !== null) {
          uiSeg2.spec = progress.spec;
          uiSeg2.error = progress.error;
        }
        parts.segments.push(uiSeg2);
        // 未闭合块之后不会再有内容(流式追加点), 直接结束
        break;
      }
    }
    return parts;
  }
}
