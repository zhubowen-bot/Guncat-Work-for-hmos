#!/usr/bin/env python3
"""Remove duplicate output rules that gyp produces in a cross build.

With --cross-compiling, node sets want_separate_host_toolset=1. Targets in
v8.gyp with toolsets ['host','target'] (run_torque, run_gen-regexp-special-case,
bytecode_builtins_list_generator, inspector protocol generation, ...) are then
declared twice, and both declarations name the same outputs (for example
gen/torque-generated/bit-fields.h). Ninja refuses to load the graph:

    multiple rules generate gen/torque-generated/bit-fields.h

This script scans every .ninja file, finds outputs claimed by more than one
build statement, and deletes the later statements. A path containing ".host"
wins, because those tools must run on the host.
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."


def iter_ninja_files(root):
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if f.endswith(".ninja"):
                yield os.path.join(dirpath, f)


def load(path):
    with open(path) as fp:
        return fp.readlines()


def logical_statements(lines):
    """Merge physical lines into (start_idx, end_idx, text) statements."""
    stmts = []
    i = 0
    n = len(lines)
    while i < n:
        start = i
        buf = lines[i].rstrip("\n")
        while buf.endswith("$"):
            buf = buf[:-1]
            i += 1
            if i >= n:
                break
            buf += " " + lines[i].rstrip("\n")
        stmts.append((start, i, buf))
        i += 1
    return stmts


def outputs_of(text):
    m = re.match(r"\s*build\s+(.*?):\s*(\S+)\s", text + " ")
    if not m:
        return None
    return m.group(1).split()


def main():
    owners = {}
    files = sorted(iter_ninja_files(ROOT))
    for path in files:
        lines = load(path)
        for start, end, text in logical_statements(lines):
            outs = outputs_of(text)
            if not outs:
                continue
            for o in outs:
                owners.setdefault(o, []).append((path, start, end))

    dup = {o: v for o, v in owners.items() if len(v) > 1}
    if not dup:
        print("ninja_dedup: no duplicate output rules")
        return 0

    drop = {}
    for _o, owner_list in dup.items():
        def rank(item):
            path = item[0]
            return (0 if ".host" in path else 1, path)

        keep = min(owner_list, key=rank)
        for item in owner_list:
            if item is keep:
                continue
            path, start, _end = item
            drop.setdefault(path, set()).add(start)

    total = 0
    for path, starts in drop.items():
        lines = load(path)
        stmts = logical_statements(lines)
        stmt_map = {s: e for s, e, _t in stmts}
        out = []
        i = 0
        while i < len(lines):
            if i in starts:
                e = stmt_map[i]
                nxt = e + 1
                while nxt < len(lines) and lines[nxt].strip() == "":
                    nxt += 1
                print("  drop %s:%d-%d" % (path, i + 1, e + 1))
                total += 1
                i = nxt
                continue
            out.append(lines[i])
            i += 1
        with open(path, "w") as fp:
            fp.writelines(out)

    print("ninja_dedup: dropped %d duplicate build statements" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
