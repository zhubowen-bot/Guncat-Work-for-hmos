import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { StorageManager } from '../data/StorageManager';
import { BackgroundReaderService } from './BackgroundReaderService';

export class ReaderVoiceOption {
  label: string = '';
  language: string = '';
  person: number = 0;
  style: string = '';
  gender: string = '';
}

export class ReaderProgress {
  visible: boolean = false;
  phase: string = '';
  progress: number = 0;
  voiceIndex: number = 0;
  voices: ReaderVoiceOption[] = [];
  speed: number = 1.5;
  paused: boolean = false;
}

export class ReaderCallbacks {
  onChange: (state: ReaderProgress) => void = (_state: ReaderProgress): void => {};
}

class ReaderSpeakListener implements textToSpeech.SpeakListener {
  onStart(requestId: string, _response: textToSpeech.StartResponse): void {
    TextReaderService.handleStart(requestId);
  }

  onComplete(requestId: string, response: textToSpeech.CompleteResponse): void {
    TextReaderService.handleComplete(requestId, response.type);
  }

  onStop(requestId: string, _response: textToSpeech.StopResponse): void {
    TextReaderService.handleStop(requestId);
  }

  onError(requestId: string, errorCode: number, errorMessage: string): void {
    TextReaderService.handleError(requestId, errorCode, errorMessage);
  }
}

export class TextReaderService {
  private static engine: textToSpeech.TextToSpeechEngine | null = null;
  private static callbacks: ReaderCallbacks = new ReaderCallbacks();
  private static voices: textToSpeech.VoiceInfo[] = [];
  private static voiceOptions: ReaderVoiceOption[] = [];
  private static voiceIndex: number = 0;
  private static speed: number = 1.5;
  private static context: common.UIAbilityContext | null = null;
  private static initialized: boolean = false;
  private static savedVoiceKey: string = '';
  private static currentRequestId: string = '';
  private static currentText: string = '';
  private static startOffset: number = 0;
  private static progressTimer: number = -1;
  private static progressValue: number = 0;
  private static progressStartedAt: number = 0;
  private static estimatedRemainingMs: number = 1000;
  private static requestSequence: number = 0;
  private static restarting: boolean = false;
  private static restartTimer: number = -1;
  private static paused: boolean = false;

  static setCallbacks(callbacks: ReaderCallbacks): void {
    TextReaderService.callbacks = callbacks;
  }

  static async initialize(context: common.UIAbilityContext): Promise<void> {
    TextReaderService.context = context;
    if (TextReaderService.initialized) {
      return;
    }
    let savedSpeed: string =
      await StorageManager.loadString(context, 'reader_speed', '1.5');
    let parsedSpeed: number = Number.parseFloat(savedSpeed);
    if (!Number.isNaN(parsedSpeed)) {
      TextReaderService.speed = Math.max(0.5, Math.min(2, parsedSpeed));
    }
    TextReaderService.savedVoiceKey =
      await StorageManager.loadString(context, 'reader_voice', '');
    TextReaderService.initialized = true;
  }

  private static notify(phase: string, progress: number, visible: boolean): void {
    let state: ReaderProgress = new ReaderProgress();
    state.phase = phase;
    state.progress = progress;
    state.visible = visible;
    state.voiceIndex = TextReaderService.voiceIndex;
    state.voices = TextReaderService.voiceOptions;
    state.speed = TextReaderService.speed;
    state.paused = TextReaderService.paused;
    TextReaderService.callbacks.onChange(state);
  }

  private static nextRequestId(): string {
    TextReaderService.requestSequence++;
    return Date.now().toString() + TextReaderService.requestSequence.toString();
  }

  private static voiceLabel(voice: textToSpeech.VoiceInfo, index: number): string {
    if (voice.description.trim() !== '') {
      return voice.description;
    }
    return voice.language + ' · 音色 ' + (index + 1).toString();
  }

  private static voiceKey(voice: textToSpeech.VoiceInfo): string {
    return voice.language + '|' + voice.person.toString() + '|' + voice.style;
  }

