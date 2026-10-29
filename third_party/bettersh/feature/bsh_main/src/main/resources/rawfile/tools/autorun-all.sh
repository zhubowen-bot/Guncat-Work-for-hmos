#!/bin/sh
# autorun-all.sh — BetterSH 无人值守自检  v4(**完整版,入库留档**)
#
# 怎么跑:它**只入库留档,不随会话落盘也不自动跑**(shell.cpp 里那句 CopyRawFile 已注释)。
# 要用的话,把 rawfile 里这份拷到设备 $HOME 再跑 —— 或者把 shell.cpp 那句放开。
#     sh $HOME/autorun-all.sh > $HOME/autorun-all.log 2>&1     (stdin 自己接 /dev/null)
# 结果看 $HOME/autorun-all.log;末行 "=== autorun 结果: PASS=n FAIL=n ===" 便于 grep。
# 日常只跑精简版(不弹框、几十秒):tools/autorun.sh,启动时自动跑、日志 $HOME/autorun.log。
#
# ⚠ 本脚本里的个别小节会**触发"是否运行 xxx"确认框** → 会把整个应用冻住,跑之前
#   心里有数(见 scripts/glibc-ohos/README §7)。
#
# ── 版本演进(每一版都是被上一版自己的毛病逼出来的) ─────────────────────
#   v1 → v2:加 [RUN] 进度标记(卡住时日志停在哪一步一目了然);
#           不再用 awk/readelf/tr/basename(不在命令表或没编进 toybox);
#           不再信 `command -v`(命令表给每个条目在 $HOME/.applets 建占位文件,
#           PATH 命中占位就算"可达",但 applet 可能压根没编进去)。
#   v2 → v3:所有可能挂住的命令都套 timeout,输出落临时文件再读 ——
#           直接 $(...) 抓的话,被 timeout 杀掉的父进程身后若有残留孙进程还占着
#           管道写端,读端会一直等到那个孙进程退出,timeout 就白加了。
#   v3 → v4:两个致命修正 + 一次重排。
#     1) **`timeout` 这个裸名字根本不可用**:命令表没注册它,PATH 里也只有一个
#        $HOME/.applets 占位以外什么都没有 → 落到 elfloader 去开 /bin/timeout,
#        报 "cannot read /bin/timeout or ldso ld-musl-aarch64.so.1",rc=127。
#        v3 里所有 tryrun 因此全部空转,断言集体失真。v4 一律走 `toybox timeout`
#        (TOY_TIMEOUT=y 已编进 libtoybox.so),并在最前面探测它是否真能用。
#     2) **每次 tryrun 用一个新的输出文件**。原因:procmgr 里真正跑 guest 的是
#        主进程 fork 出来的孙进程,不在 toybox timeout 的进程组里 —— timeout
#        超时只能杀掉中间那层,孙进程会活下来继续往它继承的 fd 里写。若输出文件
#        被复用(inode 相同),残留写入会污染后面所有断言。每次新建文件后,残留
#        进程手里的 fd 指向已被 unlink 的旧 inode,写进去也看不到了。
#     3) 六个 ABI 组合件(最可能挂住的一节)挪到**最后**,这样即使它挂死,
#        前面的结论也已经完整落盘。
#
# 已知事实(不要当成 bug 再报):
#   - awk / tr / stty 三个 applet **没编进** toybox(.config 里是 not set),
#     但命令表注册了它们 → `command -v` 为真、敲下去是 "Unknown command"。
#   - basename / readelf / timeout 编进去了,但**命令表没注册** →
#     只能 `toybox basename …` 这样用,裸敲走 PATH 会失败。
#   - bshutil(含 procmgr 的 ps/kill 能力)是最外层 mini shell 的内建,
#     mksh 里不可达。

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "[PASS] $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "[FAIL] $*"; }
info() { echo "[INFO] $*"; }
run()  { echo "[RUN ] $*"; }
sec()  { echo; echo "──── $(date +%T)  $* ────"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1 = $2"; else bad "$1 = $2(期望 $3)"; fi; }
cnt()  { set -- $("$@" 2>/dev/null | wc -l); echo "${1:-0}"; }
# 每节末尾打一条小计:v4 第一轮跑到第 8 节被卡住,前面 20 多分钟的结论差点白跑 ——
# 有了小计,即使后面挂死,日志里也留得住到那一刻为止的账。
tally() { echo "[小计] PASS=$PASS FAIL=$FAIL  ($(date +%T))"; }

HOME_DIR="$HOME"
cd "$HOME_DIR" || exit 1
OUTN=0
OUT="$HOME_DIR/zz-out.0"
TMOUT_CAP=90                 # 单个 guest 的硬上限(秒)

echo "=== BetterSH autorun v4 ==="
date
echo "HOME=$HOME_DIR  PWD=$(pwd)"
echo "PATH=$PATH"
if [ -f "$HOME_DIR/bettersh.conf" ]; then
    echo "--- bettersh.conf ---"
    head -10 "$HOME_DIR/bettersh.conf"
else
    info "还没有 bettersh.conf(没改过任何设置)"
fi

# 跑一条命令,输出落新文件、超时保护。结果:rc 变量 + $OUT 文件内容
tryrun() {
    # 内部变量用 _tmo_ 前缀:以前这里叫 t,会把**调用方的同名变量**覆盖掉
    # (探针循环 `for t in …` 就中过招 —— 循环后半段探的全是超时值)。
    _tmo_="$1"; shift
    OUTN=$((OUTN + 1))
    OUT="$HOME_DIR/zz-out.$OUTN.txt"
    rm -f "$OUT"
    if [ -n "$TOY_PREFIX_OK" ]; then
        toybox timeout "$_tmo_" "$@" > "$OUT" 2>&1 < /dev/null
    else
        "$@" > "$OUT" 2>&1 < /dev/null
    fi
    rc=$?
}
out_last() { tail -1 "$OUT" 2>/dev/null; }
out_head() { head -1 "$OUT" 2>/dev/null; }

# ══════════════════════════════════════════════════════════════════
sec "0. 工具事实核对(v4 的地基,先确认再往下跑)"
# ── 0.1 toybox 前缀的 timeout 能不能用 ──
run 'toybox timeout 可用性'
TOY_PREFIX_OK=""
tryrun 3 toybox timeout 2 true
if [ "$rc" = 0 ]; then
    TOY_PREFIX_OK=1
    ok "toybox timeout 可用(后面所有超时都用它)"
else
    bad "toybox timeout 不可用(rc=$rc)→ 后续**没有超时保护**,可能挂住"
fi
# bare timeout 的真相,顺便记一笔
run '裸 timeout(预期:不可用)'
tryrun 5 timeout 2 true
info "裸 timeout → rc=$rc,输出=[$(out_head)]"

# ── 0.2 toybox applet 逐个探活(判据:输出里有没有 "Unknown command") ──
PROBE_ERR="$HOME_DIR/zz-probe.err"
applet_exists() {
    toybox "$1" --zzz-probe > /dev/null 2> "$PROBE_ERR" < /dev/null
    grep -q 'Unknown command' "$PROBE_ERR" 2>/dev/null && return 1
    return 0
}
run 'toybox applet 探活(命令表注册的 + 几个实用的)'
# 注意剔除 toybox 自身:它是 multicall 入口,`toybox toybox <任意参数>` 会被
# 当成"要跑名叫 <参数> 的 applet",必然回 "Unknown command",探活结论会假阳性。
PROBE_LIST="ls cat echo grep egrep fgrep sed awk cp mv rm mkdir rmdir touch ln
            chmod chown head tail wc sort uniq tr cut tee xargs find which env
            printenv pwd true false sleep date uname id whoami ps kill free df du
            tar clear reset stty mount umount gzip gunzip zcat wget ping netstat
            ifconfig timeout basename readelf"
probe_total=0; probe_have=0; probe_missing=""
for a in $PROBE_LIST; do
    probe_total=$((probe_total + 1))
    if applet_exists "$a"; then
        probe_have=$((probe_have + 1))
    else
        probe_missing="$probe_missing $a"
    fi
done
info "探活结果:$probe_have/$probe_total 个 applet 在 libtoybox.so 里"
if [ -n "$probe_missing" ]; then
    info "缺失:$probe_missing"
else
    info "缺失:(无)"
fi
EXPECT_MISSING=" awk tr stty"
if [ "x$probe_missing" = "x$EXPECT_MISSING" ]; then
    ok "缺失集合与预期一致(只有 awk/tr/stty —— .config 里这三个是 not set)"
else
    bad "缺失集合与预期不符(预期只有 'awk tr stty')"
fi

# ── 0.3 注册名(.applets 占位)与真实可达性 ──
run '占位文件 vs 真能跑(command -v 会撒谎)'
ph=$(ls "$HOME_DIR/.applets" 2>/dev/null | wc -l | sed 's/ //g')
info "\$HOME/.applets 占位文件数:${ph:-0}"
for a in tr basename readelf timeout; do
    have="no"; command -v "$a" > /dev/null 2>&1 && have="yes"
    info "command -v $a → $have"
done
tryrun 10 awk 'BEGIN{print 1}'
info "裸 awk → rc=$rc,输出=[$(out_head)]"
tryrun 10 toybox awk 'BEGIN{print 1}'
info "toybox awk → rc=$rc,输出=[$(out_head)]"
tryrun 10 toybox basename /a/b
info "toybox basename /a/b → rc=$rc,输出=[$(out_last)]"

if command -v bshutil > /dev/null 2>&1; then
    run 'bshutil caps'
    tryrun 20 bshutil caps
    head -5 "$OUT" | sed 's/^/       /'
else
    info "bshutil 在 mksh 里不可达(它是最外层 mini shell 的内建;已知)"
fi

# ── 0.4 嵌套 exec 专项(2026-09-28 那轮自检暴露的问题面) ──
# 外层命令由 mksh 起(它自己按 PATH 解析,会选中 $HOME/.applets/<名字> 这个占位
# 文件,再经委托层回到命令表),而命令 so **内部**再 exec(如 toybox 的 timeout/
# xargs、clang 起 cc1)走的是委托层里的 path_search —— 它只认 ELF,跳过占位文件,
# 于是会命中 PATH 上的**同名真实文件**(/bin/sh、/bin/awk、/data/service/hnp/bin/
# fastfetch…),把命令表优先级顶掉,最后 elfloader 报
#   cannot read /bin/sh or ldso ld-musl-aarch64.so.1
# 所以这一节**专门测"在 toybox 里再起一个进程"**,它和"直接敲"是两条不同的路。
sec "0.4 嵌套 exec(命令 so 内部再 exec;与『直接敲』是两条不同的路)"
# nest:同一条命令跑两遍 —— 一遍由 mksh 直接起,一遍由 toybox(timeout)内部再起。
# 只要求**两边结果一致**;不一致就说明嵌套那条路解析错了。
nest() {
    run "直接 vs 嵌套:$*"
    tryrun 20 "$@"
    direct_rc=$rc
    OUTN=$((OUTN + 1)); OUT="$HOME/zz-out.$OUTN.txt"; rm -f "$OUT"
    toybox timeout 20 "$@" > "$OUT" 2>&1 < /dev/null
    nest_rc=$rc
    if [ "$direct_rc" = "$nest_rc" ]; then
        ok "$* 两条路一致(rc=$direct_rc)"
    else
        bad "$* 直接=$direct_rc 嵌套=$nest_rc  ← 嵌套末行: $(out_last)"
    fi
}
nest sh -c 'exit 7'
nest ls /
nest toybox
nest cat hello.c
nest echo hi
nest fastfetch --version
tally

# ══════════════════════════════════════════════════════════════════
sec "1. cwd 语义(修过的那对 bug)"
run '外层与 mksh 内的 cd/pwd/ls 对照'
mkdir -p "$HOME_DIR/zz-cwd-test" 2>/dev/null
echo one > "$HOME_DIR/zz-cwd-test/a.txt"
echo two > "$HOME_DIR/zz-cwd-test/b.txt"
cd "$HOME_DIR/zz-cwd-test" || exit 1
chk "外层 cd 后 pwd 末段" "${PWD##*/}" "zz-cwd-test"
chk "外层 cd 后 ls 条目数" "$(cnt ls)" "2"
tryrun 30 sh -c 'cd "$HOME/zz-cwd-test" && ls | wc -l'
chk "mksh 内 cd 后 ls 条目数(末行)" "$(out_last | sed 's/ //g')" "2"
tryrun 30 sh -c 'cd "$HOME/zz-cwd-test" && pwd'
chk "mksh 内 pwd(末行)" "$(out_last)" "$HOME_DIR/zz-cwd-test"
tryrun 30 sh -c 'cd "$HOME/zz-cwd-test" && cat a.txt'
chk "mksh 内相对路径读文件(末行)" "$(out_last)" "one"
cd "$HOME_DIR" || exit 1
tally

# ══════════════════════════════════════════════════════════════════
sec "2. 基础盘(管道/重定向/环境)"
run '管道与重定向'
chk "echo|wc 管道" "$(echo hi | wc -l | sed 's/ //g')" "1"
echo xyz > "$HOME_DIR/zz-a.txt"
chk "重定向写读" "$(cat "$HOME_DIR/zz-a.txt")" "xyz"
tryrun 20 uname -a
info "uname: $(out_head)"
info "ls / 条目数(仅记录): $(cnt ls /)"
tally

# ══════════════════════════════════════════════════════════════════
sec "3. 终端内编译链(180s)"
run 'clang hello.c -o $HOME/zz-h'
if command -v clang > /dev/null 2>&1; then
    rm -f "$HOME_DIR/zz-h"
    tryrun 180 clang hello.c -o "$HOME_DIR/zz-h"
    if [ -f "$HOME_DIR/zz-h" ]; then
        ok "clang 编译通过(rc=$rc,$(wc -c < "$HOME_DIR/zz-h" | sed 's/ //g') 字节)"
        tryrun 30 "$HOME_DIR/zz-h"
        hout=$(grep -av '^\[elf\]' "$OUT" | head -1)
        case "$hout" in *hello*) ok "产物可执行:$hout" ;; *) bad "产物输出异常:$hout" ;; esac
        run 'toybox readelf 验 ELF 类型(static-pie 应为 DYN)'
        tryrun 30 toybox readelf -h "$HOME_DIR/zz-h"
        info "readelf rc=$rc: $(grep -a 'Type' "$OUT" | head -1)"
        tryrun 30 python3 -c "d=open('$HOME_DIR/zz-h','rb').read(20);print({2:'EXEC',3:'DYN'}.get(int.from_bytes(d[16:18],'little'),'?'))"
        chk "产物 ELF 类型(python 读头,static-pie 应为 DYN)" "$(out_last)" "DYN"
    else
        bad "clang 编译失败(rc=$rc):$(out_head)"
    fi
