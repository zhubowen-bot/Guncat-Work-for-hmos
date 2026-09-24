// ToolSchemaValidator: 工具定义(JSON Schema 中间表示)的结构化参数校验
// 纯逻辑模块, 无 HarmonyOS 依赖, 可在 Node harness 中独立回归。
// 校验策略:
//  - required 字段必须存在(与现有工具定义的 required 数组一致);
//  - 类型检查保持宽容: string 接受 number(现有 strArg 会转字符串),
//    number/integer 接受数字或数字字符串, boolean 接受布尔或 'true'/'false';
//  - 未知字段不拒绝, 保持前向兼容; array/object 型参数允许字符串或实际值,
//    由具体工具实现继续解析(如 todos/ops/steps 常以 JSON 字符串传入)。
export class ToolSchemaValidator {
  // 返回空串表示通过; 否则返回可直接回送模型的错误说明
  static validate(def: Record<string, Object>, args: Record<string, Object>): string {
    if (args === null || typeof args !== 'object' || args instanceof Array) {
      return '参数必须是 JSON 对象';
    }
    let paramsObj: Object | undefined = def['parameters'];
    if (typeof paramsObj !== 'object' || paramsObj === null) {
      return '';
    }
    let params: Record<string, Object> = paramsObj as Record<string, Object>;
    let requiredObj: Object | undefined = params['required'];
    if (requiredObj instanceof Array) {
      let required: string[] = requiredObj as string[];
      for (let i: number = 0; i < required.length; i++) {
        let key: string = required[i];
        if (args[key] === undefined) {
          return '缺少参数 ' + key;
        }
      }
    }
    let propsObj: Object | undefined = params['properties'];
    if (typeof propsObj !== 'object' || propsObj === null) {
      return '';
    }
    let props: Record<string, Object> = propsObj as Record<string, Object>;
    let keys: string[] = Object.keys(args);
    for (let i: number = 0; i < keys.length; i++) {
      let key: string = keys[i];
      let schemaObj: Object | undefined = props[key];
      if (typeof schemaObj !== 'object' || schemaObj === null) {
        continue;
      }
      let schema: Record<string, Object> = schemaObj as Record<string, Object>;
      let type: Object | undefined = schema['type'];
      if (typeof type !== 'string') {
        continue;
      }
      let value: Object | undefined = args[key];
      if (value === undefined || value === null) {
        continue;
      }
      let typeName: string = type as string;
      if (typeName === 'string') {
        if (typeof value === 'string' || typeof value === 'number') {
          continue;
        }
        return '参数 ' + key + ' 应为 string';
      } else if (typeName === 'number' || typeName === 'integer') {
        if (typeof value === 'number') {
          continue;
        }
        if (typeof value === 'string' && ToolSchemaValidator.isNumericString(value as string)) {
          continue;
        }
        return '参数 ' + key + ' 应为 number';
      } else if (typeName === 'boolean') {
        if (typeof value === 'boolean') {
          continue;
        }
        if (typeof value === 'string' &&
          ((value as string) === 'true' || (value as string) === 'false')) {
          continue;
        }
        return '参数 ' + key + ' 应为 boolean';
      }
    }
    return '';
  }

  private static isNumericString(text: string): boolean {
    let trimmed: string = text.trim();
    if (trimmed === '') {
      return false;
    }
    return !isNaN(Number(trimmed));
  }
}
