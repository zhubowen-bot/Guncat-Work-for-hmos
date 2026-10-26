#!/usr/bin/env bash
# Guncat Work: 把**纯 Python** 第三方包 vendor 进原生 CPython。
#
# 为什么单独一个脚本: 纯 Python 包不需要交叉编译, 只要解包成 site-packages 目录、打成 zip
# 放进 rawfile 即可(运行时挂到 sys.path 上)。有 C 扩展的包走 build-*-ohos.sh 交叉编译,
# 两者互不干扰。
#
# 产物:
#   entry/src/main/resources/rawfile/python/site-packages.zip   (stored 压缩, 运行时直接挂)
#   tooling/python/vendor-licenses.md                           (各包许可摘要, 供 THIRD_PARTY_NOTICES)
#
# 用法:
#   bash tooling/python/vendor-pure.sh            # 拉取并打包
#   PKGS="requests jinja2" bash tooling/python/vendor-pure.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
WORK="${WORK:-$HOME/ohos-py-vendor}"
PYRAW="$PROJ/entry/src/main/resources/rawfile/python"

# 默认清单: 覆盖"数据处理 / 文档 / 模板 / 配置 / 文本"里最常用的纯 Python 包。
# 说明: 每个包都用 --no-deps 单独拉取, 依赖在下面显式列出, 避免 pip 解析出多余东西。
DEFAULT_PKGS="
certifi
charset-normalizer
idna
urllib3
requests
six
python-dateutil
pytz
packaging
typing-extensions
jinja2
openpyxl
et-xmlfile
xlrd
beautifulsoup4
soupsieve
markdown
pypdf
tabulate
tqdm
pyparsing
cycler
fonttools
cssselect
python-docx
python-pptx
XlsxWriter
qrcode
sympy
mpmath
watchdog
reportlab
"
# 这些包在 PyPI 上同时有"平台轮子"和"纯 Python 轮子", 直接 --only-binary 会挑到 cpXXX 平台轮;
# 显式指定 py3/any 平台把它们拉成纯 Python 版本。
PURE_FORCED="${PURE_FORCED:-charset-normalizer}"
# 需要真实文件的包(模板/证书), 运行时必须在解压后的目录里
DATA_PKGS="${DATA_PKGS:-docx pptx certifi reportlab}"
PKGS="${PKGS:-$DEFAULT_PKGS}"
SOURCE_PKGS="${SOURCE_PKGS:-pyyaml markupsafe}"
mkdir -p "$WORK/src"

mkdir -p "$WORK/wheels" "$WORK/site-packages"
rm -rf "$WORK/wheels" "$WORK/site-packages"
mkdir -p "$WORK/wheels" "$WORK/site-packages"

STAGE="$WORK/site-packages"
LIC="$HERE/vendor-licenses.md"
: > "$LIC"
echo "# vendor 纯 Python 包许可摘要(自动生成, 勿手改)" >> "$LIC"
echo "" >> "$LIC"
echo "| 包 | 版本 | 许可 |" >> "$LIC"
echo "| --- | --- | --- |" >> "$LIC"

SKIPPED=""
for pkg in $PKGS; do
  echo "== $pkg"
  if ! python3 -m pip download "$pkg" --no-deps --only-binary=:all: --quiet \
        --dest "$WORK/wheels" > "$WORK/pip-$pkg.log" 2>&1; then
    # 纯源码包(py3-none-any 之外的形态)先跳过, 交给 C 扩展构建脚本
    SKIPPED="$SKIPPED $pkg"
    echo "   skip (no pure wheel)" >&2
    continue
  fi
done

for pkg in $PURE_FORCED; do
  echo "== $pkg (pure, forced)"
  python3 -m pip download "$pkg" --no-deps --only-binary=:all: \
    --python-version 3.12 --implementation py --abi none --platform any \
    --quiet --dest "$WORK/wheels" > "$WORK/pip-$pkg.log" 2>&1 || echo "   skip" >&2
done

