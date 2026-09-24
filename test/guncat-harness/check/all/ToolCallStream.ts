// 三协议 SSE 流式工具调用累积器(共享模块)
// 从 AgentLoopService 抽出供 ChatService(聊天模式本地联网搜索)复用:
//   openai-completions → delta.tool_calls 增量累积
//   openai-responses   → response.output_item.done(function_call) 整块
//   anthropic-messages → content_block_start(tool_use) + input_json_delta 增量
import { ToolCallRecord } from './ToolCallRecord.ts';

// 流式工具调用累积器: completions/responses/anthropic 三种协议统一汇入
export class ToolCallAccumulator {
  calls: ToolCallRecord[] = [];
  // 协议内 index(completions 的 delta.index / anthropic 的 block index) → calls 下标
  keyMap: number[] = [];

  // 取 key 对应的记录, 不存在则用 maker 创建并登记
  patch(key: number, maker: () => ToolCallRecord): ToolCallRecord {
    for (let i: number = 0; i < this.keyMap.length; i++) {
      if (this.keyMap[i] === key) {
        return this.calls[i];
      }
    }
    let rec: ToolCallRecord = maker();
    this.calls.push(rec);
    this.keyMap.push(key);
    return rec;
  }

  // 无显式 index 的协议(responses)直接整块追加
  append(rec: ToolCallRecord): void {
    this.calls.push(rec);
    this.keyMap.push(-1 - this.calls.length);
  }

  find(key: number): ToolCallRecord | null {
    for (let i: number = 0; i < this.keyMap.length; i++) {
      if (this.keyMap[i] === key) {
        return this.calls[i];
      }
    }
    return null;
  }
}

// completions: delta.tool_calls[{index, id?, function?:{name?, arguments?}}]
export function collectCompletionsToolDelta(sseData: string, acc: ToolCallAccumulator): void {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return;
    }
    let choices: Object = (json as Record<string, Object>)['choices'];
    if (!(choices instanceof Array) || choices.length === 0) {
      return;
    }
    let first: Object = choices[0];
    if (typeof first !== 'object' || first === null) {
      return;
    }
    let delta: Object = (first as Record<string, Object>)['delta'];
    if (typeof delta !== 'object' || delta === null) {
      return;
    }
    let rawCalls: Object = (delta as Record<string, Object>)['tool_calls'];
    if (!(rawCalls instanceof Array)) {
      return;
    }
    let arr: Object[] = rawCalls as Object[];
    for (let i: number = 0; i < arr.length; i++) {
      let item: Object = arr[i];
      if (typeof item !== 'object' || item === null) {
        continue;
      }
      let rec: Record<string, Object> = item as Record<string, Object>;
      let rawIndex: Object = rec['index'];
      let key: number = acc.calls.length;
      if (typeof rawIndex === 'number') {
        key = rawIndex as number;
      }
      let call: ToolCallRecord = acc.patch(key, (): ToolCallRecord => {
        return ToolCallRecord.of('', '', '');
      });
      let id: Object = rec['id'];
      if (typeof id === 'string' && (id as string) !== '') {
        call.id = id as string;
      }
      let fn: Object = rec['function'];
      if (typeof fn === 'object' && fn !== null) {
        let fnRec: Record<string, Object> = fn as Record<string, Object>;
        let name: Object = fnRec['name'];
        if (typeof name === 'string' && (name as string) !== '') {
          call.name = name as string;
        }
        let args: Object = fnRec['arguments'];
        if (typeof args === 'string') {
          call.argsJson += args as string;
        }
      }
    }
  } catch (e) {
    // 单条 SSE 解析失败忽略
  }
}

// responses: response.output_item.done 携带完整 function_call 项
export function collectResponsesToolItem(sseData: string, acc: ToolCallAccumulator): void {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return;
    }
    let type: Object = (json as Record<string, Object>)['type'];
    if (typeof type !== 'string' || (type as string) !== 'response.output_item.done') {
      return;
    }
    let item: Object = (json as Record<string, Object>)['item'];
    if (typeof item !== 'object' || item === null) {
      return;
    }
    let itemRec: Record<string, Object> = item as Record<string, Object>;
    let itemType: Object = itemRec['type'];
    if (typeof itemType !== 'string' || (itemType as string) !== 'function_call') {
      return;
    }
    let callId: Object = itemRec['call_id'];
    let itemId: Object = itemRec['id'];
    let name: Object = itemRec['name'];
    let args: Object = itemRec['arguments'];
    let call: ToolCallRecord = ToolCallRecord.of(
      typeof callId === 'string' ? callId as string :
        (typeof itemId === 'string' ? itemId as string : genToolCallId()),
      typeof name === 'string' ? name as string : '',
      typeof args === 'string' ? args as string : ''
    );
    acc.append(call);
  } catch (e) {
    // ignore
  }
}

// anthropic: content_block_start(tool_use) + input_json_delta 增量
export function collectAnthropicToolEvent(sseData: string, acc: ToolCallAccumulator): void {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return;
    }
    let type: Object = (json as Record<string, Object>)['type'];
    if (typeof type !== 'string') {
      return;
    }
    let eventType: string = type as string;
    if (eventType === 'content_block_start') {
      let rawIndex: Object = (json as Record<string, Object>)['index'];
      let block: Object = (json as Record<string, Object>)['content_block'];
      if (typeof block !== 'object' || block === null) {
        return;
      }
      let blockRec: Record<string, Object> = block as Record<string, Object>;
      let blockType: Object = blockRec['type'];
      if (typeof blockType !== 'string' || (blockType as string) !== 'tool_use') {
        return;
      }
      let key: number = acc.calls.length;
      if (typeof rawIndex === 'number') {
        key = rawIndex as number;
      }
      acc.patch(key, (): ToolCallRecord => {
        let id: Object = blockRec['id'];
        let name: Object = blockRec['name'];
        return ToolCallRecord.of(
          typeof id === 'string' ? id as string : genToolCallId(),
          typeof name === 'string' ? name as string : '', '');
      });
    } else if (eventType === 'content_block_delta') {
      let rawIndex: Object = (json as Record<string, Object>)['index'];
      let delta: Object = (json as Record<string, Object>)['delta'];
      if (typeof delta !== 'object' || delta === null || typeof rawIndex !== 'number') {
        return;
      }
      let deltaRec: Record<string, Object> = delta as Record<string, Object>;
      let deltaType: Object = deltaRec['type'];
      if (typeof deltaType !== 'string' || (deltaType as string) !== 'input_json_delta') {
        return;
      }
      let call: ToolCallRecord | null = acc.find(rawIndex as number);
      if (call === null) {
        return;
      }
      let partial: Object = deltaRec['partial_json'];
      if (typeof partial === 'string') {
        call.argsJson += partial as string;
      }
    }
  } catch (e) {
    // ignore
  }
}

// 兜底 call id 生成(缺失 id 的协议/服务端)
export function genToolCallId(): string {
  return 'call_' + Date.now().toString() + '_' + Math.floor(Math.random() * 100000).toString();
}
