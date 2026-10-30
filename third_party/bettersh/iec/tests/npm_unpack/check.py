#!/usr/bin/env python3
"""check.py — npm.tar.gz 解包结果的独立断言与逐文件比对。

被测对象：
  * 仓库里随包的 rawfile/tools/npm.tar.gz（设备端由 unpackResource() 解到 <sysroot>）；
  * bsdtar（宿主 libarchive 的命令行）解出来的参考树；
  * 可选 --impl：宿主 harness 调用 common/archive_extract.cpp 里 IecExtractTar()
    解出来的实现树，与参考树逐文件比 sha256。

用法：
  python3 check.py --tar npm.tar.gz --ref /tmp/ref
  python3 check.py --tar npm.tar.gz --ref /tmp/ref --impl /tmp/impl
  python3 check.py --tar npm.tar.gz --ref /tmp/ref --impl /tmp/impl --sample 200

退出码：0 = 全部断言通过；1 = 有 FAIL。
"""

import argparse
import hashlib
import json
import os
import random
import sys
import tarfile

# 这三个数是 tar 内容的一部分：npm 10.9.3 的 deps/npm 树。改动随包版本时
# 必须同步改这里，否则测试会拦住"没意识到自己换了 npm"的提交。
EXPECTED_VERSION = "10.9.3"
EXPECTED_MEMBERS = 2697
ENTRY_FILES = ("npm/bin/npm-cli.js", "npm/bin/npx-cli.js")

FAILS = []


def ok(msg):
    print("[PASS] " + msg)


def bad(msg):
    print("[FAIL] " + msg)
    FAILS.append(msg)


def info(msg):
    print("[INFO] " + msg)


def norm(name):
    return name.rstrip("/")


def walk_tree(root):
    """返回 {相对路径: 是否文件}，目录与文件都算条目（不含 root 本身）。"""
    entries = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for d in dirnames:
            rel = os.path.relpath(os.path.join(dirpath, d), root)
            entries[rel.replace(os.sep, "/")] = False
        for f in filenames:
            rel = os.path.relpath(os.path.join(dirpath, f), root)
            entries[rel.replace(os.sep, "/")] = True
    return entries


