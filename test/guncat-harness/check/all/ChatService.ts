// ChatService: 真正的 SSE 流式三协议, 对齐 web 版本 streamChat
//  - openai-completions → Chat Completions (/chat/completions)
//  - openai-responses   → Responses API    (/responses)
//  - anthropic-messages → Anthropic Messages (/messages)
import { http } from '@kit.NetworkKit';
import { ApiConfig } from './ApiConfig.ts';
import { Agent } from './Agent.ts';
import { Message } from './Message.ts';
import { Attachment } from './Attachment.ts';
import { ToolCallRecord } from './ToolCallRecord.ts';
import { StreamCallbacks, AbortSignal } from './Types.ts';
import { Constants } from './Constants.ts';
import { LLMProtocol } from './LLMProtocol.ts';
import { SSEProtocolAdapter, SSEParseContext } from './SSEProtocolAdapter.ts';
import { SSEAdapterFactory } from './SSEAdapterFactory.ts';
import { util } from '@kit.ArkTS';
import { ToolCallAccumulator, collectCompletionsToolDelta, collectResponsesToolItem,
  collectAnthropicToolEvent, genToolCallId } from './ToolCallStream.ts';
import { LOCAL_SEARCH_TOOL_NAME, LOCAL_SEARCH_TOOL_DESC_CHAT, LOCAL_SEARCH_TOOL_DESC_CHAT_FALLBACK,
  LOCAL_SEARCH_QUERY_PROP_DESC } from './LocalWebSearch.ts';
import { HarnessTools } from './HarnessTools.ts';

export class StreamAccumulator {
  buffer: ArrayBuffer = new ArrayBuffer(0);
  decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
  fullContent: string = '';

  append(data: ArrayBuffer): string {
    let newBuffer: ArrayBuffer = new ArrayBuffer(this.buffer.byteLength + data.byteLength);
    let src: Uint8Array = new Uint8Array(this.buffer);
    let add: Uint8Array = new Uint8Array(data);
    let dst: Uint8Array = new Uint8Array(newBuffer);
    dst.set(src, 0);
    dst.set(add, this.buffer.byteLength);
    this.buffer = newBuffer;
    return this.decoder.decodeToString(add, { stream: true });
  }
}

export function getProtocol(provider: string): string {
  return LLMProtocol.pick(provider);
}

// 单次流式请求的结构化产出(聊天模式本地联网搜索工具循环需要):
// toolCalls 供调用方执行后回灌下一轮; thinkingSignature/redactedThinking 供
// Anthropic 协议思考模式下把带 tool_use 的 assistant 消息回传时随思考块携带
export class ChatStreamResult {
  toolCalls: ToolCallRecord[] = [];
  thinkingSignature: string = '';
  redactedThinking: string = '';
}

// 本地内置联网搜索 search_web 的 function tool 定义(协议相关形态):
// 强制注入聊天模式请求体, 与服务端联网搜索(可选开关)并存, 互不影响。
// serverSearchEnabled=true 时描述切换为"兜底版", 引导模型优先走服务端 web_search。
export function buildLocalSearchToolDef(protocol: string, serverSearchEnabled: boolean): Record<string, Object> {
  let schema: Record<string, Object> = {
    'type': 'object',
    'properties': {
      'query': { 'type': 'string', 'description': LOCAL_SEARCH_QUERY_PROP_DESC }
    },
    'required': ['query']
  };
  let description: string = serverSearchEnabled ?
    LOCAL_SEARCH_TOOL_DESC_CHAT_FALLBACK : LOCAL_SEARCH_TOOL_DESC_CHAT;
  if (protocol === 'anthropic') {
    return {
      'name': LOCAL_SEARCH_TOOL_NAME,
      'description': description,
      'input_schema': schema
    };
  }
  if (protocol === 'responses') {
    return {
      'type': 'function',
      'name': LOCAL_SEARCH_TOOL_NAME,
      'description': description,
      'parameters': schema
    };
  }
  return {
    'type': 'function',
    'function': {
      'name': LOCAL_SEARCH_TOOL_NAME,
      'description': description,
      'parameters': schema
    }
  };
}

// web_fetch function tool 定义(复用工作模式 HarnessTools 的定义, 按协议映射形态):
// 与 search_web 一起强制注入聊天模式, 供模型读取搜索来源/用户给的链接
function buildWebFetchToolDef(protocol: string): Record<string, Object> {
  let def: Record<string, Object> = HarnessTools.webFetchDef();
  let name: string = def['name'] as string;
  let description: string = def['description'] as string;
  let schema: Record<string, Object> = def['parameters'] as Record<string, Object>;
  if (protocol === 'anthropic') {
    return { 'name': name, 'description': description, 'input_schema': schema };
  }
  if (protocol === 'responses') {
    return { 'type': 'function', 'name': name, 'description': description, 'parameters': schema };
  }
  return {
    'type': 'function',
    'function': { 'name': name, 'description': description, 'parameters': schema }
  };
}

// 工具调用参数 JSON → 对象(解析失败回落空对象)
function parseToolArgsObject(argsJson: string): Record<string, Object> {
  try {
    let parsed: Object = JSON.parse(argsJson === '' ? '{}' : argsJson);
    if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
      return parsed as Record<string, Object>;
    }
  } catch (e) {
    // ignore
  }
  return {};
}

// 由 Base URL 推导最终请求端点(三协议共用)。
// autoSuffix=false 时严格使用用户填写的地址(仅去首尾空白), 不做任何协议路径补全——
// 用于非标准路径的自建网关/代理; 开启时按协议补全标准路径。
export function resolveEndpointUrl(config: ApiConfig, protocol: string): string {
  return LLMProtocol.resolveEndpoint(config.baseUrl, protocol, config.autoSuffix);
}