else
    # 包内不再内置 clang/lld（1533e62 移出 HAP，改由 pkg 装 ohos-sdk-prune）。
    # "没装"不是编译链坏了 —— 记 info 不计 FAIL，否则这条会一直是常驻假失败，
    # 真出问题时反而看不出来。要覆盖本档就先在终端里 `pkg install ohos-sdk-prune`。
    info "clang 未安装(包内不再内置，需 pkg install) → 本档跳过"
fi
tally

# ══════════════════════════════════════════════════════════════════
sec "4. python3(含 zip 能力;60s)"
run 'python3 算术 / import / zip 往返'
if command -v python3 > /dev/null 2>&1; then
    tryrun 60 python3 -c 'print(1+1)'
    chk "python3 算术" "$(out_last)" "2"
    mods_ok=1
    for m in zipfile tarfile json hashlib struct; do
        tryrun 30 python3 -c "import $m"
        if [ "$rc" != 0 ]; then bad "import $m 失败(rc=$rc):$(out_last)"; mods_ok=0; fi
    done
    [ "$mods_ok" = 1 ] && ok "import zipfile/tarfile/json/hashlib/struct"
    rm -rf "$HOME_DIR/zz-zip" "$HOME_DIR/zz.zip"
    tryrun 60 python3 -m zipfile -c "$HOME_DIR/zz.zip" hello.c
    zip_rc=$rc
    tryrun 60 python3 -m zipfile -e "$HOME_DIR/zz.zip" "$HOME_DIR/zz-zip"
    if [ "$zip_rc" = 0 ] && [ "$rc" = 0 ]; then
        if [ "$(cat hello.c)" = "$(cat "$HOME_DIR/zz-zip/hello.c" 2>/dev/null)" ]; then
            ok "zip 打包+解包内容一致"
        else
            bad "zip 解包内容不一致"
        fi
    else
        bad "python3 -m zipfile 失败(打包 rc=$zip_rc / 解包 rc=$rc)"
    fi
    for m in bz2 lzma zlib; do
        tryrun 30 python3 -c "import $m"
        if [ "$rc" = 0 ]; then info "python 模块 $m: 有"; else info "python 模块 $m: 无(rc=$rc)"; fi
    done
