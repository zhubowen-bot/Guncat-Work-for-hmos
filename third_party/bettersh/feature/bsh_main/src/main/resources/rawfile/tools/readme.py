# readme.py — BetterSH 的入门说明
#
# 为什么是 .py 而不是 .txt：设备上 python 一定在（内置），而且这份东西本来就是给
# 终端里看的 —— 用颜色和分隔线把章节切开，比一整片纯文本好读。
#
# 颜色有两条约定：
#   * 输出不是终端时（`python readme.py > x`、管道）自动关；
#   * 环境变量 NO_COLOR 存在时强制关（https://no-color.org）。
# 两条都是为了让重定向出去的文本里不混进转义序列。

import os
import sys
import unicodedata

USE_COLOR = sys.stdout.isatty() and "NO_COLOR" not in os.environ


def sgr(*codes):
    """按需产出 ANSI 序列；不开颜色时返回空串，调用处不用写分支。
    codes 允许写 int（sgr(0) 这样的字面量最顺手），所以这里统一转成字符串。"""
    if not USE_COLOR:
        return ""
    return "\x1b[" + ";".join(str(c) for c in codes) + "m"


def dw(text):
    """终端列宽：东亚宽字符占两列。中文键名对不齐就是漏了这一步。"""
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)


RESET = sgr(0)
BOLD = sgr(1)
DIM = sgr(2)
CYAN = sgr(36)
GREEN = sgr(32)
YELLOW = sgr(33)
BLUE = sgr(34)

BANNER = r"""  ____       _   _            ____  _   _
 | __ )  ___| |_| |_ ___ _ __/ ___|| | | |
 |  _ \ / _ \ __| __/ _ \ '__\___ \| |_| |
 | |_) |  __/ |_| ||  __/ |   ___) |  _  |
 |____/ \___|\__|\__\___|_|  |____/|_| |_|"""

WIDTH = 42  # = 横幅宽度，分隔线跟它对齐
KEY_W = 16  # 「快速上手」左列的显示宽度（缩进不计）


def rule():
    print(DIM + "-" * WIDTH + RESET)


def title(text):
    print()
    rule()
    print(BOLD + CYAN + text + RESET)
    rule()


def body(text):
    """正文。缩进交给这里，段落本身按终端宽度手写折行。"""
    for line in text.strip("\n").split("\n"):
        print(("  " + line).rstrip() if line else "")


def keyval(key, val):
    """左列按**显示宽度**补齐（中文占两列），所以这里不能直接用 ljust。"""
    print("  " + BOLD + key + RESET + " " * max(1, KEY_W - dw(key)) + val)


def cmd(text):
    return GREEN + text + RESET


def note(text):
    print("  " + DIM + YELLOW + text + RESET)


print()
print(BOLD + CYAN + BANNER + RESET)
print(DIM + ("  v0.9".center(WIDTH)).rstrip() + RESET)
print()

title("什么是 BetterSH？")
body("""
BetterSH 是一款为 HarmonyOS 开发的第三方终端模拟器，类似 iOS 上的 iSH。
通过解释执行二进制文件，并调用系统接口，在鸿蒙设备上实现终端体验。

对于平板/PC平台，得益于 jit 的加入，可以大幅提升应用执行效率，达到基本可用的程度。

此外，应用内还带了一个 Wayland compositor，图形程序可以在终端里启动并弹
出真正的窗口。解决了鸿蒙系统不支持 GUI 编程的问题。

通过 BetterSH ，相信可以为您的鸿蒙设备提供更加舒适的开发体验！
""")

title("快速上手")
keyval("基础命令", "内置 toybox：ls / cp / mv / tar / ps / 等常见命令")
keyval("完整 shell", "敲 " + cmd("sh") + " 进 mksh（历史、补全、作业控制都在这里）")
keyval("文件编辑", "内置 vim：" + cmd("vim 文件名"))
keyval("跑程序", cmd("./你的程序") + "    ARM64 / x86_64 都行")
keyval("改设置", cmd("bshutil help") + "   查看所有可调项")
keyval("更多说明", cmd("python readme.py") + " / " + cmd("python licenses.py"))
note("提示：应用设置存在 $HOME/bettersh.conf，也可以直接用编辑器改。")

title("内置的开发工具")
body("""
nodejs 与 python3.12 都随应用分发，可以直接写脚本、跑脚本，也能进交互式解
释器。npm 是内置的（跟 node 一起来）；pip 的模块为了省体积没随 HAP 走，
需要用户自行安装。

装完的常用命令：

  npm install -g @moonshot-ai/kimi-code
  npm install -g @deepseek-ai/dsh
  pip install numpy
""")
note("带 C 扩展的 npm / pip 包也能装：headers 与编译链走 pkg，详见 README。")

title("Agent 工具")
body("""
经过实测，以下两个 Agent CLI 可以在 BetterSH 里正常跑起来：

  kimi-code        npm install -g @moonshot-ai/kimi-code
  deepseek-harness npm install -g @deepseek-ai/dsh

装完在 mksh 里直接敲命令名即可（基础 sh 环境不支持，先 `sh` 进 mksh）。
""")

title("bshutil：改 BetterSH 自己的设置")
body("""
bshutil 用来调整应用本身，而不是改系统。常用的几条：

  bshutil conf                    看当前设置
  bshutil keys show|hide          显示 / 隐藏底部虚拟按键栏
  bshutil set win-scale 1.5       改图形窗口的缩放
  bshutil picker                  调系统目录选择器，来编辑外部文件

完整列表见 `bshutil help`。
""")

title("项目信息")
body("""
BetterSH 已开源：

  https://atomgit.com/qq_35859034/BetterSH

项目自身暂未选定 License；但分发物里包含以 GPL / LGPL 开源的组件
（qemu、glibc、glib、libintl 等），因此按惯例整体以 GPL 兼容的方式开源。
后续可能移除这些组件再更换协议。

完整的第三方组件清单与各自的许可：`python licenses.py`
""")

rule()
print()
