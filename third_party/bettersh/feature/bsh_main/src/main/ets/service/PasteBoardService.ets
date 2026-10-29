// service/PasteBoardService.ets — 剪贴板：右键菜单的「复制」/「粘贴」
//
// 复制不需要任何权限(setDataSync)；粘贴必须由用户点 PasteButton 这个安全控件临时授权，
// 所以**读剪贴板**这一步只在 PasteButton 的回调里做，不申请 READ_PASTEBOARD。
// controller 按调用传进来 —— 同一个 service 服务多个窗口，不能把 controller 存在实例上。
//
// smart 模式的右键（有选区直接复制 / 无选区直接粘贴）暂未接入，这里不提供对应入口。
import { pasteboard } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'BSH_Paste';

function toast(msg: string): void {
  try {
    promptAction.showToast({ message: msg, duration: 1500 });
  } catch (e) { /* ignore */ }
}

export class PasteBoardService {
  private static instance: PasteBoardService | null = null;
  static getInstance(): PasteBoardService {
    if (!PasteBoardService.instance) {
      PasteBoardService.instance = new PasteBoardService();
    }
    return PasteBoardService.instance;
  }

  /** 复制:写剪贴板不需要任何权限(setDataSync) */
  private doCopy(text: string): void {
    if (!text) return;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      toast('已复制 ' + text.length + ' 个字符');
    } catch (e) {
      hilog.error(0x0000, TAG, 'copy failed %{public}s', JSON.stringify(e));
      toast('复制失败');
    }
  }

  /** 菜单项「复制」:先向页面要选中文本(window.termGetSelection —— 取不到当前选区时
   *  页面会回退到"右键按下那一刻"的快照),拿到非空文本再交给 doCopy 写剪贴板。
   *
   *  注意 runJavaScript 回来的是 JS 结果的 **JSON 文本**:字符串结果带引号,空串是 `""`。 */
  async copySelection(controller: webview.WebviewController): Promise<void> {
    let raw = '';
    try {
      raw = await controller.runJavaScript('window.termGetSelection()');
    } catch (e) {
      hilog.error(0x0000, TAG, 'get selection failed %{public}s', JSON.stringify(e));
    }
    if (!raw || raw === '""') {
      toast('没有选中内容');
      return;
    }
    let text = '';
    try {
      text = JSON.parse(raw) as string;
    } catch (e) {
      return;
    }
    this.doCopy(text);
  }

  /** 粘贴:PasteButton 被点时才走这里。只有当 result 是 SUCCESS(用户点了这个安全控件、
   *  系统据此临时授权)才读得到剪贴板,所以不需要 READ_PASTEBOARD,也没有
   *  requestPermissionsFromUser 那一段。读到文本后用 window.termPaste() 交给 xterm
   *  自己的粘贴路径(含 \r\n 归一与 bracketed paste)。 */
  async pasteFromClipboard(result: PasteButtonOnClickResult, controller: webview.WebviewController): Promise<void> {
    if (result !== PasteButtonOnClickResult.SUCCESS) {
      toast('粘贴未获授权');
      return;
    }
    try {
      const board = pasteboard.getSystemPasteboard();
      const data = await board.getData();
      const text = data.getPrimaryText();
      if (!text) {
        toast('剪贴板是空的');
        return;
      }
      controller.runJavaScript('window.termPaste(' + JSON.stringify(text) + ')');
    } catch (e) {
      hilog.error(0x0000, TAG, 'paste failed %{public}s', JSON.stringify(e));
      toast('粘贴失败');
    }
  }
}