function buildChatCompletionsBody(config: ApiConfig, agent: Agent | null,
  history: Message[], userText: string,
  thinkingEnabled: boolean, webSearchEnabled: boolean): Record<string, Object> {
  let messages: Record<string, Object>[] = [];
  if (agent !== null && agent.systemPrompt !== '') {
    messages.push({ role: 'system', content: agent.systemPrompt });
  }
  for (let i: number = 0; i < history.length; i++) {
    let m: Message = history[i];
    // 只带工具调用的 assistant 消息(content 为空)不能跳过, 工具结果回灌依赖它
    if (m.content === '' && m.toolCalls.length === 0) {
      continue;
    }
    if (m.role !== 'user' && m.role !== 'assistant') {
      continue;
    }
    if (m.role === 'user' && m.attachments.length > 0) {
      let contentParts: Record<string, Object>[] = [];
      if (m.content !== '') {
        contentParts.push({ type: 'text', text: m.content });
      }
      for (let j: number = 0; j < m.attachments.length; j++) {
        let attachment: Attachment = m.attachments[j];
        if (attachment.parsedText !== '' || attachment.dataUrl === '') {
          continue;
        }
        if (attachment.type === 'image') {
          if (attachment.fileId !== '') {
            contentParts.push({
              type: 'file',
              file_id: attachment.fileId
            });
          } else {
            contentParts.push({
              type: 'image_url',
              image_url: { url: attachment.dataUrl }
            });
          }
        } else {
          if (attachment.fileId !== '') {
            contentParts.push({
              type: 'file',
              file_id: attachment.fileId
            });
          } else {
            // 兼容支持 file_url 的 OpenAI 兼容接口；不支持的提供商会忽略或报错。
            contentParts.push({
              type: 'file_url',
              file_url: { url: attachment.dataUrl }
            });
          }
        }
      }
      if (contentParts.length > 0) {
        messages.push({ role: 'user', content: contentParts });
        continue;
      }
    }
    if (m.role === 'assistant' && m.toolCalls.length > 0) {
      // 本地工具循环: assistant(tool_calls) + role:'tool' 结果回传
      let callArr: Record<string, Object>[] = [];
      for (let c: number = 0; c < m.toolCalls.length; c++) {
        let call: ToolCallRecord = m.toolCalls[c];
        callArr.push({
          id: call.id,
          type: 'function',
          function: { name: call.name, arguments: call.argsJson === '' ? '{}' : call.argsJson }
        });
      }
      messages.push({
        role: 'assistant',
        content: m.content === '' ? null : m.content,
        tool_calls: callArr
      });
      for (let c: number = 0; c < m.toolCalls.length; c++) {
        let call: ToolCallRecord = m.toolCalls[c];
        messages.push({
          role: 'tool',
          tool_call_id: call.id,
          content: call.result === '' ? '(无结果)' : call.result
        });
      }
      continue;
    }
    let chatMsg: Record<string, Object> = { role: m.role, content: m.content };
    // 请求携带 tools（联网搜索）时，DeepSeek 要求回传中间 assistant 的 reasoning_content，否则多轮可能 400。
    if (m.role === 'assistant' && webSearchEnabled && m.reasoning !== '') {
      chatMsg['reasoning_content'] = m.reasoning;
    }
    messages.push(chatMsg);
  }
  let lastHistory: Message | null = history.length > 0 ? history[history.length - 1] : null;
  // 本地搜索工具循环的续轮请求 userText 为空串, 不再追加用户消息
  if (userText !== '') {
    if (lastHistory === null || lastHistory.role !== 'user' || lastHistory.content !== userText) {
      messages.push({ role: 'user', content: userText });
    }
  }

  let body: Record<string, Object> = {
    model: config.model,
    messages: messages,
    stream: true
  };

  // 本地内置联网搜索 search_web 强制注入(由模型决定是否调用); 服务端联网搜索按开关并存
  let chatTools: Record<string, Object>[] = [];
  if (webSearchEnabled) {
    // OpenAI 兼容 Chat Completions 服务若支持服务端搜索，可识别该工具。
    chatTools.push({ type: 'web_search' });
  }
  chatTools.push(buildLocalSearchToolDef('completions', webSearchEnabled));
  chatTools.push(buildWebFetchToolDef('completions'));
  body['tools'] = chatTools;
  body['tool_choice'] = 'auto';
  if (config.temperature !== null) {
    body['temperature'] = config.temperature;
  }
  if (config.topP !== null) {
    body['top_p'] = config.topP;
  }
  if (config.maxTokens !== null) {
    body['max_tokens'] = config.maxTokens;
  }
  if (config.extraBody !== '') {
    try {
      let extra: Object = JSON.parse(config.extraBody);
      if (typeof extra === 'object' && extra !== null) {
        let keys: string[] = Object.keys(extra);
        for (let i: number = 0; i < keys.length; i++) {
          body[keys[i]] = (extra as Record<string, Object>)[keys[i]];
        }
      }
    } catch (e) {
      // 忽略非法 JSON
    }
  }
  // 深度思考开关（OpenAI 兼容格式）：thinking.type 控制开关 + reasoning_effort 控制强度。
  // 放在 extraBody 合并之后，确保界面开关优先级最高。
  body['thinking'] = { type: thinkingEnabled ? 'enabled' : 'disabled' };
  if (thinkingEnabled) {
    body['reasoning_effort'] = 'high';
  }
  return body;
}

