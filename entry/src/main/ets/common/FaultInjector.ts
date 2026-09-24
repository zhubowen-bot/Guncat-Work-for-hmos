// FaultInjector: 故障注入回归夹具(纯逻辑, 无 HarmonyOS 依赖)
// 为超时/取消/schema 错误/普通失败建立确定性场景, 供 LoopOrchestrator/执行器/评估链路做回归。
export class FaultOutcome {
  ok: boolean = true;
  timeout: boolean = false;
  cancelled: boolean = false;
  schemaError: boolean = false;
  fail: boolean = false;
  durationMs: number = 0;
}

export class FaultSpec {
  timeout: boolean = false;
  cancelled: boolean = false;
  schemaError: boolean = false;
  fail: boolean = false;
  durationMs: number = 10;
}

export class FaultInjector {
  // 按调用序号从脚本取结果; 超出脚本范围视为成功
  static execute(specs: FaultSpec[], index: number): FaultOutcome {
    if (index < 0 || index >= specs.length) {
      let ok: FaultOutcome = new FaultOutcome();
      return ok;
    }
    let spec: FaultSpec = specs[index];
    let out: FaultOutcome = new FaultOutcome();
    out.timeout = spec.timeout;
    out.cancelled = spec.cancelled;
    out.schemaError = spec.schemaError;
    out.fail = spec.fail;
    out.durationMs = spec.durationMs;
    out.ok = !spec.fail && !spec.timeout && !spec.cancelled;
    return out;
  }

  // 内置场景: 正常 / 单次超时 / 单次 schema 错误 / 单次取消 / 全失败
  static scenario(name: string): FaultSpec[] {
    if (name === 'happy') {
      return [FaultInjector.spec(false, false, false, false, 10)];
    }
    if (name === 'one_timeout') {
      return [
        FaultInjector.spec(true, false, false, false, 180001),
        FaultInjector.spec(false, false, false, false, 10)
      ];
    }
    if (name === 'one_schema_error') {
      return [
        FaultInjector.spec(false, false, true, true, 5),
        FaultInjector.spec(false, false, false, false, 10)
      ];
    }
    if (name === 'one_cancel') {
      return [
        FaultInjector.spec(false, true, false, true, 0),
        FaultInjector.spec(false, false, false, false, 10)
      ];
    }
    if (name === 'all_fail') {
      return [
        FaultInjector.spec(false, false, false, true, 5),
        FaultInjector.spec(false, false, false, true, 5)
      ];
    }
    return [FaultInjector.spec(false, false, false, false, 10)];
  }

  static spec(timeout: boolean, cancelled: boolean, schemaError: boolean,
    fail: boolean, durationMs: number): FaultSpec {
    let s: FaultSpec = new FaultSpec();
    s.timeout = timeout;
    s.cancelled = cancelled;
    s.schemaError = schemaError;
    s.fail = fail;
    s.durationMs = durationMs;
    return s;
  }
}
