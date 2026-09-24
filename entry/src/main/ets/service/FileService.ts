// FileService: 文件选择 + 读取
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { FileItem } from '../common/Types';
import { generateFileId } from '../common/Utils';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'FileService';

export interface PickedFile {
  name: string;
  uri: string;
  fileType: string;
  size: number;
  buffer: ArrayBuffer;
}

export class FileService {
  // 文件选择器返回的 URI 对中文等字符做了百分号编码, 截出的文件名需解码还原;
  // 文件名本身可能含字面 '%', 解码失败时回退原始名
  static decodeUriName(name: string): string {
    try {
      return decodeURIComponent(name);
    } catch (e) {
      return name;
    }
  }

  static async readSharedFiles(uris: string[]): Promise<PickedFile[]> {
    let files: PickedFile[] = [];
    let count: number = Math.min(5, uris.length);
    for (let i: number = 0; i < count; i++) {
      let picked: PickedFile | null = await FileService.readUri(uris[i], 'shared-file-' + (i + 1).toString());
      if (picked !== null) {
        files.push(picked);
      }
    }
    return files;
  }

  // 按 URI 读取单个文件(拍照/分享等场景), 失败返回 null
  static async readUri(uri: string, fallbackName: string): Promise<PickedFile | null> {
    try {
      let stat: fileIo.Stat = fileIo.statSync(uri);
      let file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      let buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer, { offset: 0 });
      fileIo.closeSync(file.fd);
      let cleanUri: string = uri.split('?')[0];
      let name: string = cleanUri.substring(cleanUri.lastIndexOf('/') + 1);
      if (name === '') {
        name = fallbackName;
      }
      name = FileService.decodeUriName(name);
      return {
        name: name,
        uri: uri,
        fileType: FileService.guessTypeByName(name),
        size: stat.size,
        buffer: buffer
      };
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'read uri failed: %{public}s', JSON.stringify(error));
      return null;
    }
  }

  static async pickFiles(): Promise<PickedFile[]> {
    let options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 5;
    let pickerInstance: picker.DocumentViewPicker = new picker.DocumentViewPicker();
    let result: string[] = await pickerInstance.select(options);
    let files: PickedFile[] = [];
    for (let i: number = 0; i < result.length; i++) {
      try {
        let uri: string = result[i];
        let stat: fileIo.Stat = fileIo.statSync(uri);
        let size: number = stat.size;
        let file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
        let buf: ArrayBuffer = new ArrayBuffer(size);
        fileIo.readSync(file.fd, buf, { offset: 0 });
        fileIo.closeSync(file.fd);
        let name: string = uri.substring(uri.lastIndexOf('/') + 1);
        if (name === '' || name.indexOf('?') !== -1) {
          name = uri.split('?')[0].substring(uri.split('?')[0].lastIndexOf('/') + 1);
        }
        name = FileService.decodeUriName(name);
        let fileType: string = FileService.guessTypeByName(name);
        files.push({ name: name, uri: uri, fileType: fileType, size: size, buffer: buf });
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'pickFiles read failed: %{public}s', JSON.stringify(e));
      }
    }
    return files;
  }

  static async pickImages(): Promise<PickedFile[]> {
    let options: picker.PhotoSelectOptions = new picker.PhotoSelectOptions();
    options.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = 5;
    let pickerInstance: picker.PhotoViewPicker = new picker.PhotoViewPicker();
    let result: picker.PhotoSelectResult = await pickerInstance.select(options);
    let uris: string[] = result.photoUris;
    let files: PickedFile[] = [];
    for (let i: number = 0; i < uris.length; i++) {
      try {
        let uri: string = uris[i];
        let stat: fileIo.Stat = fileIo.statSync(uri);
        let size: number = stat.size;
        let file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
        let buf: ArrayBuffer = new ArrayBuffer(size);
        fileIo.readSync(file.fd, buf, { offset: 0 });
        fileIo.closeSync(file.fd);
        let name: string = uri.substring(uri.lastIndexOf('/') + 1);
        if (name === '' || name.indexOf('?') !== -1) {
          name = uri.split('?')[0].substring(uri.split('?')[0].lastIndexOf('/') + 1);
        }
        name = FileService.decodeUriName(name);
        let fileType: string = 'image/jpeg';
        if (name.toLowerCase().endsWith('.png')) {
          fileType = 'image/png';
        } else if (name.toLowerCase().endsWith('.webp')) {
          fileType = 'image/webp';
        } else if (name.toLowerCase().endsWith('.gif')) {
          fileType = 'image/gif';
        }
        files.push({ name: name, uri: uri, fileType: fileType, size: size, buffer: buf });
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'pickImages read failed: %{public}s', JSON.stringify(e));
      }
    }
    return files;
  }

  static createFileItem(picked: PickedFile): FileItem {
    let item: FileItem = new FileItem();
    item.id = generateFileId();
    item.name = picked.name;
    item.uri = picked.uri;
    item.type = picked.fileType;
    item.parsedText = '';
    item.dataUrl = '';
    item.thumbnail = '';
    item.isParsing = true;
    item.error = false;
    return item;
  }

  static guessTypeByName(name: string): string {
    let lower: string = name.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.pdf')) {
      return 'application/pdf';
    }
    if (lower.endsWith('.txt') || lower.endsWith('.md')) {
      return 'text/plain';
    }
    if (lower.endsWith('.json')) {
      return 'application/json';
    }
    if (lower.endsWith('.doc')) {
      return 'application/msword';
    }
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (lower.endsWith('.xls')) {
      return 'application/vnd.ms-excel';
    }
    if (lower.endsWith('.xlsx')) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (lower.endsWith('.ppt')) {
      return 'application/vnd.ms-powerpoint';
    }
    if (lower.endsWith('.pptx')) {
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    }
    if (lower.endsWith('.csv')) {
      return 'text/csv';
    }
    return 'application/octet-stream';
  }
}
