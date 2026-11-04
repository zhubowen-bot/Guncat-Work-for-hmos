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
  // 上一次会话存档是否读取成功(见 loadConversations / conversationsLoadOk)
  private static loadOk: boolean = false;

  // ===== 存档合并写(关键性能修复) =====
  // 工具步骤边界会连续触发多次持久化; 每次都对**全部会话**做 toJson + stringify +
  // 写盘, 长任务下等于每秒把几 MB 历史搬好几遍, 是切后台/长对话闪退的主因之一。
  // 这里改成"合并写": 800ms 内的多次请求只写一次, 需要立刻落盘时调用
  // flushConversations()(切后台/停止生成/退出)。
  private static readonly SAVE_COALESCE_MS: number = 800;
  private static saveTimer: number = -1;
  private static pendingContext: Context | undefined = undefined;
  private static pendingConversations: Conversation[] | undefined = undefined;
  private static writeInFlight: boolean = false;
  private static writeAgain: boolean = false;

  // ===== 对话历史: 文件存储(无 Preferences 体积上限) =====

  private static conversationsFilePath(context: Context): string {
    return (context as common.UIAbilityContext).filesDir + '/' + StorageManager.CONVERSATIONS_FILE;
  }

  static async saveConversations(context: Context, convs: Conversation[]): Promise<void> {
    // 只记下最新引用, 真正序列化交给合并写。convs 是内存中的会话数组,
    // 稍后写盘时拿到的就是最新状态, 不会写入过期快照。
    StorageManager.pendingContext = context;
    StorageManager.pendingConversations = convs;
    if (StorageManager.saveTimer !== -1) {
      return;
    }
    StorageManager.saveTimer = setTimeout((): void => {
      StorageManager.saveTimer = -1;
      StorageManager.writePending();
    }, StorageManager.SAVE_COALESCE_MS);
  }

  /** 立刻把待写数据落盘(切后台/停止生成/退出前调用)。可安全重复调用。 */
  static async flushConversations(context?: Context): Promise<void> {
    if (context !== undefined) {
      StorageManager.pendingContext = context;
    }
    if (StorageManager.saveTimer !== -1) {
      clearTimeout(StorageManager.saveTimer);
      StorageManager.saveTimer = -1;
    }
    StorageManager.writePending();
  }

  private static writePending(): void {
    if (StorageManager.writeInFlight) {
      // 上一次写盘还没结束: 标记需要再写一轮, 不并发持有两份大对象。
      StorageManager.writeAgain = true;
      return;
    }
    const context: Context | undefined = StorageManager.pendingContext;
    const convs: Conversation[] | undefined = StorageManager.pendingConversations;
    StorageManager.pendingContext = undefined;
    StorageManager.pendingConversations = undefined;
    if (context === undefined || convs === undefined) {
      return;
    }
    StorageManager.writeInFlight = true;
    try {
      StorageManager.writeStore(context, convs);
    } catch (error) {
      // 保存失败不抛出, 避免反复重试放大内存压力
      console.error('saveConversations failed: ' + JSON.stringify(error));
    } finally {
      StorageManager.writeInFlight = false;
      if (StorageManager.writeAgain || StorageManager.pendingConversations !== undefined) {
        StorageManager.writeAgain = false;
        // 让出一拍再写, 避免工具步骤密集时把主线程连续占死。
        setTimeout((): void => {
          StorageManager.writePending();
        }, 0);
      }
    }
  }

  private static writeStore(context: Context, convs: Conversation[]): void {
    // 只序列化一次; 附件图片字节超阈值时, 仍先剥离 dataUrl/thumbnail(保留文件名与解析文本)
    let arr: Object[] = [];
    for (let i: number = 0; i < convs.length; i++) {
      arr.push(convs[i].toJson());
    }
    if (StorageManager.hasHeavyAttachments(convs)) {
      arr = StorageManager.sanitizeConversations(arr);
    }
    // 工作模式长任务的 reasoning 会无限增长, 落盘前只保留末尾(原有行为, 不丢会话)
    StorageManager.capReasoning(arr);
    StorageManager.writeConversationsFile(context, JSON.stringify(arr));
  }

  static async loadConversations(context: Context): Promise<Conversation[]> {
    // 先置 false: 只有**确实读到并解析成功**才置 true。启动清扫(孤儿工作区/日志)靠它判断
    // "会话列表可信" —— 读失败时列表为空, 若拿空列表去清扫就等于把用户所有工作区删掉。
    StorageManager.loadOk = false;
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
      let convs: Conversation[] = [];
      let trusted: boolean = false;
      if (jsonStr !== '') {
        try {
          convs = StorageManager.parseConversations(jsonStr);
          trusted = true;
        } catch (e) {
          console.error('loadConversations: main store corrupt, trying backup');
        }
      }
      if (!trusted) {
        // 主文件缺失/损坏时回退到上一次成功写下的 .bak。没有这层,
        // 一次写盘中途被杀就会让用户觉得"闪退后对话全没了"。
        const backup: string = StorageManager.readConversationsBackup(context);
        if (backup !== '') {
          try {
            convs = StorageManager.parseConversations(backup);
            trusted = true;
            // 备份可用就顺手恢复主文件, 下次启动不再走回退路径。
            // 先删掉损坏的主文件: 否则 writeConversationsFile 会把它转成 .bak,
            // 反而用坏文件覆盖掉刚才这份唯一可用的备份(崩溃窗口里就彻底没了)。
            StorageManager.unlinkQuietly(StorageManager.conversationsFilePath(context));
            StorageManager.writeConversationsFile(context, backup);
          } catch (e) {
            console.error('loadConversations: backup corrupt too');
          }
        }
      }
      // 空串 = 没有存档(全新安装), 不算"读成功"; 有内容且解析成数组 = 可信
      StorageManager.loadOk = trusted;
      return convs;
    } catch (error) {
      // 读取失败(如文件损坏)不阻塞启动, 按无历史处理
      console.error('loadConversations failed: ' + JSON.stringify(error));
      return [];
    }
  }

  // 上一次 loadConversations 是否真的读到了存档(供启动清扫判断能不能按列表删孤儿)
  static conversationsLoadOk(): boolean {
    return StorageManager.loadOk;
  }

  private static parseConversations(jsonStr: string): Conversation[] {
    if (jsonStr === '') {
      return [];
    }
    let parsed: Object = JSON.parse(jsonStr);
    // 必须显式区分"格式不对"和"没有历史": 前者要让 loadConversations 回退 .bak,
    // 也不能把 loadOk 置 true(否则启动清扫会按空列表删掉用户工作区)。
    if (!(parsed instanceof Array)) {
      throw new Error('conversations store is not an array');
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

  // 原子写文件: 写临时文件 -> 旧主文件转 .bak -> 临时文件改名为主文件。
  // **不再先删主文件**: 旧实现 rename 失败时会 unlink 主文件再改名, 若进程在这两步
  // 之间被杀, 存档就彻底消失(用户看到的"闪退后对话没了")。保留 .bak 后,
  // loadConversations 可以在主文件缺失/损坏时恢复上一次成功存档。
  private static writeConversationsFile(context: Context, jsonStr: string): void {
    const abs: string = StorageManager.conversationsFilePath(context);
    const tmpPath: string = abs + '.tmp';
    const bakPath: string = abs + '.bak';
    let wroteTmp: boolean = false;
    try {
      // fileIo.writeSync 直接接受 string, 省掉 TextEncoder + ArrayBuffer 的整份复制
      // (长历史下这曾是数 MB 的额外峰值内存)。
      const tmp: fileIo.File = fileIo.openSync(tmpPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(tmp.fd, jsonStr);
      } finally {
        fileIo.closeSync(tmp.fd);
      }
      wroteTmp = true;
    } catch (e) {
      StorageManager.unlinkQuietly(tmpPath);
    }
    if (!wroteTmp) {
      // 连临时文件都写不了(空间不足等): 不覆盖现有存档, 保留上一份可用数据。
      console.error('writeConversationsFile: cannot write temp file');
      return;
    }
    let hasMain: boolean = false;
    try {
      hasMain = fileIo.accessSync(abs);
    } catch (e) {
      hasMain = false;
    }
    if (hasMain) {
      StorageManager.unlinkQuietly(bakPath);
      try {
        fileIo.renameSync(abs, bakPath);
      } catch (e) {
        // 备份失败不阻断主流程: 主文件还在, 下面直接尝试覆盖写。
        hasMain = false;
      }
    }
    try {
      fileIo.renameSync(tmpPath, abs);
      return;
    } catch (e) {
      // 部分系统版本 rename 不覆盖已存在目标: 主文件还在时先让位再改名。
      try {
        if (fileIo.accessSync(abs)) {
          StorageManager.unlinkQuietly(abs);
        }
        fileIo.renameSync(tmpPath, abs);
        return;
      } catch (e2) {
        // 继续走恢复/兜底
      }
    }
    // 改名失败: 把 .bak 恢复成主文件, 避免出现"没有任何主文件"的窗口。
    if (!hasMain) {
      try {
        if (fileIo.accessSync(bakPath)) {
          fileIo.renameSync(bakPath, abs);
        }
      } catch (e) {
        // 恢复失败只能保留 .bak 给下次启动回退
      }
    }
    // 最后兜底: 原地截断写(仍然保留刚才的 .bak)
    try {
      const file: fileIo.File = fileIo.openSync(abs,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, jsonStr);
      } finally {
        fileIo.closeSync(file.fd);
      }
      StorageManager.unlinkQuietly(tmpPath);
    } catch (e) {
      console.error('writeConversationsFile: fallback write failed');
    }
  }

  private static unlinkQuietly(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      // 文件可能不存在或正被占用, 忽略
    }
  }

  private static readConversationsFile(context: Context): string {
    return StorageManager.readTextFile(StorageManager.conversationsFilePath(context));
  }

  private static readConversationsBackup(context: Context): string {
    return StorageManager.readTextFile(StorageManager.conversationsFilePath(context) + '.bak');
  }

  private static readTextFile(abs: string): string {
    try {
      if (!fileIo.accessSync(abs)) {
        return '';
      }
      const stat: fileIo.Stat = fileIo.statSync(abs);
      if (stat.size <= 0) {
        return '';
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const file: fileIo.File = fileIo.openSync(abs, fileIo.OpenMode.READ_ONLY);
      try {
        fileIo.readSync(file.fd, buffer, { offset: 0 });
      } finally {
        fileIo.closeSync(file.fd);
      }
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return decoder.decodeToString(new Uint8Array(buffer), { stream: false });
    } catch (e) {
      return '';
    }
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
          'dataUrl': '',
          // fileId 一定要保留: 剥离内联图片后, 后续轮次还能用 Files API 引用同一份上传,
          // 否则重载后附件会变成"看得见名字但用不了"。
          'fileId': (a['fileId'] as string) ?? ''
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
      'thinkingSignature': (m['thinkingSignature'] as string) ?? '',
      'redactedThinking': (m['redactedThinking'] as string) ?? '',
      'reasoningItems': (m['reasoningItems'] as string) ?? '',
      // 速度/缓存命中是纯统计字段, 体积可忽略; 早先 sanitize 漏掉它们,
      // 一次大附件存档后重载就永久丢失, 统计行再也不显示。
      'tokenSpeed': (m['tokenSpeed'] as number) ?? -1,
      'cacheHitRate': (m['cacheHitRate'] as number) ?? -1,
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
