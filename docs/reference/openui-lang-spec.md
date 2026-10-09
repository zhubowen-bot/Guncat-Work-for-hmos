# openui-lang — Implementation-Level Specification

Source of truth: `C:\Users\a1519\Documents\GitHub\open-intelligent-ui\node_modules\@openuidev\lang-core\dist\index.mjs`
(4475 lines; `@openuidev/lang-core@0.3.0`) and its declarations `dist/index.d.mts`.
All behaviour below was **verified by executing the built module** with Node v25.2.1 against a
sandboxed copy (module + `zod`/`ci-info` copied into `%TEMP%\dsh-X9rjKZ\openui`; nothing in the two
project directories was modified). Section 10 lists the raw observed outputs.

Line references are into `index.mjs` unless noted.

---

## 0. Pipeline overview

```
parse(input):
  trimmed = preprocess(input)                 // trim → stripFences → stripComments → trim
  if (!trimmed) return emptyResult()          // incomplete = true
  { text, wasIncomplete } = autoClose(trimmed)
  stmts = split(tokenize(text))               // RawStmt[]
  stmtMap: id → classifyStatement(raw, parseExpression(raw.tokens))   // last duplicate wins
  return buildResult(stmtMap, [...stmtMap.values()], firstId, wasIncomplete, stmtMap.size, cat, rootName)
```

`createParser(schema, rootName)` (line 3073) = `compileSchema` + `parse` inside a try/catch that
emits telemetry and re-throws. `createStreamingParser(schema, rootName)` (line 3091) =
`createStreamParser(compileSchema(schema), rootName)`.

`compileSchema` (line 3047) builds `Map<componentName, { params: ParamDef[] }>` from
`schema.$defs`, where `params` preserves **`Object.keys(def.properties)` insertion order**, each with
`{ name, required: required.includes(key), defaultValue: properties[key].default, schema: properties[key] }`.
Positional args map onto that order. `$defs` absent → empty map (every component then becomes
`unknown-component`).

---

## 1. Lexical grammar

### 1.1 Pre-lexical cleaning (before `tokenize`)

`preprocess` (line 2914) = `stripComments(stripFences(input.trim())).trim()`.

**`stripFences(input)`** (line 2829) — extracts fenced code blocks:
- Scans for ` ``` ` while skipping over `"…"` strings via `skipString` (line 2816: backslash escapes
  the next char; the helper only understands double quotes).
- For each fence: `fenceStart`, then skip to the first `\n` (drops the language tag line), then find
  the next ` ``` ` (also string-aware). The block body is pushed; scanning resumes after the closing
  fence.
- Unterminated fence → body = rest of input. Fence with no newline after it →
  `input.slice(fenceStart+3).replace(/^[^\n]*\n?/, "")`.
- If ≥1 block found → `blocks.join("\n")`. If none found **and** the input starts with ` ``` ` → the
  legacy fallback path strips the first line and everything from the last ` ``` `. Otherwise the
  input is returned unchanged.
