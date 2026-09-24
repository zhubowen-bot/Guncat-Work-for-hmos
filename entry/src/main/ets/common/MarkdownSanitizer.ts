/**
 * Markdown 表格规范化 — 防御 @luvi/lv-markdown-in 3.4.5 的表格渲染闪退
 *
 * 背景: 三方库的 TableRender 组件在 aboutToAppear 中遍历表格节点时,
 * 会对 undefined 直接调用 forEach 抛 TypeError (库内部 bug, ohpm 上
 * 3.4.5 已是最新版仍未修复)。该异常在组件生命周期中无法被业务侧捕获,
 * 进程直接闪退 (见 faultlog: jscrash-com.bowenapp.guncataibeta-*,
 * Reason: TypeError, Cannot read property forEach of undefined)。
 *
 * 触发条件: 聊天记录中某条消息的 markdown 含结构异常的表格 —— 例如
 * 表头全空 (| |)、某行无任何单元格、行与表头列数不一致等, 库的解析器
 * 会产出缺数组的节点。历史消息在冷启动重渲染时必然命中, 故每次进入
 * 会话都可能复现。
 *
 * 处理策略 (只在渲染前对内容做无害化, 不改动任何存储):
 *   1. 结构合法的 GFM 表格 → 规范化为统一形态: 行首行尾补闭合竖线、
 *      所有行补齐到最大列数、列对齐方式从分隔线保留;
 *   2. 无法修复的退化表格 (表头无任何内容单元格) → 降级为纯文本:
 *      丢弃分隔线行, 其余行原样保留, 竖线按普通字符渲染, 内容不丢失;
 *   3. 代码围栏 / 缩进代码 / 列表项 / 引用块 内的内容一律不参与检测,
 *      原样透传, 避免误伤非表格语法。
 */
