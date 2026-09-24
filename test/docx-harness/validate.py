# 校验生成的 docx: zip 完整性 / XML well-formed / 关系一致 / 样式与字号分级 / python-docx 可打开 / 图片嵌入
# 用法: python validate.py gen/out_all.docx gen/out_md.docx gen/out_edit.docx
import re
import sys
import zipfile
import json
from xml.etree import ElementTree as ET

from docx import Document

def validate(path):
    print(f'== {path} ==')
    z = zipfile.ZipFile(path)
    assert z.testzip() is None, 'zip CRC 损坏'
    names = set(z.namelist())

    for n in names:
        if n.endswith('.xml') or n.endswith('.rels'):
            ET.fromstring(z.read(n))  # well-formed 校验
    print(f'  XML well-formed: OK ({len([n for n in names if n.endswith((".xml", ".rels"))])} 个部件)')

    # 关系一致: document.xml 引用的 rId 必须存在于 document.xml.rels 且 Target 存在(外部超链接除外)
    import posixpath
    rels_root = ET.fromstring(z.read('word/_rels/document.xml.rels'))
    rid_map = {}
    ext_map = {}
    for rel in rels_root:
        rid_map[rel.get('Id')] = rel.get('Target')
        if rel.get('TargetMode') == 'External':
            ext_map[rel.get('Id')] = True
    used = set(re.findall(rb'r:(?:embed|id|link)="(rId\d+)"', z.read('word/document.xml')))
    for rid in used:
        rid = rid.decode()
        assert rid in rid_map, f'document.xml 引用了未定义的 {rid}'
        if rid in ext_map:
            continue
        target = rid_map[rid]
        full = posixpath.normpath(posixpath.join('word', target))
        assert full in names, f'关系目标不存在: {target}'
    print(f'  关系一致: OK ({len(used)} 处引用)')

    # 内嵌 Doc 源
    doc_src = json.loads(z.read('docProps/doc.json'))
    assert 'blocks' in doc_src and len(doc_src['blocks']) > 0
    print(f'  内嵌 doc.json: {len(doc_src["blocks"])} 块')

    # python-docx 打开 + 样式检查
    d = Document(path)
    styles = {s.style_id: s for s in d.styles}
    heading_ids = [f'Heading{i}' for i in range(1, 7)]
    missing = [h for h in heading_ids if h not in styles]
    assert not missing, f'缺少标题样式: {missing}'
    # 标题字号严格递减(H1 > H2 > … > H6), 且 H1 明显大于正文(24 半磅)
    sizes = []
    for h in heading_ids:
        sz = styles[h].font.size
        sizes.append(sz.pt if sz else -1)
    for i in range(len(sizes) - 1):
        assert sizes[i] > sizes[i + 1], f'标题字号未递减: {heading_ids[i]}={sizes[i]} vs {heading_ids[i+1]}={sizes[i+1]}'
    assert sizes[0] >= 20, f'H1 字号过小: {sizes[0]}pt'
    # 默认正文字号来自 docDefaults(宋体 12pt / 24 半磅), Normal 无显式 rPr 属正常
    ns = {'w': 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
    styles_root = ET.fromstring(z.read('word/styles.xml'))
    sz_el = styles_root.find('.//w:docDefaults/w:rPrDefault/w:rPr/w:sz', ns)
    default_half = int(sz_el.get('{%s}val' % ns['w'])) if sz_el is not None else None
    assert default_half == 24, f'docDefaults 字号应为 12pt(24 半磅), 实际 {default_half}'
    print(f'  样式分级: H1={sizes[0]}pt → H6={sizes[5]}pt, 默认正文={default_half // 2}pt (递减 OK)')

    # 图片嵌入
    inline_shapes = len(d.inline_shapes)
    media = [n for n in names if n.startswith('word/media/')]
    print(f'  图片: inline_shapes={inline_shapes}, media 部件={len(media)}')

    # 表格
    n_tables = len(d.tables)
    print(f'  表格: {n_tables}')
    return doc_src, inline_shapes, n_tables

def main():
    for path in sys.argv[1:]:
        validate(path)
    print('ALL VALIDATE OK')

if __name__ == '__main__':
    main()