else
    bad "python3 不可达"
fi
tally

# ══════════════════════════════════════════════════════════════════
sec "5. 其它命令 so 冒烟(各 30s;一律不给可能被当成主机的参数)"
smoke() {
    c="$1"; shift
    run "$c $*"
    if command -v "$c" > /dev/null 2>&1; then
        tryrun 30 "$c" "$@"
        h1=$(out_head)
        if [ "$rc" = 0 ]; then
            ok "$c 可运行(rc=0): $h1"
        else
            bad "$c 退出码 $rc:$h1"
        fi
    else
        info "$c 不可达(跳过)"
    fi
}
smoke vim --version
smoke fastfetch --version
# ssh 单独判:dropbear 无参数时**打 usage 并 exit 1**(这是它本来就有的行为),
# 所以不能套"rc 必须 0"的 smoke —— 修好退出码透传之后它反而会"看起来失败"。
# 这里只要求打出 banner。
run 'ssh -V'
if command -v ssh > /dev/null 2>&1; then
    tryrun 30 ssh -V
    if grep -aq 'Dropbear' "$OUT"; then
        ok "ssh 可运行(rc=$rc): $(out_head)"
    else
        bad "ssh 没打出 banner(rc=$rc):$(head -2 "$OUT" | tr '\n' ' ')"
    fi
else
    info "ssh 不可达(跳过)"
