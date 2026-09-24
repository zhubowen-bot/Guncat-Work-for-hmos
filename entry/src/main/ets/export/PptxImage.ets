// PptxImage: Deck 图片引用的解析与探测
// src 支持三种来源: 工作区相对路径 / data URL(base64) / http(s) 链接;
// 自动嗅探 mime 并解析像素尺寸(PNG/JPEG/GIF/BMP), 供 contain/cover 布局计算宽高比。
// 尺寸探测与 OoxmlBuilder(docx) 同源实现, 独立持有以便 pptx 管线单独演进。
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { WorkFileService } from '../service/WorkFileService';
import { PptxImagePart } from './PptxBuilder';

export class PptxImage {
  // 解析图片引用; 失败返回 null(由调用方决定是否整册失败)
  static async resolve(src: string, workspaceRoot: string): Promise<PptxImagePart | null> {
    let s: string = src.trim();
    if (s === '') {
      return null;
    }
    if (s.startsWith('data:image/')) {
      let comma: number = s.indexOf(',');
      if (comma < 0) {
        return null;
      }
      let header: string = s.substring(5, comma);
      let semi: number = header.indexOf(';');
      let mime: string = semi !== -1 ? header.substring(0, semi) : 'image/png';
      let b64: string = s.substring(comma + 1);
      let data: Uint8Array | null = null;
      try {
        let helper: util.Base64Helper = new util.Base64Helper();
        data = helper.decodeSync(b64);
      } catch (e) {
        return null;
      }
      return PptxImage.fromBytes(data === null ? new Uint8Array(0) : data, mime);
    }
    if (s.startsWith('http://') || s.startsWith('https://')) {
      let data: Uint8Array | null = await PptxImage.download(s);
      if (data === null) {
        return null;
      }
      return PptxImage.fromBytes(data, '');
    }
    // 工作区相对路径
    let abs: string | null = WorkFileService.resolveSafe(workspaceRoot, s);
    if (abs === null || !fileIo.accessSync(abs)) {
      return null;
    }
    let stat: fileIo.Stat = fileIo.statSync(abs);
    if (stat.isDirectory() || stat.size === 0) {
      return null;
    }
    let buffer: ArrayBuffer = new ArrayBuffer(stat.size);
    let file: fileIo.File = fileIo.openSync(abs, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.readSync(file.fd, buffer, { offset: 0 });
    } finally {
      fileIo.closeSync(file.fd);
    }
    return PptxImage.fromBytes(new Uint8Array(buffer), '');
  }

  // 字节 -> 图片部件(嗅探 mime + 解析尺寸); 非图片或尺寸未知返回 null
  static fromBytes(data: Uint8Array, mime: string): PptxImagePart | null {
    if (data.length < 8) {
      return null;
    }
    let m: string = mime !== '' ? mime : PptxImage.sniffMime(data);
    if (m === '') {
      return null;
    }
    let size: ImageDim = PptxImage.parseSize(data);
    if (size.width <= 0 || size.height <= 0) {
      return null;
    }
    let part: PptxImagePart = new PptxImagePart();
    part.data = data;
    part.mime = m;
    part.ext = PptxImage.extOf(m);
    part.widthPx = size.width;
    part.heightPx = size.height;
    return part;
  }

  private static async download(url: string): Promise<Uint8Array | null> {
    let req: http.HttpRequest = http.createHttp();
    try {
      let resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 15000
      });
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        let buf: ArrayBuffer = resp.result as ArrayBuffer;
        return new Uint8Array(buf);
      }
      return null;
    } catch (e) {
      return null;
    } finally {
      req.destroy();
    }
  }

  private static sniffMime(data: Uint8Array): string {
    if (data.length >= 8 && data[0] === 0x89 && data[1] === 0x50 && data[2] === 0x4E && data[3] === 0x47) {
      return 'image/png';
    }
    if (data.length >= 3 && data[0] === 0xFF && data[1] === 0xD8 && data[2] === 0xFF) {
      return 'image/jpeg';
    }
    if (data.length >= 6 && data[0] === 0x47 && data[1] === 0x49 && data[2] === 0x46) {
      return 'image/gif';
    }
    if (data.length >= 2 && data[0] === 0x42 && data[1] === 0x4D) {
      return 'image/bmp';
    }
    return '';
  }

  private static extOf(mime: string): string {
    if (mime === 'image/jpeg') {
      return 'jpeg';
    }
    if (mime === 'image/gif') {
      return 'gif';
    }
    if (mime === 'image/bmp') {
      return 'bmp';
    }
    return 'png';
  }

  private static parseSize(data: Uint8Array): ImageDim {
    let size: ImageDim = new ImageDim();
    let len: number = data.length;
    if (len >= 24 && data[0] === 0x89 && data[1] === 0x50 && data[2] === 0x4E && data[3] === 0x47) {
      size.width = PptxImage.be32(data, 16);
      size.height = PptxImage.be32(data, 20);
      return size;
    }
    if (len >= 10 && data[0] === 0x47 && data[1] === 0x49 && data[2] === 0x46 && data[3] === 0x38) {
      size.width = PptxImage.le16(data, 6);
      size.height = PptxImage.le16(data, 8);
      return size;
    }
    if (len >= 26 && data[0] === 0x42 && data[1] === 0x4D) {
      size.width = PptxImage.le32(data, 18);
      size.height = Math.abs(PptxImage.le32(data, 22));
      return size;
    }
    if (len >= 4 && data[0] === 0xFF && data[1] === 0xD8 && data[2] === 0xFF) {
      let i: number = 2;
      while (i + 9 < len) {
        if (data[i] !== 0xFF) {
          i++;
          continue;
        }
        let marker: number = data[i + 1];
        if (marker === 0xD8 || marker === 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
          i += 2;
          continue;
        }
        if (marker >= 0xC0 && marker <= 0xCF && marker !== 0xC4 && marker !== 0xC8 && marker !== 0xCC) {
          size.height = PptxImage.be16(data, i + 5);
          size.width = PptxImage.be16(data, i + 7);
          return size;
        }
        let segLen: number = PptxImage.be16(data, i + 2);
        if (segLen < 2) {
          break;
        }
        i += 2 + segLen;
      }
    }
    return size;
  }

  private static be16(d: Uint8Array, off: number): number {
    return (d[off] << 8) | d[off + 1];
  }

  private static be32(d: Uint8Array, off: number): number {
    return ((d[off] << 24) | (d[off + 1] << 16) | (d[off + 2] << 8) | d[off + 3]) >>> 0;
  }

  private static le16(d: Uint8Array, off: number): number {
    return d[off] | (d[off + 1] << 8);
  }

  private static le32(d: Uint8Array, off: number): number {
    return (d[off] | (d[off + 1] << 8) | (d[off + 2] << 16) | (d[off + 3] << 24)) >>> 0;
  }
}

// 图片像素尺寸
class ImageDim {
  width: number = 0;
  height: number = 0;
}
