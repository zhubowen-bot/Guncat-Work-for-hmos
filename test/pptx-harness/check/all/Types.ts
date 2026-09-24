// 共享类型定义
import { ToolCallRecord } from './model/ToolCallRecord.ts';

// 文件队列项(对齐 web 版本的 pendingFiles)
export class FileItem {
  id: string = '';
  name: string = '';
  uri: string = '';
  type: string = '';
  parsedText: string = '';
  dataUrl: string = '';
  thumbnail: string = '';
  fileId: string = '';
  isParsing: boolean = false;
  error: boolean = false;

  static create(id: string, name: string, uri: string, type: string): FileItem {
    let item: FileItem = new FileItem();
    item.id = id;
    item.name = name;
    item.uri = uri;
    item.type = type;
    item.isParsing = true;
    item.error = false;
    return item;
  }

  // 从已有 item + 解析结果创建新实例
  // 注意: thumbnail 不再复用 dataUrl(全尺寸原图 base64), 由调用方生成真缩略图,
  // 避免列表/气泡解码全尺寸 PixelMap 撑爆内存
  static withParsed(source: FileItem, parsedText: string, dataUrl: string): FileItem {
    let item: FileItem = new FileItem();
    item.id = source.id;
    item.name = source.name;
    item.uri = source.uri;
    item.type = source.type;
    item.parsedText = parsedText;
    item.dataUrl = dataUrl;
    item.thumbnail = '';
    item.isParsing = false;
    item.error = false;
    return item;
  }

  // 从已有 item 创建失败状态的新实例
  static withError(source: FileItem): FileItem {
    let item: FileItem = new FileItem();
    item.id = source.id;
    item.name = source.name;
    item.uri = source.uri;
    item.type = source.type;
    item.isParsing = false;
    item.error = true;
    return item;
  }
}

// 文件预览数据平面结构(纯字段, 无 @Observed, ChatPage 通过 @State 管理)
export class PreviewData {
  // fileId 用于匹配 FileItem, renderKey 用于在状态变化时强制 ForEach 重新创建项
  fileId: string = '';
  renderKey: string = '';
  name: string = '';
  status: string = 'parsing'; // 'parsing' | 'ready' | 'error'
  thumbnail: string = '';
  type: string = '';

  static fromFileItem(f: FileItem): PreviewData {
    let p: PreviewData = new PreviewData();
    p.fileId = f.id;
    p.name = f.name;
    p.thumbnail = f.thumbnail;
    p.type = f.type;
    if (f.isParsing) { p.status = 'parsing'; }
    else if (f.error) { p.status = 'error'; }
    else { p.status = 'ready'; }
    p.renderKey = f.id + '|' + p.status;
    return p;
  }
}

// 流式回调
export class StreamCallbacks {
  onToken: (text: string) => void = (_text: string): void => {};
  // 深度思考增量: 传入已累积的完整思考文本
  onReasoning: (text: string) => void = (_text: string): void => {};
  // 由 API 返回的 usage 派生的统计; 无返回值时传 -1
  onUsage: (tokenSpeed: number, cacheHitRate: number) => void = (_speed: number, _hit: number): void => {};
  // 工具调用流式生成过程中上抛(聊天模式本地联网搜索等 function tool)
  onToolCalls: (calls: ToolCallRecord[]) => void = (_calls: ToolCallRecord[]): void => {};
  onError: (error: string) => void = (_error: string): void => {};
  onDone: (fullContent: string) => void = (_fullContent: string): void => {};
}

// 流式取消信号
export class AbortSignal {
  aborted: boolean = false;
}

// 多模态文件解析结果(命名类: .ets 侧不能用匿名对象字面量类型)
export class ParsedFileResult {
  content: string = '';
  dataUrl: string = '';
}

// 智能体注册表项(来自 agents.json)
export interface AgentConfigEntry {
  id: string;
  name: string;
  description: string;
  shortDescription: string;
  icon: string;
  category: string;
  promptFile: string;
}
