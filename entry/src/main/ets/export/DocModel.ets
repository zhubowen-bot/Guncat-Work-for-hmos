// DocModel: Word 文档(Doc JSON)中间层
// 对齐 DeckModel(PPT)的设计: AI 写结构化 Doc JSON 源, DocxBuilder 渲染 .docx,
// 导出文件内嵌 docProps/doc.json 源, DocxImporter 读回/编辑可无损往返。
// 块类型: heading / paragraph / list / table / image / quote / code / divider / pagebreak。
// 文本字段(text/heading/quote/表格单元格)支持行内 Markdown(由 InlineParser 解析):
//   **粗体** *斜体* `行内代码` [链接](url) ![说明](src) $公式$ ~~删除线~~
import { Constants } from '../common/Constants';
import { MarkdownParser, MdBlock, InlineParser, InlineToken } from './MarkdownParser';

// 文档样式预设: 决定标题颜色与表头底色
export const DOC_STYLES: string[] = ['default', 'academic', 'minimal'];

// 样式预设 -> 标题色/表头底色(由 DocxBuilder 使用)
export class DocStyleColors {
  heading: string[] = [];   // H1..H6 颜色
  tableFill: string = '';   // 表头底色
}

export class DocStylePalette {
  static of(style: string): DocStyleColors {
    let c: DocStyleColors = new DocStyleColors();
    if (style === 'academic') {
      c.heading = ['262626', '262626', '3F3F3F', '3F3F3F', '3F3F3F', '3F3F3F'];
      c.tableFill = 'F2F2F2';
    } else if (style === 'minimal') {
      c.heading = ['595959', '595959', '6B6B6B', '6B6B6B', '6B6B6B', '6B6B6B'];
      c.tableFill = 'F5F5F5';
    } else {
      c.heading = ['1F4E79', '2E74B5', '2E74B5', '44546A', '44546A', '44546A'];
      c.tableFill = 'DEEAF6';
    }
    return c;
  }
}

// 列表条目(可含多级缩进)
export class DocListItem {
  text: string = '';
  level: number = 0;        // 0/1(两级)
}

// 内容块
export class DocBlock {
  type: string = 'paragraph'; // heading|paragraph|list|table|image|quote|code|divider|pagebreak
  level: number = 0;          // heading 1-6
  text: string = '';          // heading/paragraph/quote 的文本(行内 Markdown); code 的代码
  language: string = '';      // code 的语言标注
  ordered: boolean = false;   // list: 有序/无序
  items: DocListItem[] = [];  // list 条目
  headers: string[] = [];     // table 表头
  rows: string[][] = [];      // table 数据行
  caption: string = '';       // table/image 的题注
  src: string = '';           // image 来源(工作区相对路径/data URL/http)
  width: number = 0;          // image 宽(页内容宽比例 0~1; 0=按原始尺寸自适应)
}

// 文档
export class Doc {
  title: string = 'Guncat Work 文档';
  subtitle: string = '';      // 封面副标题
  author: string = '';        // 封面作者/单位
  date: string = '';          // 封面日期(空=渲染时取当天)
  style: string = 'default';  // default|academic|minimal
  cover: boolean = false;     // 是否生成封面页
  toc: boolean = false;       // 是否生成目录页(Word 域, 打开后右键"更新域"生效)
  blocks: DocBlock[] = [];
}

// JSON 取值辅助(对齐 DeckJson)
class DocJson {
  static asRec(v: Object | undefined): Record<string, Object> | null {
    if (v !== undefined && typeof v === 'object' && v !== null && !(v instanceof Array)) {
      return v as Record<string, Object>;
    }
    return null;
  }

  static asStr(v: Object | undefined, def: string): string {
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      return (v as number).toString();
    }
    return def;
  }

  static asNum(v: Object | undefined, def: number): number {
    if (typeof v === 'number' && !isNaN(v as number)) {
      return v as number;
    }
    if (typeof v === 'string') {
      let n: number = parseInt(v as string, 10);
      if (!isNaN(n)) {
        return n;
      }
    }
    return def;
  }

  static asBool(v: Object | undefined, def: boolean): boolean {
    if (typeof v === 'boolean') {
      return v as boolean;
    }
    if (typeof v === 'string') {
      return (v as string).toLowerCase() === 'true';
    }
    return def;
  }
}

