#!/usr/bin/env python3
"""检查 Guncat Work 导出文件的 AI 生成内容标识。

用法:
    python tools/check-aigc-mark.py sample.docx sample.pptx sample.xlsx sample.svg sample.md

校验项:
- docx/pptx/xlsx: docProps/custom.xml 中有 name="AIGC" 的自定义属性，
  值可解析为附录 E 的 JSON，且 Label / ContentProducer / ProduceID 均存在；
- docx: word/footer1.xml 与 word/document.xml 含 "AI生成"；
- pptx: 每个 ppt/slides/slideN.xml 含 "AI生成"；
- xlsx: 每个 xl/worksheets/sheetN.xml 含 "AI生成"；
- svg: 有 <metadata id="aigc-mark"> 且 JSON 可解析，正文含 "AI生成"；
- png: 有 AIGC tEXt 块且 JSON 可解析；
- md/txt/html: 末尾含 "AI生成"；
- zip: 根目录有 _AI生成内容标识.txt，且内容包含 AIGC 字段。
"""

import json
import re
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

CUSTOM_PROPERTY_NS = "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties"
LABEL = "AI生成"


def fail(errors, message):
    errors.append(message)


def read_zip_xml(zf, name):
    return ET.fromstring(zf.read(name))


def check_aigc_json(raw, errors, where):
    try:
        data = json.loads(raw)
    except Exception as exc:  # noqa: BLE001
        fail(errors, f"{where}: AIGC 值不是合法 JSON: {exc}")
        return
    aigc = data.get("AIGC") if isinstance(data, dict) else None
    if not isinstance(aigc, dict):
        fail(errors, f"{where}: 缺少 AIGC 对象")
        return
    for key in ("Label", "ContentProducer", "ProduceID", "ContentPropagator", "PropagateID"):
        if not isinstance(aigc.get(key), str) or aigc.get(key) == "":
            fail(errors, f"{where}: AIGC.{key} 缺失或为空")
    if aigc.get("Label") not in ("1", "2", "3"):
        fail(errors, f"{where}: AIGC.Label 取值应为 1/2/3，实际 {aigc.get('Label')!r}")


def check_ooxml_custom(zf, errors):
    if "docProps/custom.xml" not in zf.namelist():
        fail(errors, "缺少 docProps/custom.xml")
        return
    root = read_zip_xml(zf, "docProps/custom.xml")
    found = False
    for prop in root.findall(f"{{{CUSTOM_PROPERTY_NS}}}property"):
        if prop.get("name") != "AIGC":
            continue
        found = True
        value = "".join(prop.itertext()).strip()
        if not value:
            fail(errors, "docProps/custom.xml 的 AIGC 属性为空")
        else:
            check_aigc_json(value, errors, "docProps/custom.xml")
    if not found:
        fail(errors, "docProps/custom.xml 中缺少 name=AIGC 的属性")


def check_docx(path, errors):
    with zipfile.ZipFile(path) as zf:
        check_ooxml_custom(zf, errors)
        if "word/footer1.xml" not in zf.namelist():
            fail(errors, "缺少 word/footer1.xml")
        elif LABEL not in zf.read("word/footer1.xml").decode("utf-8", "replace"):
            fail(errors, "word/footer1.xml 中未找到 " + LABEL)
        if LABEL not in zf.read("word/document.xml").decode("utf-8", "replace"):
            fail(errors, "word/document.xml 中未找到 " + LABEL)


def check_pptx(path, errors):
    with zipfile.ZipFile(path) as zf:
        check_ooxml_custom(zf, errors)
        slides = sorted(n for n in zf.namelist() if re.fullmatch(r"ppt/slides/slide\d+\.xml", n))
        if not slides:
            fail(errors, "未找到任何 ppt/slides/slideN.xml")
        for name in slides:
            if LABEL not in zf.read(name).decode("utf-8", "replace"):
                fail(errors, f"{name} 中未找到 {LABEL}")


