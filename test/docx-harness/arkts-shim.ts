// @kit.ArkTS 的最小测试桩(仅覆盖 ZipWriter 用到的 util.TextEncoder)
// 注意: 不能用 TS namespace(Node strip-only 模式不支持), 用对象模拟命名空间。
class TextEncoderImpl {
  encode(s: string): Uint8Array {
    return new Uint8Array(Buffer.from(s, 'utf8'));
  }
}

export const util = { TextEncoder: TextEncoderImpl };
