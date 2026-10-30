#!/usr/bin/env python3
# check.py — 用宿主 x86_64 toybox 的真实输出，交叉验证 ArkTS 侧的 applet 解析与
# launcher 优先级。
#
# 被测逻辑现在抽到了 entry/src/main/ets/service/IecParsing.ts（纯 TS，无
# HarmonyOS import），IecRuntime.ets / IecShellService.ets 调用的就是它：
#   * parseAppletList()：把 `[`/`]` 换成空格、按空白分词，只留长度 1..31 且匹配
#     ^[a-z0-9_]+$ 的 token，去掉 `toybox`，去重保序；
#   * filterExplicit()：跳过 '' 与 'toybox'，再跳过 explicitNames 里的命令，
#     其余每个 applet 都写一个指向 libtoybox.so 的 launcher；
#   * writeLaunchers()：add(...) 与 writeSoLauncher(...) 注册显式命令（nc /
#     hexdump / diff / jq / sh / mksh …），它们优先于同名 toybox applet。
#
# 本脚本优先用 Node（>= 22.6 的 strip-types）**直接加载 IecParsing.ts 真实现**；
# 找不到 node / 版本过旧时退回下面 Python 复刻，只作为环境降级，不再作为判据来源。
#
# 这里不重新实现 toybox，也不抄静态 applet 清单：拿宿主编出来的同一份源码的
# 真实输出当输入，再断言：
#   1. 真实现解析结果 == `toybox --long` 的 applet 名集合（--long 不可用时退回
#      无参输出）；
#   2. 显式注册名与 toybox 的交集全部被跳过，绝不写回 libtoybox.so；
#   3. 最终 launcher 集合 == explicit ∪ (applets - explicit)；
#   4. dd/md5sum/od/nproc 由 toybox 提供；nc/hexdump/diff/jq/sh/mksh 最终存在，
#      且 nc 确实压住了 toybox 的 nc。
#
# 用法：
#   python3 third_party/bettersh/iec/tests/toybox_parse/check.py
#   python3 .../check.py --toybox /tmp/toybox-host
#
# 环境变量 TOYBOX_HOST 可覆盖 toybox 路径（默认 /tmp/toybox-host）；
# IEC_PARSE_NODE 可指定 node 可执行文件（默认从 PATH 找）。
#
# 退出码：0 = 全部通过；1 = 断言失败；2 = 环境/输入错误；77 = 还没有 toybox 二进制
# （正常流程由同目录 run.sh 先编好；直接跑 check.py 时按 SKIP 处理）。
#
# 纯 Python 标准库；不连设备、不需要 HarmonyOS SDK、不访问网络。
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
ETS = REPO / "entry" / "src" / "main" / "ets" / "service" / "IecRuntime.ets"
IEC_PARSING = REPO / "entry" / "src" / "main" / "ets" / "service" / "IecParsing.ts"
TOYBOX_SRC = REPO / "third_party" / "bettersh" / "iec" / "thirdparty" / "toybox"
DEFAULT_TOYBOX = "/tmp/toybox-host"
NODE_MIN = (22, 6)  # Node 原生 TypeScript strip 的最低版本

# 仅作 node 不可用时的降级复刻：与 IecParsing.ts 的规则保持一致。
# 注意 nbd-client / nbd-server 会被这条规则丢掉，这不是解析器 bug ——
# IecParsing.parseAppletList 同样注册不了带连字符的 applet。
APPLET_RE = re.compile(r"^[a-z0-9_]+$")
TOKEN_MAX = 32  # IecParsing: part.length < 32

# writeToyboxApplets() / filterExplicit() 里无条件跳过的名字。
SKIP_NAMES = {"", "toybox"}


class Failure(Exception):
    pass


def die(msg, code=2):
    print("toybox_parse: " + msg, file=sys.stderr)
    return code


def run(argv, timeout=30, stdin=None):
    return subprocess.run(
        argv,
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )


def decode(data):
    return data.decode("utf-8", "replace")


