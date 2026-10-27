# 原生 Python 能力清单（用户视角）

Guncat Work 内置的是**真正的 CPython 3.12.15**（aarch64 交叉编译，不是模拟器/不是精简版），
`run_python` 里能用的东西和桌面 Python 基本一致。这份文档回答两个问题：**能做什么**、
**边界在哪**。

自检脚本：`bash tooling/python/run-verify-stack.sh`（**22 项**，按真机布局在 qemu 里跑，22/22 通过）。

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

```python
from scipy import linalg, optimize, integrate, sparse, signal, interpolate, stats, special
linalg.solve(A, b); linalg.eigvals(A); linalg.cholesky(S)
sparse.csr_matrix(M).dot(v); sparse.linalg.spsolve(S, b); sparse.linalg.eigs(S, k=2)
optimize.minimize(f, x0); optimize.curve_fit(model, x, y); optimize.least_squares(res, x0)
integrate.quad(f, 0, 1); integrate.odeint(f, y0, t); integrate.solve_ivp(f, (0, 1), y0)
stats.norm.cdf(x); stats.ttest_ind(a, b); stats.linregress(x, y)
signal.butter(2, 0.2); signal.filtfilt(...); signal.find_peaks(y)
interpolate.interp1d(x, y); interpolate.CubicSpline(x, y)
```

**边界**：scipy 已随包（1.14.1 + OpenBLAS/LAPACK），但**没有 SIMD 加速**（未编 xsimd），
大规模矩阵运算比桌面慢一些，算法结果一致。

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

**中文（开箱即用）**：随包带了一份思源黑体 SC（GB2312 子集，3.4MB，OFL-1.1）。
`sitecustomize` 在启动时装了钩子，**只要 import matplotlib，中文字体就自动注册**：

```python
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
plt.title("中文标题")        # 直接可用，不会变方块
```

Pillow 想要同款字体：
```python
import guncat_fonts
font = guncat_fonts.pillow_font(24)      # ImageFont 对象
ImageDraw.Draw(im).text((10, 10), "中文", font=font, fill="black")
```
想换字体：`guncat_fonts.use_cjk("/path/your.ttf")`。

字体来源顺序：随包思源黑体(GB2312 子集) → **系统字库回退**
(`/system/fonts/HarmonyOS_Sans_SC.ttf`、`NotoSansCJK-Regular.ttc`、`ShuS-SC.ttf`、`NotoSerifCJK-Regular.ttc`，
实测都是 0 缺字)。注意 `/system/fonts/HYQiHeiL3.ttf` 是子集化字体(缺 191 字)，已排除。
边界：随包子集只含 GB2312（6763 汉字），生僻字请用系统字体或自带 ttf。

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

## 9.5 多进程与并行（设备实测边界）

设备沙箱里 **`/dev/shm` 不可访问**，所以 `multiprocessing` 的 `Lock / Semaphore / Queue /
Pool / Value / Array` 都会在 `_multiprocessing.SemLock()` 处抛 `PermissionError`；
但 `fork` 本身可用 —— `Process`（裸）、`Pipe`、`Manager`、`Process` + `mmap` 都能工作。

| 可用 | 不可用（/dev/shm 限制） |
|---|---|
| `Process`、`Pipe`、`Manager` | `Lock` / `RLock` / `Semaphore` / `Event` / `Condition` / `Barrier` |
| `Process` + `mmap` | `Queue` / `SimpleQueue` / `Pool` / `Value` / `Array` |

为此随包提供 **`guncat_mp`**（fork + Pipe，不碰信号量）：

```python
import guncat_mp
results = guncat_mp.map(heavy, [a, b, c, d], workers=4)   # 顺序与输入一致
guncat_mp.cpu_count(); guncat_mp.available()
```

- 不用 pickle **函数**，lambda / 闭包都能用（fork 直接继承）；
- **返回值必须可 pickle**（经 `pickle` 从子进程回传）：文件句柄 / socket / lambda 会失败，
  此时报错会明确说"结果不可 pickle"，不会误报成"fork 被限制"；
- 子进程异常带回完整 traceback（最多显示 3 个）。

**什么时候不该用**（真机实测）：单次 fork+管道开销约 **60–90ms**，所以

| 单任务计算量 | 串行 | 4 进程 | 结论 |
| --- | --- | --- | --- |
| 1 万次迭代（18ms） | 18ms | 299ms | 亏 16 倍 |
| 100 万次（665ms） | 665ms | 488ms | 1.36x，刚回本 |
| 300 万次（1.8s） | 1807ms | 917ms | 1.97x |
| 1000 万次（6.2s） | 6195ms | 2159ms | 2.87x |

**单任务 < 100ms 就别并行**（20 万行 CSV 聚合总耗时 146ms，并行反而慢 4 倍，pandas 更快）。
workers 甜点在 **4–6**；12 个反而降到 1.72x（内存带宽竞争）。默认 `min(8, cpu_count)`。

**建议**：先试 numpy/scipy 向量化，其次 `guncat_mp`，最后才是手工 `Process` + `Pipe`。

## 10. 文件监控

```python
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
obs = Observer(); obs.schedule(Handler(), "工作区", recursive=True); obs.start()
```

## 11. 已知边界（重要）

| 限制 | 原因 / 替代 |
| --- | --- |
| 无 GUI 后端 | matplotlib 必须 `Agg`，输出 PNG/SVG/PDF |
| 无 `tkinter` | 无窗口系统 |
| 只有单线程执行器 | 超时保护依赖"跑在固定线程 + AST 注入检查点"；`threading` 可用但不要指望并发提速 |
| `multiprocessing` 只有 fork 上下文 | `Process`/`Pipe`/`Manager` 可用；`Queue`/`Pool`/`Lock` 要 `/dev/shm`（沙箱里没有），`spawn`/`forkserver` 要重新 exec 解释器（嵌入式解释器没有可执行体，会直接报错而不是静默失败）。并行用 `guncat_mp` |
| 无 `pip install` | 包是随应用打包的（离线可用），运行期不能装新包 |
| 文件路径 | 只能读写应用沙箱与用户选择的工作区目录 |
| 超时 | `while`/`for` 到点抛 `TimeoutError`（`for` 每 256 轮采样一次）；阻塞在 C 调用里的只能放弃等待 —— 任务结束前拒绝新调用（不排队），结束后自动恢复，**不会永久停用** |
| 跨调用状态 | 解释器常驻，但 `globals`/`os.environ`/`sys.path`/日志级别/`warnings` 过滤器/`random` 种子/numpy 打印选项每次调用结束都会回滚；跨调用传状态请落文件 |
| 标准库目录只读 | `sys.prefix` 下的文件被审计钩子保护，写入会抛 `PermissionError`（改它会跨调用、跨会话生效） |

## 12. 一句话建议

写代码时按"**桌面 Python 能用什么，这里基本都能用**"来想 —— numpy / pandas / scipy /
matplotlib / Pillow / lxml / 加密 / 文档 / 网络都齐了；只有 GUI、`multiprocessing` 的
`Queue`/`Pool`/`spawn`、运行期 `pip install` 这几类需要换方案。
