#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tools/test-check-iec-libs.py — check-iec-libs.py 的自测。

这些用例不重复跑仓库本体检查，而是把检查器当被测对象：
  * NEEDED 白名单必须拒绝不在表里的 DT_NEEDED（放宽成"任意"要变红）；
  * 源码新鲜度必须看到工作区里未提交的改动（只比较 HEAD 要变红）。

用法：
    python3 tools/test-check-iec-libs.py
"""

import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent
CHECKER = TOOLS_DIR / "check-iec-libs.py"
LIBS_REL = "third_party/bettersh/iec/platform/ohos/har/libs/arm64-v8a"


def load_checker():
    spec = importlib.util.spec_from_file_location("check_iec_libs_under_test", CHECKER)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot import %s" % CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_git(cwd, *args):
    subprocess.run(["git", *args], cwd=str(cwd), check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)


class CheckerSelfTest(unittest.TestCase):
    def setUp(self):
        self.mod = load_checker()
        self.old_root = self.mod.REPO_ROOT
        self.old_libs = self.mod.LIBS_REL
        self.old_freshness = self.mod.FRESHNESS

    def tearDown(self):
        self.mod.REPO_ROOT = self.old_root
        self.mod.LIBS_REL = self.old_libs
        self.mod.FRESHNESS = self.old_freshness

    # ------------------------------------------------------------------
    # NEEDED 白名单
    # ------------------------------------------------------------------
    def _patched_lib(self, tmpdir):
        """拷贝仓库里真实的 libnc.so，把 DT_NEEDED 的 libc.so 改成 libm.so。

        改字符串而不是造 ELF：长度相同，ELF 结构不变，检查器的解析路径仍是真实的。
        """
        source = self.old_root / self.old_libs / "libnc.so"
        self.assertTrue(source.is_file(), "缺少被测样本 %s" % source)
        data = source.read_bytes()
        needle = b"libc.so\x00"
        self.assertIn(needle, data, "libnc.so 里没有预期的 DT_NEEDED libc.so")
        data = data.replace(needle, b"libm.so\x00", 1)

        libdir = Path(tmpdir) / "libs" / "arm64-v8a"
        libdir.mkdir(parents=True)
        (libdir / "libbad.so").write_bytes(data)
        self.mod.REPO_ROOT = Path(tmpdir)
        self.mod.LIBS_REL = "libs/arm64-v8a"
        return "libbad.so"

    def test_needed_whitelist_rejects_unknown_dependency(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            so = self._patched_lib(tmpdir)
            self.assertIn("libm.so", self.mod.elf_needed(
                Path(tmpdir) / "libs" / "arm64-v8a" / so) or [])

            reporter = self.mod.Reporter()
            self.mod.check_needed([so], reporter)

            self.assertTrue(reporter.fails,
                            "未知 NEEDED 必须报 FAIL；白名单被放宽成任意时会静默放过")
            joined = "\n".join(reporter.fails)
            self.assertIn("libm.so", joined)
            self.assertIn("NEEDED", joined)

    def test_needed_whitelist_accepts_known_dependency(self):
        """正对照：未改过的 libnc.so 只依赖 libc.so，必须通过。"""
        with tempfile.TemporaryDirectory() as tmpdir:
            source = self.old_root / self.old_libs / "libnc.so"
            libdir = Path(tmpdir) / "libs" / "arm64-v8a"
            libdir.mkdir(parents=True)
            shutil.copyfile(source, libdir / "libnc.so")
            self.mod.REPO_ROOT = Path(tmpdir)
            self.mod.LIBS_REL = "libs/arm64-v8a"

            reporter = self.mod.Reporter()
            self.mod.check_needed(["libnc.so"], reporter)
            self.assertEqual(reporter.fails, [], "白名单内的依赖不应误报")

    # ------------------------------------------------------------------
    # 源码新鲜度
    # ------------------------------------------------------------------
    def _freshness_repo(self, tmpdir):
        root = Path(tmpdir)
        (root / "libs" / "arm64-v8a").mkdir(parents=True)
        (root / "src").mkdir()
        (root / "libs" / "arm64-v8a" / "libfake.so").write_bytes(b"fake product\n")
        (root / "src" / "fake.c").write_text("int value = 1;\n", encoding="utf-8")
        run_git(root, "init", "-q")
        run_git(root, "config", "user.email", "selftest@example.invalid")
        run_git(root, "config", "user.name", "self test")
        run_git(root, "add", ".")
        run_git(root, "commit", "-q", "-m", "fixture")
        self.mod.REPO_ROOT = root
        self.mod.LIBS_REL = "libs/arm64-v8a"
        self.mod.FRESHNESS = ({
            "product": "libfake.so",
            "sources": ("src/fake.c",),
            "hint": "rebuild fixture",
            "warn_only": False,
        },)
        return root

    def test_freshness_fails_on_uncommitted_source_change(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = self._freshness_repo(tmpdir)
            # 正对照：干净工作区不应报错。
            clean = self.mod.Reporter()
            self.mod.check_freshness(clean)
            self.assertEqual(clean.fails, [], "干净工作区被误报为不新鲜")

            # 只改工作区、不提交：产物相对源码已经落后，必须报 FAIL。
            (root / "src" / "fake.c").write_text(
                "int value = 2;\n", encoding="utf-8")
            dirty = self.mod.Reporter()
            self.mod.check_freshness(dirty)
            self.assertTrue(dirty.fails,
                            "未提交的源码改动必须报 FAIL；只比 HEAD 时会漏掉")
            self.assertIn("libfake.so", "\n".join(dirty.fails))

    def test_freshness_ignores_only_mode_changes(self):
        """文件模式变化不算内容变化（检查器承诺不误报 chmod）。"""
        with tempfile.TemporaryDirectory() as tmpdir:
            root = self._freshness_repo(tmpdir)
            target = root / "src" / "fake.c"
            target.chmod(0o755)
            reporter = self.mod.Reporter()
            self.mod.check_freshness(reporter)
            self.assertEqual(reporter.fails, [], "仅 chmod 不应报源码不新鲜")


if __name__ == "__main__":
    unittest.main(verbosity=2)