export class DocParser {
  // Doc JSON 字符串 -> Doc; 失败抛 Error(信息面向 AI)
  static parse(docJson: string): Doc {
    let parsed: Object;
    try {
      parsed = JSON.parse(docJson);
    } catch (e) {
      throw new Error('Doc JSON 不是合法的 JSON: ' + DocParser.errMsg(e));
    }
    let rec: Record<string, Object> | null = DocJson.asRec(parsed);
    if (rec === null) {
      throw new Error('Doc JSON 顶层必须是对象(含 title 与 blocks 数组)');
    }
    return DocParser.parseRec(rec);
  }

  static parseRec(rec: Record<string, Object>): Doc {
    let doc: Doc = new Doc();
    doc.title = DocJson.asStr(rec['title'], '').trim();
    if (doc.title === '') {
      doc.title = 'Guncat Work 文档';
    }
    doc.subtitle = DocJson.asStr(rec['subtitle'], '');
    doc.author = DocJson.asStr(rec['author'], '');
    doc.date = DocJson.asStr(rec['date'], '');
    let style: string = DocJson.asStr(rec['style'], 'default').toLowerCase();
    doc.style = DocParser.isKnownStyle(style) ? style : 'default';
    doc.cover = DocJson.asBool(rec['cover'], false);
    doc.toc = DocJson.asBool(rec['toc'], false);
    let blocksArr: Object | undefined = rec['blocks'];
    if (!(blocksArr instanceof Array)) {
      throw new Error('Doc JSON 缺少 blocks 数组(内容块列表)');
    }
    let arr: Object[] = blocksArr as Object[];
    if (arr.length === 0) {
      throw new Error('blocks 数组为空: 至少需要一个内容块');
    }
    if (arr.length > Constants.WORK_DOC_MAX_BLOCKS) {
      throw new Error('blocks 超过 ' + Constants.WORK_DOC_MAX_BLOCKS.toString() + ' 块上限, 请拆分文档');
    }
    for (let i: number = 0; i < arr.length; i++) {
      doc.blocks.push(DocParser.parseBlock(arr[i], i + 1));
    }
    return doc;
  }

  static isKnownStyle(style: string): boolean {
    for (let i: number = 0; i < DOC_STYLES.length; i++) {
      if (DOC_STYLES[i] === style) {
        return true;
      }
    }
    return false;
  }