fi
smoke toybox
# Node.js(2026-09-28 新加的移植;入口 bsh_node_main + exec 委托见 build_node.sh)
smoke node --version
tryrun 60 node -e 'console.log("node ok", process.version, 1+1)'
if [ "$rc" = 0 ]; then ok "node -e → $(out_last)"; else bad "node -e rc=$rc: $(out_head)"; fi
# 注意断言要落在**输出**上:node 抛未捕获异常时会打一页错误 + 末行 "Node.js v18.x.x",
# 只判 rc==0 会被"退出码丢成 0"骗过去(第一轮就这么假 PASS 过一次)。
tryrun 60 node -e 'const {execSync}=require("child_process"); console.log("child:", execSync("echo hi").toString().trim())'
if grep -aq 'child: hi' "$OUT"; then
    ok "node child_process → $(grep -a 'child: hi' "$OUT" | head -1)"
else
    bad "node child_process(rc=$rc)输出里没有 'child: hi';末 12 行:$(tail -12 "$OUT" | sed 's/^/ | /')"
fi

# npm:入口是 JS(bsh_npm_main 拼成 [node, <资源根>/npm/bin/npm-cli.js, …]),
# JS 树由 shell.cpp 的 UnpackRes 从 rawfile/tools/npm.tar 解到**资源根**($BSH_SYSROOT,
# 见 common/bsh_paths.h;不是 $HOME)。
tryrun 30 node -e 'console.log(process.execPath)'
info "process.execPath = $(out_last)(npm 起 lifecycle 脚本就靠它)"
smoke npm --version
tryrun 30 npm config get registry
info "npm registry = $(out_last)"
run 'npm 端到端:无依赖包 + prepare 脚本'
rm -rf "$HOME/zz-npm"
mkdir -p "$HOME/zz-npm"
# 不能用 printf:mksh 这里没有 printf 内建,裸名会落到 /bin/printf(系统符号
# 链接)→ elfloader 报 cannot read,package.json 变空,npm 报 EJSONPARSE。
echo '{"name":"zz-npm","version":"1.0.0","scripts":{"prepare":"echo npm-lifecycle-ok"}}' \
    > "$HOME/zz-npm/package.json"
# 注意不能在子 shell 里调 tryrun:OUT/rc 是它设的变量,出了子 shell 就丢了
cd "$HOME/zz-npm" || exit 1
tryrun 150 npm install --no-audit --no-fund
cd "$HOME_DIR" || exit 1
if grep -aq 'npm-lifecycle-ok' "$OUT"; then
    ok "npm install 跑通了 prepare 生命周期脚本(child_process + sh 全链路)"
else
    bad "npm install(rc=$rc)没跑到 lifecycle;末 12 行:$(tail -12 "$OUT" | sed 's/^/ | /')"
fi

# node-jitless:策略在宿主、机制在命令 so。宿主(app 主进程)启动时读
# $HOME/bettersh.conf,把 node-jitless 导出成环境变量 BSH_NODE_JITLESS
# (见 bshutil/bsh_cfg.cpp 的 bsh_cfg_export_env);入口只读这个变量,不碰配置文件。
# 所以这里能直接看变量本身,而"改配置文件即时生效"已经不再成立 ——
# 手改 conf 要重开会话,`bshutil set node-jitless` 改完立即生效(它 save 后会重新导出)。
run 'node-jitless:环境变量与 auto 决策'
info "宿主导出的 BSH_NODE_JITLESS=$BSH_NODE_JITLESS"
tryrun 30 node -e 'console.log("child sees BSH_NODE_JITLESS=" + process.env.BSH_NODE_JITLESS)'
info "子进程看到: $(out_last)"
tryrun 60 node -e 'console.log("execArgv=" + JSON.stringify(process.execArgv) + " calc=" + 6*7)'
auto_line=$(out_last)
info "auto 判定结果:$auto_line"
case "$auto_line" in
    *'--jitless'*) info "(本机 auto 判出拿不到可执行内存 → 已加 --jitless)" ;;
    *'execArgv=[]'*|*'execArgv=["-e"'*) ok "auto:本机 JIT 可用,没加 --jitless 且 node 照常跑" ;;
    *) bad "node 的 execArgv 看着不对:$auto_line" ;;
esac
case "$auto_line" in *'calc=42'*) ;; *) bad "auto 下 node 没正常跑:$auto_line" ;; esac
# 机制本身:手动强制 --jitless 也得能跑(不依赖开关,直接验 flag)
tryrun 60 node --jitless --no-expose-wasm -e 'console.log("forced-jitless calc=" + 6*7)'
if grep -aq 'forced-jitless calc=42' "$OUT"; then
    ok "手动 --jitless 下 node 照常跑(纯解释器模式可用)"
else
    bad "--jitless 下 node 没跑起来(rc=$rc):$(tail -3 "$OUT" | sed 's/^/ | /')"
fi
tally

# ══════════════════════════════════════════════════════════════════
sec "5d. JDK(java / javac / jar) —— 真机验收 + 权限实验用"
# 这一段是 2026-09-28 的"去掉 module.json5 里两条 jit 权限"实验的对照用例:
#   - java 是 HotSpot(server 变体,JIT+mixed mode),它**必须**能拿到可执行内存;
#   - node(V8)在 5 节里也测,但我们给 V8 打过 prctl 夹层补丁,所以它可能活着;
#     两者一起看,就能分清"是权限没了"还是"JIT 彻底没了"。
run 'java -version'
tryrun 120 java -version
if grep -aq 'openjdk version' "$OUT"; then
    ok "java -version → $(head -1 "$OUT")"
else
    bad "java -version rc=$rc;末 5 行:$(tail -5 "$OUT" | sed 's/^/ | /')"
fi

run 'javac 编 + java 跑(端到端)'
rm -rf "$HOME/zz-java"
mkdir -p "$HOME/zz-java"
echo 'public class Hello { public static void main(String[] a){ System.out.println("jdk-ok " + System.getProperty("os.arch")); } }' \
    > "$HOME/zz-java/Hello.java"
cd "$HOME/zz-java" || exit 1
tryrun 180 javac Hello.java
if [ -f Hello.class ]; then
    ok "javac 编译通过"
else
    bad "javac rc=$rc;末 5 行:$(tail -5 "$OUT" | sed 's/^/ | /')"
fi
tryrun 180 java Hello
if grep -aq 'jdk-ok' "$OUT"; then
    ok "java 运行 → $(out_last)"
else
    bad "java Hello rc=$rc;末 5 行:$(tail -5 "$OUT" | sed 's/^/ | /')"
fi
cd "$HOME_DIR" || exit 1
tryrun 60 java NoSuchClass
info "java NoSuchClass → rc=$rc(期望 1)"
tryrun 60 jar --version
info "jar --version → rc=$rc: $(out_last)"
tally

