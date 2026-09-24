// SubagentService: subagent 工具 —— 进程内嵌套代理(对齐 DeepSeek Harness subagent 的进程内形态)
// 子代理与父任务共享同一沙箱工作区, 拥有除自身/交互类之外的全部工具, 独立上下文运行
// 一个受限步数的完整 Agent Loop, 结束后把最终报告作为工具结果交还父任务。
// 通过 hook 注入 WorkFileService(规避循环导入): ChatViewModel.init 时调用 SubagentService.init()。
import { common } from '@kit.AbilityKit';
import { AgentLoopService, LoopMessage, LoopTurnCallbacks, LoopTurnResult } from './AgentLoopService';
import { WorkFileService, ToolExecResult } from './WorkFileService';
import { SpillStore } from './SpillStore';
import { ToolCallRecord } from '../model/ToolCallRecord';
import { ApiConfig } from '../model/ApiConfig';
import { AbortSignal } from '../common/Types';
import { Constants } from '../common/Constants';
import { ToolRegistry } from '../common/ToolRegistry';
import { SubagentIsolation } from '../common/SubagentIsolation';

export class SubagentService {
  // 工具执行器(由宿主 ChatViewModel 注入的 .ets 实现, 规避 TS→ArkTS 导入限制);
  // 可选第五参传入子代理自身的取消信号, 由执行器统一套超时/取消护栏
  private static toolExecutor: ((context: common.UIAbilityContext, convId: string,
    name: string, argsJson: string,
    abortSignal?: AbortSignal | null) => Promise<ToolExecResult>) | null = null;
  // 运行期配置引用(由宿主注入: API 配置与思考开关与父任务一致)
  private static apiConfig: ApiConfig | null = null;
  private static thinkingRef: boolean = true;
  private static effortRef: string = 'high';
  // 全局子代理并发闸: 主循环并行派发后, 仍限制同时运行的子代理总数,
  // 避免并发 LLM 请求打爆模型服务限流, 也保护设备资源。
  private static activeSubagents: number = 0;
  private static subagentWaiters: Array<() => void> = [];
  // 自动产出目录序号: 每个未指定 output_dir 的子代理获得独立 subagents/sa_<n>/ 目录
  private static outputSeq: number = 0;

  private static async acquire(): Promise<void> {
    if (SubagentService.activeSubagents < Constants.WORK_MAX_PARALLEL_SUBAGENTS) {
      SubagentService.activeSubagents++;
      return;
    }
    await new Promise<void>((resolve: () => void) => {
      SubagentService.subagentWaiters.push(resolve);
    });
    SubagentService.activeSubagents++;
  }

  private static release(): void {
    SubagentService.activeSubagents--;
    const next: (() => void) | undefined = SubagentService.subagentWaiters.shift();
    if (next !== undefined) {
      next();
    }
  }

  // 宿主(ChatViewModel)在 init/每次任务开始时注入运行配置与工具执行器
  static bind(config: ApiConfig, thinkingEnabled: boolean, reasoningEffort: string,
    toolExecutor: (context: common.UIAbilityContext, convId: string,
      name: string, argsJson: string,
      abortSignal?: AbortSignal | null) => Promise<ToolExecResult>): void {
    SubagentService.apiConfig = config;
    SubagentService.thinkingRef = thinkingEnabled;
    SubagentService.effortRef = reasoningEffort;
    SubagentService.toolExecutor = toolExecutor;
    if (WorkFileService.subagentHook === null) {
      WorkFileService.subagentHook = SubagentService.run;
    }
  }

  // 子代理系统提示词: 复用主提示词, 追加子代理职责与收尾纪律
  // outputDir 为产出目录(工作区相对路径, 如 subagents/sa_1): 强制子代理所有产出写进该目录,
  // 避免并行子代理互相覆盖同名文件。
  private static buildSubagentPrompt(outputDir: string): string {
    let base: string = AgentLoopService.buildWorkSystemPrompt();
    let extra: string[] = [];
    extra.push('');
    extra.push('# 子代理模式(当前生效)');
    extra.push('- 你是一个被主代理派生的子代理, 正在独立完成一个分配的子任务; 用户看不到你的过程。');
    extra.push('- 不要向用户提问(没有交互通道); 依赖不足时基于合理假设推进, 并在报告中写明假设。');
    extra.push('- 完成子任务后, 输出一份自包含的最终报告(结论 + 关键过程 + 产出文件路径), 报告即工具结果, 主代理只能看到它。');
    extra.push('- 你的工作区产出目录是 `' + outputDir + '`(相对路径)。所有产出文件必须写入该子目录内, 严禁写到它之外; 报告中列出这些路径时也要带上前缀, 如 `' + outputDir + '/xxx`。');
    extra.push('- 你可以继续读取/搜索整个主工作区(包括主循环的文件), 但所有写入/新建/移动/删除都会被系统自动重定向或限制到 `' + outputDir + '` 内, 不会污染主工作区。');
    extra.push('- 与主代理通过工作区文件交接: 先确保产出目录存在(通常已由主代理创建), 产出写入上述相对路径, 报告中列出这些路径。');
    extra.push('- 不要使用 todo_write(避免与主代理的清单互相覆盖); 也无法创建子代理或向用户提问。');
    return base + '\n' + extra.join('\n');
  }