- Verified: `"```\nroot = Card([])"` → parses; `"root = Card([])\n```"` → **no blocks found**
  (the first ` ``` ` opens a block whose close never comes → body = `""`… precisely: the block body is
  empty, so `blocks.length > 0` and the result is `""` → `emptyResult(incomplete=true)`, root null).
  `"```js\nroot = Card([])\n```\n```\nx = 1\n```"` → both blocks joined.

**`stripComments(input)`** (line 2890) — line-by-line, with `inStr` carried **across lines**:
- Inside a string: `\` skips the next char; the matching quote (only `"` or `'`, whatever opened it)
  closes it.
- Outside a string, `"` or `'` opens a string.
- Outside a string: `//` or `#` truncates the rest of the line, then `trimEnd()`.
- A multi-line unterminated string therefore swallows the comment markers (verified:
  `'a = "unterminated # c\nb = 2'` keeps everything).

**Important**: `stripComments` does **not** understand `/* */` block comments and does not treat
`#`/`//` specially after a `$` etc. Verified: `root = Card([], 1 /* c */)` → the `/` and `*` become
real operators; result `title = BinOp("/", 1, Null)`, `subtitle = BinOp("*", Ph(c), Null)`.

### 1.2 `tokenize(src)` (line 1793) — exact rules

Flat scan, `i` from 0 to `n`, always appending `{t:13}` (EOF) at the end.

**Skipped between tokens** (line 1798): `" "` (0x20), `"\t"`, `"\r"`. Not skipped: `\n` (token),
`\f`, `\v`, NBSP, and every other char.

**Everything else**:
1. `\n` → `{t:0}` (Newline token), significant.
2. Single chars: `(`→1, `)`→2, `[`→3, `]`→4, `{`→5, `}`→6, `,`→7, `:`→8, `.`→19, `?`→34, `+`→20,
   `*`→22, `/`→23, `%`→24.
3. `=` → `==`(25) if next is `=` else `=`(9). `!`→`!=`(26) else `!`(33). `>`→`>=`(29) else `>`(27).
   `<`→`<=`(30) else `<`(28).
4. `&` → `&&`(31) if doubled, else **also 31** (single `&` is accepted as `&&`). Same for `|` → 32.
5. **Double-quoted string** (line 1936): start at `"`, advance while: `\` → skip 2 chars; `"` → close;
   else advance. `rawString = src.slice(start, i)`; if not closed, `validJsonString = rawString + "\""`.
   Then `JSON.parse(validJsonString)`.
   - Success → `{t:14, v: parsed}`. Thus **all JSON escapes are supported**: `\"`, `\\`, `\/`, `\b`,
     `\f`, `\n`, `\r`, `\t`, `\uXXXX` (and lone UTF-16 surrogates). Raw newlines inside the string are
     allowed by `JSON.parse`.
   - Failure → fallback `rawString.replace(/^"|"$/g, "")` verbatim (so `"a\qb"` → the literal
     characters `a\qb`; `"a\u00zzb"` → `a\u00zzb`; `"\u{1F600}"` → `\u{1F600}`).
   - **Unterminated** string still emits a `Str` token with the text up to EOF: `"abc` → `Str("abc")`.
   - Unterminated with a trailing backslash: `"a\` → the loop does `i += 2` past EOF, `rawString` =
     `"a\`, then autoClose later appends `\` + `"` (see §6).
6. **Single-quoted string** (line 1962): manual scan. `\` + `'`→`'`, `\\`→`\`, `\n`→LF, `\t`→TAB,
   **any other `\x` → `x`** (backslash dropped). Unterminated → token with what was read. Newlines
   are allowed literally inside.
   Verified: `'a\nb'`→LF, `'a\\b'`→`a\b`, `'a\zb'`→`azb`, `'a\'b'`→`a'b`.
7. `-` (line 1989) — *unary-minus packing*. Let `prev` = last emitted token. If
   **`prev` is absent, or `prev.t` ∉ {15 Num, 14 Str, 16 Ident, 17 Type, 2 RParen, 4 RBrack, 10 True,
   11 False, 12 Null, 18 StateVar, 35 BuiltinCall}**, **and** the next char is a digit → fall through to
   the number branch, which consumes the `-` as part of the literal. Otherwise emit `-`(21).
   Consequences (verified):
   `1 -2` → `Num 1, Minus, Num 2` (binary minus) · `(1) -2` → `…RParen, Minus, Num 2` ·
   `[-2]` → `LBrack, Num(-2)` · `x[-1]` → `Num(-1)` · `a-2` → `Minus, Num 2` ·
   `1--2` → `Num 1, Minus, Num(-2)` · `- 2` → `Minus, Num 2`.
   Also note `-` is **not** in the "prev blocks packing" set for `35 BuiltinCall`… it *is*
   (`prev.t === 35` blocks), so `@Count -2` is binary minus.
8. **Number** (line 1997): leading digit, or `-`+digit. Consume optional `-`, digits, optional
   `.`+digits (only if a digit follows the dot), optional `e|E`, optional `+|-`, digits.
   `v = +src.slice(...)` (JS unary plus).
   - No hex/octal/binary: `0x10` → `Num 0` then `Ident "x10"`.
   - `1.` → `Num 1` then Dot(19). `.5` → Dot then `Num 5`.
   - `1e` / `1e+` → slice `"1e"` / `"1e+"` → **`+…` = `NaN`** (a `Num` node whose `v` is NaN).
   - `1E5`→100000, `1e-2`→0.01, `01`→1, `999…` → nearest double.
9. `$` + `[A-Za-z_]` → **StateVar**(18), value **includes the `$`** (`"$x"`), continuation
   `[A-Za-z0-9_]`. `$` followed by anything else is **dropped** (unrecognised char → `i++`).
10. `[A-Za-z_]` → word `[A-Za-z0-9_]*`; `true`→10, `false`→11, `null`→12 (case-sensitive);
    otherwise **`Type`(17) if the first char is `[A-Z]`, else `Ident`(16)** — note the classification
    uses only the first character, so `Foo_bar` is `Type`, `_x` is `Ident`.
11. `@` + `[A-Za-z_]` → **BuiltinCall**(35) with `v` = the name **without** `@`, continuation
    `[A-Za-z0-9_]`. A bare `@` is dropped.
12. **Any other character is silently skipped** (`i++`, no token): `;`, backtick, `\`, `^`, `~`,
    `"`  handled above, `\0`, emoji, etc. Verified: `root = Card([]);x = 1` → statementCount 1.

**Token enum** (`const enum T`, `index.d.mts` lines 676–743):

| # | Name | # | Name | # | Name |
|---|------|---|------|---|------|
|0|Newline|12|Null|24|Percent|
|1|LParen|13|EOF|25|EqEq|
|2|RParen|14|Str|26|NotEq|
|3|LBrack|15|Num|27|Greater|
|4|RBrack|16|Ident|28|Less|
|5|LBrace|17|Type|29|GreaterEq|
|6|RBrace|18|StateVar|30|LessEq|
|7|Comma|19|Dot|31|And|
|8|Colon|20|Plus|32|Or|
|9|Equals|21|Minus|33|Not|
|10|True|22|Star|34|Question|
|11|False|23|Slash|35|BuiltinCall|

`type Token = { t: T; v?: string | number }`. `Str` carries `v: string`, `Num` carries `v: number`
(can be `NaN`), `Ident`/`Type`/`StateVar`/`BuiltinCall` carry `v: string`; all others carry no `v`.

---

## 2. Statement grammar

**`split(tokens)`** (line 2604) — exact algorithm:

```
pos = 0
loop:
  skip Newline tokens
  if EOF break
  tok = tokens[pos]
  if tok.t ∉ {16 Ident, 17 Type, 18 StateVar}:
        skip to next Newline/EOF ; continue          // whole line dropped
  id = tok.v ; idTokenType = tok.t ; pos++
  if tokens[pos].t !== 9 (Equals):
        skip to next Newline/EOF ; continue          // "a\n" and "a == 1" dropped
  pos++
  expr = []; depth = 0; ternaryDepth = 0
  while pos < n && tokens[pos].t !== EOF:
     tt = tokens[pos].t
     if tt === Newline && depth <= 0 && ternaryDepth <= 0:
         peek past further Newlines; nextT = type of next non-newline token (EOF if none)
         if nextT === 34 (Question)  ||  (nextT === 8 && ternaryDepth > 0):
             pos++ ; continue        // newline swallowed, statement continues
         break                       // statement ends here
     if tt === Newline: pos++ ; continue          // inside brackets/ternary: ignored
     if tt ∈ {LParen, LBrack, LBrace}: depth++
     else if tt ∈ {RParen, RBrack, RBrace} && depth > 0: depth--
     else if tt === 34 && depth === 0: ternaryDepth++
     else if tt === 8 && depth === 0 && ternaryDepth > 0: ternaryDepth--
     expr.push(tokens[pos++])
  if expr.length: stmts.push({id, idTokenType, tokens: expr})
```

Consequences (all verified):

- **Line = statement**, `identifier = Expression`. Newlines inside `()`, `[]`, `{}` are ignored
  (`depth`), so **multi-line arrays/objects/calls are allowed**.
- **Multi-line ternaries** are allowed by the `ternaryDepth` counter: after a top-level `?`,
  `ternaryDepth = 1` and every newline is swallowed until the matching top-level `:`.
  The newline *before* a `?`/`:` is skipped by the peek rule.
  **Quirk**: a newline **immediately after** `?` (or after `:`) is swallowed by the counter rather than
  the peek rule, so `a = x ?\ny :\nz` parses the *else* as `Null` and `z` becomes a discarded line
  (a `:`/`?` **at the start of a line** works correctly because the counter is 0 at that point).
  Verified: `"a = x ? y :\nz ? p : q"` → `Ternary(x, y, Null)`; `"a = x\n?\ny\n:\nz"` → `Ternary(x, y, Null)`.
- Escaping the ternary counter requires **depth 0**; a ternary inside braces does not create a
  statement continuation.
- **Blank lines** anywhere are skipped (both at `pos` and inside/after an expression).
- **Invalid lines are silently skipped**: no `=`, LHS not an Ident/Type/StateVar, or nothing after `=`.
  `a`, `garbage line`, `a == 1`, `= 5`, `@Count = 1`, `Query("t")`, `(a) = 1`, `a.b = 1`,
  `1 + root = Card([])` all yield no statement.
- **Trailing content on a line is kept as part of the statement** (`a = 1 b = 2` → one statement with
  tokens `[Num 1, Ident b, Equals, Num 2]`) and then only the first expression is parsed
  (`parseExpression` ignores trailing tokens). `root = Card([]) extra` is the same as
  `root = Card([])`.
- Identifiers: `Ident`(16) → `kind:"value"`; `Type`(17) → also `kind:"value"` (e.g. `Card = 1` is a
  value statement named `Card`); `StateVar`(18) → `kind:"state"` with `id` **including the `$`**
  (`"$count"`).
- **Duplicates**: `stmtMap.set(id, …)` → in the one-shot parser the **last** statement wins
  (and `statementCount` counts unique names). Verified: `root = Card([])\nroot = Card([], "T")` →
  root props `{children:[], title:"T"}`, `statementCount = 1`.
  The **streaming** parser behaves differently (first wins) — see §5.
- `classifyStatement` (line 2689): if the expression is `Comp` named `Query` → `kind:"query"` +
  `deps = collectQueryDeps(args[1])` (all `StateRef` names in the args AST, unique, in walk order,
  `undefined` when empty). `Comp` named `Mutation` → `kind:"mutation"`. `StateVar` id → `kind:"state"`.
  Otherwise `kind:"value"`.

---

## 3. Expression grammar

`parseExpression(tokens)` (line 1446) — Pratt parser, `pos` over the token array.
`cur()` = `tokens[pos] ?? {t:13}`; `adv()` returns and consumes; `eat(k)` consumes iff `cur().t === k`.
The parser **never throws and never reports errors**; it always returns some `ASTNode`, consuming a
prefix of the input. `parseComp`/`parseArr`/`parseObj` stop on their closing token **or on EOF token
13** (never on a Newline, which split has already removed).

### 3.1 Precedence table (lines 1433–1441)

| Level | Const | Operators | Assoc. |
|---|---|---|---|
|1 (lowest)|`PREC_TERNARY`|`?:`|right-leaning; `then` parsed at prec 0, `else` at prec 0|
|2|`PREC_OR`|`\|\|`|left|
|3|`PREC_AND`|`&&`|left|
|4|`PREC_EQ`|`==`, `!=`|left|
|5|`PREC_CMP`|`>`, `<`, `>=`, `<=`|left|
|6|`PREC_ADD`|`+`, `-`|left|
|7|`PREC_MUL`|`*`, `/`, `%`|left|
|8|`PREC_UNARY`|prefix `!`, prefix `-`|right|
|9|`PREC_MEMBER`|`.` and `[`|left (postfix, tightest)|

`getInfixPrec(tok)` maps `[`(3) and `.`(19) to `PREC_MEMBER`. The main loop is
`while (getInfixPrec(cur()) > minPrec) left = parseInfix(left)` — i.e. **left-associative**
(operands are parsed with `parseExpr(samePrec)`, so equal precedence does not nest to the right).
Verified: `1 + 2 * 3` → `BinOp(+, 1, BinOp(*, 2, 3))`; `1 < 2 && 3 > 2 || false` →
`BinOp(\|\|, BinOp(&&, BinOp(<), BinOp(>)), false)`; `1 ? 2 : 3 ? 4 : 5` → right-nested ternary.

There is **no `=` at expression level except on `$name`** (see `Assign`), and no assignment to plain
idents.

### 3.2 Prefix (`parsePrefix`, line 1483)

| Token | Result |
|---|---|
|`Str`(14)|`{k:"Str", v}`|
|`Num`(15)|`{k:"Num", v}`|
|`True`(10)/`False`(11)|`{k:"Bool", v:true/false}`|
|`Null`(12)|`{k:"Null"}`|
|`[`(3)|`parseArr()`|
|`{`(5)|`parseObj()`|
|`StateVar`(18)|advance; if next is `Equals`(9): advance, `{k:"Assign", target:$name, value: parseExpr(0)}`; else `{k:"StateRef", n:$name}`|
|`Type`(17)|**if `tokens[pos+1]?.t === 1` (LParen) AND (`!isBuiltin(name)` OR `name === "Action"`) → `parseComp()`**; else `{k:"Ref", n}`|
|`BuiltinCall`(35)|if `tokens[pos+1]?.t === 1` → `parseComp()`; else `{k:"Ref", n:name}` (the `@` is dropped! `@Count` alone → `Ref("Count")`)|
|`Ident`(16)|`{k:"Ref", n}`|
|`!`(33)|`{k:"UnaryOp", op:"!", operand: parseExpr(PREC_UNARY)}`|
|`-`(21)|`{k:"UnaryOp", op:"-", operand: parseExpr(PREC_UNARY)}`|
|`(`(1)|advance, `inner = parseExpr(0)`, `eat(RParen)`, return `inner` (no node, no tuple)|
|anything else|advance once and return `{k:"Null"}`|

Consequences:
- A builtin name **without** `(` is a plain reference (`@Count`→`Ref("Count")`; `@Count` in an
  argument yields `null` and `"Count"` in `meta.unresolved`).
- `Each` is a builtin (`LAZY_BUILTINS`), so `Each(...)` **without `@`** is *not* a component call →
  `Ref("Each")` → `null` + `unknown-component` for the enclosing component's prop.
- `Action(...)` is special-cased: `@Action(...)` and `Action(...)` both parse as a `Comp`
  (and `Action` is *not* treated as a component for entry selection).
- `Query`/`Mutation` **are not** builtins, so `Query(...)` at expression level parses as `Comp`.
- Unrecognised leading tokens degrade to `Null` rather than erroring: `()`→`Null`,
  `?`→`Null`, `:`→`Null`, `,`→…

### 3.3 Infix (`parseInfix`, line 1584)

- Arithmetic/comparison/logical as per the table, producing
  `{k:"BinOp", op, left, right}` with `op` ∈ `+ - * / % == != > < >= <= && ||`.
- `?`(34): `advance; then = parseExpr(0); eat(Colon); {k:"Ternary", cond:left, then, else: parseExpr(0)}`.
  A missing `:` is tolerated (`eat` is a no-op) — `a ? b` → `Ternary(a, b, Null)`; missing `then`
  (`a ? : b`) → `then = Null`.
- `.`(19): `advance; fieldTok = cur()` then:
  - `t ∈ {16 Ident, 17 Type, 14 Str, 15 Num}` → `advance`, `field = String(fieldTok.v)`
    (so `a.1` → field `"1"`, `a."x"` → field `"x"`, `a.true` → **not** covered → field `"?"`)
  - `t === 18 StateVar` → `advance`, `field = v.replace(/^\$/, "")` (so `a.$b` → field `"b"`)
  - anything else → `advance`, `field = "?"` (consumes one token unconditionally!)
- `[`(3): `advance; index = parseExpr(0); eat(RBrack); {k:"Index", obj:left, index}`.
  Missing `]` is tolerated (`a[` → `Index(Ref(a), Null)`; `a[1` → `Index(Ref(a), Num 1)`).
- `parseInfix` has a trailing `return left`, and the main loop only calls it when the precedence is
  positive, so it is unreachable for other tokens.

### 3.4 `parseComp()` (line 1736)

```
name = cur().v ; advance ; eat(LParen)
args = []
while (cur().t !== RParen && cur().t !== EOF):
    args.push(parseExpr(0))
    if (cur().t === Comma) advance
eat(RParen)
return { k:"Comp", name, args }
```
- **Arguments are positional and unlabelled.** A `key: value` inside a call parses as
  `Ternary`-less garbage: `Card([], x: 1)` → `x` is parsed, `:` is left as an unconsumed token, the
  loop then parses `1` as another argument. The prompt explicitly forbids colon syntax
  (`index.mjs` line 678).
- **Empty arguments are tolerated and produce `Null` args**: `Card([,])` → `args = [Arr, Null]`
  (comma → empty expr → `parsePrefix` advances the `]`… actually `parsePrefix` sees `]`(4) → default
  branch: `advance()` then `Null`), and `Card([], )` → `args = [Arr]` (`)` terminates the loop).
- Trailing comma allowed (`[1,2,]`, `Card(a,)`).
- No arity check at parse time; excess positional args are handled by validation (`excess-args`).
- **Missing `)` at EOF is tolerated**: `Card([` auto-closed by `autoClose` anyway; even without it,
  `Card(` → `Comp{name:"Card", args:[]}`.

### 3.5 `parseArr()` / `parseObj()`

- `parseArr` is structurally identical with `[`/`]`, producing `{k:"Arr", els}`.
- `parseObj` (line 1767) produces `{k:"Obj", entries: [string, ASTNode][]}`:
  key token `t ∈ {16 Ident, 14 Str, 17 Type, 15 Num}` → `String(v)`; `t === 18 StateVar` →
  `v.replace(/^\$/,"")`; **anything else → `"?"`** (and the token is consumed).
  Then `eat(Colon)` (tolerant), then `entries.push([key, parseExpr(0)])`, optional comma.
  - **Quoted keys are optional**: `{a: 1}` ≡ `{"a": 1}` ≡ `{$a: 1}` (→ key `"a"`) ≡ `{1: 2}` (→ `"1"`).
  - `{true: 2}` and `{null: 2}` → key `"?"` (True/Null are not in the accepted set).
  - `{: 2}` → key `"?"`.
  - `{a}` → `eat(Colon)` no-op, value = `parseExpr(0)` on `}` → `Null`, giving `{a: null}`, then
    `}` consumed. But since `cur()` was `}` the while condition ends… **verified result is
    `{"a": null, "?": null}`** — the `}`(6) is *not* the loop terminator in this position because the
    key scan already consumed it as the `"?"` key of a second entry.
  - Duplicate keys: last wins in the resulting JS object (`materializeValue` assigns into a plain
    object).
  - Keys are emitted **unquoted** by the serializer (`serializeASTNode` / `serializeValue`), which is
    safe for identifier-like keys but produces invalid-ish output for keys like `"a b"`.

### 3.6 `@` builtins and `Action([...])`

`BUILTINS` (line 316): `Count First Last Sum Avg Min Max Sort Filter Round Abs Floor Ceil`.
`LAZY_BUILTINS = {"Each"}`. `ACTION_STEPS = {Run:"run", ToAssistant:"continue_conversation",
OpenUrl:"open_url", Set:"set", Reset:"reset"}`; `ACTION_NAMES = {Action, Run, ToAssistant, OpenUrl,
Set, Reset}`; `BUILTIN_NAMES = BUILTINS ∪ LAZY_BUILTINS ∪ ACTION_NAMES`; `RESERVED_CALLS =
{Query, Mutation}` (not builtins).

**They all parse to ordinary `Comp` nodes** — `@Set($a, 1)` → `{k:"Comp", name:"Set", args:[StateRef,
Num]}`, `@Run(q)` → `{k:"Comp", name:"Run", args:[Ref("q")]}`, `Action([...])` → `{k:"Comp",
name:"Action", args:[Arr]}`. The `@` is dropped for builtins except in the serializer, which re-adds
it (§9). There is no dedicated action AST node.

At **parse/materialize** time builtins are left as AST nodes (they are *not* inlined); the enclosing
prop keeps the `Comp` and `hasDynamicProps` becomes `true`. At **evaluation** time
(`evaluate`, line 3408 / `evaluateActionCall`, line 3581) they become values:

| Name | Runtime result |
|---|---|
|`Count(arr)`|`Array.isArray ? length : 0`|
|`First`/`Last`|first/last element or `null`|
|`Sum`|`reduce((a,b)=>a+toNumber(b), 0)`, non-arrays → 0|
|`Avg`|`toNumber` sum / length, else 0|
|`Min`/`Max`|reduce with `toNumber`, else 0|
|`Sort(arr, field, dir?)`|copy+sort; numeric-aware; `dir === "desc"` reverses; `field` uses dot-paths|
|`Filter(arr, field, op, value)`|ops `== != > < >= <= contains` (loose `==`/`!=`, numeric `toNumber` comparisons), non-array → `[]`, unknown op → `false`|
|`Round(n, d?)`|`Math.round(n*10^d)/10^d`, d default 0|
|`Abs`/`Floor`/`Ceil`|`Math.abs/floor/ceil(toNumber(n))`|
|`Each(arr, varName, template)`|evaluate `template` once per item; `varName` accepted from `Ref` or `Str`; non-array → `[]`; <3 args → `[]`; `Ref(varName)` is substituted with the item's literal value first, and a child `resolveRef` scope is installed. The `varName` argument index 1 is skipped during materialization, and refs named `varName` are left untouched (`materializeLazyBuiltin`, line 2349)|
|`toNumber(val)`|number→itself; string→`Number(val)` (`NaN`→0); boolean→1/0; else 0|
|`Action(x)`|`{ steps: (Array.isArray(evaluatedX) ? evaluatedX : []).filter(s => s != null && typeof s === "object" && "type" in s) }` — non-array arg → `{steps: []}`|
|`Run(r)`|`null` unless `args[0].k === "RuntimeRef"` → `{type:"run", statementId, refType}`; note this inspects the **AST node kind**, so `@Run` only works after materialization turned the ref into a `RuntimeRef` (a `Ref` to a `Query`/`Mutation` statement)|
|`ToAssistant(m, c?)`|`{type:"continue_conversation", message: String(m ?? ""), context: String(c ?? "") or undefined}`|
|`OpenUrl(u)`|`{type:"open_url", url: String(u ?? "")}`|
|`Set(t, v)`|requires ≥2 args and `args[0].k === "StateRef"` else `null` → `{type:"set", target, valueAST: args[1]}`|
|`Reset(t…)`|all `StateRef` args (≥1 required, else `null`) → `{type:"reset", targets}`|
|other `ACTION_NAMES`|`null`|

Unknown `Comp` reached by `evaluate` without `mappedProps` → `console.warn("[openui] Unexpected
unmapped Comp node: …")` and `null`.

---

## 4. Reference resolution & hoisting (`materializeValue` / `materializeExpr` / `resolveRef`)

Symbol table: **all** statements are indexed first (`syms`), so **references are order-independent
(full hoisting)**: forward references work. `syms.set(id, stmt.kind === "state" ? stmt.init :
stmt.expr)`.

Entry statement selection (`pickEntryId`, line 2768) — in this order:
1. a statement literally named **`root`**;
2. else a statement named `rootName` (the 2nd `parse`/`createParser` argument), **only if it is a
   value statement**;
3. else the first value statement whose expression is `Comp` with `name === rootName`;
4. else the first *component statement* — `kind === "value" && expr.k === "Comp" &&
   !isBuiltin(name) && name !== "Query" && name !== "Mutation"`;
5. else the first statement (`firstId`). Then `if (!stmtMap.has(entryId)) return emptyResult(wasIncomplete)`.

`buildResult` (line 2775):
```
syms = id → (state ? init : expr)
unreached = all ids except entryId, excluding kind state/query/mutation
ctx = { syms, cat, errors, unres, visited:Set(), partial:wasIncomplete,
        currentStatementId: entryId, unreached }
materialized = materializeValue(syms.get(entryId), ctx)
root = isElementNode(materialized) ? materialized : null
if (root) root.statementId = entryId
{stateDeclarations, queryStatements, mutationStatements} = extractStatements(typedStmts, ctx)
meta = { incomplete: wasIncomplete, unresolved: unres, orphaned: [...unreached],
         statementCount, errors }
```

**`resolveRef(name, ctx, mode)`** (line 2310), `mode ∈ {"value","expr"}`:
```
1. if ctx.visited.has(name):  ctx.unres.push(name)
       return mode==="expr" ? {k:"Ph", n:name} : null
2. if !ctx.syms.has(name):    ctx.unres.push(name)
       return mode==="expr" ? {k:"Ph", n:name} : null
3. target = ctx.syms.get(name); ctx.unreached?.delete(name)
4. if target is Comp with a reserved name (Query/Mutation):
       return {k:"RuntimeRef", n:name, refType: name==="Mutation" ? "mutation" : "query"}
5. ctx.visited.add(name); swap currentStatementId; try { materialize… } finally { restore; visited.delete(name) }
```
Key properties:
- **Cycles** are cut by `visited` and both the cycle name and (via step 2) any unknown name land in
  `meta.unresolved` — duplicates are *not* deduplicated (a name can appear twice).
- The same name referenced twice in a *non-cyclic* position is materialized twice (verified:
  `Card([a, a])` yields two element objects, both `statementId:"a"`); `visited` is a path stack, not a
  memo.
- **Value-mode placeholder → `null`**, so an unresolved ref used as an argument becomes `null`
  (and is dropped from arrays — see below). **Expr-mode placeholder → `{k:"Ph", n}`**, so an
  unresolved ref inside a runtime expression survives as a `Ph` node (the evaluator maps `Ph` to
  `null`).
- Nested refs inherit the *referenced* statement's id for error reporting
  (`ctx.currentStatementId` is swapped), and every materialized element gets
  `result.statementId = name` — so **the statementId of a nested element is the innermost statement
  that defined it**, not the one being rendered.

**`materializeValue(node, ctx)`** (line 2452) — produces the *evaluated tree*:
| kind | result |
|---|---|
|`Ref`|`resolveRef(n, ctx, "value")`|
|`Str`/`Num`/`Bool`|plain `v`|
|`Null`|`null`|
|`Ph`|`null`|
|`Arr`|`[]`; for each `el`: skip if `el.k === "Ph"`; else `v = materializeValue(el)`; **skip if `v === null && (el.k === "Comp" \|\| el.k === "Ref")`**; else push. So unresolved refs/components vanish from arrays while explicit `null`s are kept.|
|`Obj`|plain object, every value materialized (no skipping; failed components become `null` values)|
|`Comp` builtin|if `Each` and ≥3 args with a `Ref`/`Str` var name → `materializeLazyBuiltin`; else `{...node, args: args.map(materializeExpr)}` (structure preserved, `mappedProps` absent)|
|`Comp` reserved (`Query`/`Mutation`) **inline**|push `inline-reserved` error, return `null`|
|`Comp` known component|map positional args → named props by `params` order (only `min(params.length, args.length)`); validate each against its `schema`; `excess-args` if `args.length > params.length`; fill/verify required; set `hasDynamicProps`; return `ElementNode`|
|`Comp` unknown|push `unknown-component` (with `available` = all catalog keys), return `null` (at *this* level; note `materializeExprInternal` instead keeps the node and only reports)|
|other runtime-expr kinds|delegate to `materializeExpr` (structure preserved)|
|default|return node unchanged|

**Validation order inside a known `Comp`** (lines 2491–2530):
1. For `i < min(params.length, args.length)`: `props[param.name] = materializeValue(args[i])`, then if
   `param.schema !== undefined && validateSchemaValue(value, schema, name, `/${param.name}`, ctx)` →
   `resolveInvalidValue(props, name, required, defaultValue)`: default present → substitute and keep;
   else required → mark `dropComponent = true`; else `delete props[name]`.
2. `args.length > params.length` → `excess-args` error (**path `""`**, message
   `"X takes N arg(s), got M (K excess dropped)"`). Excess args are simply ignored.
3. `missingRequired = params.filter(p => p.required && (!(p.name in props) || props[p.name] === null))`.
   For each: if `defaultValue !== undefined` → fill silently; else push
   `code: p.name in props ? "null-required" : "missing-required"`, path `/${name}`, with
   `signature` = `buildParamsSignature(...)` (`Name(a*: string, b: number, …)`, `*` = required).
   Any still-invalid → **return `null`** (component dropped).
4. `dropComponent` → `return null`.
5. Return `{type:"element", typeName, props, partial: ctx.partial, hasDynamicProps}`.
   `hasDynamicProps = Object.values(props).some(containsDynamicValue)` where
   `containsDynamicValue` is true for any AST node, else recurses arrays, ElementNode props, and plain
   object values.

**Validation recursion** (`validateSchemaValue`, line 2281):
- `value == null` → no error (required handled at the level above); `isASTNode(value)` → no error
  (deferred to runtime); `isElementNode(value)` → `validateElementPosition` (composite schema
  `$ref/anyOf/oneOf/allOf` → unchecked; a slot declaring `type`/`enum`/`const` →
  `type-mismatch` with `actual: component "X"`); composite schema → unchecked.
- `type:"object"` → `validateObjectValue`: non-object → `type-mismatch expected object`; then
  **only when `!ctx.partial`** each required key that is absent/null is filled from its schema
  `default` or reported (`null-required`/`missing-required`) and marks the object invalid; then every
  declared property present in the object is validated recursively (paths are JSON Pointers
  `path/key`), invalid children resolved by the same default/substitute/delete/require rule.
- `type:"array"` → `validateArrayValue`: non-array → `type-mismatch expected array`; with an `items`
  schema, each item is validated and invalid indices are **spliced out in reverse** (always pruned,
  never defaulted).
- otherwise → `validateLeafValue`: enum/const → membership check **skipped while `ctx.partial`**;
  otherwise `typeof` check against `string`/`number`(`integer`)/`boolean`. Errors:
  `field "/p" expects one of ["a", "b"] but got "z"` or `field "/p" expects number but got string`.
- Messages (`validationMessage`, line 2139) are exactly:
  `unknown-component`: `Unknown component "X" — not found in catalog or builtins. Available components: A, B`
  `inline-reserved`: `X() must be declared as a top-level statement, not used inline as a value`
  `missing-required`: `missing required field "/p" — signature: …`
  `null-required`: `required field "/p" cannot be null — signature: …`
  `excess-args`: `X takes N arg(s), got M (K excess dropped)`
  `type-mismatch`: `field "/p" expects E but got A`

**`materializeExpr`** (line 2437, used for builtin/lazy args and runtime expressions) differs from
`materializeValue`: refs resolve in `"expr"` mode (→ `Ph` instead of `null`), `Comp`s get
`mappedProps` added when they are catalog components, unknown components only push the error and are
returned intact, and every container is rebuilt preserving node kinds.

**`extractStatements`** (line 2727):
- `stateDeclarations[id] = materializeValue(stmt.init, ctx)` for every `kind:"state"` statement
  (id **includes `$`**). The value can be a plain literal **or a preserved AST node** (verified:
  `$count = $count + 1` → `{"$count": {k:"BinOp",…}}`; `$a = $b` with `$b` undefined → `null`).
- `queryStatements`: `{statementId, toolAST: args[0] ?? null, argsAST: args[1] ?? null,
  defaultsAST: args[2] ?? null, refreshAST: args[3] ?? null, deps (or absent), complete: true}`.
- `mutationStatements`: `{statementId, toolAST: args[0] ?? null, argsAST: args[1] ?? null}`.
- Afterwards, **every `StateRef` anywhere in every statement** (state inits, value exprs, query and
  mutation args) that is not already a key is added with value `null` — this is the "$variable
  auto-declare" rule. `$` names inside `Ph`-surviving expressions are also collected.
- Note: unreferenced/`orphaned` statements still contribute their `$` names and their Query/Mutation
  entries (the loop is over all statements, not just reachable ones).

**Orphan detection**: `unreached` starts as every value statement except the entry; a successful
`resolveRef` removes the referenced name. `meta.orphaned` = survivors (array order = statement
order). State/Query/Mutation statements are never orphans. So a chain that is only referenced from an
orphan still removes those names (verified: `a = TextContent("a")\nb = TextContent("b")\nroot =
Card([a])` → `orphaned = ["b"]`).

**`meta.incomplete`** = `autoClose(...).wasIncomplete` for the one-shot parser; for the streaming
parser it is that of the trailing pending text (or `false` when nothing is pending).
`meta.statementCount`: one-shot = number of unique statement ids. Streaming = completed count +
pending count (double counting possible; see §5).

`emptyResult(incomplete = true)`:
```
{ root: null, meta: { incomplete, unresolved: [], orphaned: [], statementCount: 0, errors: [] },
  stateDeclarations: {}, queryStatements: [], mutationStatements: [] }
```

---

## 5. Streaming / incremental parsing

`createStreamParser(cat, rootName)` (line 2939) keeps: `buf` (raw accumulated text), `cleaned`
(preprocessed), `completedEnd` (index into `cleaned` up to which statements have been harvested),
`completedStmtMap: Map<id, Statement>`, `completedCount`, `firstId`.

`push(chunk)` → `buf += chunk; return currentResult()`.
`set(fullText)` → if `fullText.length < buf.length || !fullText.startsWith(buf)` → **reset()**;
then `delta = fullText.slice(buf.length)`; if truthy, `buf += delta`; return `currentResult()`.
Note: for a shorter-but-prefix text, `delta` is `""` (no truncation of `buf`) — the buffer never
shrinks without a reset. `set` is also usable from empty (verified `set('root = Card([x])\n')`).
`getResult()` = `currentResult()` (idempotent; no new data consumed).

`currentResult()`:
```
refreshCleaned():
    next = preprocess(buf)
    if (!next.startsWith(cleaned.slice(0, completedEnd))):   // text replaced, not appended
        completedEnd = 0; completedStmtMap.clear(); completedCount = 0; firstId = ""
    cleaned = next
pendingStart = scanNewCompleted()
pendingText = cleaned.slice(pendingStart).trim()
if (!pendingText):
    if (completedCount === 0) return emptyResult()
    return buildResult(completedStmtMap, [...values], firstId, false, completedCount, cat, rootName)
{text: closed, wasIncomplete} = autoClose(pendingText)
stmts = split(tokenize(closed))
if (!stmts.length):
    if (completedCount === 0) return emptyResult(wasIncomplete)
    return buildResult(completedStmtMap, […], firstId, wasIncomplete, completedCount, …)
allStmtMap = new Map(completedStmtMap)
for (s of stmts):
    if (completedStmtMap.has(s.id)) continue         // <<< pending NEVER overrides completed
    allStmtMap.set(s.id, classifyStatement(s, parseExpression(s.tokens)))
return buildResult(allStmtMap, [...values], firstId || stmts[0].id, wasIncomplete,
                   completedCount + stmts.length, cat, rootName)
```

`scanNewCompleted()` — **the end-of-statement detector** (independent re-scan of `cleaned`, not token
based):
```
depth = 0; ternaryDepth = 0; inStr = false; esc = false; stmtStart = completedEnd
for i = completedEnd .. cleaned.length-1:
    c = cleaned[i]
    if esc: esc = false; continue
    if c === "\\" && inStr: esc = true; continue
    if inStr: if (c === inStr) inStr = false; continue
    if (c === '"' || c === "'"): inStr = c; continue
    if (c === "(" || c === "[" || c === "{"): depth++
    else if (c === ")" || c === "]" || c === "}"): depth = max(0, depth-1)
    else if (c === "?" && depth === 0): ternaryDepth++
    else if (c === ":" && depth === 0 && ternaryDepth > 0): ternaryDepth--
    else if (c === "\n" && depth <= 0 && ternaryDepth <= 0):
        peek past spaces/tabs/CR/newlines
        if (cleaned[peek] === "?" || (cleaned[peek] === ":" && ternaryDepth > 0)) continue
        t = cleaned.slice(stmtStart, i).trim()
        if (t) addStmt(t)
        stmtStart = i+1; completedEnd = i+1
return stmtStart
```
`addStmt(text)` = `split(tokenize(text))` + `classifyStatement` + `completedStmtMap.set(id, stmt)`
+ `completedCount++` + `firstId ??= id` (so **completed statements are first-wins per id**, unlike
one-shot last-wins; verified: duplicate `root` → the streaming tree keeps the *first* definition).

Behavioural contract, all verified:

- **Prefixes that parse**: any prefix is accepted. A pending (not yet newline-terminated) fragment is
  auto-closed and parsed as a *tentative* statement whose nodes get `partial: true`; completed
  statements before it keep their finished values.
- `""` → `emptyResult()` (`incomplete: true, statementCount: 0`).
- `"root "`, `"root ="`, `"root = "` → nothing yet (`incomplete:false`, count 0) because no
  `Ident = …` with a non-empty expression exists.
- `"root = Car"` → tentative statement; `root = null`, `unresolved: ["Car"]`, `statementCount: 1`.
- `"root = Card(["` → `root = Card(children: [])`, `partial: true`, `incomplete: true`.
- `"root = Card("` → **`root: null` with a `missing-required` error** for `children` (auto-close makes
  `Card()`, and top-level `missing-required` is *not* suppressed by `partial`). This transient error
  disappears as soon as `[` arrives. This matters for reimplementations: only the *nested* checks
  (object required keys, enums) are suppressed while `partial`; a component whose required positional
  args have not arrived yet is dropped.
- `root = Card([a, b])` mid-stream → children resolved as far as possible; entries whose definitions
  have not arrived are **omitted from the array** (unresolved `Ref` → `null` → skipped) while
  `meta.unresolved` lists them.
- Unterminated string: `root = Card([a], "untermin` → `title: "untermin"`, `partial: true`. Growing
  the string grows the prop (verified character-by-character).
- A trailing incomplete statement contributes `statementCount` and its nodes, but `buildResult`
  re-does entry selection over the merged map, so once `root` completes, later statements cannot
  displace it (first-wins).
- **The all-at-once equivalence holds**: feeding the whole text one character at a time, then
  `getResult()`, is byte-identical to `createParser(schema).parse(text)` — verified for
  `root = Card([a, b])\na = TextContent("Hello")\nb = TextContent("World")` (`equal: true`).
  Exception: duplicate ids (first vs last wins) and `statementCount` bookkeeping.
- **`statementCount` double counting**: every time a pending statement is re-scanned it is added
  again as `completedCount + stmts.length`, and once the newline arrives it is counted *again* in
  `completedCount`. Verified: writing `root = …` then `\n` then a second `root = …` then `\n` gives
  `statementCount: 2` for a program whose one-shot count is `1`.
- `getResult()` is safe to call repeatedly (no drift beyond the above) — verified 2/2/2.
- **Reset conditions**: `set()` with text that is not an extension of `buf` (or is shorter) resets
  everything; `refreshCleaned()` also resets if `cleaned` changed before `completedEnd` (e.g. a `#`
  comment appearing earlier rewrites the cleaned prefix). After a reset the result is recomputed from
  the new buffer.
- A line that is completed but **invalid** (no `=`) is silently dropped by `split` inside `addStmt`,
  and `completedEnd` still advances past it.

---

## 6. Partial value completion — `autoClose(input)`

```js
function autoClose(input) {
  const stack = []; let inStr = false; let esc = false;
  for (let i = 0; i < input.length; i++) {
    const c = input[i];
    if (esc) { esc = false; continue; }
    if (c === "\\" && inStr) { esc = true; continue; }
    if (inStr) { if (c === inStr) inStr = false; continue; }
    if (c === '"' || c === "'") { inStr = c; continue; }
    if (c === "(" || c === "[" || c === "{") stack.push(c);
    else if (c === ")" && stack[stack.length-1] === "(") stack.pop();
    else if (c === "]" && stack[stack.length-1] === "[") stack.pop();
    else if (c === "}" && stack[stack.length-1] === "{") stack.pop();
  }
  if (!(!!inStr || stack.length > 0)) return { text: input, wasIncomplete: false };
  let out = input;
  if (inStr) { if (esc) out += "\\"; out += inStr; }
  for (let j = stack.length - 1; j >= 0; j--) out += stack[j] === "(" ? ")" : stack[j] === "[" ? "]" : "}";
  return { text: out, wasIncomplete: true };
}
```

Exact behaviour:
- Appends the closing quote (`"` or `'`, matching whatever opened it) if a string is open, plus a
  literal `\` first if the input ended inside an escape.
- Then appends, in **reverse stack order**, `)`/`]`/`}` corresponding to each unclosed opener.
- `wasIncomplete = true` iff a quote or an opener was left open.
- **Mismatched closers are ignored**: `)`/`]`/`}` pop only when they match the top of the stack.
  `"root = Card([)"` → `"root = Card([)])"` (the `)` does not pop `[`).
- It operates on **raw text** and does not understand comments (comments have already been stripped by
  `preprocess`) and does not skip `#`/`//`.
- Single- vs double-quote state is tracked independently of `"` inside `'…'` and vice versa.
- Verified outputs:
  `"root = Card(["`→`"root = Card([])"`, `'root = Card(["a'`→`'root = Card(["a"])'`,
  `'root = Card(["a\\'`→`'root = Card(["a\\"])'`, `"root = {a: [1, {b: 2"`→`"root = {a: [1, {b: 2}]}"`,
  `'root = Card([)"'`→`'root = Card([)])'`, `'root = Card([)]'`→`'root = Card([)])'`,
  `'root = Card([})'`→`'root = Card([})])'`, `'root = Card("a"'`→`'root = Card("a")'`,
  `"root = Card([])"`→unchanged (`wasIncomplete:false`).
- Limits: no token-level repair (a missing comma is not inserted), no re-balancing of mismatched
  brackets, no truncation of a half-typed identifier (that becomes a bogus name instead — e.g. `Car`
  stays `Car`), and no help for a `:` whose `?` was never typed.

---

## 7. AST / token / result types (exact, from `index.d.mts`)

```ts
type ASTNode = {
  k: "Comp"; name: string; args: ASTNode[]; mappedProps?: Record<string, ASTNode>;
} | { k: "Str"; v: string }
  | { k: "Num"; v: number }
  | { k: "Bool"; v: boolean }
  | { k: "Null" }
  | { k: "Arr"; els: ASTNode[] }
  | { k: "Obj"; entries: [string, ASTNode][] }
  | { k: "Ref"; n: string }
  | { k: "Ph"; n: string }
  | { k: "StateRef"; n: string }
  | { k: "RuntimeRef"; n: string; refType: "query" | "mutation" }
  | { k: "BinOp"; op: string; left: ASTNode; right: ASTNode }
  | { k: "UnaryOp"; op: string; operand: ASTNode }
  | { k: "Ternary"; cond: ASTNode; then: ASTNode; else: ASTNode }
  | { k: "Member"; obj: ASTNode; field: string }
  | { k: "Index"; obj: ASTNode; index: ASTNode }
  | { k: "Assign"; target: string; value: ASTNode };

type RuntimeExprNode = Extract<ASTNode, {k:"StateRef"}|{k:"RuntimeRef"}|{k:"BinOp"}|{k:"UnaryOp"}
  |{k:"Ternary"}|{k:"Member"}|{k:"Index"}|{k:"Assign"}>;
declare function isRuntimeExpr(node: ASTNode): node is RuntimeExprNode;
declare function isASTNode(value: unknown): value is ASTNode;
declare function walkAST(node: ASTNode, visit: (node: ASTNode) => void): void;

interface CallNode { callee: string; args: ASTNode[] }

type Statement =
  | { kind: "value"; id: string; expr: ASTNode }
  | { kind: "state"; id: string; init: ASTNode }
  | { kind: "query"; id: string; call: CallNode; expr: ASTNode; deps?: string[] }
  | { kind: "mutation"; id: string; call: CallNode; expr: ASTNode };

// tokens
declare const enum T { Newline=0, LParen=1, RParen=2, LBrack=3, RBrack=4, LBrace=5, RBrace=6,
  Comma=7, Colon=8, Equals=9, True=10, False=11, Null=12, EOF=13, Str=14, Num=15, Ident=16, Type=17,
  StateVar=18, Dot=19, Plus=20, Minus=21, Star=22, Slash=23, Percent=24, EqEq=25, NotEq=26,
  Greater=27, Less=28, GreaterEq=29, LessEq=30, And=31, Or=32, Not=33, Question=34, BuiltinCall=35 }
type Token = { t: T; v?: string | number };
interface RawStmt { id: string; idTokenType: T; tokens: Token[] }

// library / params
type JSONSchemaProperty = Record<string, unknown>;
type JSONSchemaDef = { properties?: JSONSchemaProperty; required?: string[]; description?: string };
interface LibraryJSONSchema { $defs?: Record<string, JSONSchemaDef> }
interface ParamDef { name: string; required: boolean; defaultValue?: unknown; schema?: unknown }
type ParamMap = Map<string, { params: ParamDef[] }>;

// evaluated tree
interface ElementNode {
  type: "element";
  statementId?: string;
  typeName: string;
  props: Record<string, unknown>;
  partial: boolean;
  hasDynamicProps?: boolean;
}
type ValidationErrorCode = "missing-required" | "null-required" | "unknown-component"
  | "inline-reserved" | "excess-args" | "type-mismatch";
interface ValidationError { code: ValidationErrorCode; component: string; path: string;
  message: string; statementId?: string }

type ParseResult = {
  root: ElementNode | null;
  meta: { incomplete: boolean; unresolved: string[]; orphaned: string[];
          statementCount: number; errors: ValidationError[] };
  stateDeclarations: Record<string, unknown>;
  queryStatements: QueryStatementInfo[];
  mutationStatements: MutationStatementInfo[];
};
interface QueryStatementInfo { statementId: string; toolAST: ASTNode | null; argsAST: ASTNode | null;
  defaultsAST: ASTNode | null; refreshAST: ASTNode | null; deps?: string[]; complete: boolean }
interface MutationStatementInfo { statementId: string; toolAST: ASTNode | null; argsAST: ASTNode | null }

interface StreamParser {
  push(chunk: string): ParseResult;
  set(fullText: string): ParseResult;
  getResult(): ParseResult;
}
interface Parser { parse(input: string): ParseResult }
declare function parse(input: string, cat: ParamMap, rootName?: string): ParseResult;
declare function createParser(schema: LibraryJSONSchema, rootName?: string): Parser;
declare function createStreamingParser(schema: LibraryJSONSchema, rootName?: string): StreamParser;

// evaluation
type OpenUIErrorSource = "parser" | "runtime" | "query" | "mutation";
type OpenUIErrorCode = ValidationErrorCode | "runtime-error" | "render-error" | "parse-exception"
  | "parse-failed" | "tool-not-found" | "tool-error" | "mcp-error";
interface OpenUIError { source: OpenUIErrorSource; code: OpenUIErrorCode; message: string;
  statementId?: string; component?: string; path?: string; toolName?: string; hint?: string }

declare enum BuiltinActionType { ContinueConversation = "continue_conversation", OpenUrl = "open_url" }
type ActionStep =
  | { type: "run"; statementId: string; refType: "query" | "mutation" }
  | { type: "continue_conversation"; message: string; context?: string }
  | { type: "open_url"; url: string }
  | { type: "set"; target: string; valueAST: ASTNode }
  | { type: "reset"; targets: string[] };
interface ActionPlan { steps: ActionStep[] }

interface EvaluationContext { getState(name: string): unknown; resolveRef(name: string): unknown;
  extraScope?: Record<string, unknown> }
interface SchemaContext { library: { components: Record<string, { props: { shape?: Record<string, unknown> } }> } }
interface ReactiveAssign { __reactive: "assign"; target: string; expr: ASTNode }
declare function isReactiveAssign(value: unknown): value is ReactiveAssign;
declare function evaluate(node: ASTNode, context: EvaluationContext, schemaCtx?: SchemaContext): unknown;
declare function stripReactiveAssign(value: unknown, context: EvaluationContext): unknown;
declare function evaluateElementProps(el: ElementNode, evalCtx: EvalContext): ElementNode;
interface EvalContext { ctx: EvaluationContext; library: Library; store: Store | null; errors?: OpenUIError[] }
interface StateField<T = unknown> { name: string; value: T; setValue: (v: T) => void; isReactive: boolean }
declare function resolveStateField<T = unknown>(name: string, bindingValue: unknown, store: Store | null,
  evaluationContext: EvaluationContext | null, fieldGetter: (n: string) => unknown,
  fieldSetter: (n: string, v: unknown) => void): StateField<T>;
```

`isASTNode` accepts exactly the 17 discrimants in `AST_KINDS`
(`Comp Ref StateRef RuntimeRef BinOp UnaryOp Ternary Member Index Assign Str Num Bool Null Arr Obj Ph`)
and requires a non-array object.
`walkAST` visits a node, then (in this order) `Comp.args` + `Object.values(Comp.mappedProps ?? {})`,
`Arr.els`, `Obj` values (not keys), `BinOp.left`/`right`, `UnaryOp.operand`, `Ternary.cond`/`then`/`else`,
`Member.obj`, `Index.obj`/`index`, `Assign.value`; leaves (`Str`, `Num`, `Bool`, `Null`, `Ref`, `Ph`,
`StateRef`, `RuntimeRef`) are visited only.

---

## 8. Error handling

**Parsing never throws.** `tokenize`, `parseExpression`, `split`, `autoClose`, `preprocess`,
`materialize*` are all total. The only throw path is `createParser(...).parse`, which wraps `parse`
in try/catch solely to record telemetry and **re-throw**; nothing inside was observed to throw for
any input tried (including `"("`, `")))"`, `"@"`, `"$ = 1"`, `"\u0000"`, `"root = Card([,])"`).
Verified: all such inputs return a normal `ParseResult`.

**Silently tolerated** (no error, no diagnostic):
- characters the tokenizer does not recognise (`;`, backtick, `\`, `^`, `~`, `@`/`$` without a name);
- lines without `=`, with a non-identifier LHS, or with an empty RHS;
- trailing tokens after a complete expression in a statement;
- missing `)`, `]`, `}`, `:` (filled by tolerant `eat`/`-> Null`);
- empty / dangling call arguments and array elements (`Null` nodes, usually pruned later);
- duplicate statement ids (last-wins one-shot, first-wins streaming);
- inline `Query`/`Mutation` in nested positions reports `inline-reserved` and yields `null`.
- `evaluate`'s missing default branch returns `undefined`; only an unmapped `Comp` warns
  (`console.warn("[openui] Unexpected unmapped Comp node: X")`).

**Reported as `ValidationError`** (in `meta.errors`) — six codes only:
`unknown-component`, `missing-required`, `null-required`, `inline-reserved`, `excess-args`,
`type-mismatch`. Each carries `{code, component, path (JSON-pointer-ish, "" at component level),
message, statementId}`. `statementId` is `ctx.currentStatementId`, which during a nested resolution is
the *referenced* statement (e.g. an unknown component inside `x = Nope([])` reports
`statementId: "x"` even though the root is `root`).

**Components dropped**: `unknown-component`, `inline-reserved` (inline query/mutation),
unresolvable `missing-required`/`null-required`, and `dropComponent` (required prop failed its type
check with no default) make `materializeValue` return `null`, so the parent receives `null` and, if it
was an array element of kind `Comp`/`Ref`, the element is removed from the array.

**`enrichErrors(validationErrors, schema, componentNames)`** (line 3111, deprecated) maps each
`ValidationError` to `OpenUIError`:
```js
{ source: "parser", code: ve.code, message: ve.message, component: ve.component,
  path: ve.path || undefined, statementId: ve.statementId, hint? }