function buildResponsesBody(config: ApiConfig, agent: Agent | null,
  history: Message[], userText: string,
  thinkingEnabled: boolean, webSearchEnabled: boolean): Record<string, Object> {
  let input: Record<string, Object>[] = [];
  for (let i: number = 0; i < history.length; i++) {
    let m: Message = history[i];
    // 只带工具调用的 assistant 消息(content 为空)不能跳过, 工具结果回灌依赖它
    if (m.content === '' && m.toolCalls.length === 0) {
      continue;
    }
    if (m.role !== 'user' && m.role !== 'assistant') {
      continue;
    }
    if (m.role === 'user' && m.attachments.length > 0) {
      let contentParts: Record<string, Object>[] = [];
      contentParts.push({ type: 'input_text', text: m.content });
      for (let j: number = 0; j < m.attachments.length; j++) {
        let attachment: Attachment = m.attachments[j];
        if (attachment.parsedText !== '' || attachment.dataUrl === '') {
          continue;
        }
        if (attachment.type === 'image') {
          if (attachment.fileId !== '') {
            contentParts.push({
              type: 'input_image',
              file_id: attachment.fileId
            });
          } else {
            contentParts.push({
              type: 'input_image',
              image_url: attachment.dataUrl
            });
          }
        } else {
          // 统一发送 input_file；若服务商不支持会由服务端返回错误。
          if (attachment.fileId !== '') {
            contentParts.push({
              type: 'input_file',
              file_id: attachment.fileId
            });
          } else {
            contentParts.push({
              type: 'input_file',
              filename: attachment.name,
              file_data: attachment.dataUrl
            });
          }
        }
      }
      input.push({ role: m.role, content: contentParts });
    } else if (m.role === 'assistant' && m.toolCalls.length > 0) {
      // 本地工具循环: function_call + function_call_output 输入项
      if (m.content !== '') {
        input.push({
          role: 'assistant',
          content: [{ type: 'output_text', text: m.content }]
        });
      }
      for (let c: number = 0; c < m.toolCalls.length; c++) {
        let call: ToolCallRecord = m.toolCalls[c];
        input.push({
          type: 'function_call',
          call_id: call.id,
          name: call.name,
          arguments: call.argsJson === '' ? '{}' : call.argsJson
        });
      }
      for (let c: number = 0; c < m.toolCalls.length; c++) {
        let call: ToolCallRecord = m.toolCalls[c];
        input.push({
          type: 'function_call_output',
          call_id: call.id,
          output: call.result === '' ? '(无结果)' : call.result
        });
      }
    } else {
      input.push({ role: m.role, content: m.content });
    }
  }
  let lastHistory: Message | null = history.length > 0 ? history[history.length - 1] : null;
  // 本地搜索工具循环的续轮请求 userText 为空串, 不再追加用户消息
  if (userText !== '') {
    if (lastHistory === null || lastHistory.role !== 'user' || lastHistory.content !== userText) {
      input.push({ role: 'user', content: userText });
    }
  }

  let body: Record<string, Object> = {
    model: config.model,
    input: input,
    stream: true,
    store: false
  };

  if (agent !== null && agent.systemPrompt !== '') {
    body['instructions'] = agent.systemPrompt;
  }
  // 本地内置联网搜索 search_web 强制注入(由模型决定是否调用); 服务端联网搜索按开关并存
  let respTools: Record<string, Object>[] = [];
  if (webSearchEnabled) {
    // OpenAI Responses 兼容格式；DeepSeek 与火山方舟均支持该工具。
    respTools.push({ type: 'web_search' });
  }
  respTools.push(buildLocalSearchToolDef('responses', webSearchEnabled));
  respTools.push(buildWebFetchToolDef('responses'));
  body['tools'] = respTools;
  body['tool_choice'] = 'auto';
  if (config.temperature !== null) {
    body['temperature'] = config.temperature;
  }
  if (config.topP !== null) {
    body['top_p'] = config.topP;
  }
  if (config.maxTokens !== null) {
    body['max_output_tokens'] = config.maxTokens;
  }
  if (config.extraBody !== '') {
    try {
      let extra: Object = JSON.parse(config.extraBody);
      if (typeof extra === 'object' && extra !== null) {
        let keys: string[] = Object.keys(extra);
        for (let i: number = 0; i < keys.length; i++) {
          body[keys[i]] = (extra as Record<string, Object>)[keys[i]];
        }
      }
    } catch (e) {
      // ignore
    }
  }
  // 深度思考开关（Responses API 格式）：reasoning.effort 控制开关，none 表示关闭。
  // 放在 extraBody 合并之后，确保界面开关优先级最高。
  body['reasoning'] = { effort: thinkingEnabled ? 'high' : 'none' };
  return body;
}

function appendAnthropicMessage(messages: Record<string, Object>[], role: string, content: Object): void {
  let last: Record<string, Object> | null = messages.length > 0 ? messages[messages.length - 1] : null;
  let lastRole: Object = last !== null ? last['role'] : null;
  if (typeof lastRole === 'string' && lastRole === role) {
    let prevContent: Object = last['content'];
    if (typeof prevContent === 'string' && typeof content === 'string') {
      last['content'] = prevContent + '\n\n' + content;
      return;
    }
    if (prevContent instanceof Array && content instanceof Array) {
      let prevArr: Object[] = prevContent as Object[];
      let addArr: Object[] = content as Object[];
      for (let i: number = 0; i < addArr.length; i++) {
        prevArr.push(addArr[i]);
      }
      return;
    }
    if (prevContent instanceof Array && typeof content === 'string') {
      let prevArr: Object[] = prevContent as Object[];
      prevArr.push({ type: 'text', text: content });
      return;
    }
    if (typeof prevContent === 'string' && content instanceof Array) {
      let merged: Object[] = [{ type: 'text', text: prevContent }];
      let addArr: Object[] = content as Object[];
      for (let i: number = 0; i < addArr.length; i++) {
        merged.push(addArr[i]);
      }
      last['content'] = merged;
      return;
    }
  }
  messages.push({ role: role, content: content });
}