  private static async queryVoices(): Promise<void> {
    if (TextReaderService.voices.length > 0) {
      return;
    }
    let query: textToSpeech.VoiceQuery = {
      requestId: TextReaderService.nextRequestId(),
      online: 1
    };
    TextReaderService.voices = await textToSpeech.listVoices(query);
    if (TextReaderService.voices.length === 0) {
      throw new Error('设备没有可用的系统朗读音色');
    }
    let options: ReaderVoiceOption[] = [];
    let preferredIndex: number = 0;
    let femaleIndex: number = -1;
    let savedIndex: number = -1;
    for (let index: number = 0; index < TextReaderService.voices.length; index++) {
      let voice: textToSpeech.VoiceInfo = TextReaderService.voices[index];
      let option: ReaderVoiceOption = new ReaderVoiceOption();
      option.label = TextReaderService.voiceLabel(voice, index);
      option.language = voice.language;
      option.person = voice.person;
      option.style = voice.style;
      option.gender = voice.gender;
      options.push(option);
      if (femaleIndex === -1 && voice.gender.toLowerCase().includes('female')) {
        femaleIndex = index;
      }
      if (TextReaderService.savedVoiceKey !== '' &&
        TextReaderService.voiceKey(voice) === TextReaderService.savedVoiceKey) {
        savedIndex = index;
      }
      let gender: string = voice.gender.toLowerCase();
      let isFemale: boolean = gender.includes('female') || gender.includes('女') ||
        voice.description.includes('女声');
      if (preferredIndex === 0 && voice.person !== 0 && !isFemale) {
        preferredIndex = index;
      }
    }
    TextReaderService.voiceOptions = options;
    if (femaleIndex !== -1) {
      preferredIndex = femaleIndex;
    }
    if (savedIndex !== -1) {
      preferredIndex = savedIndex;
    }
    TextReaderService.voiceIndex = preferredIndex;
  }

  private static async createEngineForSelectedVoice(): Promise<void> {
    await TextReaderService.queryVoices();
    let selected: textToSpeech.VoiceInfo = TextReaderService.voices[TextReaderService.voiceIndex];
    if (selected.status === 'EOM') {
      throw new Error('该音色当前不可用');
    }
    if (TextReaderService.engine !== null) {
      TextReaderService.engine.shutdown();
      TextReaderService.engine = null;
    }
    let params: textToSpeech.CreateEngineParams = {
      language: selected.language,
      person: selected.person,
      online: 1,
      extraParams: {
        'style': selected.style,
        'locate': 'CN',
        'name': 'Guncat Work Reader',
        'isBackStage': true
      }
    };
    let engine: textToSpeech.TextToSpeechEngine | null = null;
    try {
      engine = await textToSpeech.createEngine(params);
    } catch (error) {
      if (selected.status !== 'GA') {
        throw new Error('所选系统音色无法初始化');
      }
      await TextReaderService.ensureVoiceDownloaded(selected);
      engine = await textToSpeech.createEngine(params);
    }
    if (engine === null) {
      throw new Error('朗读引擎初始化失败');
    }
    engine.setListener(new ReaderSpeakListener());
    TextReaderService.engine = engine;
  }

  private static async ensureEngine(): Promise<void> {
    await TextReaderService.queryVoices();
    if (TextReaderService.engine === null) {
      await TextReaderService.createEngineForSelectedVoice();
    }
  }