```
`hint` is set for: `unknown-component` + non-empty `componentNames` →
`Available components: A, B`; `missing-required`/`null-required` → `buildSignatureHint` =
`Signature: Name(a*, b) — * marks required` (from `schema.$defs[component]`; `undefined` if the def
has no `properties`); `inline-reserved` → `Declare as a top-level statement: myVar = X(...)`.
Note the `path: ve.path || undefined` normalisation: for `excess-args` (`path: ""`) the enriched error
**loses** the `path` field (`JSON.stringify` drops `undefined`). Verified.

Runtime-side errors: `evaluateElementProps` catches per-prop evaluation failures and pushes
`{source:"runtime", code:"runtime-error", component, statementId, message: 'Evaluating prop "k" on X
failed: …', hint}`, keeping the original (unevaluated) prop value.

---

## 9. Serializer (`jsonToOpenUI`, line 3383)

```
jsonToOpenUI(json, library, options?):
  paramMap = compileSchema(library.toJSONSchema())
  collector = new StatementCollector()          // ordered, dedup by id
  rootExpr = serializeElementExpr(json, paramMap, collector)
  rootId   = json.statementId || "root"
  lines = [`${rootId} = ${rootExpr}`]
  for (stmt of collector.getStatements()) if (stmt.id !== rootId) lines.push(stmt.text)
  if (options?.stateDeclarations) lines.push(...serializeStateDeclarations(...))
  return lines.join("\n")
```

- `serializeElementExpr(node)` uses the catalog's param order and emits **positional** args, then
  pops trailing `"null"` args while the corresponding param is not required. Unknown `typeName` →
  `Object.values(node.props)` order.
- `serializeElementValue(node)`: if `node.statementId` is set, it registers
  `${statementId} = ${expr}` **on first use** and returns the bare id as a reference; otherwise it
  inlines the expression. `StatementCollector.register` is idempotent.
- `serializeASTNode` (line 3285): `Str`→`JSON.stringify(v)`, `Num`→`String(v)`, `Bool`, `Null`,
  `Ph`/`StateRef`/`RuntimeRef`/`Ref`→`n`, `Arr`→`[a, b]`, `Obj`→`{k: v}` (**unquoted keys**),
  `BinOp`→`l op r` with parentheses only when the child's precedence is strictly lower
  (`PRECEDENCE` map; there is no side-awareness, so `1 - (2 - 3)` — same precedence — is **not**
  parenthesised), `UnaryOp`→`op` + operand (no space/parens), `Ternary`→`c ? t : e` (no parens),
  `Member`→`obj.field`, `Index`→`obj[index]`, `Assign`→`target = value`, `Comp`→
  `@Name(args)` **iff `isBuiltin(name) && name !== "Action"`**, else `Name(args)`; default `"null"`.
- `serializeValue`: `null`/`undefined`→`"null"`, string→`JSON.stringify`, number→`String`,
  boolean, `ElementNode`→element path, `ASTNode`→`serializeASTNode`, array→`[...]`, plain object→
  `{k: v}`, else `"null"`.
- `serializeStateDeclarations`: `${name} = ${value}` for every entry whose value is **not `null`**
  (`continue` on null). Because auto-declared `$vars` are `null`, they are omitted; explicitly
  declared ones are re-emitted *after* the statements.

**Round-trip fidelity** (verified):
- Structural round-trip is lossless for pure-literal trees: `root = Card([a], "T")\na =
  TextContent("x")` serialises back to itself and re-parses to a deep-equal `ElementNode`.
  `root = Card([Header("h")])` likewise.
- `hasDynamicProps`/`partial` are recomputed on re-parse, not preserved.
- **Not lossless in general**:
  - duplicate/overwritten statements are lost (only the winning value survives);
  - expressions are re-serialised from the *materialised* tree, so `RuntimeRef`-based props lose their
    Query definition: a tree whose prop is `Member(RuntimeRef q, "a")` serialises to
    `root = Card([], q.a)` with **no `q = Query(...)` line** → re-parsing yields `Ph("q")` and no
    query statement (verified);
  - `partial` trees can serialise to text that parses differently;
  - `Obj` keys are always unquoted, so non-identifier keys produce source the parser reads as a
    different key (`"?"`);
  - `BinOp` parenthesisation is precedence-only (associativity can change on re-parse);
  - `Ph` serialises as its bare name (a `Ref` on re-parse).
- **`mergeStatements(existing, patch, rootId = "root")`** (line 3221) is the companion patcher:
  `splitStatementSource` (string/bracket-aware line splitter), then per patch statement:
  `ast.k === "Null"` ⇒ **delete** that id (and its position), else override/replace in place; new ids
  append in patch order. Then `gcUnreachable(order, merged, asts, rootId)` walks `Ref`/`RuntimeRef`
  from `rootId` (no-op if there is no `rootId` statement), keeps every id starting with `$`, and drops
  everything else. Empty `existing` ⇒ returns the patch verbatim; empty `patch` ⇒ returns `existing`.
  The patch is `stripFences`d first (not comment-stripped).
  Verified: `merge('root = Card([x])\nx = TextContent("a")\ndead = TextContent("d")',
  'x = TextContent("c")')` → `root = Card([x])\nx = TextContent("c")` (dead GC'd);
  `patch 'x = null'` deletes `x`, leaving `root = Card([x])` (now a dangling ref);
  `'root = Card([])'` as patch GCs the orphaned `x`.

---

## 10. Worked examples (raw observed output)

Schema used for all of these (`$defs` key order matters for positional mapping):

```json
{"Card":      {"properties":{"children":{"type":"array"},"title":{"type":"string"},
                             "subtitle":{"type":"string"},"items":{"type":"array"},
                             "count":{"type":"number"},"visible":{"type":"boolean"},
                             "mode":{"enum":["a","b"]},"withDefault":{"type":"string","default":"D"}},
               "required":["children"]},
 "TextContent":{"properties":{"text":{"type":"string"},"size":{"type":"string"}},"required":["text"]},
 "Header":    {"properties":{"title":{"type":"string"},"subtitle":{"type":"string"}},"required":["title"]}}
```

Abbreviated to `root=<typeName>{props} u=[unresolved] o=[orphaned] n=count e=[errors]`;
`partial`/`incomplete` shown explicitly where they matter.

### E1 — valid, hoisted forward reference
`root = Card([x])\nx = TextContent("hi")`
```
root=Card{children:[{type:element,typeName:TextContent,props:{text:"hi"},partial:false,
        hasDynamicProps:false,statementId:"x"}]} partial=false hd=false statementId="root"
u=[] o=[] n=2 e=[] incomplete=false stateDeclarations={} queries=[] mutations=[]
```
Identical result for the reversed order (`x` first) — hoisting confirmed.

### E2 — undefined reference in a prop
`root = Card([x])` (no `x`)
```
root=Card{children:[]} u=["x"] o=[] n=1 e=[] incomplete=false
```
`Card([missing])` → same, `u=["missing"]`. The unresolved `Ref` became `null` and was dropped from the
array (arrays drop `Comp`/`Ref` results that materialise to `null`).

### E3 — undefined reference inside a runtime expression (survives as `Ph`)
`root = Card([], a.b.c[0].d)`
```
root=Card{children:[],title:{k:"Member",field:"d",obj:{k:"Index",index:{k:Num,v:0},
   obj:{k:"Member",field:"c",obj:{k:"Member",field:"b",obj:{k:Ph,n:"a"}}}}}}
u=["a"] o=[] n=1 e=[] incomplete=false
```
Evaluating that `Member` chain with an undefined `a` returns `null`.

### E4 — cycle
`x = y\ny = x\nroot = Card([x])`
```
root=Card{children:[]} u=["x"] o=[] n=3 e=[] incomplete=false
```
(`resolveRef("x")` → visited contains `x` → `Ph`/`null` + `unresolved`.) Self-nesting
`root = Card([a])\na = Card([b])\nb = Card([a])` yields a two-level tree with the innermost children
`[]` and `u=["a"]`.

### E5 — partial stream, character by character (extract)
Program `root = Card([a, b])\na = TextContent("Hello")\nb = TextContent("World")`
```
after "root = Card("        root=null  inc=true  n=1
      e=[{code:"missing-required",component:"Card",path:"/children",
          message:'missing required field "/children" — signature: Card(children*: array, title: string, …)'}]
after "root = Card(["       root=Card{children:[]} partial=true inc=true n=1
after "root = Card([a"      root=Card{children:[]} partial=true inc=true u=["a"]
after "root = Card([a, b]"  root=Card{children:[]} partial=true inc=true u=["a","b"]
after "root = Card([a, b])" root=Card{children:[]} partial=false inc=false u=["a","b"]
after "\na"                 n=1 (still pending)
after "\na = T"             root=Card{children:[]} n=2 u=["T","b"]
after '\na = TextContent("Hel' root=Card{children:[TextContent{text:"Hel"}]} partial=true inc=true u=["b"]
after '\na = TextContent("Hello")\n' root=Card{children:[TextContent{text:"Hello"}]} partial=false inc=false u=["b"]
…final: root=Card{children:[TextContent{text:"Hello"},TextContent{text:"World"}]} n=3 u=[]
```
Feeding all characters through `push` then `getResult()` is **byte-identical** to the one-shot parse.

### E6 — unterminated string / unbalanced brackets (autoClose)
| input | `autoClose` | parse result |
|---|---|---|
|`root = Card([`|`root = Card([])`, `true`|`Card{children:[]} partial=true incomplete=true`|
|`root = Card([a], "unterminated`|`root = Card([a], "unterminated")`, `true`|`Card{children:[],title:"unterminated"} partial=true incomplete=true`|
|`root = Card([{"`|`root = Card([{}])`, `true`|`Card{children:[{}]}`|
|`root = Card([{a: [`|`root = Card([{a: []}])`, `true`|nested empty array|
|`root = Card([)`|`root = Card([)])`, `true`|`Card{children:[]} partial=true incomplete=true` (mismatch ignored)|
|`root = Card([)]`|`root = Card([)])`, `true`|same|
|`root = Card([})`|`root = Card([})])`, `true`|same|
|`root = Card("a"`|`root = Card("a")`, `true`|`Card{children:"a"}` → `type-mismatch /children`|
|`root = Card([])`|unchanged, `false`|complete|
`root = Card([], "a\\` → `root = Card([], "a\\")` — title `a\`.

### E7 — tokenizer spot checks
```
"a = 1"                 → [{t:16,v:"a"},{t:9},{t:15,v:1},{t:13}]
"$x = $y"               → [{t:18,v:"$x"},{t:9},{t:18,v:"$y"},{t:13}]
"@Count(a)"             → [{t:35,v:"Count"},{t:1},{t:16,v:"a"},{t:2},{t:13}]
"1 -2 - 2 a-2"          → [Num 1, Minus, Num 2, Minus, Minus, Num 2, Ident a, Minus, Num 2]
"[-2] x[-1] - 2"        → [LBrack, Num(-2), RBrack, Ident x, LBrack, Num(-1), RBrack, Minus, Num 2]
"a & b"                 → [{t:16},{t:31},{t:16},{t:13}]         // single & becomes &&
'"unterminated'         → [{t:14,v:"unterminated"},{t:13}]
'"a\\qb"'               → [{t:14,v:"a\\qb"}]                     // JSON.parse failed → raw fallback
"'a\\zb'"               → [{t:14,v:"azb"}]                        // manual escapes drop the backslash
"1e"                    → [{t:15,v:NaN},{t:13}]
"0x10"                  → [{t:15,v:0},{t:16,v:"x10"},{t:13}]
"1."                    → [{t:15,v:1},{t:19},{t:13}]
"//comment\nroot = …"   → [{t:23},{t:23},{t:16,v:"comment"},{t:0},…]  // tokenize sees comments!
```
(The last line matters: comment stripping happens in `preprocess`, **not** in `tokenize`.)

### E8 — split
```
"a = 1\nb = 2"                    → [{id:"a",idTokenType:16,tokens:[Num 1]},
                                     {id:"b",idTokenType:16,tokens:[Num 2]}]
"a = 1\n\nb = 2"                  → same
"a = Card([\n1,\n2\n])\nb = 2"    → [{id:"a",tokens:[Type Card,LParen,LBrack,Num1,Comma,Num2,RBrack,RParen]},
                                     {id:"b",…}]
"garbage line\na = 1"             → [{id:"a",…}]
"a\nb = 2"                        → [{id:"b",…}]
"a == 1"                          → []
"= 5"                             → []
"@Count = 1"                      → []
"a = 1 b = 2"                     → [{id:"a",tokens:[Num1,Ident b,Equals,Num2]}]
"a = 1\nb = 2\ntrailing ="        → [a, b]           // emptied statement dropped
"a = x ? y : z\n…"                → single statement with all 5 tokens
"a = x ?\ny :\nz\nb = 2"          → a's tokens = [x, ?, y, :]   (else branch lost; z discarded)
```

### E9 — invalid input is tolerated (never throws)
```
"root = Card([], = )"    → Card{children:[],title:null} n=1 e=[]
"root = Card([,])"       → Card{children:[null]}        n=1 e=[]
"root = Card([], )"      → Card{children:[]}            n=1 e=[]
"root = Card([], \"a\" \"b\")" → Card{children:[],title:"a",subtitle:"b"}  (adjacent args, no comma)
"))))"                   → root=null, statementCount=0, incomplete=false
"$ = 1"                  → statementCount 0  ($ dropped, "= 1" has no valid LHS)
"root = Card([], 1 /* c */)" → title={k:BinOp,op:"/",left:Num 1,right:Null},
                               subtitle={k:BinOp,op:"*",left:Ph c,right:Null}, u=["c"]
"```js\nroot = Card([])\n```\n```\nx = 1\n```" → root=Card, o=["x"], n=2
"root = Card([])\n```"   → root=null, incomplete=true   (fence logic: block body becomes "")
```

### E10 — validation / promotion
```
schema Card(children*, title, subtitle, items, count, visible, mode:"a"|"b", withDefault="D")
'root = Card([], "T", "S", [], 3, true, "zz")'
   → root=Card{children:[],title:"T",subtitle:"S",items:[],count:3,visible:true}   // "zz" pruned
     e=[{code:"type-mismatch",component:"Card",path:"/mode",
         message:'field "/mode" expects one of ["a", "b"] but got "zz"',statementId:"root"}]
'root = Card([], "T", "S", [], "notnum")'
   → count deleted; e=[{code:"type-mismatch",path:"/count",
         message:'field "/count" expects number but got string'}]
'root = Card([], "T", "S", [], 3, true, "a", "D", "extra")'
   → e=[… {code:"excess-args",path:"",message:"Card takes 8 arg(s), got 9 (1 excess dropped)"}]
'root = Card()'  → root=null; e=[{code:"missing-required",path:"/children",
                       message:'missing required field "/children" — signature: …'}]
'root = Card([], {a: 1})' → title is an object → type-mismatch /title, title deleted
'root = Nope([])' → root=null; e=[{code:"unknown-component",component:"Nope",path:"",
                       message:'Unknown component "Nope" — not found in catalog or builtins. Available components: …'}]
'root = Card([], Query("t", {}, {}))' → title=null; e=[{code:"inline-reserved",component:"Query",path:"",…}]
required-with-default: W(a*, b*="B") → 'W()' → null + missing-required "/a" (b would have defaulted);
                       'W("x")' → {a:"x",b:"B"}; 'W(null)' → null + null-required "/a";
                       'W(1)' with a default on a → {a:"A"} + type-mismatch
```

### E11 — Query/Mutation extraction and state auto-declaration
```
'q = Query("tool", {a: $x}, {rows: []}, 30)'
 → queryStatements=[{statementId:"q",
      toolAST:{k:"Str",v:"tool"},
      argsAST:{k:"Obj",entries:[["a",{k:"StateRef",n:"$x"}]]},
      defaultsAST:{k:"Obj",entries:[["rows",{k:"Arr",els:[]}]]},
      refreshAST:{k:"Num",v:30}, deps:["$x"], complete:true}]
   stateDeclarations={"$x":null}          // auto-declared
   mutationStatements=[]
'root = Card([], $undeclared)'
 → props.title={k:"StateRef",n:"$undeclared"}, stateDeclarations={"$undeclared":null}
'$count = $count + 1' + root
 → stateDeclarations={"$count":{k:"BinOp",op:"+",left:{k:"StateRef",n:"$count"},right:{k:"Num",v:1}}}
'Action([@ToAssistant("m"), @OpenUrl("u"), @Set($a,1), @Reset($b)])' (evaluated at runtime)
 → {steps:[{type:"continue_conversation",message:"m",context:undefined},
           {type:"open_url",url:"u"},
           {type:"set",target:"$a",valueAST:{k:"Num",v:1}},
           {type:"reset",targets:["$b"]}]}
```

### E12 — entry-point selection
```
schema $defs {Root, Card, TextContent}; no statement named "root" except where noted
'main = Card([])'                       → root=Card@main              (rule 4: first component statement)
'a = 1\nb = 2'                          → root=null, o=["b"]          (rule 5, non-element → null)
'a = 1\nb = Card([])'                   → root=Card@b,   o=["a"]
'z = TextContent("z")\nmain = Card([z])' with rootName="main" → root=Card@main
'ROOT = Card([])'                       → root=Card@ROOT              (rule 4, case-sensitive)
'root = TextContent("t")\nroot = Card([])' → root=Card{children:[]} n=1 (last-wins, one-shot)
'root = Card([])\nroot = Card([], "T")'    → one-shot root has title "T", n=1
                                            streaming root has NO title,  n=2 (first-wins)
```

### E13 — serialization
```
jsonToOpenUI(Card{children:[TextContent{text:"x"}],title:"T"} @root, library)
  → "root = Card([a], \"T\")\na = TextContent(\"x\")"
  reparses to the same ElementNode (deep-equal, verified true)
jsonToOpenUI(Card{children:[Header{title:"h"}]} @root)   → "root = Card([Header(\"h\")])"
jsonToOpenUI(root with title = Member(RuntimeRef(q),"a")) → "root = Card([], q.a)"   // q = Query(…) LOST
jsonToOpenUI(root with title = StateRef($a), stateDeclarations={"$a":5})
  → "root = Card([], $a)\n$a = 5"      (re-parses with $a = 5)
jsonToOpenUI(root with title = StateRef($x), stateDeclarations={"$x":null})
  → "root = Card([], $x)"              (null-valued state lines skipped)
jsonToOpenUI(root with title = BinOp(+,1,2), stateDeclarations={"$n":BinOp(+,1,2)})
  → "root = Card([])\n$n = 1 + 2"
```

### E14 — `mergeStatements` (patch/GC)
```
('root = Card([x])\nx = TextContent("a")', 'x = TextContent("b")')
  → 'root = Card([x])\nx = TextContent("b")'
('root = Card([x])\nx = TextContent("a")', 'root = Card([y])\ny = TextContent("n")')
  → 'root = Card([y])\ny = TextContent("n")'      // old x GC'd
('root = Card([x])\nx = TextContent("a")', 'x = null')
  → 'root = Card([x])'                            // deletion leaves a dangling ref
('root = Card([x])\nx = TextContent("a")\ndead = TextContent("d")', 'x = TextContent("c")')
  → 'root = Card([x])\nx = TextContent("c")'      // dead GC'd
('root = Card([x])\nx = TextContent("a")', 'zzz = 1')
  → unchanged (zzz unreachable → GC'd immediately)
('$v = 1\nroot = Card([x])\nx = TextContent("a")', 'root = Card([])')
  → '$v = 1\nroot = Card([])'                     // $ names always survive
('root = Card([x])\nx = TextContent("a")', '```\nx = TextContent("z")\n```')
  → 'root = Card([x])\nx = TextContent("z")'
```

---

## 11. Reimplementation checklist / gotchas

1. `preprocess` (fence extraction → line comments) runs **before** `autoClose`/`tokenize`;
   `tokenize` itself has no comment or fence awareness.
2. `autoClose` works on characters, matches bracket *kinds* only for popping, and closes in reverse
   stack order; `wasIncomplete` = "quote open OR stack non-empty".
3. Newlines are lexical tokens; `split` uses bracket depth **and** a ternary counter; blank lines and
   invalid lines are dropped.
4. `parseExpression` is total, precedence-climbing, and silently truncates on unexpected tokens;
   `(` … `)` grouping returns the inner node, `:` is `eat`-tolerant, `.` consumes one token even when
   it is not a valid field.
5. `$name` is one token including the `$`; `$name = expr` in expression position is `Assign`, not a
   statement; a statement `$name = expr` is `kind:"state"` keyed by `"$name"`.
6. Builtins are ordinary `Comp` nodes with the `@` stripped; `Action` may appear with or without `@`;
   `@Name` without `(` is a `Ref` to `Name`.
7. Hoisting is full; cycles are cut by a path-stack (`visited`) that also produces `unresolved`
   duplicates; unresolved refs are `null` in value position and `Ph` in expression position; arrays
   drop null-valued `Comp`/`Ref` elements.
8. Evaluation-tree lowering (positional→named via `$defs` key order, validation, default filling,
   component dropping) is *parser* work, not runtime work; `partial` only relaxes nested required-key
   and enum checks.
9. One-shot is last-statement-wins for duplicate ids; streaming is first-wins and can over-count
   `statementCount`.
10. `jsonToOpenUI` is not a faithful inverse for dynamic/duplicate/query-backed trees.
