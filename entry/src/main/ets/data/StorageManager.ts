// 配置类小数据仍用 Preferences; 对话历史改为文件存储(<filesDir>/guncat_conversations.json),
// 不再受 Preferences 单值 16MB 上限约束, 历史多了也不会写失败或被迫丢会话。
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { Conversation } from '../model/Conversation';
import { Message } from '../model/Message';
import { Attachment } from '../model/Attachment';
import { ApiConfig } from '../model/ApiConfig';
import { MultimodalConfig } from '../model/MultimodalConfig';
import { ApiProfile } from '../model/ApiProfile';
import { Constants } from '../common/Constants';

let preferencesInstance: preferences.Preferences | undefined = undefined;

async function getPreferences(context: Context): Promise<preferences.Preferences> {
  if (preferencesInstance === undefined) {
    preferencesInstance = await preferences.getPreferences(context, 'guncat_preferences');
  }
  return preferencesInstance;
}

export class StorageManager {
  private static readonly CONVERSATIONS_FILE: string = 'guncat_conversations.json';

  // ===== 对话历史: 文件存储(无 Preferences 体积上限) =====

  private static conversationsFilePath(context: Context): string {
    return (context as common.UIAbilityContext).filesDir + '/' + StorageManager.CONVERSATIONS_FILE;
  }

  static async saveConversations(context: Context, convs: Conversation[]): Promise<void> {
    try {
      // 附件图片字节超阈值时, 仍先剥离 dataUrl/thumbnail(保留文件名与解析文本)
      let arr: Object[] = [];
      for (let i: number = 0; i < convs.length; i++) {
        arr.push(convs[i].toJson());
      }
      if (StorageManager.hasHeavyAttachments(convs)) {
        arr = StorageManager.sanitizeConversations(arr);
      }
      // 工作模式长任务的 reasoning 会无限增长, 落盘前只保留末尾(原有行为, 不丢会话)
      StorageManager.capReasoning(arr);
      let jsonStr: string = JSON.stringify(arr);
      StorageManager.writeConversationsFile(context, jsonStr);
    } catch (error) {
      // 保存失败不抛出, 避免反复重试放大内存压力
      console.error('saveConversations failed: ' + JSON.stringify(error));
    }
  }

  static async loadConversations(context: Context): Promise<Conversation[]> {
    try {
      // 新存储优先读文件
      let jsonStr: string = StorageManager.readConversationsFile(context);
      if (jsonStr === '') {
        // 首次升级到文件存储: 从 Preferences 迁移旧对话数据
        let legacy: string = await StorageManager.readLegacyConversations(context);
        if (legacy !== '') {
          try {
            let parsed: Object = JSON.parse(legacy);
            if (parsed instanceof Array) {
              StorageManager.writeConversationsFile(context, legacy);
              await StorageManager.clearLegacyConversations(context);
              jsonStr = legacy;
            }
          } catch (e) {
            // 旧数据非法则忽略, 按空历史处理
          }
        }
      }
      return StorageManager.parseConversations(jsonStr);
    } catch (error) {
      // 读取失败(如文件损坏)不阻塞启动, 按无历史处理
      console.error('loadConversations failed: ' + JSON.stringify(error));
      return [];
    }
  }

  private static parseConversations(jsonStr: string): Conversation[] {
    if (jsonStr === '') {
      return [];
    }
    let parsed: Object = JSON.parse(jsonStr);
    if (!(parsed instanceof Array)) {
      return [];
    }
    let rawArr: Object[] = parsed as Object[];
    let result: Conversation[] = [];
    for (let i: number = 0; i < rawArr.length; i++) {
      result.push(Conversation.fromJson(rawArr[i] as Record<string, Object>));
    }
    return result;
  }

  private static async readLegacyConversations(context: Context): Promise<string> {
    try {
      let prefs: preferences.Preferences = await getPreferences(context);
      return (await prefs.get(Constants.LS_KEY_CONVERSATIONS, '')) as string;
    } catch (e) {
      return '';
    }
  }

  private static async clearLegacyConversations(context: Context): Promise<void> {
    try {
      let prefs: preferences.Preferences = await getPreferences(context);
      await prefs.delete(Constants.LS_KEY_CONVERSATIONS);
      await prefs.flush();
    } catch (e) {
      // 清理失败不影响使用, 旧 key 会作为无用的历史残留
    }
  }

