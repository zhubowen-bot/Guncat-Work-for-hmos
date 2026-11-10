// LegalDocuments: 设置 →「合规与许可」页面的内容。
//
// 只放两类内容：
// 1. AI 生成内容标识说明（当前版本的显式/隐式标识实现）；
// 2. 第三方组件与许可（随包组件、许可证和原文）。
//
// 不写隐私政策、用户协议、未成年人条款等需要法务确认的文本。
export class LegalDoc {
  id: string = '';
  title: string = '';
  summary: string = '';
  body: string = '';

  constructor(id: string, title: string, summary: string, body: string) {
    this.id = id;
    this.title = title;
    this.summary = summary;
    this.body = body;
  }
}

export class LegalLicense {
  label: string = '';
  file: string = '';
  license: string = '';

  constructor(label: string, file: string, license: string) {
    this.label = label;
    this.file = file;
    this.license = license;
  }
}

export class LegalDocuments {
  static readonly UPDATED: string = '2026-11-10';

  static readonly AIGC: LegalDoc = new LegalDoc(
    'aigc',
    'AI 生成内容标识',
    '应用内、复制文本和导出文件中的显式标识，以及文件元数据里的隐式标识。',
    `## 1. 服务形态

本应用不内置、不代理、不转售任何大模型服务，也不包含开发者持有的模型 API Key。模型服务由你在设置中自行配置：你填写服务商 Base URL、API Key 和模型名，请求由设备直接发送到该服务商。

应用可能提供常见服务商的 Base URL 预设或占位提示，但不含可用 Key。生成合成内容的模型服务由你自行选择，开发者不提供该模型服务；应用仍对界面展示、复制和导出文件中的 AI 生成内容添加标识。

## 2. 显式标识

| 场景 | 标识位置 | 形式 |
| --- | --- | --- |
| 对话回答 | 回答正文末尾 | AI生成 小角标 |
| 工作模式最终回答 | 最终回答正文末尾 | AI生成 小角标 |
| 交互模式消息 | 消息末尾 | AI生成 小角标 |
| 复制纯文本 | 文本末尾 | 追加 AI生成 |
| 复制 Markdown | 文本末尾 | 追加 > AI生成 |
| 导出 Word | 正文末尾 + 每页页脚 | 8pt 浅灰 AI生成 |
| 生成 PowerPoint | 每页左下角 | 8pt 浅灰 AI生成 |
| 生成 Excel | 打印/页面布局页脚 | AI生成 |
| 生成 SVG | 图片右下角 | AI生成，字号不低于最短边 5% |
| SVG 预览 PNG | 图片右下角 + PNG 元数据 | AI生成 文字 + AIGC 字段 |
| 工作区 ZIP | 压缩包根目录 | _AI生成内容标识.txt |

## 3. 隐式标识

- Word / PowerPoint / Excel：在 docProps/custom.xml 写入名为 AIGC 的自定义属性，值为附录 E 规定的 JSON，每个文件仅一份。
- SVG：在根元素后写入 metadata id="aigc-mark"，内容为同一份 AIGC JSON。
- PNG 预览：在 tEXt 块写入 AIGC 关键字和 JSON。

字段包括生成合成标签、生成合成服务提供者名称/编码、内容制作编号、内容传播服务提供者与传播编号。首次写入时传播者与制作者一致。

## 4. 不涉及的场景

本应用不提供合成人声/仿声、人脸生成/替换/操控、姿态操控、沉浸式拟真场景等深度合成能力，不生成或导出音频、视频文件。

朗读功能使用 HarmonyOS CoreSpeechKit 系统 TTS 播放 AI 文本，不提供音色克隆/仿声，也不产生可下载的音频文件；朗读控制条带 AI生成 提示。

## 5. 导出与分享

复制、导出 Word、生成 PPT/Excel/SVG、分享工作区文件、导出工作区 ZIP 都会按上述方式添加标识。CSV/JSON 等结构化数据为保持可机读性，不在数据行中插入会破坏结构的标识；其 AI 生成属性在应用内角标、产物卡片和 ZIP 说明文件中体现。`
  );