function buildAnthropicBody(config: ApiConfig, agent: Agent | null,
  history: Message[], userText: string,
  thinkingEnabled: boolean, webSearchEnabled: boolean): Record<string, Object> {
  let messages: Record<string, Object>[] = [];
  for (let i: number = 0; i < history.length; i++) {
    let m: Message = history[i];
    // 只带工具调用的 assistant 消息(content 为空)不能跳过, 工具结果回灌依赖它
    if (m.content === '' && m.toolCalls.length === 0) {
      continue;
    }
    if (m.role !== 'user' && m.role !== 'assistant') {
      continue;
    }
    if (m.role === 'user' && m.attachments.length > 0) {
      let contentParts: Record<string, Object>[] = [];
      if (m.content !== '') {
        contentParts.push({ type: 'text', text: m.content });
      }
      for (let j: number = 0; j < m.attachments.length; j++) {
        let attachment: Attachment = m.attachments[j];
        if (attachment.parsedText !== '' || attachment.dataUrl === '') {
          continue;
        }
        if (attachment.type === 'image') {
          if (attachment.fileId !== '') {
            contentParts.push({
              type: 'image',
              source: { type: 'file', file_id: attachment.fileId }
            });
          } else if (attachment.dataUrl.startsWith('http://') || attachment.dataUrl.startsWith('https://')) {
            contentParts.push({
              type: 'image',
              source: { type: 'url', url: attachment.dataUrl }
            });
          } else {
            let dataUrl: string = attachment.dataUrl;
            let comma: number = dataUrl.indexOf(';base64,');
            if (comma > 0) {
              let mediaType: string = dataUrl.substring(5, comma);
              let data: string = dataUrl.substring(comma + 8);
              contentParts.push({
                type: 'image',
                source: { type: 'base64', media_type: mediaType, data: data }
              });
            }
          }
        } else {
          // 统一发送 document 块；若服务商不支持会由服务端返回错误。
          if (attachment.fileId !== '') {
            contentParts.push({
              type: 'document',
              source: { type: 'file', file_id: attachment.fileId }
            });
          } else if (attachment.dataUrl.startsWith('http://') || attachment.dataUrl.startsWith('https://')) {
            contentParts.push({
              type: 'document',
              source: { type: 'url', url: attachment.dataUrl }
            });
          } else {
            let dataUrl: string = attachment.dataUrl;
            let comma: number = dataUrl.indexOf(';base64,');
            if (comma > 0) {
              let mediaType: string = dataUrl.substring(5, comma);
              let data: string = dataUrl.substring(comma + 8);
              contentParts.push({
                type: 'document',
                source: { type: 'base64', media_type: mediaType, data: data }
              });
            }
          }
        }
      }
      if (contentParts.length > 0) {
        appendAnthropicMessage(messages, 'user', contentParts);
        continue;
      }
    }
    if (m.role === 'assistant' && m.toolCalls.length > 0) {
      // 本地工具循环: assistant(thinking? + text? + tool_use) + user(tool_result)。
      // 思考模式下带 tool_use 的 assistant 消息必须回传思考块(置于首位, 与工作模式同规则):
      // 有思考文本即回传, 签名在流式捕获到时随块携带(部分兼容服务不返回签名则省略该字段)
      let blocks: Object[] = [];
      if (thinkingEnabled && m.reasoning !== '') {
        let thinkingBlock: Record<string, Object> = { type: 'thinking', thinking: m.reasoning };
        if (m.thinkingSignature !== '') {
          thinkingBlock['signature'] = m.thinkingSignature;
        }
        blocks.push(thinkingBlock);
      }
      if (m.content !== '') {
        blocks.push({ type: 'text', text: m.content });
      }
      for (let c: number = 0; c < m.toolCalls.length; c++) {
        let call: ToolCallRecord = m.toolCalls[c];
        blocks.push({
          type: 'tool_use',
          id: call.id,
          name: call.name,
          input: parseToolArgsObject(call.argsJson)
        });
      }
      appendAnthropicMessage(messages, 'assistant', blocks);
      let results: Object[] = [];
      for (let c: number = 0; c < m.toolCalls.length; c++) {
        let call: ToolCallRecord = m.toolCalls[c];
        results.push({
          type: 'tool_result',
          tool_use_id: call.id,
          content: call.result === '' ? '(无结果)' : call.result
        });
      }
      appendAnthropicMessage(messages, 'user', results);
    } else {
      appendAnthropicMessage(messages, m.role, m.content);
    }
  }
  let lastHistory: Message | null = history.length > 0 ? history[history.length - 1] : null;
  // 本地搜索工具循环的续轮请求 userText 为空串, 不再追加用户消息
  if (userText !== '') {
    if (lastHistory === null || lastHistory.role !== 'user' || lastHistory.content !== userText) {
      appendAnthropicMessage(messages, 'user', userText);
    }
  }

  // Anthropic Messages API 必填 max_tokens(其他两种协议可省略由服务端决定)。
  // 未配置时默认下发 128K(Constants.DEFAULT_MAX_OUTPUT_TOKENS): 额度顶满时服务端
  // 按 stop_reason=max_tokens 截断输出, 且思考模式的思考文本同样计入该额度。
  let maxTokens: number = config.maxTokens !== null ?
    config.maxTokens : Constants.DEFAULT_MAX_OUTPUT_TOKENS;
  let body: Record<string, Object> = {
    model: config.model,
    messages: messages,
    stream: true,
    max_tokens: maxTokens
  };
  if (agent !== null && agent.systemPrompt !== '') {
    body['system'] = agent.systemPrompt;
  }
  // 本地内置联网搜索 search_web 强制注入(由模型决定是否调用); 服务端联网搜索按开关并存
  let anthroTools: Object[] = [];
  if (webSearchEnabled) {
    let tool: Record<string, Object> = {
      type: 'web_search_20250305',
      name: 'web_search',
      max_uses: 5
    };
    anthroTools.push(tool);
  }
  anthroTools.push(buildLocalSearchToolDef('anthropic', webSearchEnabled));
  anthroTools.push(buildWebFetchToolDef('anthropic'));
  body['tools'] = anthroTools;
  if (config.temperature !== null) {
    body['temperature'] = config.temperature;
  }
  if (config.topP !== null) {
    body['top_p'] = config.topP;
  }
  if (config.extraBody !== '') {
    try {
      let extra: Object = JSON.parse(config.extraBody);
      if (typeof extra === 'object' && extra !== null) {
        let keys: string[] = Object.keys(extra);
        for (let i: number = 0; i < keys.length; i++) {
          body[keys[i]] = (extra as Record<string, Object>)[keys[i]];
        }
      }
    } catch (e) {
      // ignore
    }
  }
  // 深度思考开关（Anthropic 兼容格式）：thinking.type 控制开关 + output_config.effort 控制强度。
  // 放在 extraBody 合并之后，确保界面开关优先级最高。
  body['thinking'] = { type: thinkingEnabled ? 'enabled' : 'disabled' };
  if (thinkingEnabled) {
    body['output_config'] = { effort: 'high' };
  }
  return body;
}

