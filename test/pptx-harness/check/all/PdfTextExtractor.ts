export class PdfPagesResult { pageCount: number = 0; startPage: number = 1; endPage: number = 1; nextStartPage: number = 0; pages: string[] = []; }
export class PdfSearchHit { pageIndex: number = 0; context: string = ''; }
export class PdfRenderResult { pageCount: number = 0; startPage: number = 1; endPage: number = 1; nextStartPage: number = 0; files: string[] = []; }
export class PdfTextExtractor {
  static async extractPages(abs: string, page: number, limit: number, cap: number): Promise<PdfPagesResult> { return new PdfPagesResult(); }
  static async searchText(abs: string, query: string, max: number): Promise<PdfSearchHit[]> { return []; }
  static async renderPages(abs: string, page: number, limit: number, outDir: string): Promise<PdfRenderResult> { return new PdfRenderResult(); }
  static async extractText(abs: string, cap: number): Promise<string> { return ''; }
}