  static readonly THIRD_PARTY: LegalDoc = new LegalDoc(
    'thirdparty',
    '第三方组件与许可',
    '随应用分发的原生组件、Python 运行时、界面库及其许可证。',
    `## 1. Shell 与原生执行核

| 组件 | 许可证 | 用途 |
| --- | --- | --- |
| IEC / BetterSH | MIT | exec/tty 服务、loader、fs/exec/tty shim |
| mksh | MirOS licence | sh / mksh |
| toybox | 0BSD | ls/cat/grep/sed/awk/find/xargs 等 |
| libarchive | BSD-2-Clause | tar / unzip / cpio / zip |
| git | GPL-2.0 | git 与 git-remote-http(s) |
| dropbear | MIT | ssh / scp / ssh-keygen / sftp |
| Node.js | MIT（含 npm / ICU / OpenSSL 等内嵌声明） | node / npm / npx |
| jq | MIT | jq |
| oniguruma | BSD-2-Clause | jq 正则引擎（静态链接） |
| curl | curl licence | curl 与 git https 传输 |
| GNU bc | GPL-3.0-or-later | bc |
| OpenSSH sftp | BSD（ISC 风格） | sftp 客户端 |
| zlib | zlib License | 多个原生组件的静态依赖 |
| OpenSSL | Apache-2.0 | git / node / curl / sftp |
| PCRE2 | BSD-3-Clause | git |

## 2. 原生 Python

| 组件 | 许可证 | 说明 |
| --- | --- | --- |
| CPython 3.12 | PSF-2.0 | run_python 与 shell 里的 python3 |
| Source Han Sans SC | OFL-1.1 | 随包中文字体 |
| numpy / scipy / pandas | BSD 系列 | 本地科学计算与绘图 |
| matplotlib | PSF-2.0 + MIT / CC0 / OFL / Bitstream-Vera 等 | 绘图（字体与样例数据各有单独许可） |
| Pillow / libjpeg-turbo / libpng | HPND / IJG / libpng | 图片处理 |
| lxml / libxml2 / libxslt | BSD / MIT / BSD | XML 处理 |
| PyCryptodome | BSD-2-Clause / public domain 部分 | 加密原语 |
| python-docx / python-pptx / reportlab / openpyxl | MIT / MIT / BSD / MIT | 文档生成 |
| sympy / regex / psutil | BSD / Apache-2.0 / BSD | 符号计算、正则、进程信息 |

完整的 Python 三方包清单以随包 licenses/THIRD_PARTY_NOTICES.md 为准。

## 3. 界面与运行时

| 组件 | 许可证 | 用途 |
| --- | --- | --- |
| @luvi/lv-markdown-in | 见 oh_modules 内 LICENSE | Markdown 渲染 |
| @cangjie-tpc/formula_hybrid | 见 oh_modules 内 LICENSE | LaTeX 公式 |
| @cangjie-tpc/prism_hybrid | 见 oh_modules 内 LICENSE | 代码高亮 |
| HarmonyOS SDK / JSVM-API | 华为 HarmonyOS SDK 许可 | 系统能力与 run_js |

## 4. GPL 组件说明

git 以 GPL-2.0 分发，GNU bc 以 GPL-3.0-or-later 分发。它们以独立 .so 随包，不与主程序静态合并；本仓库未修改 bc 源码，git 仅做交叉编译、入口改名和链接调整。对应源码可从上游获取，构建脚本随仓库提供。

完整声明和许可证原文随应用包分发，可在“开源许可证全文”中查看。`
  );

  static readonly DOCS: LegalDoc[] = [
    LegalDocuments.AIGC,
    LegalDocuments.THIRD_PARTY
  ];

  static readonly LICENSES: LegalLicense[] = [
    new LegalLicense('IEC', 'licenses/IEC-MIT.txt', 'MIT'),
    new LegalLicense('BetterSH', 'licenses/BetterSH-MIT.txt', 'MIT'),
    new LegalLicense('mksh', 'licenses/mksh-MirOS.txt', 'MirOS licence'),
    new LegalLicense('toybox', 'licenses/toybox-0BSD.txt', '0BSD'),
    new LegalLicense('libarchive', 'licenses/libarchive-BSD-2-Clause.txt', 'BSD-2-Clause'),
    new LegalLicense('git', 'licenses/GPL-2.0.txt', 'GPL-2.0'),
    new LegalLicense('GNU bc', 'licenses/GPL-3.0.txt', 'GPL-3.0'),
    new LegalLicense('Dropbear', 'licenses/dropbear-MIT.txt', 'MIT'),
    new LegalLicense('Node.js', 'licenses/node-LICENSE.txt', 'MIT + bundled'),
    new LegalLicense('jq', 'licenses/jq-MIT.txt', 'MIT'),
    new LegalLicense('Oniguruma', 'licenses/oniguruma-BSD-2-Clause.txt', 'BSD-2-Clause'),
    new LegalLicense('curl', 'licenses/curl-LICENSE.txt', 'curl licence'),
    new LegalLicense('OpenSSH sftp', 'licenses/openssh-BSD.txt', 'BSD'),
    new LegalLicense('OpenSSL', 'licenses/Apache-2.0-OpenSSL.txt', 'Apache-2.0'),
    new LegalLicense('CPython', 'licenses/CPython-LICENSE.txt', 'PSF-2.0')
  ];

  static find(id: string): LegalDoc | null {
    for (let i: number = 0; i < LegalDocuments.DOCS.length; i++) {
      if (LegalDocuments.DOCS[i].id === id) {
        return LegalDocuments.DOCS[i];
      }
    }
    return null;
  }
}