export function sanitizeMarkdownForRender(content: string): string {
  // 快速路径: 没有竖线就绝不可能是表格, 直接返回原文
  if (content === '' || content.indexOf('|') < 0) {
    return content;
  }

  const lines: string[] = content.split('\n');
  const out: string[] = [];
  let inFence: boolean = false;
  let fenceChar: string = '';
  let i: number = 0;

  while (i < lines.length) {
    const line: string = lines[i];

    // 代码围栏 (``` / ~~~, 允许 0-3 个前导空格): 围栏内内容原样透传
    if (/^ {0,3}(`{3,}|~{3,})/.test(line)) {
      const ch: string = line.replace(/^ +/, '').charAt(0);
      if (inFence) {
        if (ch === fenceChar) {
          inFence = false;
        }
      } else {
        inFence = true;
        fenceChar = ch;
      }
      out.push(line);
      i++;
      continue;
    }
    // 围栏内 / 缩进代码块 (≥4 空格或 Tab) / 列表项 / 引用块: 不参与表格检测
    if (inFence || isIndentedCode(line) || isListOrQuoteLine(line)) {
      out.push(line);
      i++;
      continue;
    }

    // 表格检测: 当前行含未转义竖线, 且下一行是合法的分隔线
    if (looksLikeTableRow(line)) {
      const next: string = i + 1 < lines.length ? lines[i + 1] : '';
      if (isSeparatorLine(next)) {
        // 收集整个表格块: 连续的非空且含竖线的行
        const block: string[] = [line, next];
        let j: number = i + 2;
        while (j < lines.length && lines[j].trim() !== '' && looksLikeTableRow(lines[j])) {
          block.push(lines[j]);
          j++;
        }
        const fixed: string[] | null = normalizeTableBlock(block);
        if (fixed === null) {
          // 退化表格: 降级为纯文本 (丢弃分隔线行, 其余原样保留)
          for (let k: number = 0; k < block.length; k++) {
            if (k !== 1) {
              out.push(block[k]);
            }
          }
        } else {
          for (const fixedLine of fixed) {
            out.push(fixedLine);
          }
        }
        // 表格块后若紧跟非空且不以 '|' 开头的行, 补一个空行分隔
        // (库的表格体收集逻辑在空行处结束, 避免把表后正文吞进表格)
        if (j < lines.length && lines[j].trim() !== '' && !lines[j].trim().startsWith('|')) {
          out.push('');
        }
        i = j;
        continue;
      }
    }

    out.push(line);
    i++;
  }

  return out.join('\n');
}

// 缩进代码块 (≥4 空格或 Tab 开头): 原样透传, 不参与表格检测
function isIndentedCode(line: string): boolean {
  return line.startsWith('    ') || line.startsWith('\t');
}

// 列表项 / 引用块行: 内部表格结构复杂 (缩进、前缀), 一律原样透传
// (合法表格在库中本就正常渲染, 只有退化表格才会闪退, 保持现状即可)
function isListOrQuoteLine(line: string): boolean {
  return /^ {0,3}(>(\s|$)|[-*+]\s|\d+[.)]\s)/.test(line);
}

// 行内是否含未转义的竖线
function hasUnescapedPipe(text: string): boolean {
  let escaped: boolean = false;
  for (let k: number = 0; k < text.length; k++) {
    const ch: string = text.charAt(k);
    if (escaped) {
      escaped = false;
    } else if (ch === '\\') {
      escaped = true;
    } else if (ch === '|') {
      return true;
    }
  }
  return false;
}

function looksLikeTableRow(line: string): boolean {
  const t: string = line.trim();
  return t !== '' && hasUnescapedPipe(t);
}

// 分隔线行判定 (GFM): 行内含未转义竖线, 每个单元格只能是 可选冒号 + 至少一个 '-'
function isSeparatorLine(line: string): boolean {
  if (!hasUnescapedPipe(line)) {
    return false;
  }
  const cells: string[] = splitCells(line);
  if (cells.length === 0) {
    return false;
  }
  for (let k: number = 0; k < cells.length; k++) {
    if (!/^:?-+:?$/.test(cells[k])) {
      return false;
    }
  }
  return true;
}

// 把表格行拆成单元格 (尊重 \| 转义, 每个单元格 trim)
// 行首/行尾竖线产生的空单元格按 GFM 规则丢弃
function splitCells(line: string): string[] {
  const t: string = line.trim();
  const cells: string[] = [];
  let cur: string = '';
  let escaped: boolean = false;
  for (let k: number = 0; k < t.length; k++) {
    const ch: string = t.charAt(k);
    if (escaped) {
      cur += ch;
      escaped = false;
    } else if (ch === '\\') {
      cur += ch;
      escaped = true;
    } else if (ch === '|') {
      cells.push(cur.trim());
      cur = '';
    } else {
      cur += ch;
    }
  }
  cells.push(cur.trim());
  if (cells.length > 0 && cells[0] === '') {
    cells.shift();
  }
  if (cells.length > 0 && cells[cells.length - 1] === '') {
    cells.pop();
  }
  return cells;
}

// 规范化表格块; 无法修复时返回 null, 由调用方降级为纯文本。
// 无法修复的情况:
//   1. 表头无任何内容单元格 (如 `| |`)
//   2. 表头存在空单元格 (如 `| a | | c |`) — 库的 TableRender 遍历表头单元格
//      children 时, 空单元格节点缺 children 属性, 直接 forEach undefined 闪退
//      (三方库 3.4.5 反编译确认, faultlog: Cannot read property forEach of undefined)
//   3. 只有表头 + 分隔线、无任何数据行 — 同一崩溃路径 (库对 header-only 表格
//      渲染异常), 且无数据行的表格本就没有展示价值, 降级零损失
function normalizeTableBlock(block: string[]): string[] | null {
  const headerCells: string[] = splitCells(block[0]);
  if (headerCells.length === 0 || headerCells.every((c: string) => c === '')) {
    return null;
  }
  if (headerCells.some((c: string) => c === '')) {
    return null;
  }
  // 无数据行的表格 (仅表头 + 分隔线) 直接降级
  // (空数据行的情况由下方 rowCellLists.length === 0 一并覆盖)

  // 列对齐方式从分隔线各列推导 (GFM: 冒号在左=左对齐, 在右=右对齐, 两边=居中)
  const sepCells: string[] = splitCells(block[1]);
  const aligns: string[] = [];
  for (let k: number = 0; k < sepCells.length; k++) {
    const t: string = sepCells[k];
    const left: boolean = t.startsWith(':');
    const right: boolean = t.endsWith(':');
    aligns.push(left ? (right ? 'center' : 'left') : (right ? 'right' : 'none'));
  }

  // 列数取 表头 / 分隔线 / 所有数据行 的最大值, 保证每行列数一致
  let colCount: number = Math.max(headerCells.length, sepCells.length);
  const rowCellLists: string[][] = [];
  for (let r: number = 2; r < block.length; r++) {
    const cells: string[] = splitCells(block[r]);
    // 全空数据行直接丢弃 (库对空行的处理不可靠, 丢弃不影响内容)
    if (cells.every((c: string) => c === '')) {
      continue;
    }
    rowCellLists.push(cells);
    if (cells.length > colCount) {
      colCount = cells.length;
    }
  }
  // 过滤后仍无任何有效数据行 (仅表头 + 分隔线) → 降级
  if (rowCellLists.length === 0) {
    return null;
  }

  // 重建规范化表格, 保留首行缩进 (覆盖顶格表与列表内缩进表)
  const indent: string = leadingSpaces(block[0]);
  const result: string[] = [];
  result.push(indent + '| ' + padCells(headerCells, colCount).join(' | ') + ' |');
  result.push(indent + '| ' + buildSeparator(aligns, colCount).join(' | ') + ' |');
  for (const cells of rowCellLists) {
    // 全空数据行直接丢弃 (库对空行的处理不可靠, 丢弃不影响内容)
    if (cells.every((c: string) => c === '')) {
      continue;
    }
    result.push(indent + '| ' + padCells(cells, colCount).join(' | ') + ' |');
  }
  return result;
}

// 补齐单元格数组到指定列数 (缺列用空字符串, 与 GFM 缺列补空行为一致)
function padCells(cells: string[], n: number): string[] {
  const padded: string[] = cells.slice();
  while (padded.length < n) {
    padded.push('');
  }
  return padded;
}

// 按对齐方式生成分隔线单元格 (统一用 3 个 '-' 保证 markdown-it 系列解析器识别)
function buildSeparator(aligns: string[], n: number): string[] {
  const out: string[] = [];
  for (let k: number = 0; k < n; k++) {
    const a: string = k < aligns.length ? aligns[k] : 'none';
    if (a === 'left') {
      out.push(':---');
    } else if (a === 'right') {
      out.push('---:');
    } else if (a === 'center') {
      out.push(':---:');
    } else {
      out.push('---');
    }
  }
  return out;
}

// 行首空格数 (仅空格, Tab 开头已被排除)
function leadingSpaces(line: string): string {
  const m: RegExpMatchArray | null = line.match(/^ */);
  return m !== null ? m[0] : '';
}
