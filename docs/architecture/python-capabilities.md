# 原生 Python 能力清单（用户视角）

Guncat Work 内置的是**真正的 CPython 3.12.15**（aarch64 交叉编译，不是模拟器/不是精简版），
`run_python` 里能用的东西和桌面 Python 基本一致。这份文档回答两个问题：**能做什么**、
**边界在哪**。

自检脚本：`python3 tooling/python/verify-python-stack.py`（20 项，真机布局下 20/20 通过）。

## 1. 标准库

| 能力 | 说明 |
| --- | --- |
| 文件 / 目录 / 路径 | `pathlib`、`os`、`shutil`、`tempfile` 全可用，工作区就是应用沙箱 |
| 压缩 | `zlib`、`bz2`、`lzma`、`zipfile`、`tarfile`（含 gz/bz2/xz） |
| 数据库 | `sqlite3` 3.45.3，可建库、事务、JSON1 扩展 |
| 网络 | `socket`、`ssl`（118 个根证书随包）、`http.client`、`urllib` |
| 并发 | `threading`、`queue`、`concurrent.futures`、`asyncio`（单线程事件循环） |
| 文本 | `re`、`json`、`csv`、`html.parser`、`xml.etree` |
| 其它 | `hashlib`、`hmac`、`secrets`、`datetime`、`decimal`、`fractions`、`statistics`、`unicodedata` |

## 2. 数值与数据

```python
import numpy as np
a = np.linspace(0, 1, 1000).reshape(100, 10)
np.linalg.svd(a, full_matrices=False)      # 线性代数（自带 lapack_lite）
np.fft.rfft(a)                             # FFT
np.random.default_rng(0).normal(size=5)    # 随机数
```

```python
import pandas as pd
df = pd.read_csv("data.csv")                       # 也可 read_excel / read_json
df.groupby("city")["amt"].sum()
pd.date_range("2026-01-01", periods=30, freq="D", tz="Asia/Shanghai")
df.pivot_table(index="a", columns="b", values="c", aggfunc="mean")
```

**边界**：没有 scipy（`scipy.optimize` / `scipy.sparse` / `scipy.signal` 不可用）。
原因见 `docs/architecture/python-third-party.md`：scipy 需要 LAPACK（Fortran），
而 OHOS 工具链没有 Fortran 编译器。numpy 的 `linalg`/`fft` 能覆盖大部分场景。

## 3. 绘图与图像

```python
import matplotlib
matplotlib.use("Agg")                 # 必须：设备上没有 GUI 后端
import matplotlib.pyplot as plt
fig, ax = plt.subplots(figsize=(6, 4))
ax.plot(x, y); ax.set_title("标题"); ax.grid(True)
fig.savefig("chart.png", dpi=150)     # PNG 最稳；SVG/PDF 也可
```

```python
from PIL import Image, ImageDraw, ImageFilter
im = Image.open("photo.jpg")                  # JPEG/PNG/BMP/GIF/TIFF
im.resize((800, 600)).filter(ImageFilter.SHARPEN).save("out.jpg", quality=85)
ImageDraw.Draw(im).text((10, 10), "Guncat", fill=(255, 255, 255))
```

**中文字体**：matplotlib 默认字体不含中文，需要指定系统/自带字体：
```python
from matplotlib import font_manager
# 把 ttf 放到工作区后：
font_manager.fontManager.addfont("NotoSansSC.ttf")
plt.rcParams["font.family"] = "Noto Sans SC"
```

## 4. 解析与文本

```python
from lxml import etree, html
doc = etree.fromstring(xml_bytes)
doc.xpath("//item[@type='a']/text()")
page = html.fromstring(html_text)
[e.text for e in page.cssselect("div.title")]
```

```python
import regex                                    # 支持 Unicode 属性
regex.findall(r"\p{Han}+", "中文 abc 汉字")      # ['中文', '汉字']
regex.sub(r"\p{Nd}+", "#", "订单 12345")         # '订单 #'
```

## 5. 加密

