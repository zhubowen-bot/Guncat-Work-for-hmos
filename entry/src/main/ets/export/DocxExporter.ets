// 导出服务: Markdown 内容 -> .docx 文件(基于 DocxBuilder 的统一管线)
// 流程: Markdown -> Doc(中间层) -> OOXML 部件 -> 组装 zip -> 系统保存面板选择位置写入
import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { DocxBuilder, DocxImagePart } from './DocxBuilder';
import { PptxImage } from './PptxImage';
import { PptxImagePart } from './PptxBuilder';
import { XmlUtil } from './XmlUtil';

export class DocxExporter {
  // 导出对话消息为 Word 文档, 返回保存的文件名; 用户取消时抛出错误
  static async exportToDocx(context: common.UIAbilityContext, markdown: string,
    defaultName: string): Promise<string> {
    let title: string = defaultName !== '' ? defaultName : 'Guncat Work 对话导出';
    let bytes: Uint8Array = await DocxBuilder.buildFromMarkdown(markdown, title,
      DocxExporter.basicResolver);
    return DocxExporter.saveViaPicker(context, bytes);
  }

  // 仅构建 .docx 字节(兼容旧入口), 不弹保存面板
  static async buildDocxBytes(title: string, markdown: string): Promise<Uint8Array> {
    return DocxBuilder.buildFromMarkdown(markdown, title, DocxExporter.basicResolver);
  }

  // 聊天导出的图片解析器: 仅 data URL / http(s)(无工作区概念); 尺寸/嗅探复用 PptxImage
  private static async basicResolver(src: string): Promise<DocxImagePart | null> {
    let p: PptxImagePart | null = await PptxImage.resolve(src, '');
    if (p === null) {
      return null;
    }
    let d: DocxImagePart = new DocxImagePart();
    d.data = p.data;
    d.mime = p.mime;
    d.ext = p.ext;
    d.widthPx = p.widthPx;
    d.heightPx = p.heightPx;
    return d;
  }

  // 系统文档保存面板, 写入文件
  private static async saveViaPicker(context: common.UIAbilityContext, bytes: Uint8Array): Promise<string> {
    let fileName: string = XmlUtil.makeFileName('Guncat-导出');
    // newFileNames 不携带扩展名, 后缀由 fileSuffixChoices 拼接(需带点号)
    let baseName: string = fileName.endsWith('.docx') ?
      fileName.substring(0, fileName.length - 5) : fileName;
    let options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [baseName];
    options.fileSuffixChoices = ['.docx'];
    let viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    let uris: string[] = await viewPicker.save(options);
    if (uris.length === 0) {
      throw new Error('已取消导出');
    }
    let uri: string = uris[0];
    let file: fs.File = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      // 写入 zip 字节
      let buffer: ArrayBuffer = bytes.buffer as ArrayBuffer;
      if (bytes.byteOffset !== 0 || bytes.byteLength !== buffer.byteLength) {
        buffer = bytes.slice().buffer as ArrayBuffer;
      }
      fs.writeSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }
    return fileName;
  }
}