  // 自动产出目录: 时间戳+序号, 跨会话/并行调用都不易冲突
  private static nextAutoOutputDir(): string {
    SubagentService.outputSeq++;
    return Constants.WORK_SUBAGENT_OUTPUT_DIR_PREFIX + '/sa_' +
      Date.now().toString() + '_' + SubagentService.outputSeq.toString();
  }

  // 清洗用户传入的 output_dir: 只接受工作区内相对路径, 非法时回退自动目录
  private static sanitizeOutputDir(raw: string): string {
    let dir: string = raw.trim();
    if (dir !== '') {
      dir = dir.replace(/\\/g, '/');
      while (dir.startsWith('./')) {
        dir = dir.substring(2);
      }
      while (dir.startsWith('/')) {
        dir = dir.substring(1);
      }
      dir = dir.replace(/\/+/g, '/');
      if (dir === '' || dir === '..' || dir.startsWith('../') ||
        dir.includes('/../') || dir.endsWith('/..')) {
        dir = '';
      }
    }
    if (dir === '') {
      dir = SubagentService.nextAutoOutputDir();
    }
    return dir;
  }

  // 在工作区根下创建产出目录, 返回可用相对路径(清洗后); 创建失败时也回退自动目录
  private static ensureOutputDir(context: common.UIAbilityContext, convId: string,
    outputDir: string): string {
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let rel: string = SubagentService.sanitizeOutputDir(outputDir);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      rel = SubagentService.nextAutoOutputDir();
      abs = WorkFileService.resolveSafe(root, rel);
    }
    if (abs !== null) {
      WorkFileService.ensureDir(abs);
    }
    return rel;
  }

  // 子代理工具面: 从全量工具定义中排除自身(防递归)与交互/调度类(无宿主通道)
  private static excludedTools(): string[] {
    return ['subagent', 'ask_user_question',
      'schedule_create', 'schedule_delete', 'schedule_list',
      'goal_create', 'goal_update', 'todo_write'];
  }

  private static filteredToolDefs(): Record<string, Object>[] {
    // 工具面裁剪走 ToolRegistry: 同步后按 excluded 名单取工具名, 再取定义
    WorkFileService.toolRegistrySynced();
    let excluded: string[] = SubagentService.excludedTools();
    let names: string[] = ToolRegistry.names(excluded);
    let out: Record<string, Object>[] = [];
    for (let i: number = 0; i < names.length; i++) {
      let def: Record<string, Object> | null = ToolRegistry.findDef(names[i]);
      if (def !== null) {
        out.push(def);
      }
    }
    return out;
  }

  // 执行子任务; 返回作为工具结果送回父任务的文本
  // outputDir 为产出目录(可选): 不传时自动分配独立 subagents/sa_<n>/, 实现并行子代理工作区隔离
  // parentAbortSignal 为父任务取消信号(可选): 并行派发子代理后, 用户取消主任务时
  // 必须能同步中止所有在跑子代理, 而不是让它们在后台继续空跑。
  private static async run(context: common.UIAbilityContext, convId: string,
    description: string, prompt: string, outputDir?: string,
    parentAbortSignal?: AbortSignal | null): Promise<ToolExecResult> {
    let config: ApiConfig | null = SubagentService.apiConfig;
    if (config === null) {
      return SubagentService.failResult('子代理尚未绑定模型配置');
    }
    // 产出目录隔离: 用户指定则用指定(经清洗), 否则自动分配独立子目录
    let effectiveOutputDir: string = SubagentService.ensureOutputDir(context, convId,
      outputDir !== undefined ? outputDir : '');
    // 全局并发闸: 超出 WORK_MAX_PARALLEL_SUBAGENTS 时排队等待, 而不是失败
    await SubagentService.acquire();
    // 子代理内部取消信号: 跟随父级 abortSignal, 父任务取消时立即中止子代理循环
    let abortSignal: AbortSignal = new AbortSignal();
    let abortPoller: number = -1;
    if (parentAbortSignal !== null && parentAbortSignal !== undefined && parentAbortSignal.aborted) {
      abortSignal.aborted = true;
    } else if (parentAbortSignal !== null && parentAbortSignal !== undefined) {
      abortPoller = setInterval((): void => {
        if (parentAbortSignal !== null && parentAbortSignal !== undefined && parentAbortSignal.aborted) {
          abortSignal.aborted = true;
          if (abortPoller !== -1) {
            clearInterval(abortPoller);
            abortPoller = -1;
          }
        }
      }, 100);
    }
    let messages: LoopMessage[] = [];
    messages.push(LoopMessage.system(SubagentService.buildSubagentPrompt(effectiveOutputDir)));
    messages.push(LoopMessage.user('【子任务】' + description + '\n\n【执行指令】\n' + prompt));
    let finalText: string = '';
    let stepsUsed: number = 0;
    try {
      for (let step: number = 0; step < Constants.WORK_SUBAGENT_MAX_STEPS; step++) {
        if (abortSignal.aborted) {
          break;
        }
        let callbacks: LoopTurnCallbacks = new LoopTurnCallbacks();
        let turn: LoopTurnResult = await AgentLoopService.runTurnWithRetry(
          config, messages, SubagentService.thinkingRef, SubagentService.effortRef, false,
          callbacks, abortSignal, true, 2, SubagentService.filteredToolDefs());
        stepsUsed = step + 1;
        let calls: ToolCallRecord[] = turn.toolCalls;
        if (calls.length === 0) {
          finalText = turn.content;
          break;
        }
        // 执行工具(全部顺序执行; 子代理过程不进入 UI 时间线)
        // fromTurn 携带思考文本与签名: Anthropic 思考模式下下一轮请求需回传 thinking 块
        let loopMsg: LoopMessage = LoopMessage.fromTurn(turn);
        for (let i: number = 0; i < calls.length; i++) {
          if (abortSignal.aborted) {
            calls[i].result = '(子代理被中断, 无结果)';
            calls[i].isError = true;
            calls[i].cancelled = true;
            continue;
          }
          let execStart: number = Date.now();
          let exec: ToolExecResult = await SubagentService.runTool(
            context, convId, calls[i].name, calls[i].argsJson, abortSignal, effectiveOutputDir);
          calls[i].durationMs = Date.now() - execStart;
          calls[i].isError = !exec.ok;
          calls[i].timeout = exec.timeout;
          calls[i].cancelled = exec.cancelled;
          calls[i].schemaError = exec.schemaError;
          calls[i].result = SubagentService.capResult(context, convId, exec.output,
            calls[i].name, execStart);
        }
        messages.push(loopMsg);
      }
    } catch (e) {
      let err: Error = e as Error;
      let msg: string = err.message !== undefined ? err.message : '子代理执行失败';
      if (finalText === '') {
        return SubagentService.failResult('子代理执行失败(' + msg + '), 已运行 ' +
          stepsUsed.toString() + ' 步');
      }
    } finally {
      if (abortPoller !== -1) {
        clearInterval(abortPoller);
        abortPoller = -1;
      }
      SubagentService.release();
    }
    if (finalText.trim() === '') {
      return SubagentService.failResult('子代理在 ' + stepsUsed.toString() +
        ' 步内未产出最终报告(可能被截断), 可拆小任务重试');
    }
    let header: string = '【子代理报告】(' + description + ' · ' + stepsUsed.toString() +
      ' 步 · 产出: ' + effectiveOutputDir + ')\n\n';
    let out: ToolExecResult = new ToolExecResult();
    out.ok = true;
    out.output = header + finalText;
    return out;
  }

  // 工具执行(经宿主注入的执行器; 未注入时全部报错; 取消信号透传给执行器护栏)
  // 写隔离: 写类工具的目标路径统一重定向到 output_dir(读类工具不受影响, 仍可读主工作区);
  // 删除/移动越界直接拦截; 写入越界重定向后给工具结果附加明确提示, 避免子代理被静默误导。
  private static async runTool(context: common.UIAbilityContext, convId: string,
    name: string, argsJson: string, abortSignal: AbortSignal,
    outputDir: string): Promise<ToolExecResult> {
    let blocked: string = SubagentIsolation.isolationBlockReason(name, argsJson, outputDir);
    if (blocked !== '') {
      return SubagentService.failResult(blocked);
    }
    let notice: string = SubagentIsolation.redirectNotice(name, argsJson, outputDir);
    let finalArgsJson: string = SubagentIsolation.isolatedArgsJson(name, argsJson, outputDir);
    let executor = SubagentService.toolExecutor;
    if (executor === null) {
      return SubagentService.failResult('子代理工具执行器尚未注入');
    }
    let exec: ToolExecResult = await executor(context, convId, name, finalArgsJson, abortSignal);
    if (notice !== '') {
      exec.output = notice + '\n' + exec.output;
    }
    return exec;
  }

  // 工具结果截断 + 溢出暂存(与主循环 applyToolResult 同策略, 简化为独立实现)
  private static capResult(context: common.UIAbilityContext, convId: string,
    output: string, toolName: string, execStart: number): string {
    if (output.length <= Constants.WORK_RESULT_MAX_CHARS) {
      return output;
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let label: string = 'subagent_' + toolName + '_' + execStart.toString();
    let spillRel: string = SpillStore.save(root, label, output);
    return SpillStore.truncateWithLocator(output, spillRel);
  }

  private static failResult(msg: string): ToolExecResult {
    let r: ToolExecResult = new ToolExecResult();
    r.ok = false;
    r.output = 'ERROR: ' + msg;
    return r;
  }
}