  // 单个块 JSON -> DocBlock; 非法抛 Error(含块序号便于定位)
  static parseBlock(v: Object, blockNo: number): DocBlock {
    let rec: Record<string, Object> | null = DocJson.asRec(v);
    if (rec === null) {
      throw new Error('第 ' + blockNo.toString() + ' 个 block 必须是 JSON 对象');
    }
    let type: string = DocJson.asStr(rec['type'], 'paragraph').toLowerCase();
    let block: DocBlock = new DocBlock();
    block.type = type;
    block.text = DocJson.asStr(rec['text'], '');
    block.language = DocJson.asStr(rec['language'], '');
    block.caption = DocJson.asStr(rec['caption'], '');
    block.ordered = DocJson.asBool(rec['ordered'], false);
    block.level = DocJson.asNum(rec['level'], 0);
    block.src = DocJson.asStr(rec['src'], '').trim();
    block.width = DocJson.asNum(rec['width'], 0);
    if (type === 'heading') {
      if (block.level < 1 || block.level > 6) {
        throw new Error('第 ' + blockNo.toString() + ' 个 heading 块的 level 需为 1~6');
      }
      if (block.text.trim() === '') {
        throw new Error('第 ' + blockNo.toString() + ' 个 heading 块缺少 text');
      }
    } else if (type === 'paragraph') {
      if (block.text.trim() === '') {
        throw new Error('第 ' + blockNo.toString() + ' 个 paragraph 块缺少 text');
      }
    } else if (type === 'quote') {
      if (block.text.trim() === '') {
        throw new Error('第 ' + blockNo.toString() + ' 个 quote 块缺少 text');
      }
    } else if (type === 'code') {
      if (block.text === '') {
        throw new Error('第 ' + blockNo.toString() + ' 个 code 块缺少 text(代码内容)');
      }
    } else if (type === 'list') {
      let itemsArr: Object | undefined = rec['items'];
      if (!(itemsArr instanceof Array) || (itemsArr as Object[]).length === 0) {
        throw new Error('第 ' + blockNo.toString() + ' 个 list 块缺少 items 数组');
      }
      let arr: Object[] = itemsArr as Object[];
      if (arr.length > 200) {
        throw new Error('第 ' + blockNo.toString() + ' 个 list 块条目超过 200 条, 请拆分');
      }
      for (let i: number = 0; i < arr.length; i++) {
        let item: DocListItem = new DocListItem();
        let iv: Object = arr[i];
        if (typeof iv === 'string') {
          item.text = iv as string;
          item.level = 0;
        } else {
          let ir: Record<string, Object> | null = DocJson.asRec(iv);
          if (ir === null) {
            throw new Error('第 ' + blockNo.toString() + ' 个 list 块第 ' + (i + 1).toString() + ' 条需为字符串或对象');
          }
          item.text = DocJson.asStr(ir['text'], '');
          item.level = DocJson.asNum(ir['level'], 0);
        }
        if (item.level < 0) {
          item.level = 0;
        }
        if (item.level > 1) {
          item.level = 1;
        }
        if (item.text.trim() === '') {
          throw new Error('第 ' + blockNo.toString() + ' 个 list 块第 ' + (i + 1).toString() + ' 条缺少 text');
        }
        block.items.push(item);
      }
    } else if (type === 'table') {
      let headersArr: Object | undefined = rec['headers'];
      if (!(headersArr instanceof Array)) {
        throw new Error('第 ' + blockNo.toString() + ' 个 table 块缺少 headers 数组');
      }
      let hs: Object[] = headersArr as Object[];
      if (hs.length === 0) {
        throw new Error('第 ' + blockNo.toString() + ' 个 table 块的 headers 不能为空');
      }
      if (hs.length > Constants.WORK_DOC_TABLE_MAX_COLS) {
        throw new Error('第 ' + blockNo.toString() + ' 个 table 块超过 ' +
          Constants.WORK_DOC_TABLE_MAX_COLS.toString() + ' 列上限');
      }
      for (let i: number = 0; i < hs.length; i++) {
        block.headers.push(DocJson.asStr(hs[i], ''));
      }
      let rowsArr: Object | undefined = rec['rows'];
      if (!(rowsArr instanceof Array)) {
        throw new Error('第 ' + blockNo.toString() + ' 个 table 块缺少 rows 数组(可为空数组)');
      }
      let rs: Object[] = rowsArr as Object[];
      if (rs.length > Constants.WORK_DOC_TABLE_MAX_ROWS) {
        throw new Error('第 ' + blockNo.toString() + ' 个 table 块超过 ' +
          Constants.WORK_DOC_TABLE_MAX_ROWS.toString() + ' 行上限');
      }
      for (let r: number = 0; r < rs.length; r++) {
        let rowV: Object = rs[r];
        if (!(rowV instanceof Array)) {
          throw new Error('第 ' + blockNo.toString() + ' 个 table 块第 ' + (r + 1).toString() + ' 行需为数组');
        }
        let rowArr: Object[] = rowV as Object[];
        if (rowArr.length > hs.length) {
          throw new Error('第 ' + blockNo.toString() + ' 个 table 块第 ' + (r + 1).toString() +
            ' 行列数(' + rowArr.length.toString() + ')超过表头列数(' + hs.length.toString() + ')');
        }
        let row: string[] = [];
        for (let c: number = 0; c < rowArr.length; c++) {
          row.push(DocJson.asStr(rowArr[c], ''));
        }
        block.rows.push(row);
      }
    } else if (type === 'image') {
      if (block.src === '') {
        throw new Error('第 ' + blockNo.toString() + ' 个 image 块缺少 src(工作区相对路径/data URL/http)');
      }
      if (block.width < 0 || block.width > 1) {
        throw new Error('第 ' + blockNo.toString() + ' 个 image 块的 width 需为 0~1(页宽比例)');
      }
    } else if (type === 'divider' || type === 'pagebreak') {
      // 无附加字段
    } else {
      throw new Error('第 ' + blockNo.toString() + ' 个 block 的 type 未知: "' + type +
        '"(支持 heading/paragraph/list/table/image/quote/code/divider/pagebreak)');
    }
    return block;
  }