def check_xlsx(path, errors):
    with zipfile.ZipFile(path) as zf:
        check_ooxml_custom(zf, errors)
        sheets = sorted(n for n in zf.namelist()
                        if re.fullmatch(r"xl/worksheets/sheet\d+\.xml", n))
        if not sheets:
            fail(errors, "未找到任何 xl/worksheets/sheetN.xml")
        for name in sheets:
            if LABEL not in zf.read(name).decode("utf-8", "replace"):
                fail(errors, f"{name} 中未找到 {LABEL}")


def check_svg(path, errors):
    text = path.read_text(encoding="utf-8", errors="replace")
    m = re.search(r'<metadata\s+id="aigc-mark"[^>]*>(.*?)</metadata>', text, re.S)
    if not m:
        fail(errors, '缺少 <metadata id="aigc-mark">')
    else:
        raw = m.group(1).strip()
        # XML 解析会还原 &quot; 等实体
        try:
            raw = ET.fromstring(f"<x>{raw}</x>").text or ""
        except Exception:  # noqa: BLE001
            pass
        check_aigc_json(raw, errors, "svg metadata")
    if LABEL not in text:
        fail(errors, f"SVG 中未找到 {LABEL}")


def check_png(path, errors):
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        fail(errors, "不是有效的 PNG 文件")
        return
    pos = 8
    found = False
    while pos + 12 <= len(data):
        length = int.from_bytes(data[pos:pos + 4], "big")
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"tEXt":
            if b"\x00" in body:
                keyword, value = body.split(b"\x00", 1)
                if keyword.decode("latin-1") == "AIGC":
                    found = True
                    check_aigc_json(value.decode("latin-1"), errors, "png tEXt")
        if kind == b"IEND":
            break
        pos += 12 + length
    if not found:
        fail(errors, "PNG 中缺少 AIGC tEXt 块")


def check_text(path, errors):
    text = path.read_text(encoding="utf-8", errors="replace")
    if LABEL not in text[-64:]:
        fail(errors, f"文本末尾 64 个字符内未找到 {LABEL}")


def check_html(path, errors):
    text = path.read_text(encoding="utf-8", errors="replace")
    if LABEL not in text[-512:]:
        fail(errors, f"HTML 末尾未找到 {LABEL}")


def check_zip(path, errors):
    with zipfile.ZipFile(path) as zf:
        names = zf.namelist()
        notice = next((n for n in names if n.endswith("_AI生成内容标识.txt")), None)
        if notice is None:
            fail(errors, "压缩包根目录缺少 _AI生成内容标识.txt")
            return
        body = zf.read(notice).decode("utf-8", "replace")
        if "AIGC" not in body and "人工智能" not in body:
            fail(errors, f"{notice} 未包含 AIGC/人工智能说明")


def check(path):
    errors = []
    suffix = path.suffix.lower()
    try:
        if suffix == ".docx":
            check_docx(path, errors)
        elif suffix == ".pptx":
            check_pptx(path, errors)
        elif suffix == ".xlsx":
            check_xlsx(path, errors)
        elif suffix == ".svg":
            check_svg(path, errors)
        elif suffix == ".png":
            check_png(path, errors)
        elif suffix in (".md", ".txt"):
            check_text(path, errors)
        elif suffix in (".html", ".htm"):
            check_html(path, errors)
        elif suffix == ".zip":
            check_zip(path, errors)
        else:
            fail(errors, f"不支持的文件类型: {suffix}")
    except Exception as exc:  # noqa: BLE001
        fail(errors, f"检查失败: {exc}")
    return errors


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    failed = 0
    for item in argv[1:]:
        path = Path(item)
        if not path.exists():
            print(f"[FAIL] {path} 不存在")
            failed += 1
            continue
        errors = check(path)
        if errors:
            failed += 1
            print(f"[FAIL] {path}")
            for err in errors:
                print(f"       - {err}")
        else:
            print(f"[OK]   {path}")
    if failed:
        print(f"\n{failed} 个文件未通过 AIGC 标识检查")
        return 1
    print("\n全部文件通过 AIGC 标识检查")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
