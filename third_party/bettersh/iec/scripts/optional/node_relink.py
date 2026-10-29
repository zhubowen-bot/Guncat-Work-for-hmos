#!/usr/bin/env python3
"""node_relink.py -- recover the libnode link command from gyp's ninja files.

The node build does not expose a hook for the extra objects the IEC command
object needs (the entry wrapper, the exec shim, the in-memory dlopen loader),
so the link line has to be reconstructed and replayed. gyp puts the 2000+
object files into a response file that ninja deletes after the command runs.
The response file is generated from a fixed rule:

    rspfile_content = -Wl,--whole-archive $in $solibs -Wl,--no-whole-archive $libs

so the original inputs can be recovered from the build statement.

Output: one shell command on stdout, to be eval'ed from <out/Release>.
"""
import os
import re
import sys


def die(msg):
    sys.stderr.write("node_relink: %s\n" % msg)
    sys.exit(1)


def unroll(lines, i):
    """Join a ninja statement that uses trailing '$' continuation lines."""
    s = lines[i].rstrip("\n")
    while s.rstrip().endswith("$") and i + 1 < len(lines):
        s = s.rstrip()[:-1]
        i += 1
        s += " " + lines[i].strip()
    return s, i + 1


def main():
    if len(sys.argv) < 5:
        die("usage: node_relink.py <out/Release> <lib relative path> "
            "<new output .so> <compiler command>")
    build_dir, lib_rel, out_so, cc = sys.argv[1:5]

    ninja_file = None
    with open(os.path.join(build_dir, "build.ninja")) as fp:
        for line in fp:
            m = re.match(r"subninja (\S+)", line)
            if not m:
                continue
            cand = os.path.join(build_dir, m.group(1))
            try:
                with open(cand) as cfp:
                    if "build %s" % lib_rel in cfp.read():
                        ninja_file = cand
                        break
            except OSError:
                continue
    if not ninja_file:
        die("no ninja file in %s generates %s" % (build_dir, lib_rel))

    with open(ninja_file) as fp:
        lines = fp.readlines()

    libs = ldflags = ""
    for s in lines:
        m = re.match(r"libs\s*=\s*(.*)", s)
        if m and not libs:
            libs = m.group(1).strip()
        m = re.match(r"ldflags\s*=\s*(.*)", s)
        if m and not ldflags:
            ldflags = m.group(1).strip()

    inputs = []
    i = 0
    while i < len(lines):
        if lines[i].startswith("build %s" % lib_rel):
            stmt, _ = unroll(lines, i)
            after = stmt.split(":", 1)[1].strip().split()[1:]
            for tok in after:
                if tok in ("|", "||"):
                    break
                inputs.append(tok)
            break
        i += 1
    if not inputs:
        die("could not parse the inputs of %s from %s"
            % (lib_rel, ninja_file))

    parts = [cc, "-shared"]
    if ldflags:
        parts.append(ldflags)
    parts += ["-o", '"%s"' % out_so, "-Wl,-soname,libnode.so",
              "-Wl,--whole-archive"]
    parts += inputs
    parts.append("-Wl,--no-whole-archive")
    if libs:
        parts.append(libs)
    print(" ".join(parts))
    sys.stderr.write(
        "node_relink: %d link inputs (from %s; libs=[%s])\n"
        % (len(inputs), os.path.basename(ninja_file), libs))


if __name__ == "__main__":
    main()