  private static errMsg(e: Object): string {
    if (e instanceof Error) {
      let err: Error = e as Error;
      return err.message !== undefined ? err.message : String(e);
    }
    return String(e);
  }
}

// Markdown -> Doc(旧 write_docx markdown 路径与新 doc 路径的统一入口)
// 整段只有一张图的段落提升为 image 块, 让 markdown 里的 ![说明](工作区路径) 真正进 docx。
export class MdToDoc {
  static convert(markdown: string, title: string): Doc {
    let doc: Doc = new Doc();
    doc.title = title !== '' ? title : 'Guncat Work 文档';
    let blocks: MdBlock[] = MarkdownParser.parseBlocks(markdown);
    for (let i: number = 0; i < blocks.length; i++) {
      let b: MdBlock = blocks[i];
      let block: DocBlock = new DocBlock();
      block.type = b.type;
      block.level = b.level;
      block.text = b.inline;
      block.language = b.lang;
      block.rows = b.tableRows;
      block.headers = b.tableHeaders;
      if (b.type === 'heading') {
        block.type = 'heading';
      } else if (b.type === 'paragraph') {
        // 整段只有一张图 -> 提升为 image 块
        let imgSrc: string = MdToDoc.onlyImageSrc(b.inline);
        if (imgSrc !== '') {
          block.type = 'image';
          block.src = imgSrc;
          block.text = '';
        } else {
          block.type = 'paragraph';
        }
      } else if (b.type === 'ul' || b.type === 'ol') {
        block.type = 'list';
        block.ordered = b.type === 'ol';
        for (let j: number = 0; j < b.items.length; j++) {
          let li: DocListItem = new DocListItem();
          li.text = b.items[j];
          li.level = j < b.itemLevels.length ? b.itemLevels[j] : 0;
          block.items.push(li);
        }
      } else if (b.type === 'codeblock') {
        block.type = 'code';
        block.text = b.code;
      } else if (b.type === 'quote') {
        block.type = 'quote';
      } else if (b.type === 'table') {
        block.type = 'table';
      } else if (b.type === 'hr') {
        block.type = 'divider';
        block.text = '';
      } else if (b.type === 'math') {
        // 块级公式 -> 段落行内公式(渲染为独立显示公式段落)
        block.type = 'paragraph';
        block.text = '$$' + b.math + '$$';
      } else {
        block.type = 'paragraph';
      }
      doc.blocks.push(block);
    }
    return doc;
  }

  // 段落的行内 token 若只有一张图片, 返回其 src; 否则返回 ''
  private static onlyImageSrc(inline: string): string {
    let tokens: InlineToken[] = InlineParser.parse(inline);
    if (tokens.length === 0) {
      return '';
    }
    let src: string = '';
    for (let i: number = 0; i < tokens.length; i++) {
      let t: InlineToken = tokens[i];
      if (t.type !== 'image') {
        return '';
      }
      src = t.text.trim();
    }
    return src;
  }
}