# ══════════════════════════════════════════════════════════════════
sec "5e. zip / unzip(Info-ZIP 3.0 / 6.0;两个独立命令 so)"
# 见 scripts/build_zip.sh + scripts/zip-ohos/README.md。
# so 名是 libzipcmd.so / libunzipcmd.so —— libzip.so 这个名字被 JDK 的
# java.util.zip 原生库占着(build_jdk.sh 的 install 阶段拷进 entry/libs),
# 同名会互相覆盖,所以命令 so 的名字后面加 cmd。
# zip64 / 大文件不做,用例里也不测。
ZZ="$HOME_DIR/zz-zipcmd"
rm -rf "$ZZ"
mkdir -p "$ZZ/dir/sub" "$ZZ/中文目录"
echo alpha > "$ZZ/dir/a.txt"
echo beta  > "$ZZ/dir/sub/b.txt"
echo hanzi > "$ZZ/中文目录/文件名.txt"
# 二进制样本:纯文本看不出 CRLF/编码被动过,一组 0..255 的字节最能说明问题
python3 -c "open('$ZZ/dir/bin.dat','wb').write(bytes(range(256))*7)" 2>/dev/null
cd "$ZZ" || exit 1

run 'zip -r z.zip dir'
tryrun 60 zip -q -r z.zip dir
zip_rc=$rc
if [ "$zip_rc" = 0 ] && [ -f z.zip ] && [ "$(wc -c < z.zip | sed 's/ //g')" -gt 0 ]; then
    ok "zip 打包成功(z.zip $(wc -c < z.zip | sed 's/ //g') 字节)"
else
    bad "zip 打包失败 rc=$zip_rc:$(out_head)"
fi

run 'unzip -l z.zip(条目/名字)'
tryrun 30 unzip -l z.zip
if grep -aq 'dir/a.txt' "$OUT" && grep -aq 'dir/sub/b.txt' "$OUT" \
   && grep -aq 'dir/bin.dat' "$OUT"; then
    ok "unzip -l 三个条目名字都对得上"
else
    bad "unzip -l 不对(rc=$rc):$(tail -8 "$OUT" | sed 's/^/ | /')"
fi

run 'unzip -d out 解包 → 逐字节比对'
tryrun 60 unzip -o -q z.zip -d out
unzip_rc=$rc
diff_list=""
for f in dir/a.txt dir/sub/b.txt dir/bin.dat; do
    toybox cmp -s "out/$f" "$f" > /dev/null 2>&1 || diff_list="$diff_list $f"
done
if [ -z "$diff_list" ] && [ "$unzip_rc" = 0 ]; then
    ok "解包内容与源逐字节一致(cmp 3 个文件,含 1792 字节二进制样本)"
else
    bad "解包内容不一致:$diff_list(unzip rc=$unzip_rc;末尾:$(tail -3 "$OUT" | sed 's/^/ | /'))"
fi
# rc 必须是 0:只要有一个目录的 utime/chmod 失败,unzip 会退成 PK_WARN(1),
# 内容照样对得上 —— 只看 cmp 会漏掉这一类"看着成功其实报了警"的情况。

run '交叉验证 A:我们的 zip → python3 -m zipfile'
tryrun 60 python3 -m zipfile -e z.zip pyx
diff_list=""
for f in dir/a.txt dir/sub/b.txt dir/bin.dat; do
    toybox cmp -s "pyx/$f" "$f" > /dev/null 2>&1 || diff_list="$diff_list $f"
done
if [ -z "$diff_list" ] && [ "$rc" = 0 ]; then
    ok "python 解开我们的包,内容一致"
else
    bad "python 解我们的包不一致:$diff_list(rc=$rc)"
fi
# testzip() 逐条目重算 CRC32 —— deflate 流或 CRC 只要有一位不对就会报出来
tryrun 30 python3 -c "import zipfile;print('testzip=',zipfile.ZipFile('z.zip').testzip())"
chk "python 校验我们的包(testzip None = 全部 CRC 对)" "$(out_last)" "testzip= None"

run '交叉验证 B:python3 -m zipfile -c → 我们的 unzip'
# 注意 python 的 zipfile CLI 用 arcname=basename:传 dir/a.txt 进去,条目名是 a.txt,
# 所以解出来落在 pyout/ 根下,比对也要按 basename 比(第一轮就是这里误判成 FAIL 的)。
tryrun 30 python3 -m zipfile -c py.zip dir/a.txt dir/sub/b.txt dir/bin.dat
info "python 打包 rc=$rc,py.zip=$(wc -c < py.zip | sed 's/ //g') 字节"
tryrun 30 unzip -l py.zip
grep -a 'a\.txt\|b\.txt\|bin\.dat' "$OUT" | head -4 | sed 's/^/       /'
tryrun 60 unzip -o -q py.zip -d pyout
pyout_rc=$rc
diff_list=""
toybox cmp -s pyout/a.txt     dir/a.txt      || diff_list="$diff_list a.txt"
toybox cmp -s pyout/b.txt     dir/sub/b.txt  || diff_list="$diff_list b.txt"
toybox cmp -s pyout/bin.dat   dir/bin.dat    || diff_list="$diff_list bin.dat"
if [ -z "$diff_list" ] && [ "$pyout_rc" = 0 ]; then
    ok "我们的 unzip 解开 python 的包,内容一致"
else
    bad "unzip 解 python 的包不一致:$diff_list(unzip rc=$pyout_rc)"
fi

run '中文文件名往返(zip -UN=UTF8 / unzip)'
tryrun 60 zip -q -r -UN=UTF8 zh.zip 中文目录
zh_zip_rc=$rc
tryrun 60 unzip -o -q zh.zip -d zhout
zh_rc=$rc
if [ "$zh_zip_rc" = 0 ] && [ "$zh_rc" = 0 ] && [ -f "zhout/中文目录/文件名.txt" ] \
   && toybox cmp -s "zhout/中文目录/文件名.txt" "中文目录/文件名.txt"; then
    ok "中文目录/文件名往返 OK(-UN=UTF8 → 设备上名字仍是 UTF-8)"
else
    bad "中文往返失败(打包 rc=$zh_zip_rc,解包 rc=$zh_rc);zhout 里:$(ls zhout 2>&1)"
