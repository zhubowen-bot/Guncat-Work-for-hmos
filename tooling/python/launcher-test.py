#!/usr/bin/env python3
"""在桌面上跑 run_python 的启动器模板(从 guncat_py.cpp 里抽出来), 做回归验证。

为什么需要它: 启动器是 C++ 裸字符串里的 Python 源码, 真机才能跑、改一行就可能
静默坏掉(上一版就因为顶层 import json 让整个工具只剩"没有产出结果")。这个脚本
把模板原样抽出来, 在桌面 CPython 里模拟 PyRun_SimpleString 的语义(**同一个
__main__ globals 反复 exec**, 解释器不重启), 于是一次调用能覆盖:

  * stdout/stderr 捕获(含 fd 级 os.write / sys.stdout.buffer / fileno)
  * 跨调用的状态泄漏(os.environ / sys.path / warnings / logging / random)
  * 超时注入(while / range)与 TimeoutError 语义
  * meta/diag 的落盘与"启动器没写出结果"之外的所有失败路径

用法:
    python tooling/python/launcher-test.py            # 跑全部场景
    python tooling/python/launcher-test.py -v         # 打印每次调用的原始产物

退出码 0 = 全过。
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CPP = ROOT / "entry" / "src" / "main" / "cpp" / "python" / "guncat_py.cpp"


def load_launcher() -> str:
    text = CPP.read_text(encoding="utf-8")
    m = re.search(r'const char\* kLauncher = R"PYSRC\((.*?)\)PYSRC";', text, re.S)
    if not m:
        raise SystemExit("找不到 kLauncher 模板(源码结构变了?)")
    return m.group(1)


class Runtime:
    """模拟宿主 native 侧的 PyRun_SimpleString: 一个常驻的 __main__ globals。"""

    def __init__(self, template: str, scratch: Path):
        self.template = template
        self.scratch = scratch
        self.main = {"__name__": "__main__", "__builtins__": __builtins__}

    def run(self, code: str, timeout_ms: int = 30000, stdin: str | None = None) -> dict:
        s = self.scratch
        s.mkdir(parents=True, exist_ok=True)
        code_path = s / "code.py"
        out_path = s / "stdout.txt"
        err_path = s / "stderr.txt"
        meta_path = s / "meta.txt"
        diag_path = s / "diag.txt"
        argv_path = s / "argv.txt"
        stdin_path = s / "stdin.txt"
        for p in (out_path, err_path, meta_path, diag_path):
            if p.exists():
                p.unlink()
        code_path.write_text(code, encoding="utf-8")
        argv_path.write_text("-c", encoding="utf-8")
        if stdin is not None:
            stdin_path.write_text(stdin, encoding="utf-8")

        script = (self.template
                  .replace("__GUNCAT_CODE__", str(code_path).replace("\\", "/"))
                  .replace("__GUNCAT_OUT__", str(out_path).replace("\\", "/"))
                  .replace("__GUNCAT_ERR__", str(err_path).replace("\\", "/"))
                  .replace("__GUNCAT_META__", str(meta_path).replace("\\", "/"))
                  .replace("__GUNCAT_DIAG__", str(diag_path).replace("\\", "/"))
                  .replace("__GUNCAT_ARGV__", str(argv_path).replace("\\", "/"))
                  .replace("__GUNCAT_STDIN__", str(stdin_path if stdin is not None else "").replace("\\", "/"))
                  .replace("__GUNCAT_DEADLINE__", "%.3f" % (timeout_ms / 1000.0)))

        t0 = time.monotonic()
        try:
            exec(compile(script, "<launcher>", "exec"), self.main)
        finally:
            dur = (time.monotonic() - t0) * 1000.0

        meta = meta_path.read_text(encoding="utf-8") if meta_path.exists() else ""
        parts = meta.split("\n")
        ok = parts[0].strip() == "1" if parts else False
        exit_code = 0
        error = ""
        if len(parts) >= 2:
            try:
                exit_code = int(parts[1])
            except ValueError:
                exit_code = 0
        if len(parts) >= 3:
            error = "\n".join(parts[2:])
        stage = ""
        m = re.search(r"\nstage=(\S+)", "\n" + error)
        if m:
            stage = m.group(1)
        diag = diag_path.read_text(encoding="utf-8") if diag_path.exists() else ""
        # 与 native 侧(run_python 的 C++ 分支)保持同一套拼装规则
        if not ok and diag.strip() and "import " not in error:
            error += "\n—— 运行库诊断 ——\n" + diag.strip()
        return {
            "ok": ok,
            "exit_code": exit_code,
            "stdout": out_path.read_text(encoding="utf-8", errors="replace"),
            "stderr": err_path.read_text(encoding="utf-8", errors="replace"),
            "error": error,
            "stage": stage,
            "diag": diag,
            "duration_ms": dur,
            "timed_out": (not ok) and ("run_python 超时" in error),
        }


PASS = 0
FAIL = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   {name}")
    else:
        FAIL += 1
        print(f"  FAIL {name}" + (f"  << {detail}" if detail else ""))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    template = load_launcher()
    scratch_root = Path(tempfile.mkdtemp(prefix="guncat-launcher-"))
    work = scratch_root / "work"
    work.mkdir()
    os.chdir(work)
    rt = Runtime(template, scratch_root / "scratch")

    def run(code, **kw):
        r = rt.run(code, **kw)
        if args.verbose:
            print(f"--- code ---\n{code}\n--- result ---\n{r}")
        return r

    print("[捕获: stdout / stderr / fd 级输出]")
    r = run('import sys, os\n'
            'print("hello")\n'
            'sys.stderr.write("warn\\n")\n'
            'os.write(1, b"raw-fd-1\\n")\n'
            'os.write(2, b"raw-fd-2\\n")\n')
    check("print 进 stdout", "hello" in r["stdout"], r["stdout"])
    check("stderr 进 stderr", "warn" in r["stderr"], r["stderr"])
    check("os.write(1) 被捕获", "raw-fd-1" in r["stdout"], r["stdout"])
    check("os.write(2) 被捕获", "raw-fd-2" in r["stderr"], r["stderr"])

    r = run('import sys\n'
            'print(type(sys.stdout).__name__)\n'
            'print(hasattr(sys.stdout, "buffer"))\n'
            'try:\n'
            '    sys.stdout.fileno()\n'
            '    print("fileno-ok")\n'
            'except Exception as e:\n'
            '    print("fileno-fail:" + type(e).__name__)\n'
            'try:\n'
            '    sys.stdout.buffer.write(b"buffer-write\\n")\n'
            '    sys.stdout.flush()\n'
            '    print("buffer-ok")\n'
            'except Exception as e:\n'
            '    print("buffer-fail:" + type(e).__name__)\n')
    check("sys.stdout 有 buffer", "True" in r["stdout"] and "buffer-fail" not in r["stdout"], r["stdout"])
    check("sys.stdout.fileno() 可用", "fileno-fail" not in r["stdout"], r["stdout"])
    check("buffer.write 的字节被捕获", "buffer-write" in r["stdout"], r["stdout"])

    print("[跨调用状态隔离]")
    base = run('import warnings\nprint("filters=%d" % len(warnings.filters))\n')
    base_count = int(base["stdout"].strip().split("=")[-1])
    run('import os, sys, random, warnings, logging\n'
        'os.environ["GUNCAT_LEAK"] = "1"\n'
        'sys.path.append("/FAKE/LEAK/PATH")\n'
        'random.seed(12345)\n'
        'logging.getLogger().setLevel(logging.CRITICAL)\n'
        'warnings.simplefilter("ignore")\n')
    r = run('import os, sys, random, logging, warnings\n'
            'print("env=" + os.environ.get("GUNCAT_LEAK", "<none>"))\n'
            'print("path=" + ("/FAKE/LEAK/PATH" in sys.path and "leaked" or "clean"))\n'
            'print("level=" + str(logging.getLogger().level))\n'
            'print("filters=%d" % len(warnings.filters))\n'
            'print("rand=" + ("%.17f" % random.random()))\n')
    check("os.environ 不跨调用", "env=<none>" in r["stdout"], r["stdout"])
    check("sys.path 不跨调用", "path=clean" in r["stdout"], r["stdout"])
    check("logging 级别不跨调用", "level=30" in r["stdout"], r["stdout"])
    got = int(r["stdout"].split("filters=")[-1].split()[0])
    check("warnings.filters 不跨调用", got == base_count, f"{got} vs base {base_count}")
    check("random 不继承上一轮的 seed",
          "0.41661987254534116" not in r["stdout"], r["stdout"])
    r2 = run('import random\nprint("%.17f" % random.random())\n')
    check("random 每次调用都重新播种", r["stdout"].split("rand=")[-1].strip() !=
          r2["stdout"].strip(), r["stdout"] + " | " + r2["stdout"])

    r = run('print(__import__("sys").path[:3])\nprint(sorted(__import__("os").environ)[:2])\n')
    check("恢复后仍可正常执行", r["ok"] and r["stdout"], r["error"])

    print("[超时: while]")
    t0 = time.monotonic()
    r = run('while True:\n    pass\n', timeout_ms=1000)
    dt = time.monotonic() - t0
    check("while True 被中断", r["timed_out"], r["error"][:200])
    check("while True 误差 < 0.6s", dt < 1.6, f"{dt:.2f}s")

    print("[超时: for range]")
    t0 = time.monotonic()
    r = run('import time\n'
            'for i in range(10 ** 9):\n'
            '    time.sleep(0.001)\n', timeout_ms=1000)
    dt = time.monotonic() - t0
    check("for range 最终被中断", r["timed_out"], r["error"][:200])
    check("for range 中断延迟 < 3s(每 256 轮采样)", dt < 3.0, f"{dt:.2f}s")

    print("[解释器安装树只读]")
    r = run('import sys, os\n'
            'def probe(label, fn):\n'
            '    try:\n'
            '        fn()\n'
            '        print(label + "=allowed")\n'
            '    except PermissionError as e:\n'
            '        print(label + ("=guarded" if "解释器安装目录" in str(e) else "=os-denied"))\n'
            'probe("write", lambda: open(os.path.join(sys.prefix, "_probe.txt"), "w").write("x"))\n'
            'probe("mkdir", lambda: os.makedirs(os.path.join(sys.prefix, "evilpkg"), exist_ok=True))\n'
            'probe("chmod", lambda: os.chmod(sys.prefix, 0o777))\n'
            'probe("remove", lambda: os.remove(os.path.join(sys.prefix, "nothing-here")))\n'
            'print("read=" + ("ok" if os.listdir(sys.prefix) is not None else "bad"))\n'
            'open("relative.txt", "w").write("workspace-ok")\n'
            'print("workspace=" + open("relative.txt").read())\n')
    check("写解释器目录被拒", "write=guarded" in r["stdout"], r["stdout"])
    check("在解释器目录建包被拒", "mkdir=guarded" in r["stdout"], r["stdout"])
    check("chmod 解释器目录被拒", "chmod=guarded" in r["stdout"], r["stdout"])
    check("删解释器目录文件被拒", "remove=guarded" in r["stdout"], r["stdout"])
    check("解释器目录仍可读", "read=ok" in r["stdout"], r["stdout"])
    check("工作区写入不受影响", "workspace=workspace-ok" in r["stdout"], r["stdout"])

    print("[multiprocessing: spawn 不再静默失败]")
    r = run('import multiprocessing\n'
            'import multiprocessing.spawn as s\n'
            'try:\n'
            '    s.get_executable()\n'
            '    print("patched=no")\n'
            'except RuntimeError as e:\n'
            '    print("patched=yes" if "spawn" in str(e) else "patched=other")\n')
    check("spawn 的可执行体探测抛明确异常", "patched=yes" in r["stdout"], r["stdout"])

    print("[numpy 选项不跨调用]")
    r = run('import numpy\n'
            'numpy.set_printoptions(precision=2)\n'
            'numpy.seterr(all="ignore")\n'
            'print("set")\n')
    r = run('import numpy\n'
            'print("precision=%d" % numpy.get_printoptions()["precision"])\n'
            'print("divide=%s" % numpy.geterr()["divide"])\n'
            'print("array=" + str(numpy.array([1.23456789])))\n'
            'numpy.set_printoptions(precision=2)\n'
            'numpy.seterr(all="ignore")\n')
    r2 = run('import numpy\n'
             'print("precision=%d" % numpy.get_printoptions()["precision"])\n'
             'print("divide=%s" % numpy.geterr()["divide"])\n')
    check("numpy 打印精度不跨调用", "precision=8" in r2["stdout"], r2["stdout"])
    check("numpy 错误处理不跨调用", "divide=warn" in r2["stdout"], r2["stdout"])

    print("[output capture fallback (dup2 unavailable)]")
    fb = template.replace("st['fd1'] = os.dup(1)", "raise OSError('forced fallback')")
    rt2 = Runtime(fb, scratch_root / "fallback")
    r = rt2.run('print("fallback-stdout")\nimport sys\nsys.stderr.write("fb-err")\n')
    check("fallback still captures print", "fallback-stdout" in r["stdout"], r["stdout"])
    check("fallback still captures stderr", "fb-err" in r["stderr"], r["stderr"])
    check("fallback still succeeds", r["ok"], r["error"])

    print("[异常与诊断]")
    r = run('import numpy_missing_thing\n')
    check("缺库给出 traceback", (not r["ok"]) and "ModuleNotFoundError" in r["error"], r["error"][:200])
    check("缺库附带提示", "提示" in r["error"], r["error"][:400])
    check("失败时带诊断", "version=" in r["error"] and "path=" in r["error"], r["error"][:200])

    r = run('open("/tmp/guncat-no-such-dir/x.txt", "w")\n')
    check("/tmp 不存在时给 tempfile 提示", "tempfile.gettempdir()" in r["error"], r["error"][:400])

    r = run('import os, sys\nopen(os.path.join(sys.prefix, "_x.txt"), "w")\n')
    check("只读目录的报错带解释", "解释器安装目录" in r["error"] and
          "只读" in r["error"], r["error"][:400])

    r = run('raise SystemExit(3)\n')
    check("SystemExit(3) 记退出码", (not r["ok"]) and r["exit_code"] == 3, str(r))

    r = run('import sys\nsys.exit(0)\n')
    check("SystemExit(0) 算成功", r["ok"], r["error"])

    print("[超时后通道仍可用]")
    r = run('print("still alive")\n')
    check("超时后下一次调用正常", r["ok"] and "still alive" in r["stdout"], r["error"])

    print(f"\n{PASS} passed, {FAIL} failed")
    os.chdir(ROOT)
    if not args.keep:
        shutil.rmtree(scratch_root, ignore_errors=True)
    else:
        print("scratch:", scratch_root)
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