def total_file_bytes(root, entries):
    total = 0
    for rel, is_file in entries.items():
        if is_file:
            total += os.stat(os.path.join(root, rel)).st_size
    return total


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_version(root):
    path = os.path.join(root, "npm", "package.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f).get("version")
    except (OSError, ValueError):
        return None


def compare_trees(ref, impl, sample_size):
    ref_entries = walk_tree(ref)
    impl_entries = walk_tree(impl)
    # .unpack-complete 是调用方协议的一部分（harness 复刻 ArkTS 写它），不属于
    # tar 内容；比对归档树时把它摘掉，别把它算成"多出来的条目"。
    impl_entries.pop("npm/.unpack-complete", None)

    if set(impl_entries) == set(ref_entries):
        ok("实现树与参考树的条目集合完全一致（%d 个）" % len(ref_entries))
    else:
        missing = sorted(set(ref_entries) - set(impl_entries))[:5]
        extra = sorted(set(impl_entries) - set(ref_entries))[:5]
        bad("条目集合不一致：参考 %d / 实现 %d；缺 %s；多 %s"
            % (len(ref_entries), len(impl_entries), missing, extra))

    ref_bytes = total_file_bytes(ref, ref_entries)
    impl_bytes = total_file_bytes(impl, impl_entries)
    if ref_bytes == impl_bytes:
        ok("实现树总字节数与参考树一致（%d）" % ref_bytes)
    else:
        bad("总字节数不一致：参考 %d / 实现 %d" % (ref_bytes, impl_bytes))

    # 逐文件比对：固定种子抽 200 个，外加两个入口（入口无论是否抽中都必比）。
    files = sorted(p for p, is_file in ref_entries.items() if is_file)
    sample = sorted(set(random.Random(0).sample(files, min(sample_size, len(files))))
                    | set(ENTRY_FILES))
    mismatched = []
    for rel in sample:
        ref_path = os.path.join(ref, rel)
        impl_path = os.path.join(impl, rel)
        if not os.path.isfile(impl_path):
            mismatched.append(rel + "（缺失）")
            continue
        if sha256(ref_path) != sha256(impl_path):
            mismatched.append(rel)
    if mismatched:
        bad("sha256 不一致 %d 个：%s" % (len(mismatched), mismatched[:5]))
    else:
        ok("sha256 抽样一致（%d 个文件，含 npm-cli.js / npx-cli.js）" % len(sample))

    version = read_version(impl)
    if version == EXPECTED_VERSION:
        ok("实现树 npm/package.json version=%s" % version)
    else:
        bad("实现树 npm/package.json version=%r，期望 %s"
            % (version, EXPECTED_VERSION))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tar", required=True, help="npm.tar.gz 路径")
    ap.add_argument("--ref", required=True, help="bsdtar 解出的参考树")
    ap.add_argument("--impl", help="IecExtractTar() 解出的实现树（可选）")
    ap.add_argument("--sample", type=int, default=200, help="逐文件抽样数量")
    args = ap.parse_args()

    if not os.path.isfile(args.tar):
        bad("tar 不存在：%s" % args.tar)
        return 1
    if not os.path.isdir(args.ref):
        bad("参考树不存在：%s" % args.ref)
        return 1

    try:
        with tarfile.open(args.tar, "r:*") as t:
            members = t.getmembers()
    except (OSError, tarfile.TarError) as e:
        bad("tar 打不开：%s" % e)
        return 1

    names = [norm(m.name) for m in members if norm(m.name) not in ("", ".")]
    if len(names) == EXPECTED_MEMBERS:
        ok("归档条目数 %d（期望 %d）" % (len(names), EXPECTED_MEMBERS))
    else:
        bad("归档条目数 %d，期望 %d" % (len(names), EXPECTED_MEMBERS))

    tops = sorted({n.split("/", 1)[0] for n in names})
    if tops == ["npm"]:
        ok("顶层只有一个目录 npm/")
    else:
        bad("顶层条目为 %s，期望只有 npm/" % tops)

    file_members = [m for m in members if m.isfile()]
    expected_bytes = sum(m.size for m in file_members)
    info("归档非压缩总量：%d 字节，%d 个普通文件，%d 个目录"
         % (expected_bytes, len(file_members), len(members) - len(file_members)))

    ref_entries = walk_tree(args.ref)
    if len(ref_entries) == EXPECTED_MEMBERS:
        ok("参考树条目数 %d（目录+文件）" % len(ref_entries))
    else:
        bad("参考树条目数 %d，期望 %d" % (len(ref_entries), EXPECTED_MEMBERS))

    if set(ref_entries) == set(names):
        ok("参考树与归档的条目路径逐条一致")
    else:
        missing = sorted(set(names) - set(ref_entries))[:5]
        extra = sorted(set(ref_entries) - set(names))[:5]
        bad("参考树与归档路径不一致：缺 %s；多 %s" % (missing, extra))

    ref_bytes = total_file_bytes(args.ref, ref_entries)
    if ref_bytes == expected_bytes:
        ok("参考树总字节数 %d == 归档非压缩总量" % ref_bytes)
    else:
        bad("参考树总字节数 %d != 归档非压缩总量 %d"
            % (ref_bytes, expected_bytes))

    version = read_version(args.ref)
    if version == EXPECTED_VERSION:
        ok("参考树 npm/package.json version=%s" % version)
    else:
        bad("参考树 npm/package.json version=%r，期望 %s"
            % (version, EXPECTED_VERSION))

    for rel in ENTRY_FILES:
        path = os.path.join(args.ref, rel)
        if os.path.isfile(path) and os.path.getsize(path) > 0:
            ok("%s 存在且非空（%d 字节）" % (rel, os.path.getsize(path)))
        else:
            bad("%s 不存在或为空" % rel)

    if args.impl:
        if not os.path.isdir(args.impl):
            bad("实现树不存在：%s" % args.impl)
        else:
            impl_entries = walk_tree(args.impl)
            impl_entries.pop("npm/.unpack-complete", None)
            if len(impl_entries) == EXPECTED_MEMBERS:
                ok("实现树条目数 %d" % len(impl_entries))
            else:
                bad("实现树条目数 %d，期望 %d"
                    % (len(impl_entries), EXPECTED_MEMBERS))
            compare_trees(args.ref, args.impl, args.sample)

    if FAILS:
        print("SUMMARY: FAIL=%d" % len(FAILS))
        return 1
    print("SUMMARY: FAIL=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
