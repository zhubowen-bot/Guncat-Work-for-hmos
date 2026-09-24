export declare namespace zlib {
  function decompressFile(src: string, dest: string): Promise<void>;
}
export declare namespace pasteboard {
  function getSystemPasteboard(): { setData(content: object): Promise<void>; };
  function createData(mime: string): { addTextRecord(text: string): void; };
  function createPlainTextData(text: string): object;
}
