import { audio } from '@kit.AudioKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';

const AUDIO_PACKET_SIZE: number = 1280;

export class VoiceInputService {
  private engine: speechRecognizer.SpeechRecognitionEngine | undefined = undefined;
  private capturer: audio.AudioCapturer | undefined = undefined;
  private sessionId: string = '';
  private pendingAudio: Uint8Array = new Uint8Array(0);
  private listening: boolean = false;
  private finishing: boolean = false;
  private inputPrefix: string = '';
  private onText: (text: string) => void = (_text: string): void => {};
  private onStateChange: (listening: boolean) => void = (_listening: boolean): void => {};
  private onError: (message: string) => void = (_message: string): void => {};

  isListening(): boolean {
    return this.listening;
  }

  async start(
    inputPrefix: string,
    onText: (text: string) => void,
    onStateChange: (listening: boolean) => void,
    onError: (message: string) => void
  ): Promise<void> {
    if (this.listening) {
      return;
    }
    this.inputPrefix = inputPrefix;
    this.onText = onText;
    this.onStateChange = onStateChange;
    this.onError = onError;
    this.pendingAudio = new Uint8Array(0);
    this.finishing = false;
    this.sessionId = `guncat-asr-${Date.now()}`;

    try {
      let extraParams: Record<string, Object> = {
        'locate': 'CN',
        'recognizerMode': 'short'
      };
      this.engine = await speechRecognizer.createEngine({
        language: 'zh-CN',
        online: 1,
        extraParams: extraParams
      });
      this.setRecognitionListener();

      let options: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_VOICE_MESSAGE,
          capturerFlags: 0
        }
      };
      this.capturer = await audio.createAudioCapturer(options);
      this.capturer.on('readData', (buffer: ArrayBuffer) => {
        this.writeAudio(buffer);
      });

      this.engine.startListening({
        sessionId: this.sessionId,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: 16000,
          soundChannel: 1,
          sampleBit: 16
        }
      });
      await this.capturer.start();
      this.listening = true;
      this.onStateChange(true);
    } catch (error) {
      let businessError: BusinessError = error as BusinessError;
      console.error(`VoiceInputService start failed: ${businessError.code}, ${businessError.message}`);
      await this.releaseResources(true);
      this.onError('语音输入启动失败，请稍后重试');
    }
  }

  async stop(): Promise<void> {
    if (!this.listening || this.finishing) {
      return;
    }
    this.finishing = true;
    this.listening = false;
    this.onStateChange(false);
    await this.releaseCapturer();
    if (this.engine !== undefined && this.sessionId !== '') {
      try {
        if (this.pendingAudio.length === 640) {
          this.engine.writeAudio(this.sessionId, this.pendingAudio);
        }
        this.engine.finish(this.sessionId);
      } catch (error) {
        let businessError: BusinessError = error as BusinessError;
        console.error(`VoiceInputService finish failed: ${businessError.code}, ${businessError.message}`);
        await this.releaseEngine();
      }
    }
  }

  async cancel(): Promise<void> {
    if (this.engine !== undefined && this.sessionId !== '') {
      try {
        this.engine.cancel(this.sessionId);
      } catch (error) {
        let businessError: BusinessError = error as BusinessError;
        console.error(`VoiceInputService cancel failed: ${businessError.code}, ${businessError.message}`);
      }
    }
    await this.releaseResources(false);
  }

  private setRecognitionListener(): void {
    if (this.engine === undefined) {
      return;
    }
    let listener: speechRecognizer.RecognitionListener = {
      onStart: (_sessionId: string, _eventMessage: string): void => {},
      onEvent: (_sessionId: string, _eventCode: number, _eventMessage: string): void => {},
      onResult: (_sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
        let separator: string = this.inputPrefix !== '' && result.result !== '' ? ' ' : '';
        this.onText(`${this.inputPrefix}${separator}${result.result}`);
        if (result.isLast) {
          this.listening = false;
          this.onStateChange(false);
        }
      },
      onComplete: (_sessionId: string, _eventMessage: string): void => {
        this.listening = false;
        this.onStateChange(false);
        this.releaseResources(false);
      },
      onError: (_sessionId: string, errorCode: number, errorMessage: string): void => {
        console.error(`VoiceInputService recognition failed: ${errorCode}, ${errorMessage}`);
        this.listening = false;
        this.onStateChange(false);
        this.releaseResources(false);
        this.onError('没有识别到语音，请重试');
      }
    };
    this.engine.setListener(listener);
  }

  private writeAudio(buffer: ArrayBuffer): void {
    if (!this.listening || this.engine === undefined) {
      return;
    }
    let incoming: Uint8Array = new Uint8Array(buffer);
    let combined: Uint8Array = new Uint8Array(this.pendingAudio.length + incoming.length);
    for (let i: number = 0; i < this.pendingAudio.length; i++) {
      combined[i] = this.pendingAudio[i];
    }
    for (let i: number = 0; i < incoming.length; i++) {
      combined[this.pendingAudio.length + i] = incoming[i];
    }

    let offset: number = 0;
    try {
      while (combined.length - offset >= AUDIO_PACKET_SIZE) {
        let packet: Uint8Array = new Uint8Array(AUDIO_PACKET_SIZE);
        for (let i: number = 0; i < AUDIO_PACKET_SIZE; i++) {
          packet[i] = combined[offset + i];
        }
        this.engine.writeAudio(this.sessionId, packet);
        offset += AUDIO_PACKET_SIZE;
      }
    } catch (error) {
      let businessError: BusinessError = error as BusinessError;
      console.error(`VoiceInputService writeAudio failed: ${businessError.code}, ${businessError.message}`);
      this.onError('语音识别中断，请重试');
      this.cancel();
      return;
    }

    this.pendingAudio = new Uint8Array(combined.length - offset);
    for (let i: number = 0; i < this.pendingAudio.length; i++) {
      this.pendingAudio[i] = combined[offset + i];
    }
  }

  private async releaseCapturer(): Promise<void> {
    if (this.capturer === undefined) {
      return;
    }
    let currentCapturer: audio.AudioCapturer = this.capturer;
    this.capturer = undefined;
    try {
      currentCapturer.off('readData');
      await currentCapturer.stop();
    } catch (error) {
      let businessError: BusinessError = error as BusinessError;
      console.error(`VoiceInputService stop capturer failed: ${businessError.code}, ${businessError.message}`);
    }
    try {
      await currentCapturer.release();
    } catch (error) {
      let businessError: BusinessError = error as BusinessError;
      console.error(`VoiceInputService release capturer failed: ${businessError.code}, ${businessError.message}`);
    }
  }

  private async releaseEngine(): Promise<void> {
    if (this.engine !== undefined) {
      this.engine.shutdown();
      this.engine = undefined;
    }
    this.finishing = false;
    this.sessionId = '';
    this.pendingAudio = new Uint8Array(0);
  }

  private async releaseResources(cancelEngine: boolean): Promise<void> {
    this.listening = false;
    this.onStateChange(false);
    await this.releaseCapturer();
    if (cancelEngine && this.engine !== undefined && this.sessionId !== '') {
      try {
        this.engine.cancel(this.sessionId);
      } catch (error) {
        let businessError: BusinessError = error as BusinessError;
        console.error(`VoiceInputService cleanup cancel failed: ${businessError.code}, ${businessError.message}`);
      }
    }
    await this.releaseEngine();
  }
}
