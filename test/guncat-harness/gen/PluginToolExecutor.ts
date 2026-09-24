// PluginToolExecutor: 插件工具声明式实现注册(纯逻辑, 无 HarmonyOS 依赖)
// 插件 manifest 只声明工具元数据; 工具实现由宿主代码通过 register() 注入,
// WorkToolRunner 对已注册插件工具直接调用 handler, 未注册返回“插件未实现”。
import { AbortSignal } from './Types.ts';

export class PluginToolResult {
  ok: boolean = false;
  output: string = '';
  imageDataUrl: string = '';
  meta: string = '';
  timeout: boolean = false;
  cancelled: boolean = false;
  schemaError: boolean = false;
}

export type PluginToolHandler = (context: Object, convId: string, name: string,
  argsJson: string, abortSignal: AbortSignal | null) => Promise<PluginToolResult>;

export class PluginToolExecutor {
  private static handlers: Record<string, PluginToolHandler> = {};

  static register(name: string, handler: PluginToolHandler): void {
    PluginToolExecutor.handlers[name] = handler;
  }

  static unregister(name: string): void {
    delete PluginToolExecutor.handlers[name];
  }

  static has(name: string): boolean {
    return PluginToolExecutor.handlers[name] !== undefined;
  }

  // 执行已注册的插件工具; 未注册返回 null
  static execute(name: string, context: Object, convId: string, argsJson: string,
    abortSignal: AbortSignal | null): Promise<PluginToolResult> | null {
    let h: PluginToolHandler | undefined = PluginToolExecutor.handlers[name];
    if (h === undefined) {
      return null;
    }
    return h(context, convId, name, argsJson, abortSignal);
  }

  static clear(): void {
    PluginToolExecutor.handlers = {};
  }
}
