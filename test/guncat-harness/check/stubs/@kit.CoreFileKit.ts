export declare namespace fileIo {
  interface Stat { size: number; mtime: number; isDirectory(): boolean; }
  interface File { fd: number; }
  enum OpenMode { READ_ONLY = 0, READ_WRITE = 1, CREATE = 2, TRUNC = 4, APPEND = 8 }
  function accessSync(path: string): boolean;
  function statSync(path: string): Stat;
  function mkdirSync(path: string, recursion?: boolean): void;
  function listFileSync(path: string): string[];
  function openSync(path: string, mode: number): File;
  function readSync(fd: number, buffer: ArrayBuffer, opts: { offset: number }): number;
  function writeSync(fd: number, buffer: ArrayBuffer): number;
  function writeSync(fd: number, buffer: ArrayBuffer, opts: { offset: number; length?: number }): number;
  function closeSync(fileOrFd: File | number): void;
  function unlinkSync(path: string): void;  function rmdirSync(path: string): void;
  function renameSync(oldPath: string, newPath: string): void;
  function moveFileSync(src: string, dst: string): void;  function moveDirSync(src: string, dst: string): void;
}
export declare namespace picker {
  class DocumentSaveOptions { newFileNames?: string[]; fileSuffixChoices?: string[]; }
  class DocumentViewPicker { constructor(context: object); save(options: DocumentSaveOptions): Promise<string[]>; }
}
