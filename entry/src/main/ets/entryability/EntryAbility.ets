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

import { AbilityConstant, ConfigurationConstant, UIAbility, Want, Configuration } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { systemShare } from '@kit.ShareKit';
import { window } from '@kit.ArkUI';
import { BackgroundTaskService } from '../service/BackgroundTaskService';

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
    this.publishSharedFiles(want);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.publishSharedFiles(want);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
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

      // 读取当前系统 colorMode, 按深浅色设置状态栏 & 导航栏颜色
      try {
        const win = windowStage.getMainWindowSync();
        this.mainWindow = win;
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
    // 回到前台后进程不再受挂起限制, 立即释放后台保活任务(若切后台期间流式已结束, stop 为空操作)
    BackgroundTaskService.stop(this.context);
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // 切后台时若流式长程任务(AI 回复/Agent 循环)仍在进行, 申请 dataTransfer 长时任务保活
    if (AppStorage.get<boolean>('chatStreamingActive') === true) {
      BackgroundTaskService.start(this.context);
    }
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

  // 根据深浅色主题设置状态栏 & 导航栏颜色
  private applySystemBarTheme(win: window.Window, isDark: boolean): void {
    if (isDark) {
      // 深色下 statusBar/navigationBar 用 surface (#1B1F27) 与顶部标题栏、底部输入区背景一致
      win.setWindowSystemBarProperties({
        statusBarColor: '#FF1B1F27',
        statusBarContentColor: '#FFEDF0F5',
        navigationBarColor: '#FF1B1F27',
        navigationBarContentColor: '#FFEDF0F5'
      });
    } else {
      // 浅色下 statusBar/navigationBar 用 surface (#FFFFFF) 与顶部标题栏、底部输入区背景一致
      win.setWindowSystemBarProperties({
        statusBarColor: '#FFFFFFFF',
        statusBarContentColor: '#FF1B2330',
        navigationBarColor: '#FFFFFFFF',
        navigationBarContentColor: '#FF1B2330'
      });
    }
  }
}
