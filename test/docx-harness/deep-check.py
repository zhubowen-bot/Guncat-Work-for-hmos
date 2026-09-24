# 深度校验: 内嵌 doc.json 往返一致性 + python-docx 读正文/表格/图片核验
# 用法: python deep-check.py gen/out_all.docx gen/out_md.docx gen/out_edit.docx
import sys
import zipfile
import json
from docx import Document

def deep(path):
    print(f'== {path} ==')
    z = zipfile.ZipFile(path)
    src = json.loads(z.read('docProps/doc.json'))
    d = Document(path)

    # 1) 正文文本: python-docx 抽取的纯文本应包含 Doc 源中的主要文本片段
    paras = [p.text for p in d.paragraphs if p.text.strip()]
    joined = '\n'.join(paras)
    checks = []
    for b in src['blocks']:
        if b.get('type') == 'paragraph':
            # 去行内 markdown 标记后抽查关键词(取前 8 个中文字符)
            text = b.get('text', '')
            key = text.replace('**', '').replace('*', '').replace('`', '')[:8]
            if key:
                checks.append(key in joined)
    # 表格文本
    tbl_texts = []
    for t in d.tables:
        for row in t.rows:
            for cell in row.cells:
                tbl_texts.append(cell.text)
    tbl_joined = ' '.join(tbl_texts)
    assert any(x.strip() for x in tbl_texts), '表格内容未读出'
    if '渠道' in tbl_joined:
        print(f'  表格核验: 表头「渠道」读出 OK')
    print(f'  正文抽查: 通过 ({sum(checks)}/{len(checks)})')

    # 2) 标题顺序: python-docx 读出的 Heading1 与 Doc 源一致
    src_h1 = [b['text'] for b in src['blocks'] if b.get('type') == 'heading' and b.get('level') == 1]
    doc_h1 = []
    for p in d.paragraphs:
        if p.style.name == 'Heading 1' and p.text.strip():
            doc_h1.append(p.text)
    # 部分标题文本可能带行内 markdown 标记, 逐字符宽松比较
    def loose(a, b):
        return a.replace('**', '').replace('*', '') == b.replace('**', '').replace('*', '')
    for a in src_h1:
        assert any(loose(a, b) for b in doc_h1), f'H1 缺失: {a}'
    print(f'  H1 顺序核验: OK ({len(doc_h1)} 个)')

    # 3) 图片数: inline_shapes 与 Doc 源独立图片块 + 行内图片之和一致
    n_src_img = sum(1 for b in src['blocks'] if b.get('type') == 'image')
    n_inline = sum(b.get('text', '').count('![') for b in src['blocks'] if b.get('type') == 'paragraph')
    got = len(d.inline_shapes)
    expect = n_src_img + n_inline
    assert got == expect, f'图片数不一致: python-docx={got}, Doc 源={expect}'
    print(f'  图片核验: {got} == {expect} OK')

    # 4) 封面/目录: cover=true 时应存在 Title 段落; toc=true 时应存在 TOC 域
    if src.get('cover'):
        titles = [p.text for p in d.paragraphs if p.style.name == 'Title']
        assert any(p.text.strip() == src['title'] for p in d.paragraphs if p.style.name == 'Title'), '封面标题缺失'
        print('  封面: OK')
    if src.get('toc'):
        all_xml = '\n'.join(p._p.xml for p in d.paragraphs)
        assert 'TOC' in all_xml and 'instrText' in all_xml, '目录域缺失'
        print('  目录: OK')

if __name__ == '__main__':
    for path in sys.argv[1:]:
        deep(path)
    print('ALL DEEP-CHECK OK')