def parse_applets(text, strip_paths=False):
    """复刻 IecRuntime.listToyboxApplets() 的分词/过滤规则。

    strip_paths 只用于 --long 输出：它给每个 applet 加了 bin/、usr/bin/ 等前缀，
    先取最后一段再套同样的正则；无参输出的 token 本身就是名字，不剥路径。
    """
    cleaned = text.replace("[", " ").replace("]", " ")
    names = []
    for part in cleaned.split():
        if strip_paths:
            part = part.rsplit("/", 1)[-1]
        if 0 < len(part) < TOKEN_MAX and APPLET_RE.match(part):
            names.append(part)
    return names


def node_binary():
    """返回 (node 路径, 版本) 或 (None, 不可用原因)。"""
    exe = os.environ.get("IEC_PARSE_NODE") or shutil.which("node")
    if not exe:
        return None, "找不到 node"
    try:
        result = run([exe, "-p", "process.versions.node"])
    except OSError as exc:
        return None, "node 无法执行: {}".format(exc)
    if result.returncode != 0:
        return None, "node 不可用: {}".format(decode(result.stderr).strip()[:200])
    version = decode(result.stdout).strip()
    try:
        major, minor = (int(x) for x in version.split(".")[:2])
    except ValueError:
        return None, "无法解析 node 版本 {}".format(version)
    if (major, minor) < NODE_MIN:
        return None, "node {} 过旧（需要 >= 22.6 的原生 TypeScript strip）".format(version)
    return exe, version


def parse_with_real_module(raw, explicit):
    """用 Node 直接加载 IecParsing.ts，返回 ((parsed, written), 说明) 或 (None, 原因)。

    IecRuntime / IecShellService 调用的就是这份模块，避免 Python 复刻随规则漂移。
    """
    node, detail = node_binary()
    if node is None:
        return None, detail
    if not IEC_PARSING.is_file():
        return None, "找不到 {}".format(IEC_PARSING)
    script = (
        "import { parseAppletList, filterExplicit } from " +
        json.dumps(IEC_PARSING.as_uri()) + ";\n"
        "const chunks = [];\n"
        "for await (const c of process.stdin) chunks.push(c);\n"
        "const req = JSON.parse(Buffer.concat(chunks).toString('utf8'));\n"
        "const parsed = parseAppletList(req.raw);\n"
        "const written = filterExplicit(parsed, new Set(req.explicit));\n"
        "process.stdout.write(JSON.stringify({ parsed, written }));\n"
    )
    payload = json.dumps({"raw": raw, "explicit": sorted(explicit)}).encode("utf-8")
    try:
        result = run([node, "--experimental-strip-types", "--input-type=module", "-e", script],
                     stdin=payload)
    except OSError as exc:
        return None, "node 无法执行: {}".format(exc)
    if result.returncode != 0:
        return None, "node 加载真实现失败: {}".format(
            decode(result.stderr).strip()[:400])
    try:
        data = json.loads(decode(result.stdout))
        return ([str(n) for n in data["parsed"]],
                [str(n) for n in data["written"]]), detail
    except (ValueError, KeyError, TypeError) as exc:
        return None, "真实现输出无法解析: {}".format(exc)


def dropped_tokens(text):
    """列出被方括号替换 / 正则过滤掉的原始 token，便于解释数量差。"""
    dropped = []
    for token in text.split():
        cleaned = token.replace("[", " ").replace("]", " ").strip()
        if cleaned == "":
            dropped.append((token, "方括号替换后为空"))
        elif not (0 < len(cleaned) < TOKEN_MAX and APPLET_RE.match(cleaned)):
            dropped.append((token, "不匹配 ^[a-z0-9_]+$ 或长度越界"))
    return dropped


def find_method_body(text, signature):
    """截出 ArkTS 方法体（从签名后的 { 到配对的 }），避免误扫文件其它部分。"""
    start = text.find(signature)
    if start < 0:
        raise Failure("在 IecRuntime.ets 里找不到 " + signature)
    brace = text.find("{", start)
    if brace < 0:
        raise Failure(signature + " 后面没有方法体")
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:i]
    raise Failure(signature + " 的方法体括号不配对")