fi
tryrun 30 unzip -l zh.zip
# -DNO_WORKING_ISPRINT 就是为这一条加的:OHOS 的 ctype.h 把 isprint 定义成
# "永远按 ASCII 判"的宏,不关掉它中文名会被 fnfilter 印成 ????/。
if grep -aFq '中文目录/文件名.txt' "$OUT"; then
    ok "unzip -l 原样印出中文名(没被 fnfilter 换成 ?)"
else
    bad "unzip -l 没印出中文名,末尾:$(tail -3 "$OUT" | sed 's/^/ | /')"
fi
# 反向:python 打的中文名包,我们也得解对(同样只留 basename)
tryrun 30 python3 -m zipfile -c pyzh.zip 中文目录/文件名.txt
tryrun 60 unzip -o -q pyzh.zip -d pyzhout
if [ -f "pyzhout/文件名.txt" ] && toybox cmp -s "pyzhout/文件名.txt" "中文目录/文件名.txt"; then
    ok "python 打的中文名包,我们解出来也对(pyzhout/文件名.txt)"
else
    bad "python 的中文名包解错(rc=$rc);pyzhout 里:$(ls pyzhout 2>&1)"
fi

run '覆盖提示路径:unzip 默认 / -o / -n'
echo CHANGED > out/dir/a.txt
tryrun 60 unzip -o -q z.zip -d out
if [ "$rc" = 0 ] && [ "$(cat out/dir/a.txt)" = "alpha" ]; then
    ok "-o 无条件覆盖(内容回到 alpha)"
else
    bad "-o 覆盖失败(rc=$rc,内容=$(cat out/dir/a.txt 2>&1))"
fi
echo CHANGED > out/dir/a.txt
tryrun 60 unzip -n -q z.zip -d out
if [ "$rc" = 0 ] && [ "$(cat out/dir/a.txt)" = "CHANGED" ]; then
    ok "-n 全跳过(已存在的文件没被动)"
else
    bad "-n 跳过失败(rc=$rc,内容=$(cat out/dir/a.txt 2>&1))"
fi
# 默认(既不给 -o 也不给 -n):非交互环境不能挂住,上游的兜底是 fgets 失败→"Assume none"
echo CHANGED2 > out/dir/a.txt
tryrun 30 unzip z.zip -d out
info "默认(无 -o/-n;stdin=/dev/null、stdout 是文件不是 tty)→ rc=$rc"
# 说明:toybox 的 grep 是 BRE,GNU 的 \| 交替在这里**不认**(会当字面量),
# 所以本节所有多选一都用 grep -aE。
grep -aE 'replace|Assume' "$OUT" | head -2 | sed 's/^/       /'
if [ "$rc" != 0 ] && [ "$(cat out/dir/a.txt)" = "CHANGED2" ]; then
    ok "默认非交互:问一句 → 拿不到答复就跳过,rc 非 0(不会挂住)"
else
    bad "默认非交互行为异常(rc=$rc,内容=$(cat out/dir/a.txt 2>&1))"
fi

run '退出码:打不开的包 / 缺参数'
tryrun 30 unzip "$ZZ/zz-no-such.zip"
chk "unzip 打不开的包(PK_NOZIP=9)" "$rc" "9"
python3 -c "open('$ZZ/garbage.zip','wb').write(b'not a zip file'*40)" 2>/dev/null
tryrun 30 unzip "$ZZ/garbage.zip"
chk "unzip 非 zip 文件" "$rc" "9"
tryrun 30 unzip -q
info "unzip 给选项但不给 zipfile → rc=$rc(源码里 PK_PARAM=10)"
chk "unzip 缺 zipfile" "$rc" "10"
tryrun 30 zip -q -r "$ZZ/zz-none.zip"
info "zip 只有 zipfile、没有输入文件 → rc=$rc(源码里 ZE_NONE=12)"
chk "zip 缺参数(没有要加的文件)" "$rc" "12"
tryrun 30 zip --version
if [ "$rc" = 0 ]; then ok "zip --version → $(out_head)"; else bad "zip --version rc=$rc"; fi
tryrun 30 unzip -v
info "unzip 编译开关(看 Unicode/MBCS 有没有编进去):"
grep -aE 'UNICODE_SUPPORT|MBCS-support' "$OUT" | head -3 | sed 's/^/       /'
# 裸 zip / 裸 unzip 是上游定义的"用法屏"路径,不是错误:
#   zip   无参数 → 过滤模式(zipstdout():把 stdin 打成 zip 写 stdout);
#   unzip 无参数 → 打 usage 后 PK_OK(见 unzip.c 的 G.noargs 分支)。
# 只记录,不当断言。
tryrun 30 zip
info "裸 zip(过滤模式)→ rc=$rc,输出 $(wc -c < "$OUT" | sed 's/ //g') 字节"
tryrun 30 unzip
info "裸 unzip(usage 屏)→ rc=$rc"
tally