```python
from Crypto.Cipher import AES
from Crypto.PublicKey import RSA
from Crypto.Hash import SHA256
from Crypto.Signature import pkcs1_15

cipher = AES.new(key32, AES.MODE_GCM, nonce=nonce12)
ct, tag = cipher.encrypt_and_digest(b"secret")
plain = AES.new(key32, AES.MODE_GCM, nonce=nonce12).decrypt_and_verify(ct, tag)

rsa = RSA.generate(2048)
sig = pkcs1_15.new(rsa).sign(SHA256.new(b"msg"))
pkcs1_15.new(rsa.publickey()).verify(SHA256.new(b"msg"), sig)
```
还支持 ECC（`Crypto.PublicKey.ECC`）、SHA3、HMAC、PBKDF2、ChaCha20。

## 6. 文档与办公

```python
import docx
d = docx.Document(); d.add_heading("标题", 0); d.add_paragraph("正文"); d.save("a.docx")

import pptx
p = pptx.Presentation(); s = p.slides.add_slide(p.slide_layouts[1])
s.shapes.title.text = "幻灯片"; p.save("a.pptx")

import xlsxwriter
wb = xlsxwriter.Workbook("a.xlsx"); ws = wb.add_worksheet()
ws.write(0, 0, 42); ws.write_formula(1, 0, "=A1*2"); wb.close()

from reportlab.pdfgen import canvas
c = canvas.Canvas("a.pdf"); c.drawString(72, 720, "Hello PDF"); c.save()
```
（写入工作区后，也可以用内置的文档工具做转换/预览。）

## 7. 网络

```python
import requests
r = requests.get("https://api.example.com/items", timeout=15)
r.raise_for_status(); data = r.json()
```

自检工具（判断设备到底能不能出网、断在哪一层）：

```python
import guncat_net
guncat_net.check()        # 打印 回环 / DNS / TCP / TLS / HTTPS 五段 + 结论
guncat_net.diagnose()     # 同上但不打印，返回 dict，适合 if 判断
guncat_net.get("https://example.com")                 # 取文本（自动处理编码）
guncat_net.download("https://x/a.png", "a.png")        # 下载到文件（流式，不占内存）
```

`check()` 会报告：本机回环是否正常（区分"沙箱坏了"还是"没网"）、每个域名的 IPv4/IPv6 记录、
TCP 连接耗时、TLS 版本与证书到期天数、代理环境变量。证书校验失败时会明确提示
"检查设备系统时间"——这是设备上最常见的证书问题来源。

## 8. 系统信息

```python
import psutil
psutil.cpu_count(); psutil.virtual_memory().total
psutil.Process().num_threads(); psutil.disk_usage("/").free
```
**边界**：设备上只能看到本应用沙箱/容器内的信息，看不到整机所有进程。

## 9. 数学

```python
import sympy
x = sympy.symbols("x")
sympy.integrate(x**2, x)          # x**3/3
sympy.solve(x**2 - 4, x)          # [-2, 2]
sympy.sqrt(2).evalf(20)
```

## 10. 文件监控

```python
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
obs = Observer(); obs.schedule(Handler(), "工作区", recursive=True); obs.start()
```

## 11. 已知边界（重要）

| 限制 | 原因 / 替代 |
| --- | --- |
| 无 scipy | 缺 Fortran/LAPACK；用 numpy + 手写实现 |
| 无 GUI 后端 | matplotlib 必须 `Agg`，输出 PNG/SVG/PDF |
| 无 `tkinter` | 无窗口系统 |
| 只有单线程执行器 | 超时保护依赖"跑在固定线程 + AST 注入检查点"；`threading` 可用但不要指望并发提速 |
| 不能用 `os.fork` / `multiprocessing` | 沙箱与超时模型限制 |
| 无 `pip install` | 包是随应用打包的（离线可用），运行期不能装新包 |
| 文件路径 | 只能读写应用沙箱与用户选择的工作区目录 |
| 超时 | 单次调用有超时；被硬超时打断后，长时间死循环会被熔断（连续 10 次则停用 python 工具，重启应用恢复） |

## 12. 一句话建议

写代码时按"**桌面 Python 能用什么，这里基本都能用**"来想；遇到 `scipy`、GUI、`fork`、
运行期 `pip install` 这四类才需要换方案。