def parse_explicit_names(text):
    """从 writeLaunchers() 里提取显式注册名及其 so。

    覆盖三种写法：
      * add('name', 'libX.so', ...)；
      * for (const name of ['a', 'b']) { add(name, 'libX.so', ...) }；
      * writeSoLauncher(BIN_DIR + 'name', BUNDLE_LIBS + 'libX.so', ...)
        （toybox / sh / mksh 走这条）；
      * IecRuntime.explicitNames.add('name')（与上面重复，兜底）。
    返回保持源码顺序的 {name: so 或 '?'}。
    """
    body = find_method_body(text, "private static writeLaunchers(): string")
    found = {}

    def remember(name, so="?"):
        if not name:
            raise Failure("解析到空的显式命令名")
        if not re.match(r"^[A-Za-z0-9_.+-]+$", name):
            raise Failure("显式命令名含意外字符: " + repr(name))
        found.setdefault(name, so)

    # 1) 字面量 add('name', 'lib.so', ...)
    for name, so in re.findall(
            r"\badd\(\s*'([^']+)'\s*,\s*'([^']+)'", body):
        remember(name, so)

    # 2) for (const name of [...]) { add(name, 'lib.so', ...) }
    loop_re = re.compile(r"for \(const name of \[([^\]]*)\]\)\s*\{")
    for match in loop_re.finditer(body):
        names = re.findall(r"'([^']+)'", match.group(1))
        block = find_loop_body(body, match.end())
        if not re.search(r"\badd\(name\b", block):
            continue
        so_match = re.search(r"\badd\(name\s*,\s*'([^']+)'", block)
        so = so_match.group(1) if so_match else "?"
        for name in names:
            remember(name, so)

    # 3) writeSoLauncher(BIN_DIR + 'name', BUNDLE_LIBS + 'lib.so', ...)
    for name, so in re.findall(
            r"writeSoLauncher\(\s*BIN_DIR\s*\+\s*'([^']+)'\s*,\s*"
            r"BUNDLE_LIBS\s*\+\s*'([^']+)'", body):
        remember(name, so)

    # 4) explicitNames.add('name')（对 3 做兜底，正常不新增）
    for name in re.findall(r"explicitNames\.add\(\s*'([^']+)'", body):
        remember(name)
    return found


def find_loop_body(body, after_brace):
    """从 for (...) { 的 { 之后找配对的 }，只用于提取 add(name, ...) 的 so。"""
    depth = 1
    for i in range(after_brace, len(body)):
        if body[i] == "{":
            depth += 1
        elif body[i] == "}":
            depth -= 1
            if depth == 0:
                return body[after_brace:i]
    raise Failure("for (const name of [...]) 循环体括号不配对")


def read_source_version():
    try:
        text = (TOYBOX_SRC / "toys.h").read_text(encoding="utf-8")
    except OSError:
        return "?"
    match = re.search(r'#define TOYBOX_VERSION "([^"]+)"', text)
    return match.group(1) if match else "?"


def report_version(toybox):
    result = run([str(toybox), "--version"])
    version = decode(result.stdout).strip() or decode(result.stderr).strip()
    print("toybox 二进制: {}（{}）".format(toybox, version or "版本未知"))
    source = read_source_version()
    print("源码 toys.h 版本: {}；设备构建脚本 build_toybox.sh 用 "
          "-DTOYBOX_VERSION=\"0.8.14\" 覆盖 main.c，故设备上 --version 报 0.8.14。"
          .format(source))