// ===== 编辑算子(edit_docx) =====
export class DocOps {
  // 对 doc 应用操作 JSON 数组并返回摘要; 非法操作抛 Error
  static apply(doc: Doc, opsJson: string): string {
    let ops: Object[];
    try {
      let parsed: Object = JSON.parse(opsJson);
      if (!(parsed instanceof Array)) {
        throw new Error('ops 必须是 JSON 数组');
      }
      ops = parsed as Object[];
    } catch (e) {
      throw new Error('ops 不是合法的 JSON 数组: ' + DocOps.errMsg(e));
    }
    let summary: string[] = [];
    for (let i: number = 0; i < ops.length; i++) {
      let rec: Record<string, Object> | null = DocJson.asRec(ops[i]);
      if (rec === null) {
        throw new Error('第 ' + (i + 1).toString() + ' 个 op 必须是 JSON 对象');
      }
      let op: string = DocJson.asStr(rec['op'], '');
      if (op === 'set_title') {
        let t: string = DocJson.asStr(rec['title'], '').trim();
        if (t === '') {
          throw new Error('set_title 缺少 title');
        }
        doc.title = t;
        summary.push('标题 → ' + t);
      } else if (op === 'set_subtitle') {
        doc.subtitle = DocJson.asStr(rec['subtitle'], '');
        summary.push('副标题已更新');
      } else if (op === 'set_author') {
        doc.author = DocJson.asStr(rec['author'], '');
        summary.push('作者已更新');
      } else if (op === 'set_style') {
        let s: string = DocJson.asStr(rec['style'], '').toLowerCase();
        if (!DocParser.isKnownStyle(s)) {
          throw new Error('set_style 未知样式 "' + s + '"(支持 ' + DOC_STYLES.join('/') + ')');
        }
        doc.style = s;
        summary.push('样式 → ' + s);
      } else if (op === 'set_cover') {
        doc.cover = DocJson.asBool(rec['cover'], true);
        summary.push(doc.cover ? '已启用封面页' : '已关闭封面页');
      } else if (op === 'set_toc') {
        doc.toc = DocJson.asBool(rec['toc'], true);
        summary.push(doc.toc ? '已启用目录页' : '已关闭目录页');
      } else if (op === 'add_block') {
        let idx: number = DocOps.indexArg(rec['index'], -1);
        let blockV: Object | undefined = rec['block'];
        let block: DocBlock = DocParser.parseBlock(blockV as Object, doc.blocks.length + 1);
        if (doc.blocks.length + 1 > Constants.WORK_DOC_MAX_BLOCKS) {
          throw new Error('add_block 超过块数上限 ' + Constants.WORK_DOC_MAX_BLOCKS.toString());
        }
        if (idx < 0 || idx > doc.blocks.length) {
          doc.blocks.push(block);
          summary.push('追加 ' + block.type + ' 块');
        } else {
          doc.blocks.splice(idx - 1, 0, block);
          summary.push('在第 ' + idx.toString() + ' 位插入 ' + block.type + ' 块');
        }
      } else if (op === 'delete_block') {
        let idx: number = DocOps.indexArg(rec['index'], -1);
        if (idx < 1 || idx > doc.blocks.length) {
          throw new Error('delete_block 的 index(' + idx.toString() + ')越界, 当前共 ' +
            doc.blocks.length.toString() + ' 块');
        }
        let removed: DocBlock = doc.blocks[idx - 1];
        doc.blocks.splice(idx - 1, 1);
        summary.push('删除第 ' + idx.toString() + ' 块(' + removed.type + ')');
      } else if (op === 'update_block') {
        let idx: number = DocOps.indexArg(rec['index'], -1);
        if (idx < 1 || idx > doc.blocks.length) {
          throw new Error('update_block 的 index(' + idx.toString() + ')越界, 当前共 ' +
            doc.blocks.length.toString() + ' 块');
        }
        let patch: Object | undefined = rec['block'];
        let patchRec: Record<string, Object> | null = DocJson.asRec(patch);
        if (patchRec === null) {
          throw new Error('update_block 缺少 block 对象(要更新的字段)');
        }
        let merged: Record<string, Object> = DocOps.blockToRec(doc.blocks[idx - 1]);
        DocOps.mergePatch(merged, patchRec);
        doc.blocks[idx - 1] = DocParser.parseBlock(merged, idx);
        summary.push('更新第 ' + idx.toString() + ' 块');
      } else if (op === 'move_block') {
        let from: number = DocOps.indexArg(rec['from'], -1);
        let to: number = DocOps.indexArg(rec['to'], -1);
        if (from < 1 || from > doc.blocks.length || to < 1 || to > doc.blocks.length) {
          throw new Error('move_block 的 from/to 越界(1~' + doc.blocks.length.toString() + ')');
        }
        let item: DocBlock = doc.blocks[from - 1];
        doc.blocks.splice(from - 1, 1);
        doc.blocks.splice(to - 1, 0, item);
        summary.push('移动第 ' + from.toString() + ' 块到第 ' + to.toString() + ' 位');
      } else if (op === 'replace_text') {
        let find: string = DocJson.asStr(rec['find'], '');
        let replace: string = DocJson.asStr(rec['replace'], '');
        if (find === '') {
          throw new Error('replace_text 缺少 find');
        }
        let count: number = DocOps.replaceText(doc, find, replace);
        summary.push('全文替换 "' + find + '" → "' + replace + '"(' + count.toString() + ' 处)');
      } else {
        throw new Error('未知操作: "' + op +
          '"(支持 set_title/set_subtitle/set_author/set_style/set_cover/set_toc/' +
          'add_block/delete_block/update_block/move_block/replace_text)');
      }
    }
    return summary.join('\n');
  }