# ══════════════════════════════════════════════════════════════════
sec "5f. glibc guest 探针(临时:回答『elfloader 能不能跑 glibc arm64』)"
# 注意:这条探针里**既不能用 tr、也不能用 printf** —— toybox 里没编进 tr,
# 而 mksh 这边没有 printf 内建(裸名会落到 /bin/printf 被 elfloader 拒),两者都会吞掉输出。
G="$HOME/zz-glibc"
if [ -d "$G" ]; then
    cd "$G" || exit 1
    run '逐 syscall 探测(沙箱放行哪些;159=SIGSYS 被拦)'
    for nr in 96 99 214 226 261 278 283 293 361; do
        tryrun 20 ./sysprobe "$nr"
        rcd=$rc
        last=$(tail -1 "$OUT")
        echo "       nr=$nr rc=$rcd $last"
    done
    info "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
    run 'elfloader ← glibc 静态(自带 libc,不需要外部库)'
    tryrun 60 ./glibc-static
    info "rc=$rc(期望 7 = guest 的返回值);输出:"
    tail -6 "$OUT" | sed 's/^/       /'
    run 'mmap(PROT_EXEC) 判别:bundle libs 里的文件能不能映射'
    B=/data/storage/el1/bundle/libs/arm64
    # 注意:这一段会引内核的「是否运行 xxx」确认框 —— **请在设备上点允许**。
    # 上一轮用户全程拒绝/超时,结果连我们自己天天 dlopen 的 libtoybox.so 都 EACCES,
    # 说明"拒绝"把测量污染了(要么进程被降权,要么该文件被标记为不可执行)。
    # 超时给到 90s,留足点按时间;每条都先探一遍 RO 做对照。
    echo "       >>> 若设备弹「是否运行…」请点【允许】<<<"
    # 判别"上下文"假设:python3 是 kSoMain 命令(应用上下文),而 mmapprobe 跑在
    # elfloader 的 guest 里。同一个文件、同一种映射,两边结果若不同,说明拦的是
    # "guest 上下文"而不是文件本身。
    run 'sh 自己的 /proc/self/maps:bundle libs 的 .so 是以什么权限映射的'
    tryrun 20 sh -c "grep -E 'bundle|el2/base' /proc/self/maps | head -6"
    tail -6 "$OUT" | sed 's/^/       /'
    run 'sh 的 status(seccomp / NoNewPrivs)'
    tryrun 20 sh -c "grep -E 'Seccomp|NoNewPrivs|CapEff' /proc/self/status"
    tail -3 "$OUT" | sed 's/^/       /'

    info "对照:在应用上下文(python3, kSoMain)里映射同一个文件"
    for f in "$B/libtoybox.so" "$B/libc.so.6"; do
        tryrun 40 python3 -c "import mmap,os,sys; fd=os.open('$f',os.O_RDONLY); m=mmap.mmap(fd,0,prot=mmap.PROT_READ|mmap.PROT_EXEC); print('py mmap RX OK', '$f'); m.close()"
        echo "       py rx $f -> rc=$rc $(tail -1 "$OUT")"
    done
    for f in "$B/libtoybox.so" "$B/libtoybox.so" "$B/libc.so.6" "$G/glibc-dynamic"; do
        for md in ro rx mprot; do
            tryrun 90 ./mmapprobe "$f" "$md"
            echo "       $md  $f"
            echo "          -> $(tail -1 "$OUT")"
        done
    done

    run 'elfloader ← glibc 动态(库在 bundle libs,guest 目录里没有)'
    info "  (首次跑若弹「是否允许运行外部二进制」,那是内核在拦文件 mmap;见 README)"
    tryrun 90 ./glibc-dynamic
    info "rc=$rc(期望 7);输出:"
    tail -6 "$OUT" | sed 's/^/       /'
    run 'qemu-aarch64 ← glibc 动态(对照)'
    tryrun 120 qemu-aarch64 -L . ./glibc-dynamic
    info "rc=$rc;输出:"
    tail -6 "$OUT" | sed 's/^/       /'
    cd "$HOME_DIR" || exit 1
else
    info "没有 $G(样本没解包?)"
fi
tally

# ══════════════════════════════════════════════════════════════════
sec "6. 退出码透传(多探针:定位丢在哪一环)"
run 'exit-code probes'
tryrun 20 sh -c 'exit 7'
info "sh -c 'exit 7'  → rc=$rc(期望 7)"
tryrun 20 sh -c 'exit 0'
info "sh -c 'exit 0'  → rc=$rc(期望 0)"
tryrun 20 false
info "false           → rc=$rc(期望 1)"
tryrun 20 true
info "true            → rc=$rc(期望 0)"
tryrun 20 ls "$HOME_DIR/zz-不存在"
info "ls 不存在路径    → rc=$rc(期望非 0)"
tryrun 20 sh -c 'exit 7'
chk "sh -c 'exit 7' 的退出码" "$rc" "7"
tryrun 20 sh -c 'exit 3'
chk "sh -c 'exit 3' 的退出码" "$rc" "3"

# 判别探针:非 0 退出码是在哪一层丢的 ——
#   命令 so 直接 return 值的(false/true):已知正常;
#   guest 自己调 exit()/sys.exit() 的(sh/python):看是不是这两条一起丢,
#   一起丢就说明"调 exit()"这条路径的码没回到 procmgr。
run '退出码判别探针(return vs exit(3))'
tryrun 20 python3 -c 'import sys; sys.exit(7)'
info "python3 sys.exit(7)   → rc=$rc"
tryrun 20 python3 -c 'raise SystemExit(7)'
info "python3 SystemExit(7) → rc=$rc"
tryrun 20 python3 -c 'import os; os._exit(7)'
info "python3 os._exit(7)    → rc=$rc(若这条=7 而上面=0,就是 exit() 的锅)"
tryrun 20 python3 -c 'import os; os._exit(5)'
info "python3 os._exit(5)    → rc=$rc"
tryrun 20 python3 -c 'print(1)'
info "python3 正常退出        → rc=$rc(期望 0)"
tryrun 20 sh -c 'false'
info "sh -c false            → rc=$rc(期望 1)"
tryrun 20 toybox false
info "toybox false           → rc=$rc(期望 1)"
tryrun 20 toybox timeout 20 false
info "嵌套 false             → rc=$rc(期望 1)"
tally

# ══════════════════════════════════════════════════════════════════
sec "7. 信号(20s)"
run 'SIGINT 自送'
tryrun 20 sh -c 'kill -INT $$; echo survived'
info "自送 SIGINT → rc=$rc,输出=[$(out_head)]"
tally