export function extractChatCompletionsDelta(sseData: string): string {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return '';
    }
    let choices: Object = (json as Record<string, Object>)['choices'];
    if (!(choices instanceof Array) || choices.length === 0) {
      return '';
    }
    let first: Object = choices[0];
    if (typeof first !== 'object' || first === null) {
      return '';
    }
    let delta: Object = (first as Record<string, Object>)['delta'];
    if (typeof delta !== 'object' || delta === null) {
      return '';
    }
    let content: Object = (delta as Record<string, Object>)['content'];
    if (typeof content === 'string') {
      return content;
    }
    return '';
  } catch (e) {
    return '';
  }
}

export function extractResponsesDelta(sseData: string): string {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return '';
    }
    let type: Object = (json as Record<string, Object>)['type'];
    if (typeof type !== 'string' || type !== 'response.output_text.delta') {
      return '';
    }
    let delta: Object = (json as Record<string, Object>)['delta'];
    if (typeof delta === 'string') {
      return delta;
    }
    return '';
  } catch (e) {
    return '';
  }
}

export function extractResponsesFailure(sseData: string): string {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return '';
    }
    let type: Object = (json as Record<string, Object>)['type'];
    if (typeof type !== 'string' || type !== 'response.failed') {
      return '';
    }
    let resp: Object = (json as Record<string, Object>)['response'];
    if (typeof resp !== 'object' || resp === null) {
      return 'Responses API 返回失败';
    }
    let err: Object = (resp as Record<string, Object>)['error'];
    if (typeof err === 'object' && err !== null) {
      let msg: Object = (err as Record<string, Object>)['message'];
      if (typeof msg === 'string') {
        return msg;
      }
    }
    return 'Responses API 返回失败';
  } catch (e) {
    return '';
  }
}

export function extractAnthropicDelta(sseData: string): string {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return '';
    }
    let type: Object = (json as Record<string, Object>)['type'];
    if (typeof type !== 'string' || type !== 'content_block_delta') {
      return '';
    }
    let delta: Object = (json as Record<string, Object>)['delta'];
    if (typeof delta !== 'object' || delta === null) {
      return '';
    }
    let deltaType: Object = (delta as Record<string, Object>)['type'];
    if (typeof deltaType !== 'string' || deltaType !== 'text_delta') {
      return '';
    }
    let text: Object = (delta as Record<string, Object>)['text'];
    if (typeof text === 'string') {
      return text;
    }
    return '';
  } catch (e) {
    return '';
  }
}

export function extractAnthropicFailure(sseData: string): string {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return '';
    }
    let type: Object = (json as Record<string, Object>)['type'];
    if (typeof type !== 'string' || type !== 'error') {
      return '';
    }
    let err: Object = (json as Record<string, Object>)['error'];
    if (typeof err === 'object' && err !== null) {
      let msg: Object = (err as Record<string, Object>)['message'];
      if (typeof msg === 'string') {
        return msg;
      }
    }
    return 'Anthropic Messages API 返回失败';
  } catch (e) {
    return '';
  }
}

// ===== 深度思考增量解析 (对齐 web 版本 extractXXXReasoning) =====

export function extractChatCompletionsReasoning(sseData: string): string {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return '';
    }
    let choices: Object = (json as Record<string, Object>)['choices'];
    if (!(choices instanceof Array) || choices.length === 0) {
      return '';
    }
    let first: Object = choices[0];
    if (typeof first !== 'object' || first === null) {
      return '';
    }
    let delta: Object = (first as Record<string, Object>)['delta'];
    if (typeof delta !== 'object' || delta === null) {
      return '';
    }
    // DeepSeek 使用 reasoning_content; 部分 OpenAI 兼容服务使用 reasoning
    let reasoning: Object = (delta as Record<string, Object>)['reasoning_content'];
    if (typeof reasoning === 'string') {
      return reasoning;
    }
    let reasoningAlt: Object = (delta as Record<string, Object>)['reasoning'];
    if (typeof reasoningAlt === 'string') {
      return reasoningAlt;
    }
    return '';
  } catch (e) {
    return '';
  }
}