  private static ensureVoiceDownloaded(voice: textToSpeech.VoiceInfo): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      let downloadParams: textToSpeech.VoiceDownload = {
        requestId: TextReaderService.nextRequestId(),
        language: voice.language,
        person: voice.person,
        style: voice.style
      };
      textToSpeech.downloadVoice(downloadParams,
        (error: BusinessError, response: textToSpeech.DownloadResponse): void => {
          if (error !== undefined && error.code === 1002300010) {
            resolve();
            return;
          }
          if (error !== undefined && error.code !== 0) {
            reject(new Error('系统音色下载失败：' + error.message));
            return;
          }
          response.on('start', (_message: string): void => {
            TextReaderService.notify('正在下载所选音色', TextReaderService.progressValue, true);
          });
          response.on('progress', (progressText: string): void => {
            let progress: number = Number.parseFloat(progressText);
            if (!Number.isNaN(progress)) {
              TextReaderService.notify('正在下载所选音色', Math.min(0.95, progress / 100), true);
            }
          });
          response.on('complete', (_voice: textToSpeech.VoiceInfo): void => {
            resolve();
          });
          response.on('cancel', (_message: string): void => {
            reject(new Error('已取消系统音色下载'));
          });
          response.on('error', (downloadError: BusinessError): void => {
            reject(new Error('系统音色下载失败：' + downloadError.message));
          });
        });
    });
  }

  private static estimateProgress(): number {
    if (TextReaderService.currentText.length === 0) {
      return 0;
    }
    let elapsed: number = Date.now() - TextReaderService.progressStartedAt;
    let localProgress: number = Math.min(0.98, elapsed / TextReaderService.estimatedRemainingMs);
    let remainingRatio: number =
      (TextReaderService.currentText.length - TextReaderService.startOffset) /
      TextReaderService.currentText.length;
    return Math.min(0.99,
      TextReaderService.startOffset / TextReaderService.currentText.length + localProgress * remainingRatio);
  }

  private static startProgressTimer(): void {
    TextReaderService.stopProgressTimer();
    TextReaderService.progressStartedAt = Date.now();
    let remainingChars: number =
      Math.max(1, TextReaderService.currentText.length - TextReaderService.startOffset);
    TextReaderService.estimatedRemainingMs =
      Math.max(1000, remainingChars * 240 / TextReaderService.speed);
    TextReaderService.progressTimer = setInterval((): void => {
      TextReaderService.progressValue = TextReaderService.estimateProgress();
      TextReaderService.notify('正在朗读', TextReaderService.progressValue, true);
    }, 250);
  }

  private static stopProgressTimer(): void {
    if (TextReaderService.progressTimer !== -1) {
      clearInterval(TextReaderService.progressTimer);
      TextReaderService.progressTimer = -1;
    }
  }

  private static findReadableOffset(target: number): number {
    if (target <= 0) {
      return 0;
    }
    if (target >= TextReaderService.currentText.length) {
      return TextReaderService.currentText.length - 1;
    }
    let punctuation: string = '。！？；.!?;\n';
    let lowerBound: number = Math.max(0, target - 40);
    for (let index: number = target; index >= lowerBound; index--) {
      if (punctuation.includes(TextReaderService.currentText.charAt(index))) {
        return Math.min(TextReaderService.currentText.length - 1, index + 1);
      }
    }
    return target;
  }

  private static async speakFromOffset(): Promise<void> {
    if (TextReaderService.engine === null || TextReaderService.currentText.length === 0) {
      return;
    }
    if (TextReaderService.context !== null) {
      try {
        await BackgroundReaderService.start(TextReaderService.context);
      } catch (error) {
        console.error('Failed to start reader background task');
      }
    }
    TextReaderService.currentRequestId = TextReaderService.nextRequestId();
    TextReaderService.paused = false;
    let extraParams: Record<string, Object> = {
      'speed': TextReaderService.speed,
      'playType': 1,
      'queueMode': 1,
      'soundChannel': 3
    };
    let speakParams: textToSpeech.SpeakParams = {
      requestId: TextReaderService.currentRequestId,
      extraParams: extraParams
    };
    TextReaderService.notify('准备朗读', TextReaderService.progressValue, true);
    TextReaderService.engine.speak(
      TextReaderService.currentText.substring(TextReaderService.startOffset), speakParams);
  }

  static handleStart(requestId: string): void {
    if (requestId !== TextReaderService.currentRequestId) {
      return;
    }
    TextReaderService.startProgressTimer();
  }

  static handleComplete(requestId: string, completeType: number): void {
    if (requestId !== TextReaderService.currentRequestId) {
      return;
    }
    if (TextReaderService.restarting) {
      TextReaderService.finishRestart(requestId);
      return;
    }
    if (completeType !== 1) {
      return;
    }
    TextReaderService.stopProgressTimer();
    TextReaderService.currentRequestId = '';
    TextReaderService.progressValue = 1;
    TextReaderService.notify('朗读完成，可拖动进度重新播放', 1, true);
    if (TextReaderService.context !== null) {
      BackgroundReaderService.stop(TextReaderService.context);
    }
  }

  static handleStop(requestId: string): void {
    if (requestId !== TextReaderService.currentRequestId) {
      return;
    }
    if (TextReaderService.restarting) {
      TextReaderService.finishRestart(requestId);
      return;
    }
    TextReaderService.stopProgressTimer();
    TextReaderService.currentRequestId = '';
    TextReaderService.notify('朗读已暂停', TextReaderService.progressValue, true);
  }

  static handleError(requestId: string, errorCode: number, errorMessage: string): void {
    if (requestId !== TextReaderService.currentRequestId) {
      return;
    }
    TextReaderService.stopProgressTimer();
    TextReaderService.currentRequestId = '';
    TextReaderService.notify('朗读失败：' + errorCode.toString() + ' ' + errorMessage,
      TextReaderService.progressValue, true);
    if (TextReaderService.context !== null) {
      BackgroundReaderService.stop(TextReaderService.context);
    }
  }

  static async read(_context: common.UIAbilityContext, _id: string, text: string): Promise<void> {
    await TextReaderService.stop();
    await TextReaderService.initialize(_context);
    TextReaderService.currentText = text;
    TextReaderService.startOffset = 0;
    TextReaderService.progressValue = 0;
    TextReaderService.paused = false;
    TextReaderService.notify('正在查询可用音色', 0, true);
    await TextReaderService.ensureEngine();
    TextReaderService.speakFromOffset();
  }

  static async selectVoice(index: number): Promise<void> {
    await TextReaderService.queryVoices();
    if (index < 0 || index >= TextReaderService.voices.length ||
      index === TextReaderService.voiceIndex) {
      return;
    }
    let shouldResume: boolean = TextReaderService.currentRequestId !== '';
    TextReaderService.progressValue = TextReaderService.estimateProgress();
    TextReaderService.startOffset =
      TextReaderService.findReadableOffset(
        Math.round(TextReaderService.progressValue * TextReaderService.currentText.length));
    TextReaderService.restarting = true;
    TextReaderService.stopProgressTimer();
    if (TextReaderService.engine !== null && TextReaderService.engine.isBusy()) {
      TextReaderService.engine.stop();
    }
    TextReaderService.currentRequestId = '';
    TextReaderService.voiceIndex = index;
    TextReaderService.savedVoiceKey =
      TextReaderService.voiceKey(TextReaderService.voices[index]);
    if (TextReaderService.context !== null) {
      await StorageManager.saveString(
        TextReaderService.context, 'reader_voice', TextReaderService.savedVoiceKey);
    }
    TextReaderService.notify('正在切换音色', TextReaderService.progressValue, true);
    await TextReaderService.createEngineForSelectedVoice();
    TextReaderService.restarting = false;
    if (shouldResume) {
      TextReaderService.speakFromOffset();
    } else {
      TextReaderService.notify('音色已切换', TextReaderService.progressValue, true);
    }
  }

  static setSpeed(speed: number): void {
    TextReaderService.speed = Math.max(0.5, Math.min(2, speed));
    if (TextReaderService.context !== null) {
      StorageManager.saveString(
        TextReaderService.context, 'reader_speed', TextReaderService.speed.toString());
    }
    if (TextReaderService.currentRequestId !== '') {
      TextReaderService.restartAtCurrentProgress();
    } else if (TextReaderService.currentText.length > 0) {
      if (TextReaderService.progressValue >= 0.99) {
        TextReaderService.progressValue = 0;
        TextReaderService.startOffset = 0;
      }
      TextReaderService.restartFromSelection();
    } else {
      TextReaderService.notify('语速 ' + TextReaderService.speed.toFixed(1) + '×',
        TextReaderService.progressValue, true);
    }
  }

  static pause(): void {
    if (TextReaderService.engine === null || TextReaderService.currentRequestId === '') {
      return;
    }
    TextReaderService.progressValue = TextReaderService.estimateProgress();
    TextReaderService.startOffset = TextReaderService.findReadableOffset(
      Math.round(TextReaderService.progressValue * TextReaderService.currentText.length));
    TextReaderService.stopProgressTimer();
    TextReaderService.currentRequestId = '';
    TextReaderService.paused = true;
    if (TextReaderService.engine.isBusy()) {
      TextReaderService.engine.stop();
    }
    if (TextReaderService.context !== null) {
      BackgroundReaderService.stop(TextReaderService.context);
    }
    TextReaderService.notify('已暂停', TextReaderService.progressValue, true);
  }

  static resume(): void {
    if (!TextReaderService.paused || TextReaderService.currentText.length === 0) {
      return;
    }
    TextReaderService.paused = false;
    TextReaderService.notify('正在继续朗读', TextReaderService.progressValue, true);
    if (TextReaderService.restartTimer !== -1) {
      clearTimeout(TextReaderService.restartTimer);
    }
    TextReaderService.restartTimer = setTimeout((): void => {
      TextReaderService.restartTimer = -1;
      TextReaderService.speakFromOffset();
    }, 220);
  }

  static seek(progress: number): void {
    if (TextReaderService.currentText.length === 0) {
      return;
    }
    TextReaderService.progressValue = Math.max(0, Math.min(0.99, progress));
    TextReaderService.startOffset = TextReaderService.findReadableOffset(
      Math.round(TextReaderService.progressValue * TextReaderService.currentText.length));
    TextReaderService.restartFromSelection();
  }

  private static restartAtCurrentProgress(): void {
    TextReaderService.progressValue = TextReaderService.estimateProgress();
    TextReaderService.startOffset = TextReaderService.findReadableOffset(
      Math.round(TextReaderService.progressValue * TextReaderService.currentText.length));
    TextReaderService.restartFromSelection();
  }

  private static restartFromSelection(): void {
    if (TextReaderService.engine === null) {
      return;
    }
    TextReaderService.restarting = true;
    TextReaderService.stopProgressTimer();
    TextReaderService.notify('正在应用朗读设置', TextReaderService.progressValue, true);
    if (TextReaderService.engine.isBusy()) {
      TextReaderService.engine.stop();
      let stoppedRequestId: string = TextReaderService.currentRequestId;
      if (TextReaderService.restartTimer !== -1) {
        clearTimeout(TextReaderService.restartTimer);
      }
      TextReaderService.restartTimer = setTimeout((): void => {
        TextReaderService.finishRestart(stoppedRequestId);
      }, 500);
      return;
    }
    TextReaderService.currentRequestId = '';
    TextReaderService.restarting = false;
    TextReaderService.paused = false;
    TextReaderService.speakFromOffset();
  }

  private static finishRestart(stoppedRequestId: string): void {
    if (!TextReaderService.restarting ||
      stoppedRequestId !== TextReaderService.currentRequestId) {
      return;
    }
    if (TextReaderService.restartTimer !== -1) {
      clearTimeout(TextReaderService.restartTimer);
      TextReaderService.restartTimer = -1;
    }
    TextReaderService.currentRequestId = '';
    TextReaderService.restarting = false;
    TextReaderService.restartTimer = setTimeout((): void => {
      TextReaderService.restartTimer = -1;
      TextReaderService.speakFromOffset();
    }, 180);
  }

  static async stop(): Promise<void> {
    TextReaderService.stopProgressTimer();
    if (TextReaderService.restartTimer !== -1) {
      clearTimeout(TextReaderService.restartTimer);
      TextReaderService.restartTimer = -1;
    }
    TextReaderService.restarting = false;
    if (TextReaderService.engine !== null && TextReaderService.engine.isBusy()) {
      TextReaderService.engine.stop();
    }
    TextReaderService.currentRequestId = '';
    TextReaderService.currentText = '';
    TextReaderService.startOffset = 0;
    TextReaderService.progressValue = 0;
    TextReaderService.notify('', 0, false);
    if (TextReaderService.context !== null) {
      await BackgroundReaderService.stop(TextReaderService.context);
    }
  }
}