# ══════════════════════════════════════════════════════════════════
sec "8. 七个 ABI 组合件"
# 顺序有讲究:能过的先跑(x86_64-glibc-dynamic 是第一轮挂住的那一个,放最后)。
# 这一节真挂住也不会丢前面的账 —— 上面每个 sec 末尾都有 [小计]。
# 路径注意:testprogs 解在**资源根**($BSH_SYSROOT/testprogs),**不是** $HOME
# ($HOME 是 $BSH_SYSROOT/home)。第 9 节早就改对了,这一节一直漏改 —— 症状是它安静地
# 报"目录不存在"并跳过整档 ABI 组合(2026-10-03 的全量回归才发现:第 9 节 PASS、
# 第 8 节 FAIL,而两节看的是同一个目录)。
TG_DIR="${BSH_SYSROOT:-$HOME_DIR/..}/testprogs"
if [ -d "$TG_DIR" ]; then
    cd "$TG_DIR" || exit 1
    for f in aarch64-musl-dynamic aarch64-musl-static \
             aarch64-glibc-dynamic-nopie \
             x86_64-musl-dynamic \
             x86_64-musl-static x86_64-glibc-static \
             x86_64-glibc-dynamic; do
        run "./$f(裸名,验 e_machine 自动路由)"
        if [ ! -f "$f" ]; then bad "$f 缺失"; continue; fi
        tryrun $TMOUT_CAP ./"$f"
        # 汇总行的格式是 `blocks=N  pass=N  fail=N  skip=N`（见 programs/testx64/main.c）。
        # 以前这里 grep 的是 `total=` —— 那个字段**早就不存在了**，于是每个组合都被判成
        # "未跑完"，整档 ABI 组合实际上一直没在记账（2026-10-03 全量回归才发现）。
        sum=$(grep -a 'blocks=' "$OUT" | head -1)
        combo=$(grep -a 'combination:' "$OUT" | head -1)
        if [ -n "$sum" ]; then
            ok "$f → $sum (rc=$rc)"
        elif [ "$rc" = 124 ] || [ "$rc" = 143 ] || [ "$rc" = 137 ]; then
            bad "$f 超时(${TMOUT_CAP}s,rc=$rc;停在: $(out_last))"
        else
            bad "$f 未跑完(rc=$rc,停在: $(out_last))"
        fi
        [ -n "$combo" ] && info "        $combo"
        [ -n "$sum" ] && info "        $sum"
    done
    run 'box64 显式前缀对照(90s)'
    if command -v box64 > /dev/null 2>&1; then
        tryrun $TMOUT_CAP box64 ./x86_64-musl-dynamic
        sum=$(grep -a 'blocks=' "$OUT" | head -1)
        if [ -n "$sum" ]; then ok "box64 显式调用 → $sum"; else bad "box64 显式调用未跑完(rc=$rc)"; fi
    else
        info "box64 不可达(跳过)"
    fi
    cd "$HOME_DIR" || exit 1
else
    bad "testprogs 目录不存在(资源没解包?)"
fi

# ══════════════════════════════════════════════════════════════════
# 9 /proc/self/exe 替身（shim 的 BSH_GUEST_EXE 一层，见 shim/README.md §3.1b）
# 只跑 aarch64 的两只专用自测程序（静态/x86 组合吃不到 preload，测了只会得到
# "已知不支持"的 FAIL）。判据：末行 selfexe: PASS=8 FAIL=0。
# 路径注意：testprogs 解在**资源根**（$BSH_SYSROOT/testprogs，见 shell.cpp 的
# UnpackRes 与 bsh_paths.h），**不是** $HOME（$HOME 是 $BSH_SYSROOT/home）。
sec "9 /proc/self/exe 替身(2 只自测程序)"
TG_DIR="${BSH_SYSROOT:-$HOME_DIR/..}/testprogs"
if [ -d "$TG_DIR" ]; then
    for f in selfexe-aarch64-musl-dynamic selfexe-aarch64-glibc-dynamic; do
        if [ ! -f "$TG_DIR/$f" ]; then
            bad "$f 缺失(testprogs.tar 里没有?旧包?)"
            continue
        fi
        run "$f"
        tryrun $TMOUT_CAP "$TG_DIR/$f"
        line=$(grep -a '^selfexe: PASS=' "$OUT" | tail -1)
        case "$line" in
            *"FAIL=0") ok "$f → $line" ;;
            "")        bad "$f 没打出汇总行(rc=$rc;停在: $(out_last))" ;;
            *)         bad "$f → $line" ;;
        esac
    done
else
    bad "testprogs 目录不存在($TG_DIR;资源没解包?)"
fi

# ══════════════════════════════════════════════════════════════════
sec "10 残留 guest 清理(尽力而为)"
# 超时杀掉的是中间那层,真 guest 是 procmgr 的孙进程,只能按名字找出来杀。
# 找不到就跳过,不影响结论。
run '清理残留 guest 进程'
tryrun 20 toybox ps -A -o PID,ARGS
if [ "$rc" = 0 ]; then
    leftovers=$(grep -a -E 'testprogs/|zz-out\.' "$OUT" | grep -av 'grep' | head -20)
    if [ -n "$leftovers" ]; then
        info "还有残留:"
        echo "$leftovers" | sed 's/^/       /'
        echo "$leftovers" | while read -r lpid lrest; do
            case "$lpid" in ''|*[!0-9]*) continue ;; esac
            toybox kill -9 "$lpid" 2> /dev/null
        done
        info "已按 pid 尝试 kill -9"
    else
        ok "没有残留 guest 进程"
    fi
else
    info "toybox ps 不可用(rc=$rc),跳过残留清理"
fi

# ── 先出结果:后面的超时自检是最可能挂住的一步,结果行必须在它之前 ──
echo
echo "=== autorun 结果: PASS=$PASS FAIL=$FAIL ==="
date

# ══════════════════════════════════════════════════════════════════
sec "11. 超时机制自检(可能挂住:挂住本身就是结论)"
# 上一轮自检在第 8 节卡死、超过了 toybox timeout 给的上限还没回来,说明
# "timeout 杀不掉中间层"。这一步正面验证:timeout 3 跑 sleep 20,正常应 3 秒返回
# 且 rc=124;若一直不返回,就证明 kill 没生效(或 timeout 根本没在计时)。
run 'toybox timeout 3 sleep 20(期望 ~3s 返回,rc=124)'
t0=$(date +%s)
tryrun 8 toybox timeout 3 sleep 20
t1=$(date +%s)
info "耗时 $((t1 - t0))s,rc=$rc(期望 ~3s / 124)"
if [ "$rc" = 124 ] && [ $((t1 - t0)) -le 6 ]; then
    ok "超时机制生效"
elif [ "$rc" = 124 ]; then
    bad "超时触发了但耗时 $((t1 - t0))s(>6s)"
else
    bad "超时未生效:rc=$rc,耗时 $((t1 - t0))s"
fi

sec "10. 收尾"
rm -rf "$HOME_DIR/zz-cwd-test" "$HOME_DIR/zz-zip" "$HOME_DIR/zz.zip" "$HOME_DIR/zz-npm" \
       "$HOME_DIR/zz-h" "$HOME_DIR/zz-a.txt" "$HOME_DIR/zz-probe.err" "$HOME_DIR/zz-zipcmd"
rm -f "$HOME_DIR"/zz-out.*.txt
echo "=== autorun END ==="