export function extractResponsesReasoning(sseData: string): string {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return '';
    }
    let type: Object = (json as Record<string, Object>)['type'];
    if (typeof type !== 'string') {
      return '';
    }
    if (type !== 'response.reasoning_summary_text.delta' && type !== 'response.reasoning_text.delta') {
      return '';
    }
    let delta: Object = (json as Record<string, Object>)['delta'];
    if (typeof delta === 'string') {
      return delta;
    }
    if (delta instanceof Array) {
      let parts: string[] = [];
      let arr: Object[] = delta as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        let item: Object = arr[i];
        if (typeof item === 'object' && item !== null) {
          let text: Object = (item as Record<string, Object>)['text'];
          if (typeof text === 'string') {
            parts.push(text);
          }
        }
      }
      return parts.join('');
    }
    return '';
  } catch (e) {
    return '';
  }
}

export function extractAnthropicReasoning(sseData: string): string {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return '';
    }
    let type: Object = (json as Record<string, Object>)['type'];
    if (typeof type !== 'string' || type !== 'content_block_delta') {
      return '';
    }
    let delta: Object = (json as Record<string, Object>)['delta'];
    if (typeof delta !== 'object' || delta === null) {
      return '';
    }
    let deltaType: Object = (delta as Record<string, Object>)['type'];
    if (typeof deltaType !== 'string' || deltaType !== 'thinking_delta') {
      return '';
    }
    let thinking: Object = (delta as Record<string, Object>)['thinking'];
    if (typeof thinking === 'string') {
      return thinking;
    }
    return '';
  } catch (e) {
    return '';
  }
}

// 思考块签名增量: thinking 块结束后由 signature_delta 事件携带, 回传 thinking 块时随块携带
export function extractAnthropicSignature(sseData: string): string {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return '';
    }
    let type: Object = (json as Record<string, Object>)['type'];
    if (typeof type !== 'string' || type !== 'content_block_delta') {
      return '';
    }
    let delta: Object = (json as Record<string, Object>)['delta'];
    if (typeof delta !== 'object' || delta === null) {
      return '';
    }
    let deltaType: Object = (delta as Record<string, Object>)['type'];
    if (typeof deltaType !== 'string' || deltaType !== 'signature_delta') {
      return '';
    }
    let signature: Object = (delta as Record<string, Object>)['signature'];
    if (typeof signature === 'string') {
      return signature;
    }
    return '';
  } catch (e) {
    return '';
  }
}

// 加密思考块(redacted_thinking): content_block_start 事件直接携带完整 data 字段,
// 回传时原样送回(无增量), 否则思考模式下服务端 400
export function extractAnthropicRedactedThinking(sseData: string): string {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return '';
    }
    let type: Object = (json as Record<string, Object>)['type'];
    if (typeof type !== 'string' || type !== 'content_block_start') {
      return '';
    }
    let block: Object = (json as Record<string, Object>)['content_block'];
    if (typeof block !== 'object' || block === null) {
      return '';
    }
    let blockRec: Record<string, Object> = block as Record<string, Object>;
    let blockType: Object = blockRec['type'];
    if (typeof blockType !== 'string' || (blockType as string) !== 'redacted_thinking') {
      return '';
    }
    let data: Object = blockRec['data'];
    if (typeof data === 'string') {
      return data;
    }
    return '';
  } catch (e) {
    return '';
  }
}

// ===== usage 解析 (对齐 web 版本 extractXXXUsage) =====

export function extractChatCompletionsUsage(sseData: string): Record<string, Object> | null {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return null;
    }
    let usage: Object = (json as Record<string, Object>)['usage'];
    if (typeof usage === 'object' && usage !== null) {
      return usage as Record<string, Object>;
    }
    return null;
  } catch (e) {
    return null;
  }
}

export function extractResponsesUsage(sseData: string): Record<string, Object> | null {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return null;
    }
    let type: Object = (json as Record<string, Object>)['type'];
    if (typeof type !== 'string' || type !== 'response.completed') {
      return null;
    }
    let resp: Object = (json as Record<string, Object>)['response'];
    if (typeof resp === 'object' && resp !== null) {
      let usage: Object = (resp as Record<string, Object>)['usage'];
      if (typeof usage === 'object' && usage !== null) {
        return usage as Record<string, Object>;
      }
    }
    return null;
  } catch (e) {
    return null;
  }
}

export function extractAnthropicUsage(sseData: string): Record<string, Object> | null {
  try {
    let json: Object = JSON.parse(sseData);
    if (typeof json !== 'object' || json === null) {
      return null;
    }
    let type: Object = (json as Record<string, Object>)['type'];
    if (typeof type !== 'string' || type !== 'message_delta') {
      return null;
    }
    let usage: Object = (json as Record<string, Object>)['usage'];
    if (typeof usage === 'object' && usage !== null) {
      return usage as Record<string, Object>;
    }
    return null;
  } catch (e) {
    return null;
  }
}