def main():
    parser = argparse.ArgumentParser(
        description="用真实 toybox 输出交叉验证 IecRuntime 的 applet 解析")
    parser.add_argument(
        "--toybox", default=os.environ.get("TOYBOX_HOST", DEFAULT_TOYBOX),
        help="宿主 x86_64 toybox 路径（默认 %(default)s）")
    parser.add_argument(
        "--ets", default=str(ETS), help="IecRuntime.ets 路径（默认自动定位）")
    args = parser.parse_args()

    toybox = Path(args.toybox)
    if not toybox.is_file():
        return die("找不到 {}；请先跑同目录 run.sh，或 "
                   "`make defconfig && make` 后把 toybox 放到该路径".format(toybox), 77)
    if not os.access(toybox, os.X_OK):
        return die("{} 不可执行".format(toybox), 2)
    ets = Path(args.ets)
    if not ets.is_file():
        return die("找不到 {}".format(ets), 2)

    report_version(toybox)

    plain = run([str(toybox)])
    if plain.returncode != 0:
        return die("{} 无参运行失败（rc={}）：{}".format(
            toybox, plain.returncode, decode(plain.stderr).strip()), 2)
    plain_text = decode(plain.stdout)

    # 显式注册名：解析 writeLaunchers() 的 add(...) / writeSoLauncher(...)。
    ets_text = ets.read_text(encoding="utf-8")
    try:
        explicit_so = parse_explicit_names(ets_text)
    except Failure as exc:
        return die(str(exc), 1)
    explicit = set(explicit_so)

    # 先用真实现（IecParsing.ts）解析与过滤；node 不可用才退回 Python 复刻。
    real, real_detail = parse_with_real_module(plain_text, explicit)
    if real is not None:
        parsed, toybox_written = real
        impl_label = "IecParsing.ts 真实现（Node {}）".format(real_detail)
    else:
        parsed = parse_applets(plain_text)
        toybox_written = None
        impl_label = "Python 复刻（降级）"

    print()
    print("== 解析器 ==")
    print("解析/过滤实现: {}".format(impl_label))
    if real is None:
        print("  注意: {}".format(real_detail))
    print("无参输出原始 token 数: {}".format(len(plain_text.split())))
    dropped = dropped_tokens(plain_text)
    for token, reason in dropped:
        print("  丢弃 {!r}: {}".format(token, reason))
    print("解析出 {} 个 applet".format(len(parsed)))
    if len(parsed) < 100:
        return die("只解析出 {} 个 applet，输出疑似为空/被截断".format(len(parsed)), 1)
    if len(parsed) != len(set(parsed)):
        dup = sorted({n for n in parsed if parsed.count(n) > 1})
        return die("解析结果有重复 applet: {}".format(", ".join(dup)), 1)

    # 真值：toybox --long（0.8.15 支持；不支持时退回无参输出）。
    long_result = run([str(toybox), "--long"])
    if long_result.returncode == 0 and decode(long_result.stdout).strip():
        oracle = parse_applets(decode(long_result.stdout), strip_paths=True)
        oracle_name = "toybox --long（剥掉 bin/usr/bin 前缀）"
    else:
        oracle = parse_applets(plain_text)
        oracle_name = "toybox 无参输出（--long 不可用）"
        print("注意: `toybox --long` 不可用（rc={}），退回无参输出".format(
            long_result.returncode))

    failures = []

    def check(cond, message):
        if cond:
            print("  PASS  " + message)
        else:
            print("  FAIL  " + message)
            failures.append(message)

    print()
    print("== 断言 1：解析结果 == {} ==".format(oracle_name))
    oracle_set = set(oracle)
    parsed_set = set(parsed)
    check(parsed_set == oracle_set,
          "applet 集合一致（{} 个）".format(len(parsed_set)))
    if parsed_set != oracle_set:
        missing = sorted(oracle_set - parsed_set)
        extra = sorted(parsed_set - oracle_set)
        check(False, "缺少: {}".format(", ".join(missing) or "无"))
        check(False, "多出: {}".format(", ".join(extra) or "无"))
    # --long 只是加了路径前缀，和直接解析无参输出必须一致；--long 不可用时跳过。
    if long_result.returncode == 0 and decode(long_result.stdout).strip():
        check(set(parse_applets(plain_text)) == oracle_set,
              "无参输出与 --long 的 applet 集合一致")

    # 显式注册名已在解析前取出（真实现过滤要用）。
    print()
    print("== 断言 2：显式注册与 launcher 优先级 ==")
    print("解析到 {} 个显式注册名".format(len(explicit)))
    required_explicit = {
        "toybox", "sh", "mksh", "nc", "hexdump", "diff", "jq", "tar", "hd", "cpio",
    }
    missing_explicit = sorted(required_explicit - explicit)
    check(not missing_explicit,
          "关键显式名都从 IecRuntime.ets 解析出来（缺: {}）".format(
              ", ".join(missing_explicit) or "无"))

    # toybox 写入 = filterExplicit(parsed, explicit)，真实现已在上方算好；
    # 降级时按同一规则复刻：跳过 ''/'toybox'，再跳过 explicitNames。
    if toybox_written is None:
        toybox_written = []
        for name in parsed:
            if name in SKIP_NAMES:
                continue
            if name not in explicit:
                toybox_written.append(name)
    skipped = [name for name in parsed if name in explicit]
    skipped_set = set(skipped)
    toybox_set = set(toybox_written)
    collisions = sorted(set(parsed) & explicit)

    check(set(skipped) == set(collisions),
          "所有也是 toybox applet 的显式名都被跳过（{} 个: {}）".format(
              len(collisions), ", ".join(collisions) or "无"))
    check(not (toybox_set & explicit),
          "没有显式命令被写回 libtoybox.so")
    for name in collisions:
        check(name in skipped_set, "显式 {} 被跳过，未被 toybox 覆盖".format(name))
        print("        {} -> {}".format(name, explicit_so.get(name, "?")))

    # 最终 launcher 集合 = explicit ∪ (applets - explicit)。
    final_set = explicit | toybox_set
    expected = explicit | (set(parsed) - explicit)
    check(final_set == expected,
          "最终 launcher 集合 = explicit ∪ (applets - explicit)（{} 个）".format(
              len(final_set)))
    check(toybox_written and len(final_set) == len(explicit) + len(toybox_written),
          "toybox 写入与显式写入不重叠（toybox {} + 显式 {}）".format(
              len(toybox_written), len(explicit)))

    # 关键命令：toybox 编进去的，以及我们自己的 so。
    print()
    print("== 断言 3：关键命令最终可用 ==")
    for name in ("dd", "md5sum", "od", "nproc"):
        check(name in set(parsed) and name not in explicit and name in toybox_set,
              "{} 由 toybox 提供".format(name))
    for name in ("nc", "hexdump", "diff", "jq", "sh", "mksh"):
        check(name in final_set, "{} 最终存在".format(name))
        check(name in explicit, "{} 来自显式注册（{}）".format(
            name, explicit_so.get(name, "?")))
    check("nc" in set(parsed), "toybox 确实也带 nc，覆盖路径被真实触发")
    check("nc" in explicit and "nc" not in toybox_set,
          "nc 的 launcher 指向 {}，不是 libtoybox.so".format(
              explicit_so.get("nc", "?")))
    check("toybox" in final_set, "toybox 本体 launcher 存在")

    # 诊断输出：toybox 有但最终不存在、最终有但 toybox 没有。
    print()
    print("== 集合差异（诊断） ==")
    absent = sorted(set(parsed) - final_set)
    print("toybox 有但最终不存在: {} 个{}".format(
        len(absent), "（" + ", ".join(absent) + "）" if absent else "（无）"))
    print("toybox 有但被我们自己的 so 覆盖: {} 个（{}）".format(
        len(collisions), ", ".join(collisions) or "无"))
    ours = sorted(final_set - set(parsed))
    print("最终存在但 toybox 没有: {} 个（{}）".format(len(ours), ", ".join(ours)))

    # 上面 absent 按定义应为空；如果未来 writeToyboxApplets 加了过滤，这里会
    # 把它显式暴露出来，而不是悄悄少注册。
    check(not absent, "没有 toybox applet 在最终 launcher 集合里缺席")

    print()
    if failures:
        print("FAILED: {} 项断言失败".format(len(failures)), file=sys.stderr)
        return 1
    print("OK: applet 解析、显式覆盖与最终 launcher 集合全部一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
