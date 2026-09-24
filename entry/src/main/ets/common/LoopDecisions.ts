// LoopDecisions: LoopOrchestrator 纯决策层(无 HarmonyOS 依赖)
// 把执行循环里的关键分支判断收敛为可单测函数:
//   快照去重 / 溢出强制压缩 / max_tokens 收尾 / 无效步判定
export class LoopDecisions {
  // 运行时快照去重: 内容与最后一条快照一致则不追加, 保持请求前缀逐字节稳定
  static shouldAppendSnapshot(lastSnapshot: string, newSnapshot: string): boolean {
    return lastSnapshot !== newSnapshot;
  }

  // 上下文溢出后的强制压缩: 未中止 + 确实溢出 + 本轮尚未压缩过, 才值得再试一次
  static shouldForceCompactOnOverflow(aborted: boolean, isContextOverflow: boolean,
    alreadyCompactedThisTurn: boolean): boolean {
    return !aborted && isContextOverflow && !alreadyCompactedThisTurn;
  }

  // 模型输出顶到 max_tokens: 收尾并提示继续
  static shouldBreakOnMaxTokens(finishReason: string): boolean {
    return finishReason === 'max_tokens';
  }

  // 无工具调用的轮次计为无效步(评估指标用)
  static isInvalidStep(toolCallCount: number): boolean {
    return toolCallCount <= 0;
  }
}