// 由 API 返回的 usage 派生 token 速度(tok/s)与缓存命中率(0..1);
// 只读返回值, 不做自创算法; 无对应字段时返回 -1.
export function deriveStreamStats(usage: Record<string, Object> | null, elapsedMs: number): number[] {
  let speed: number = -1;
  let hit: number = -1;
  if (usage === null) {
    return [speed, hit];
  }
  let outTokens: number = -1;
  let completionTokens: Object = usage['completion_tokens'];
  if (typeof completionTokens === 'number') {
    outTokens = completionTokens as number;
  } else {
    let outputTokens: Object = usage['output_tokens'];
    if (typeof outputTokens === 'number') {
      outTokens = outputTokens as number;
    }
  }
  let hitTokens: number = -1;
  let totalTokens: number = -1;
  let hitT: Object = usage['prompt_cache_hit_tokens'];
  let missT: Object = usage['prompt_cache_miss_tokens'];
  if (typeof hitT === 'number' && typeof missT === 'number') {
    hitTokens = hitT as number;
    totalTokens = (hitT as number) + (missT as number);
  } else {
    let promptDetails: Object = usage['prompt_tokens_details'];
    if (typeof promptDetails === 'object' && promptDetails !== null) {
      let cached: Object = (promptDetails as Record<string, Object>)['cached_tokens'];
      if (typeof cached === 'number') {
        hitTokens = cached as number;
        let promptTokens: Object = usage['prompt_tokens'];
        totalTokens = typeof promptTokens === 'number' ? (promptTokens as number) : hitTokens;
      }
    } else {
      let inputDetails: Object = usage['input_tokens_details'];
      if (typeof inputDetails === 'object' && inputDetails !== null) {
        let cached: Object = (inputDetails as Record<string, Object>)['cached_tokens'];
        if (typeof cached === 'number') {
          hitTokens = cached as number;
          let inputTokens: Object = usage['input_tokens'];
          totalTokens = typeof inputTokens === 'number' ? (inputTokens as number) : hitTokens;
        }
      } else {
        let cacheRead: Object = usage['cache_read_input_tokens'];
        let cacheCreate: Object = usage['cache_creation_input_tokens'];
        let inputT: Object = usage['input_tokens'];
        if (typeof cacheRead === 'number' || typeof cacheCreate === 'number') {
          let cr: number = typeof cacheRead === 'number' ? (cacheRead as number) : 0;
          let cc: number = typeof cacheCreate === 'number' ? (cacheCreate as number) : 0;
          let inp: number = typeof inputT === 'number' ? (inputT as number) : 0;
          hitTokens = cr;
          totalTokens = cr + cc + inp;
        }
      }
    }
  }
  if (outTokens > 0 && elapsedMs > 0) {
    speed = outTokens / (elapsedMs / 1000);
  }
  if (hitTokens >= 0 && totalTokens > 0) {
    hit = hitTokens / totalTokens;
  }
  return [speed, hit];
}

export class ChatService {
  private static activeRequest: http.HttpRequest | null = null;

