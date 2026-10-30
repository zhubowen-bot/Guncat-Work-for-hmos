#!/usr/bin/env python3
# oracle.py — 用 Python 大整数复算 mksh 算术表达式，给出期望值。
#
# 输入: 每行一个算术表达式（不含外层 $(( ))），空行忽略。
# 输出: 每行 "回绕值\t精确值"（十进制）。
#   - 回绕值: 按 mksh（-DMKSH_LEGACY_MODE，mksh_ari_t = long）的 64 位有符号
#     语义逐步回绕后的结果；
#   - 精确值: 同一表达式在 Python 大整数下不做回绕的结果。
#   两者相等 = 该表达式没有溢出；不等 = 发生了 64 位回绕。run.sh 用前者做
#   "未溢出必须逐条相等、溢出比较回绕值" 的判据。
#
# 解析失败的表达式输出 "ERR\t原因"，由 run.sh 计为 FAIL。
#
# 只实现测试用到的子集：十进制/0x/base# 字面量、+ - * / % << >> & ^ | ~
# 一元正负、括号、三目运算。除法按 C 语义向零截断，取模符号随被除数。
import ast
import re
import sys

MASK = (1 << 64) - 1
SIGN = 1 << 63


def s64(x):
    """按 64 位补码回绕到有符号整数。"""
    x &= MASK
    return x - (1 << 64) if x >= SIGN else x


def tdiv(a, b):
    """C 语义的整数除法：向零截断。"""
    if b == 0:
        raise ZeroDivisionError("division by zero")
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def tmod(a, b):
    """C 语义的取模：结果符号与被除数一致。"""
    return a - tdiv(a, b) * b


class Bad(Exception):
    pass


BASE_RE = re.compile(r'(?<![\w#])(\d{1,2})#([0-9A-Za-z]+)')
# 测试只用到单层三目（cond ? a : b），Python 没有这个运算符，先改写成条件表达式。
TERN_RE = re.compile(r'^(.+?)\?(.+?):(.+)$')


def expand_ternary(expr):
    m = TERN_RE.match(expr)
    if not m:
        return expr
    return '(%s if %s else %s)' % (m.group(2), m.group(1), m.group(3))


def expand_bases(expr):
    def repl(m):
        base = int(m.group(1))
        digits = m.group(2)
        if not 2 <= base <= 36:
            raise Bad("进制超出 2..36: %s" % m.group(0))
        try:
            return str(int(digits, base))
        except ValueError:
            raise Bad("进制字面量非法: %s" % m.group(0))

    return BASE_RE.sub(repl, expr)


def ev(node, wrap):
    if isinstance(node, ast.Expression):
        return ev(node.body, wrap)

    if isinstance(node, ast.Constant):
        if not isinstance(node.value, int) or isinstance(node.value, bool):
            raise Bad("只支持整数常量")
        return s64(node.value) if wrap else node.value

    if isinstance(node, ast.UnaryOp):
        v = ev(node.operand, wrap)
        if isinstance(node.op, ast.USub):
            r = -v
        elif isinstance(node.op, ast.UAdd):
            r = v
        elif isinstance(node.op, ast.Invert):
            r = ~v
        else:
            raise Bad("不支持的一元运算符 %s" % type(node.op).__name__)
        return s64(r) if wrap else r

    if isinstance(node, ast.BinOp):
        a = ev(node.left, wrap)
        b = ev(node.right, wrap)
        op = node.op
        if isinstance(op, ast.Add):
            r = a + b
        elif isinstance(op, ast.Sub):
            r = a - b
        elif isinstance(op, ast.Mult):
            r = a * b
        elif isinstance(op, ast.Div):
            r = tdiv(a, b)
        elif isinstance(op, ast.Mod):
            r = tmod(a, b)
        elif isinstance(op, (ast.LShift, ast.RShift)):
            if not 0 <= b < 64:
                # mksh 在 LEGACY_MODE 下不掩码移位数，C 的移位溢出是未定义行为；
                # 这类表达式不放进 oracle 用例，遇到直接报错而不是猜一个值。
                raise Bad("移位数 %d 超出 0..63（C 未定义行为）" % b)
            if isinstance(op, ast.LShift):
                r = (a & MASK) << b if wrap else a << b
            else:
                r = a >> b
        elif isinstance(op, ast.BitAnd):
            r = a & b
        elif isinstance(op, ast.BitOr):
            r = a | b
        elif isinstance(op, ast.BitXor):
            r = a ^ b
        else:
            raise Bad("不支持的二元运算符 %s" % type(op).__name__)
        return s64(r) if wrap else r

    if isinstance(node, ast.IfExp):
        # 三目：条件按非零为真，只求值被选中的分支。
        if ev(node.test, wrap):
            return ev(node.body, wrap)
        return ev(node.orelse, wrap)

    raise Bad("不支持的语法节点 %s" % type(node).__name__)


def evaluate(expr):
    prepared = expand_ternary(expand_bases(expr.strip()))
    tree = ast.parse(prepared, mode='eval')
    wrapped = ev(tree, True)
    exact = ev(tree, False)
    return wrapped, exact


def main():
    for line in sys.stdin:
        expr = line.strip()
        if not expr:
            continue
        try:
            wrapped, exact = evaluate(expr)
            print("%d\t%d" % (wrapped, exact))
        except (Bad, SyntaxError, ZeroDivisionError) as exc:
            print("ERR\t%s" % str(exc).replace("\n", " "))


if __name__ == '__main__':
    main()
