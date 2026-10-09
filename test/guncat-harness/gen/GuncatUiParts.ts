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
} from './GuncatUiSpec.ts';

// 片段类型
export class GuncatUiSegType {
  static readonly TEXT: string = 'text';
  static readonly UI: string = 'ui';
}

export class GuncatUiSeg {
  type: string = GuncatUiSegType.TEXT;
  text: string = '';
  // UI 片段: 完整闭合为 true, 流式中间态为 false
  complete: boolean = true;
  spec: GuncatUiSpec | null = null;
  error: string = '';
}

export class GuncatUiParts {
  segments: GuncatUiSeg[] = [];
  // 存在至少一个已解析成功的界面块(用于决定是否隐藏原始围栏文本)
  hasUi: boolean = false;

  static build(content: string): GuncatUiParts {
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
          parts.segments.push(uiSeg);
          parts.hasUi = true;
        } else {
          // 闭合但非法: 原文交还 Markdown(含围栏标记), 让用户看到真实输出
          let rawSeg: GuncatUiSeg = new GuncatUiSeg();
          rawSeg.text = GuncatUiBlocks.renderRaw(f.text);
          parts.segments.push(rawSeg);
        }
      } else {
        // 流式中间态: 渐进渲染, 禁用交互
        let progress: GuncatUiProgress | null = GuncatUiBlocks.progress(content);
        let uiSeg2: GuncatUiSeg = new GuncatUiSeg();
        uiSeg2.type = GuncatUiSegType.UI;
        uiSeg2.complete = false;
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