  static async streamChat(
    config: ApiConfig,
    agent: Agent | null,
    history: Message[],
    userText: string,
    thinkingEnabled: boolean,
    webSearchEnabled: boolean,
    callbacks: StreamCallbacks,
    abortSignal: AbortSignal
  ): Promise<ChatStreamResult> {
    let protocol: string = getProtocol(config.provider);
    let url: string = resolveEndpointUrl(config, protocol);

    let body: Record<string, Object>;
    if (protocol === 'responses') {
      body = buildResponsesBody(config, agent, history, userText, thinkingEnabled, webSearchEnabled);
    } else if (protocol === 'anthropic') {
      body = buildAnthropicBody(config, agent, history, userText, thinkingEnabled, webSearchEnabled);
    } else {
      body = buildChatCompletionsBody(config, agent, history, userText, thinkingEnabled, webSearchEnabled);
    }
    let bodyStr: string = JSON.stringify(body);

    let httpRequest: http.HttpRequest = http.createHttp();
    ChatService.activeRequest = httpRequest;
    let acc: StreamAccumulator = new StreamAccumulator();
    let lineBuffer: string = '';
    let receivedAnyData: boolean = false;
    let aborted: boolean = false;
    let failedMsg: string = '';
    // 深度思考累积 + 请求起始时间(用于由 usage 派生 token 速度)
    let fullReasoning: string = '';
    let startTime: number = Date.now();
    // 工具调用累积(本地联网搜索 search_web 等强制注入的 function tool)
    let callAcc: ToolCallAccumulator = new ToolCallAccumulator();
    let sseAdapter: SSEProtocolAdapter = SSEAdapterFactory.build(protocol, callAcc);
    let lastToolSig: string = '';
    // Anthropic 思考块签名与加密思考块(思考模式下本地工具循环回传所需)
    let thinkingSignature: string = '';
    let redactedThinking: string = '';
    let streamResult: ChatStreamResult = new ChatStreamResult();
    // 对齐 web 版本: SSE 解析出一个 delta 就立即 onToken 全量累积,
    // UI 端 50ms 节流刷新. 不做应用层字符拆分 (避免 setTimeout 队列过长 OOM)

    // 单条 SSE 数据分发(数据流与 dataEnd 兜底共用): 协议适配器统一解析文本/思考/工具调用/usage
    let processSseData = (sseData: string): void => {
      let ctx: SSEParseContext = new SSEParseContext();
      ctx.onFailure = (msg: string): boolean => {
        failedMsg = msg;
        throw new Error(msg);
      };
      ctx.onToken = (delta: string): void => {
        acc.fullContent += delta;
        callbacks.onToken(delta);
      };
      ctx.onReasoning = (text: string): void => {
        fullReasoning += text;
        callbacks.onReasoning(fullReasoning);
      };
      ctx.onSignature = (signature: string): void => {
        thinkingSignature += signature;
      };
      ctx.onRedactedThinking = (data: string): void => {
        redactedThinking = data;
      };
      ctx.onUsage = (usageObj: Record<string, Object> | null): void => {
        let stats: number[] = deriveStreamStats(usageObj, Date.now() - startTime);
        callbacks.onUsage(stats[0], stats[1]);
      };
      sseAdapter.handleLine(sseData, ctx);
      // 工具调用流式生成过程中即时上抛(调用数或累计参数量变化时)
      if (callAcc.calls.length > 0) {
        let argsLen: number = 0;
        for (let i: number = 0; i < callAcc.calls.length; i++) {
          argsLen += callAcc.calls[i].argsJson.length;
        }
        let sig: string = callAcc.calls.length.toString() + ':' + argsLen.toString();
        if (sig !== lastToolSig) {
          lastToolSig = sig;
          callbacks.onToolCalls(callAcc.calls);
        }
      }
    };

    try {
      await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
        let statusCode: number = 0;
        let dataEnded: boolean = false;
        let settled: boolean = false;
        httpRequest.on('dataReceive', (data: ArrayBuffer) => {
          if (abortSignal.aborted) {
            return;
          }
          receivedAnyData = true;
          try {
            let chunk: string = acc.append(data);
            lineBuffer += chunk;
            let lines: string[] = lineBuffer.split('\n');
            if (lineBuffer.endsWith('\n')) {
              lineBuffer = '';
            } else {
              lineBuffer = lines.pop() as string;
            }
            for (let i: number = 0; i < lines.length; i++) {
              let line: string = lines[i];
              let trimmed: string = line.trim();
              if (trimmed === '' || trimmed === Constants.SSE_DONE_TOKEN) {
                continue;
              }
              if (!trimmed.startsWith(Constants.SSE_DATA_PREFIX)) {
                continue;
              }
              processSseData(trimmed.substring(Constants.SSE_DATA_PREFIX.length));
            }
          } catch (e) {
            let err: Error = e as Error;
            reject(err);
          }
        });

        httpRequest.on('dataEnd', () => {
          if (lineBuffer !== '') {
            let trimmed: string = lineBuffer.trim();
            if (trimmed.startsWith(Constants.SSE_DATA_PREFIX) && trimmed !== Constants.SSE_DONE_TOKEN) {
              try {
                processSseData(trimmed.substring(Constants.SSE_DATA_PREFIX.length));
              } catch (e) {
                let err: Error = e as Error;
                if (!settled) {
                  settled = true;
                  reject(err);
                }
                return;
              }
            }
            lineBuffer = '';
          }
          dataEnded = true;
          if (statusCode !== 0 && statusCode >= 200 && statusCode < 300 && !settled) {
            settled = true;
            resolve();
          }
        });

        let headers: Record<string, string> = {
          'Content-Type': 'application/json'
        };
        if (protocol === 'anthropic') {
          let needsAnthropicBeta: boolean = false;
          for (let hi: number = 0; hi < history.length; hi++) {
            let hm: Message = history[hi];
            for (let hj: number = 0; hj < hm.attachments.length; hj++) {
              if (hm.attachments[hj].fileId !== '') {
                needsAnthropicBeta = true;
                break;
              }
            }
            if (needsAnthropicBeta) {
              break;
            }
          }
          headers['x-api-key'] = config.apiKey;
          headers['anthropic-version'] = '2023-06-01';
          headers['Accept'] = 'text/event-stream';
          if (needsAnthropicBeta) {
            headers['anthropic-beta'] = 'files-api-2025-04-14';
          }
        } else {
          headers['Authorization'] = 'Bearer ' + config.apiKey;
        }
        httpRequest.requestInStream(url, {
          method: http.RequestMethod.POST,
          header: headers,
          extraData: bodyStr,
          connectTimeout: 30000,
          readTimeout: 180000,
          usingProtocol: http.HttpProtocol.HTTP1_1
        }).then((code: number) => {
          statusCode = code;
          if (abortSignal.aborted) {
            return;
          }
          if (code < 200 || code >= 300) {
            if (!settled) {
              settled = true;
              let msg: string = '';
              if (code === 401) {
                msg = 'API Key 无效，请检查设置';
              } else if (code === 429) {
                msg = '请求过于频繁，请稍后再试';
              } else if (code >= 400 && code < 500) {
                msg = 'API 请求错误 (' + code + ')，请检查配置';
              } else if (code >= 500) {
                msg = '服务器错误 (' + code + ')，请稍后再试';
              } else {
                msg = '请求失败，状态码: ' + code;
              }
              reject(new Error(msg));
            }
            return;
          }
          if (dataEnded && !settled) {
            settled = true;
            resolve();
          }
        }).catch((err: Error) => {
          if (abortSignal.aborted) {
            // 当 abort 导致 requestInStream 抛错时 resolve, 让 promise 得以完成, finally 得以执行
            if (!settled) {
              settled = true;
              resolve();
            }
            return;
          }
          if (!settled) {
            settled = true;
            reject(err);
          }
        });
      });
      // 结构化产出: 累积的工具调用/思考块签名随流结束返回给调用方
      streamResult.toolCalls = ChatService.normalizeChatToolCalls(callAcc.calls);
      streamResult.thinkingSignature = thinkingSignature;
      streamResult.redactedThinking = redactedThinking;
    } catch (e) {
      let err: Error = e as Error;
      if (abortSignal.aborted) {
        aborted = true;
      } else {
        if (failedMsg === '' && err.message !== undefined) {
          failedMsg = err.message;
        }
        if (failedMsg === '') {
          failedMsg = '请求失败';
        }
        callbacks.onError(failedMsg);
      }
    } finally {
      if (abortSignal.aborted) {
        aborted = true;
      }
      ChatService.activeRequest = null;
      try {
        httpRequest.off('dataReceive');
        httpRequest.off('dataEnd');
        httpRequest.destroy();
      } catch (e) {
        // ignore
      }
      if (!aborted) {
        callbacks.onDone(acc.fullContent);
      }
    }
    return streamResult;
  }

  // 兜底补全: 缺名字的调用记录不送回(避免协议校验失败), 空 argsJson 填 '{}', 缺 id 补生成
  private static normalizeChatToolCalls(calls: ToolCallRecord[]): ToolCallRecord[] {
    let out: ToolCallRecord[] = [];
    for (let i: number = 0; i < calls.length; i++) {
      let call: ToolCallRecord = calls[i];
      if (call.name === '') {
        continue;
      }
      if (call.id === '') {
        call.id = genToolCallId();
      }
      if (call.argsJson.trim() === '') {
        call.argsJson = '{}';
      }
      out.push(call);
    }
    return out;
  }

  static abort(): void {
    let req: http.HttpRequest | null = ChatService.activeRequest;
    if (req !== null) {
      try {
        req.destroy();
      } catch (e) {
        // ignore
      }
      ChatService.activeRequest = null;
    }
  }
}
