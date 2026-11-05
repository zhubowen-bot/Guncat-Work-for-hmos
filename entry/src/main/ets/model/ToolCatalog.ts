// 设置页「工具」只读目录。
// 静态快照, 与 WorkFileService / HarnessTools 的工具定义保持同名;
// 打开设置页不需要构造 40+ 份工具定义与长描述, 页面渲染不产生额外计算与监听。
export class ToolCatalogItem {
  name: string = '';
  summary: string = '';

  constructor(name: string, summary: string) {
    this.name = name;
    this.summary = summary;
  }
}

export class ToolCatalogGroup {
  title: string = '';
  icon: string = '';
  tools: ToolCatalogItem[] = [];

  constructor(title: string, icon: string, tools: ToolCatalogItem[]) {
    this.title = title;
    this.icon = icon;
    this.tools = tools;
  }
}

export const TOOL_CATALOG: ToolCatalogGroup[] = [
  new ToolCatalogGroup('阅读与检索', 'search', [
    new ToolCatalogItem('list_files', '浏览工作区文件'),
    new ToolCatalogItem('glob', '按文件名匹配路径'),
    new ToolCatalogItem('read_file', '读取文件内容'),
    new ToolCatalogItem('search_files', '在文件中查找内容'),
    new ToolCatalogItem('grep', '按规则搜索文本'),
    new ToolCatalogItem('parse_document', '解析 PDF 文本'),
    new ToolCatalogItem('search_pdf', '在 PDF 中查找'),
    new ToolCatalogItem('pdf_to_images', '把 PDF 转成图片'),
    new ToolCatalogItem('view_image', '查看工作区图片')
  ]),
  new ToolCatalogGroup('写入与编辑', 'edit', [
    new ToolCatalogItem('write_file', '写入或覆盖文件'),
    new ToolCatalogItem('append_file', '在文件末尾追加'),
    new ToolCatalogItem('edit', '精确修改文件片段'),
    new ToolCatalogItem('str_replace_editor', '按指令编辑文本'),
    new ToolCatalogItem('create_dir', '新建目录'),
    new ToolCatalogItem('move_file', '移动或重命名'),
    new ToolCatalogItem('delete_file', '删除文件或目录'),
    new ToolCatalogItem('download_file', '下载网络文件'),
    new ToolCatalogItem('write_svg', '生成 SVG 图形')
  ]),
  new ToolCatalogGroup('计算与执行', 'code', [
    new ToolCatalogItem('transform_file', '清洗与转换表格数据'),
    new ToolCatalogItem('write_csv', '生成 CSV 表格'),
    new ToolCatalogItem('run_js', '执行 JavaScript'),
    new ToolCatalogItem('run_python', '执行 Python'),
    new ToolCatalogItem('shell', '运行 Shell 命令')
  ]),
  new ToolCatalogGroup('文档产出', 'doc', [
    new ToolCatalogItem('write_docx', '生成 Word 文档'),
    new ToolCatalogItem('read_docx', '读取 Word 文档'),
    new ToolCatalogItem('edit_docx', '修改 Word 文档'),
    new ToolCatalogItem('write_xlsx', '生成 Excel 工作簿'),
    new ToolCatalogItem('read_xlsx', '读取 Excel 工作簿'),
    new ToolCatalogItem('edit_xlsx', '修改 Excel 工作簿'),
    new ToolCatalogItem('write_pptx', '生成演示文稿'),
    new ToolCatalogItem('read_ppt', '读取演示文稿'),
    new ToolCatalogItem('edit_ppt', '修改演示文稿')
  ]),
  new ToolCatalogGroup('联网与上下文', 'web', [
    new ToolCatalogItem('local_web_search', '设备内联网搜索'),
    new ToolCatalogItem('web_fetch', '抓取网页内容'),
    new ToolCatalogItem('record_search', '记录搜索来源'),
    new ToolCatalogItem('session_search', '检索会话记录')
  ]),
  new ToolCatalogGroup('任务与协作', 'task', [
    new ToolCatalogItem('todo_write', '维护任务清单'),
    new ToolCatalogItem('ask_user_question', '向用户确认关键信息'),
    new ToolCatalogItem('schedule_create', '创建定时提醒'),
    new ToolCatalogItem('schedule_list', '查看定时提醒'),
    new ToolCatalogItem('schedule_delete', '取消定时提醒'),
    new ToolCatalogItem('goal_create', '建立任务目标'),
    new ToolCatalogItem('goal_get', '查看任务目标'),
    new ToolCatalogItem('goal_update', '更新任务目标'),
    new ToolCatalogItem('subagent', '委派独立子任务')
  ]),
  new ToolCatalogGroup('技能', 'skill', [
    new ToolCatalogItem('list_skills', '查看可用技能'),
    new ToolCatalogItem('load_skill', '加载技能说明')
  ])
];

export function toolCatalogCount(): number {
  let total: number = 0;
  for (let i: number = 0; i < TOOL_CATALOG.length; i++) {
    total += TOOL_CATALOG[i].tools.length;
  }
  return total;
}
