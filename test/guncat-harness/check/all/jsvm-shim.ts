export interface JsRunOptions {
  inputs?: Record<string, string>;
  resourceName?: string;
  heapMb?: number;
  stdoutLimitKb?: number;
  outputFileLimitKb?: number;
  outputTotalLimitKb?: number;
  maxOutputFiles?: number;
}
export interface JsRunResult {
  ok: boolean;
  hasResult: boolean;
  stdout: string;
  result: string;
  error: string;
  notice: string;
  durationMs: number;
  inputCount: number;
  inputKeys: string[];
  outputs: Record<string, string>;
}
export function runJs(code: string, options?: JsRunOptions): Promise<JsRunResult> {
  return Promise.reject(new Error('jsvm-shim: 原生模块仅在设备侧可用'));
}
export function engineStatus(): string { return 'jsvm-shim'; }
