/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want, Configuration, common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { systemShare } from '@kit.ShareKit';
import { window } from '@kit.ArkUI';
import { BackgroundTaskService } from '../service/BackgroundTaskService';
import { StorageManager } from '../data/StorageManager';
import { HarnessTools } from '../service/HarnessTools';
import { IecShellService } from '../service/IecShellService';
import { ToolExecResult } from '../service/WorkFileService';
import { UsageMeter } from '../service/UsageMeter';
import { startPyRunner } from 'iec';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  // 缓存窗口引用, 供 onConfigurationUpdate 中更新状态栏颜色
  private mainWindow: window.Window | undefined = undefined;
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // 初始化时同步当前系统主题到 AppStorage, 供 RichTextView 等组件读取
    // 优先用 onConfigurationUpdate 写入, 启动时也兜底读取一次
    AppStorage.setOrCreate<boolean>('systemColorMode', false);
    AppStorage.setOrCreate<string>('sharedFileUris', '');
    // 前后台状态: 页面用它暂停 1s/100ms 轮询, VM 用它判断后台启动的任务要不要保活
    AppStorage.setOrCreate<boolean>('appForeground', true);
    // 用量账本只记住 filesDir, 不在这里读盘; 第一次记账/打开用量页时才懒加载。
    UsageMeter.init(this.context);
    this.publishSharedFiles(want);
    // shell 工具走设备内原生执行核（IEC）：不启虚拟机、不需要 JIT 权限。
    // 钩子由 .ets 侧注入，HarnessTools(.ts) 只负责调用。
    // 先起 python3 的独立解释器 runner：必须在任何 run_python 之前 fork，此时
    // 进程内还没有初始化 CPython，runner 才能给出干净的解释器。
    try {
      const ok: boolean = startPyRunner();
      hilog.info(DOMAIN, 'testTag', 'python runner: %{public}s', ok ? 'started' : 'failed');
    } catch (e) {
      hilog.warn(DOMAIN, 'testTag', 'python runner failed: %{public}s', JSON.stringify(e));
    }
    HarnessTools.shellBackendHook =
      (context: common.UIAbilityContext, convId: string, args: Record<string, Object>):
        Promise<ToolExecResult> => IecShellService.run(context, convId, args);

    // 验收钩子：`aa start ... --ps iecSelfTest 1` 时跑一条命令，把结果写 hilog。
    const params: Record<string, Object> | undefined = want.parameters;
    if (params !== undefined && params['iecSelfTest'] !== undefined) {
      hilog.info(DOMAIN, 'IecSelfTest', 'starting');
      IecShellService.selfTest(this.context).then((text: string): void => {
        // 逐行打：一次 hilog 调用有长度上限，整段多行结果会被截断/拆散，
        // 之后想 grep 一行 [FAIL] 都找不到。
        text.split('\n').forEach((line: string): void => {
          hilog.info(DOMAIN, 'IecSelfTest', 'ST|%{public}s', line);
        });
      }).catch((e: Error): void => {
        hilog.error(DOMAIN, 'IecSelfTest', 'FAILED %{public}s', e.message);
      });
    }
    this.runProbe(want);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.publishSharedFiles(want);
    // 覆盖已运行实例时也能跑探针：冷启动只用于安装后第一次，之后的排障
    // 用 `aa start` 落到这里，不必 force-stop（前台也就不会中断）。
    this.runProbe(want);
  }

  // 调试钩子：`aa start ... --ps iecCmdB64 <base64>` 时用 shell 工具同一条链路跑一遍，
  // 结果写 hilog。只用于真机排障，正常使用不会走到这里。命令走 base64 是为了避开
  // aa 参数对引号/空格/中文的解析；可选的 `iecStdinB64` 注入同一份 stdin。
  private runProbe(want: Want): void {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) return;
    const raw: Object | undefined = params['iecCmdB64'];
    if (raw === undefined) return;
    let command: string = '';
    let stdin: string = '';
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      command = decoder.decodeToString(new util.Base64Helper().decodeSync(raw as string));
      const stdinRaw: Object | undefined = params['iecStdinB64'];
      if (stdinRaw !== undefined) {
        const d2: util.TextDecoder = util.TextDecoder.create('utf-8');
        stdin = d2.decodeToString(new util.Base64Helper().decodeSync(stdinRaw as string));
      }
    } catch (e) {
      hilog.error(DOMAIN, 'IecProbe', 'bad probe param: %{public}s', JSON.stringify(e));
      return;
    }
    hilog.info(DOMAIN, 'IecProbe', 'CMD %{public}s', command);
    let timeoutMs: number = 30000;
    const tRaw: Object | undefined = params['iecTimeoutMs'];
    if (tRaw !== undefined) {
      const t: number = Number(tRaw as string);
      if (!isNaN(t) && t >= 1000) timeoutMs = t;
    }
    let cwd: string = '';
    const cRaw: Object | undefined = params['iecCwd'];
    if (cRaw !== undefined) cwd = cRaw as string;
    IecShellService.run(this.context, '__iec_probe', {
      'command': command,
      'stdin': stdin,
      'cwd': cwd,
      'timeout_ms': timeoutMs
    }).then((r: ToolExecResult): void => {
      // 折成一行：hilog 会把内嵌换行拆成不带 tag 的后续行，抓日志时容易漏。
      const flat: string = r.output.split('\n').join('\\n');
      hilog.info(DOMAIN, 'IecProbe', 'RESULT %{public}s', flat);
    }).catch((e: Error): void => {
      hilog.error(DOMAIN, 'IecProbe', 'FAILED %{public}s', e.message);
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    // 进程被回收前把合并窗口里的会话落盘, 避免"退出后最后几条对话消失"
    StorageManager.flushConversations(this.context).catch((): void => {});
    // 用量账本同样落盘; 同步写几十 KB, 退出路径可以接受
    UsageMeter.flush();
    // 释放长时/短时任务，避免进程退出后系统侧还留着通知或配额占用
    BackgroundTaskService.stop(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 在 loadContent 前读取当前系统主题写入 AppStorage,
    // 否则 RichTextView 等组件初始化时 @StorageProp 读到 onCreate 硬编码的 false 值
    const isDark = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate<boolean>('systemColorMode', isDark);

    windowStage.loadContent('pages/ChatPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');

      // 初始化主窗口: 开启屏幕常亮, 并按当前系统 colorMode 设置状态栏 & 导航栏颜色
      try {
        const win = windowStage.getMainWindowSync();
        this.mainWindow = win;
        // 屏幕常亮: 应用在前台期间不自动熄屏, 避免长程任务(流式回复/Agent 循环)被熄屏打断
        this.keepScreenOn(win);
        this.applySystemBarTheme(win, isDark);
      } catch (e) {
        hilog.error(DOMAIN, 'testTag', 'Failed to set system bar. Cause: %{public}s', JSON.stringify(e));
      }
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
    this.mainWindow = undefined;
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    AppStorage.set<boolean>('appForeground', true);
    // 回到前台后进程不再受挂起限制, 立即释放后台保活任务(若切后台期间流式已结束, stop 为空操作)
    BackgroundTaskService.stop(this.context);
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    AppStorage.set<boolean>('appForeground', false);
    // 先申请保活再落盘: 大存档的序列化可能占用几百毫秒, 不能让后台任务请求
    // 排在这段同步工作后面(系统可能已经准备挂起进程)。
    // 切后台时若流式长程任务(AI 回复/Agent 循环)仍在进行, 申请 dataTransfer 长时任务保活
    if (AppStorage.get<boolean>('chatStreamingActive') === true) {
      BackgroundTaskService.start(this.context);
    }
    // 切后台前落盘: 系统随时可能回收后台进程, 合并写窗口里的内容不能丢
    StorageManager.flushConversations(this.context).catch((): void => {});
    // 用量账本通常只有几十 KB, 同步 flush 一次, 避免最后几笔统计丢在内存里
    UsageMeter.flush();
    // 页面侧的 1s/100ms 轮询会在下一次 tick 看到 appForeground=false 后跳过重活
  }

  private async publishSharedFiles(want: Want): Promise<void> {
    let uris: string[] = [];
    try {
      const sharedData: systemShare.SharedData = await systemShare.getSharedData(want);
      const records: systemShare.SharedRecord[] = sharedData.getRecords();
      for (let i: number = 0; i < records.length; i++) {
        const uri: string | undefined = records[i].uri;
        if (uri !== undefined && uri !== '') {
          uris.push(uri);
        }
      }
    } catch (err) {
      hilog.info(DOMAIN, 'testTag', 'Want does not contain Share Kit data: %{public}s', JSON.stringify(err));
    }
    if (uris.length === 0 && want.parameters !== undefined) {
      let streamValue: Object | undefined = want.parameters['ability.params.stream'];
      if (streamValue instanceof Array) {
        let values: Object[] = streamValue as Object[];
        for (let i: number = 0; i < values.length; i++) {
          if (typeof values[i] === 'string') {
            uris.push(values[i] as string);
          }
        }
      } else if (typeof streamValue === 'string') {
        uris.push(streamValue as string);
      }
    }
    if (uris.length === 0 && want.uri !== undefined && want.uri !== '') {
      uris.push(want.uri);
    }
    if (uris.length > 0) {
      AppStorage.set<string>('sharedFileUris', JSON.stringify(uris));
    }
  }

  // 系统配置变化回调 (深浅色模式切换)
  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.info(DOMAIN, 'testTag', 'onConfigurationUpdate colorMode=%{public}d', newConfig.colorMode);
    // ConfigurationConstant.ColorMode: 0=LIGHT, 1=DARK
    const isDark = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.set<boolean>('systemColorMode', isDark);

    // 同步更新系统状态栏、导航栏颜色
    try {
      if (this.mainWindow !== undefined) {
        this.applySystemBarTheme(this.mainWindow, isDark);
      }
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'Failed to update system bar on config change. Cause: %{public}s', JSON.stringify(e));
    }
  }

  // 屏幕常亮: 应用打开后一直保持亮屏, 避免任务执行中因熄屏中断
  // 参见 https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/brightness-control
  private keepScreenOn(win: window.Window): void {
    win.setWindowKeepScreenOn(true).then((): void => {
      hilog.info(DOMAIN, 'testTag', '%{public}s', 'Succeeded in keeping the screen on.');
    }).catch((err: BusinessError): void => {
      hilog.error(DOMAIN, 'testTag', 'Failed to keep the screen on. Cause: %{public}s', JSON.stringify(err));
    });
  }

  // 根据深浅色主题设置状态栏 & 导航栏颜色。
  // 状态栏直接用顶栏的 surface 色, 视觉上等同于把标题栏底色向上拉长;
  // 内容仍由系统安全区限制在下方, 不会上移。导航栏保持透明, 由页面底部自行延伸。
  private applySystemBarTheme(win: window.Window, isDark: boolean): void {
    if (isDark) {
      win.setWindowBackgroundColor('#FF151517');
      win.setWindowSystemBarProperties({
        statusBarColor: '#FF232324',
        statusBarContentColor: '#FFEDF0F5',
        navigationBarColor: '#00000000',
        navigationBarContentColor: '#FFEDF0F5'
      });
    } else {
      win.setWindowBackgroundColor('#FFFFFFFF');
      win.setWindowSystemBarProperties({
        statusBarColor: '#FFFFFFFF',
        statusBarContentColor: '#FF1B2330',
        navigationBarColor: '#00000000',
        navigationBarContentColor: '#FF1B2330'
      });
    }
  }
}