  // 原子写文件: 先写临时文件再 rename, 失败时回退直接截断写
  private static writeConversationsFile(context: Context, jsonStr: string): void {
    let abs: string = StorageManager.conversationsFilePath(context);
    let encoder: util.TextEncoder = new util.TextEncoder();
    let bytes: Uint8Array = encoder.encode(jsonStr);
    let buffer: ArrayBuffer = bytes.buffer as ArrayBuffer;
    if (bytes.byteOffset !== 0 || bytes.byteLength !== buffer.byteLength) {
      buffer = bytes.slice().buffer as ArrayBuffer;
    }
    let tmpPath: string = abs + '.tmp';
    let renamed: boolean = false;
    try {
      let tmp: fileIo.File = fileIo.openSync(tmpPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(tmp.fd, buffer);
      } finally {
        fileIo.closeSync(tmp.fd);
      }
      try {
        fileIo.renameSync(tmpPath, abs);
      } catch (e) {
        // 部分系统版本 rename 不覆盖已存在目标: 先删旧文件再改名
        if (fileIo.accessSync(abs)) {
          fileIo.unlinkSync(abs);
        }
        fileIo.renameSync(tmpPath, abs);
      }
      renamed = true;
    } catch (e) {
      try {
        fileIo.unlinkSync(tmpPath);
      } catch (e2) {
        // 临时文件可能尚未创建成功
      }
    }
    if (!renamed) {
      // 改名仍失败时回退原地截断重写
      let file: fileIo.File = fileIo.openSync(abs,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, buffer);
      } finally {
        fileIo.closeSync(file.fd);
      }
    }
  }

  private static readConversationsFile(context: Context): string {
    let abs: string = StorageManager.conversationsFilePath(context);
    if (!fileIo.accessSync(abs)) {
      return '';
    }
    let stat: fileIo.Stat = fileIo.statSync(abs);
    if (stat.size <= 0) {
      return '';
    }
    let buffer: ArrayBuffer = new ArrayBuffer(stat.size);
    let file: fileIo.File = fileIo.openSync(abs, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.readSync(file.fd, buffer, { offset: 0 });
    } finally {
      fileIo.closeSync(file.fd);
    }
    let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(new Uint8Array(buffer), { stream: false });
  }

  // ===== 原有会话预处理(保留, 非破坏性) =====

  // 持久化前修剪思考文本: 单条消息只保留末尾 REASONING_SAVE_MAX_CHARS
  // (toJson/sanitizeConversations 返回的都是全新对象, 原地修改不影响内存中的会话)
  private static capReasoning(arr: Object[]): void {
    for (let i: number = 0; i < arr.length; i++) {
      let c: Record<string, Object> = arr[i] as Record<string, Object>;
      let rawMsgs: Object = c['messages'];
      if (rawMsgs === undefined || !(rawMsgs instanceof Array)) {
        continue;
      }
      let msgs: Object[] = rawMsgs as Object[];
      for (let j: number = 0; j < msgs.length; j++) {
        let m: Record<string, Object> = msgs[j] as Record<string, Object>;
        let r: Object = m['reasoning'];
        if (typeof r === 'string' && (r as string).length > Constants.REASONING_SAVE_MAX_CHARS) {
          m['reasoning'] = '…' +
            (r as string).slice((r as string).length - Constants.REASONING_SAVE_MAX_CHARS);
        }
      }
    }
  }

  // 附件图片(dataUrl/thumbnail)字节总量是否超过安全阈值
  private static hasHeavyAttachments(convs: Conversation[]): boolean {
    let total: number = 0;
    for (let i: number = 0; i < convs.length; i++) {
      let msgs: Message[] = convs[i].messages;
      for (let j: number = 0; j < msgs.length; j++) {
        let atts: Attachment[] = msgs[j].attachments;
        for (let k: number = 0; k < atts.length; k++) {
          total += atts[k].dataUrl.length + atts[k].thumbnail.length;
          if (total > Constants.LS_CONVERSATIONS_SAFE_BYTES) {
            return true;
          }
        }
      }
    }
    return false;
  }

  // 重建会话 JSON, 剥离附件 dataUrl/thumbnail(仅保留文件名与解析文本)
  private static sanitizeConversations(arr: Object[]): Object[] {
    let out: Object[] = [];
    for (let i: number = 0; i < arr.length; i++) {
      let c: Record<string, Object> = arr[i] as Record<string, Object>;
      let msgs: Object[] = [];
      let rawMsgs: Object = c['messages'];
      if (rawMsgs !== undefined) {
        let rawArr: Object[] = rawMsgs as Object[];
        for (let j: number = 0; j < rawArr.length; j++) {
          msgs.push(StorageManager.sanitizeMessage(rawArr[j] as Record<string, Object>));
        }
      }
      out.push({
        'id': (c['id'] as string) ?? '',
        'agentId': (c['agentId'] as string) ?? '',
        'title': (c['title'] as string) ?? '',
        'messages': msgs,
        'createdAt': (c['createdAt'] as number) ?? 0,
        'mode': (c['mode'] as string) ?? 'chat'
      });
    }
    return out;
  }

  private static sanitizeMessage(m: Record<string, Object>): Record<string, Object> {
    let atts: Object[] = [];
    let rawAtts: Object = m['attachments'];
    if (rawAtts !== undefined) {
      let rawArr: Object[] = rawAtts as Object[];
      for (let i: number = 0; i < rawArr.length; i++) {
        let a: Record<string, Object> = rawArr[i] as Record<string, Object>;
        atts.push({
          'name': (a['name'] as string) ?? '',
          'parsedText': (a['parsedText'] as string) ?? '',
          'type': (a['type'] as string) ?? '',
          'thumbnail': '',
          'dataUrl': ''
        });
      }
    }
    // 工作模式的工具调用步骤原样保留(纯文本字段, 体积小)
    let calls: Object[] = [];
    let rawCalls: Object = m['toolCalls'];
    if (rawCalls !== undefined && rawCalls instanceof Array) {
      let rawCallArr: Object[] = rawCalls as Object[];
      for (let i: number = 0; i < rawCallArr.length; i++) {
        calls.push(rawCallArr[i]);
      }
    }
    return {
      'id': (m['id'] as string) ?? '',
      'role': (m['role'] as string) ?? '',
      'content': (m['content'] as string) ?? '',
      'displayContent': (m['displayContent'] as string) ?? '',
      'attachments': atts,
      'timestamp': (m['timestamp'] as number) ?? 0,
      'reasoning': (m['reasoning'] as string) ?? '',
      'toolCalls': calls
    };
  }

  // ===== 配置类数据仍走 Preferences =====

  static async saveApiConfig(context: Context, config: ApiConfig): Promise<void> {
    let prefs: preferences.Preferences = await getPreferences(context);
    await prefs.put(Constants.LS_KEY_API_CONFIG, JSON.stringify(config.toJson()));
    await prefs.flush();
  }

  static async loadApiConfig(context: Context): Promise<ApiConfig | null> {
    let prefs: preferences.Preferences = await getPreferences(context);
    let jsonStr: string = (await prefs.get(Constants.LS_KEY_API_CONFIG, '')) as string;
    if (jsonStr === '') {
      return null;
    }
    let parsed: Object = JSON.parse(jsonStr);
    if (typeof parsed !== 'object' || parsed === null) {
      return null;
    }
    return ApiConfig.fromJson(parsed as Record<string, Object>);
  }

  static async saveMultimodalConfig(context: Context, config: MultimodalConfig): Promise<void> {
    let prefs: preferences.Preferences = await getPreferences(context);
    await prefs.put(Constants.LS_KEY_MULTIMODAL_CONFIG, JSON.stringify(config.toJson()));
    await prefs.flush();
  }

  static async loadMultimodalConfig(context: Context): Promise<MultimodalConfig> {
    let prefs: preferences.Preferences = await getPreferences(context);
    let jsonStr: string = (await prefs.get(Constants.LS_KEY_MULTIMODAL_CONFIG, '')) as string;
    if (jsonStr === '') {
      return MultimodalConfig.default();
    }
    let parsed: Object = JSON.parse(jsonStr);
    if (typeof parsed !== 'object' || parsed === null) {
      return MultimodalConfig.default();
    }
    return MultimodalConfig.fromJson(parsed as Record<string, Object>);
  }

  static async saveApiProfiles(context: Context, profiles: ApiProfile[]): Promise<void> {
    let data: Object[] = [];
    for (let i: number = 0; i < profiles.length; i++) {
      data.push(profiles[i].toJson());
    }
    let prefs: preferences.Preferences = await getPreferences(context);
    await prefs.put(Constants.LS_KEY_API_PROFILES, JSON.stringify(data));
    await prefs.flush();
  }

  static async loadApiProfiles(context: Context): Promise<ApiProfile[]> {
    let prefs: preferences.Preferences = await getPreferences(context);
    let jsonStr: string = (await prefs.get(Constants.LS_KEY_API_PROFILES, '')) as string;
    if (jsonStr === '') {
      return [];
    }
    let parsed: Object = JSON.parse(jsonStr);
    if (!(parsed instanceof Array)) {
      return [];
    }
    let values: Object[] = parsed as Object[];
    let result: ApiProfile[] = [];
    for (let i: number = 0; i < values.length; i++) {
      result.push(ApiProfile.fromJson(values[i] as Record<string, Object>));
    }
    return result;
  }

  static async saveBoolean(context: Context, key: string, val: boolean): Promise<void> {
    let prefs: preferences.Preferences = await getPreferences(context);
    await prefs.put(key, val);
    await prefs.flush();
  }

  static async loadBoolean(context: Context, key: string, defaultVal: boolean): Promise<boolean> {
    let prefs: preferences.Preferences = await getPreferences(context);
    let v: Object = await prefs.get(key, defaultVal);
    if (typeof v === 'boolean') {
      return v;
    }
    return defaultVal;
  }

  static async saveString(context: Context, key: string, val: string): Promise<void> {
    let prefs: preferences.Preferences = await getPreferences(context);
    await prefs.put(key, val);
    await prefs.flush();
  }

  static async loadString(context: Context, key: string, defaultVal: string): Promise<string> {
    let prefs: preferences.Preferences = await getPreferences(context);
    let v: Object = await prefs.get(key, defaultVal);
    if (typeof v === 'string') {
      return v;
    }
    return defaultVal;
  }
}