  // 块 -> 可合并的 Record(序列化后按 patch 覆盖)
  private static blockToRec(block: DocBlock): Record<string, Object> {
    let rec: Record<string, Object> = {};
    rec['type'] = block.type;
    rec['level'] = block.level;
    rec['text'] = block.text;
    rec['language'] = block.language;
    rec['ordered'] = block.ordered;
    rec['caption'] = block.caption;
    rec['src'] = block.src;
    rec['width'] = block.width;
    let items: Object[] = [];
    for (let i: number = 0; i < block.items.length; i++) {
      let li: DocListItem = new DocListItem();
      li.text = block.items[i].text;
      li.level = block.items[i].level;
      items.push(li);
    }
    rec['items'] = items;
    let headers: Object[] = [];
    for (let i: number = 0; i < block.headers.length; i++) {
      headers.push(block.headers[i]);
    }
    rec['headers'] = headers;
    let rows: Object[] = [];
    for (let r: number = 0; r < block.rows.length; r++) {
      let row: Object[] = [];
      for (let c: number = 0; c < block.rows[r].length; c++) {
        row.push(block.rows[r][c]);
      }
      rows.push(row);
    }
    rec['rows'] = rows;
    return rec;
  }

  private static mergePatch(target: Record<string, Object>, patch: Record<string, Object>): void {
    let keys: string[] = Object.keys(patch);
    for (let i: number = 0; i < keys.length; i++) {
      let k: string = keys[i];
      target[k] = patch[k];
    }
  }

  // 全文文本替换: 覆盖 block.text/items/headers/rows/caption; 返回替换处数
  private static replaceText(doc: Doc, find: string, replace: string): number {
    let count: number = 0;
    for (let i: number = 0; i < doc.blocks.length; i++) {
      let b: DocBlock = doc.blocks[i];
      if (b.type === 'code') {
        continue; // 代码块不做全文替换(易破坏语法)
      }
      count += DocOps.replaceInText(b, 'text', find, replace);
      count += DocOps.replaceInText(b, 'caption', find, replace);
      for (let j: number = 0; j < b.items.length; j++) {
        count += DocOps.replaceInItem(b.items[j], find, replace);
      }
      for (let j: number = 0; j < b.headers.length; j++) {
        if (b.headers[j].indexOf(find) !== -1) {
          count += DocOps.countOccurrences(b.headers[j], find);
          b.headers[j] = b.headers[j].split(find).join(replace);
        }
      }
      for (let r: number = 0; r < b.rows.length; r++) {
        for (let c: number = 0; c < b.rows[r].length; c++) {
          if (b.rows[r][c].indexOf(find) !== -1) {
            count += DocOps.countOccurrences(b.rows[r][c], find);
            b.rows[r][c] = b.rows[r][c].split(find).join(replace);
          }
        }
      }
    }
    return count;
  }

  private static replaceInText(owner: DocBlock, field: string, find: string, replace: string): number {
    let v: string = field === 'caption' ? owner.caption : owner.text;
    if (v.indexOf(find) === -1) {
      return 0;
    }
    let n: number = DocOps.countOccurrences(v, find);
    if (field === 'caption') {
      owner.caption = v.split(find).join(replace);
    } else {
      owner.text = v.split(find).join(replace);
    }
    return n;
  }

  private static replaceInItem(item: DocListItem, find: string, replace: string): number {
    if (item.text.indexOf(find) === -1) {
      return 0;
    }
    let n: number = DocOps.countOccurrences(item.text, find);
    item.text = item.text.split(find).join(replace);
    return n;
  }

  private static countOccurrences(text: string, find: string): number {
    let count: number = 0;
    let idx: number = 0;
    while (true) {
      let at: number = text.indexOf(find, idx);
      if (at < 0) {
        break;
      }
      count++;
      idx = at + find.length;
    }
    return count;
  }

  private static indexArg(v: Object | undefined, def: number): number {
    if (typeof v === 'number') {
      return Math.floor(v as number);
    }
    if (typeof v === 'string') {
      let n: number = parseInt(v as string, 10);
      if (!isNaN(n)) {
        return n;
      }
    }
    return def;
  }

  private static errMsg(e: Object): string {
    if (e instanceof Error) {
      let err: Error = e as Error;
      return err.message !== undefined ? err.message : String(e);
    }
    return String(e);
  }
}