for whl in "$WORK"/wheels/*.whl; do
  [ -f "$whl" ] || continue
  # 只接受纯 Python 轮子; 平台轮子(带 abi 标签)留给交叉编译
  case "$(basename "$whl")" in
    *-py3-none-any.whl|*-py2.py3-none-any.whl|*-cp312-none-any.whl) ;;
    *) echo "   skip wheel $(basename "$whl")" >&2; continue ;;
  esac
  python3 - "$whl" "$STAGE" "$LIC" <<'PY'
import sys, zipfile, pathlib, re, email
whl, stage, lic = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
name = pathlib.Path(whl).name
with zipfile.ZipFile(whl) as z:
    z.extractall(stage)
    meta = [n for n in z.namelist() if n.endswith('.dist-info/METADATA')]
    if meta:
        raw = z.read(meta[0]).decode('utf-8', 'replace')
        msg = email.message_from_string(raw)
        pkg = msg.get('Name', '?')
        ver = msg.get('Version', '?')
        license_text = msg.get('License-Expression') or msg.get('License') or ''
        if not license_text or len(license_text) > 60:
            classifiers = [c for c in (msg.get_all('Classifier') or []) if c.startswith('License ::')]
            license_text = '; '.join(x.split('::')[-1].strip() for x in classifiers) or '见包内 LICENSE'
        with open(lic, 'a') as f:
            f.write('| %s | %s | %s |\n' % (pkg, ver, license_text.replace('|', '\\|').strip()))
print('   +', name)
PY
done

# 只有平台轮子的包: 取 sdist, 只拷纯 Python 部分(PyYAML / MarkupSafe 都有纯 Python 回退实现)
for pkg in $SOURCE_PKGS; do
  echo "== $pkg (sdist, 纯 Python 部分)"
  python3 -m pip download "$pkg" --no-deps --no-binary=:all: --quiet \
    --dest "$WORK/src" > "$WORK/src-$pkg.log" 2>&1 || { echo "   skip" >&2; continue; }
done
for arc in "$WORK"/src/*.tar.gz; do
  [ -f "$arc" ] || continue
  tmp="$WORK/unpack"; rm -rf "$tmp"; mkdir -p "$tmp"
  tar xzf "$arc" -C "$tmp" --strip-components=1
  case "$arc" in
    *PyYAML*|*pyyaml*)
      cp -r "$tmp/lib/yaml" "$STAGE/yaml" ;;
    *MarkupSafe*|*markupsafe*)
      cp -r "$tmp/src/markupsafe" "$STAGE/markupsafe" ;;
  esac
done

# 自带的小工具(网络自检等), 与三方包一起进 zip
mkdir -p "$HERE/local-pkgs"
if [ -d "$HERE/local-pkgs" ]; then
  # 注意: sitecustomize 必须放在 extras(解压后的真实目录)里, 不能进 zip ——
  # 反过来的话它会比 extras 里那份更早被 import, 补丁(如 GUNCAT_PY_LIBDIR)就不生效了
  for f in "$HERE"/local-pkgs/*.py; do
    case "$(basename "$f")" in
      sitecustomize.py) continue ;;
    esac
    cp -f "$f" "$STAGE/" 2>/dev/null || true
  done
fi

# 带"真实数据文件"的包不能留在 zip 里: 它们用 os.path 定位模板/证书, zipimport 下拿不到路径。
# 这些包会被挪到 extras 目录(运行时解成真实文件), 见脚本末尾的输出提示。
for pkg in $DATA_PKGS; do
  if [ -d "$STAGE/$pkg" ]; then
    mkdir -p "$WORK/extras-pkgs"
    rm -rf "$WORK/extras-pkgs/$pkg"
    cp -r "$STAGE/$pkg" "$WORK/extras-pkgs/$pkg"
    rm -rf "$STAGE/$pkg"
    echo "   data-pkg -> extras: $pkg"
  fi
done
for d in "$STAGE"/*.dist-info; do
  case "$(basename "$d")" in
    docx-*|python_docx-*|pptx-*|python_pptx-*|certifi-*) ;;
    *) continue ;;
  esac
  mkdir -p "$WORK/extras-pkgs"
  mv "$d" "$WORK/extras-pkgs/" 2>/dev/null || true
done

# 去掉 __pycache__ 与测试目录, 减小体积
find "$STAGE" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$STAGE" -maxdepth 1 -type d -name 'tests' -prune -exec rm -rf {} + 2>/dev/null || true

rm -f "$PYRAW/site-packages.zip"
( cd "$STAGE" && zip -qr0 "$PYRAW/site-packages.zip" . )
echo "== 产物"
ls -lh "$PYRAW/site-packages.zip" | awk '{print $5, $9}'
echo "包数: $(find "$STAGE" -maxdepth 1 -mindepth 1 -type d | wc -l) 个目录"
if [ -d "$WORK/extras-pkgs" ]; then
  echo "带数据的包已放到 $WORK/extras-pkgs —— 需要合并进 rawfile/python/extras.zip:"
  ls "$WORK/extras-pkgs" | tr '\n' ' '; echo
fi
[ -n "$SKIPPED" ] && echo "跳过(需交叉编译):$SKIPPED" || true
