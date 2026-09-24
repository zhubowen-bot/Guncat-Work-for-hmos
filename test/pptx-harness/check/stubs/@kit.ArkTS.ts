export declare namespace util {
  class TextEncoder { encode(input: string): Uint8Array; }
  class TextDecoder {
    static create(encoding: string, opts?: { ignoreBOM?: boolean }): TextDecoder;
    decodeToString(input: Uint8Array, opts?: { stream: boolean }): string;
  }
  class Base64Helper { decodeSync(src: string): Uint8Array; }
}
