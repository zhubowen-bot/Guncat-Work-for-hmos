#!/usr/bin/env bash
# 跨域桥(npy)的离线端到端测试:
#   * 在宿主上真启动 VM(与 app 相同的 9p 通道), 跑一条会调用 `npy` 的 shell 命令;
#   * 宿主演一个"ArkTS 的 serveNpyCalls": 扫描 ipc/<conv>/call/*/ready, 用**宿主原生 CPython**
#     执行, 再把结果写回 ipc/<conv>/out/<id>/ —— 与 LinuxShellService 的行为一致;
#   * 断言: 数值正确、stdin 透传、argv、管道、退出码、相对路径读写、子目录 cwd。
#
# 用法: bash tooling/linux-vm/npy-test.sh
# 依赖: 宿主 qemu-system-aarch64、bash、python3(这里用 /opt/py312/bin/python3.12 更好)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="${PROJ:-$(cd "$HERE/../.." && pwd)}"
RAW="$PROJ/entry/src/main/resources/rawfile/vm"
WORK="${WORK:-/tmp/guncat-npy-test}"
CONV="npytest"
QEMU="${QEMU:-qemu-system-aarch64}"
HOSTPY="${HOSTPY:-/opt/py312/bin/python3.12}"
MEM="${MEM:-2048}"

passed=0; failed=0
pass() { echo "  OK  $1"; passed=$((passed+1)); }
bad()  { echo "  FAIL $1"; failed=$((failed+1)); }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else bad "$1 (期望 [$2] 实际 [$3])"; fi; }

cleanup() { [ -n "${VM_PID:-}" ] && kill "$VM_PID" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

rm -rf "$WORK"; mkdir -p "$WORK/vm/keymaps" "$WORK/workspaces/$CONV/sub" "$WORK/ipc"
# 模拟应用侧 stageGuestScripts: 启动前把"随 HAP 打包"的 guest 脚本放进共享目录, 客人开机时覆盖安装
mkdir -p "$WORK/ipc/guest"
sed '2i NPY_STAGED_BY_HOST=1' "$HERE/guest/npy" > "$WORK/ipc/guest/npy"
cp "$RAW/kernel_aarch64" "$WORK/vm/"
cp "$RAW/efi-virtio.rom" "$WORK/vm/"
cp "$RAW/keymaps/en-us" "$WORK/vm/keymaps/"
cp "$RAW/rootfs_guncat.qcow2" "$WORK/rootfs.qcow2"

"$QEMU" \
  -machine virt,acpi=on,gic-version=max,iommu=none,its=off,usb=off,virtualization=off \
  -cpu max,pauth-impdef=on,sve=off,pmu=off -accel tcg,thread=single -smp 1 -m "$MEM" \
  -kernel "$WORK/vm/kernel_aarch64" \
  -append "root=/dev/sda rw rootfstype=ext4 rootwait console=ttyAMA0 consoleblank=0 loglevel=3 init=/init mitigations=off audit=0 random.trust_cpu=on elevator=noop skew_tick=1 nmi_watchdog=0 panic=1" \
  -rtc base=utc,clock=host -L "$WORK/vm" \
  -drive if=none,format=qcow2,file="$WORK/rootfs.qcow2",id=hd0,cache=writeback,aio=threads,discard=unmap \
  -device virtio-scsi-pci-non-transitional,id=scsi0,num_queues=1 \
  -device scsi-hd,drive=hd0,bus=scsi0.0,logical_block_size=4096,physical_block_size=4096,rotation_rate=1,bootindex=1 \
  -fsdev local,security_model=none,id=fsdev0,path="$WORK/workspaces" \
  -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=workspaces \
  -fsdev local,security_model=none,id=fsdev1,path="$WORK/ipc" \
  -device virtio-9p-pci,id=fs1,fsdev=fsdev1,mount_tag=guncatipc \
  -netdev user,id=eth0 -device virtio-net-pci-non-transitional,netdev=eth0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci-non-transitional,rng=rng0 \
  -serial file:"$WORK/serial.log" -display none -monitor none -no-reboot > "$WORK/qemu.out" 2>&1 &
VM_PID=$!

for _ in $(seq 1 1800); do [ -f "$WORK/ipc/.ready" ] && break; sleep 0.1; done
[ -f "$WORK/ipc/.ready" ] || { echo "ERROR: 客人未就绪"; tail -20 "$WORK/serial.log"; exit 1; }
echo "== 客人就绪"
command -v npy >/dev/null 2>&1 || true

# ---- 宿主侧扮演 serveNpyCalls: 用原生 CPython 执行客人转发的请求 ----
serve_calls() {
  local call_dir="$WORK/ipc/$CONV/call"
  [ -d "$call_dir" ] || return 0
  local req
  for req in "$call_dir"/*; do
    [ -d "$req" ] || continue
    [ -f "$req/ready" ] || continue
    local id="${req##*/}"
    local out="$WORK/ipc/$CONV/out/$id"
    mkdir -p "$out"
    local cwd_rel; cwd_rel=$(cat "$req/cwd" 2>/dev/null || echo "")
    local workdir="$WORK/workspaces/$CONV"
    [ -n "$cwd_rel" ] && workdir="$workdir/$cwd_rel"
    local argv_json; argv_json=$(cat "$req/argv" 2>/dev/null || echo '[]')
    local stdin_path=""; [ -f "$req/stdin" ] && stdin_path="$req/stdin"
    "$HOSTPY" - "$req/code" "$argv_json" "$workdir" "$stdin_path" > "$out/stdout" 2> "$out/stderr" <<'PY'
import json, os, sys
code_path, argv_json, workdir, stdin_path = sys.argv[1:5]
os.chdir(workdir)
sys.argv = json.loads(argv_json)
if stdin_path:
    sys.stdin = open(stdin_path, 'r', encoding='utf-8', errors='replace')
src = open(code_path, 'r', encoding='utf-8').read()
g = {'__name__': '__main__', '__file__': code_path}
try:
    exec(compile(src, '<npy>', 'exec'), g, g)
except SystemExit as e:
    raise
PY
    echo "$?" > "$out/code"
    : > "$out/done"
    rm -rf "$req"
  done
}

run_job() {  # id, cmd, timeout_sec[, cwd]
  local id="$1" cmd="$2" tmo="${3:-120}" cwd="${4:-}"
  local req="$WORK/ipc/$CONV/in/$id" out="$WORK/ipc/$CONV/out/$id"
  mkdir -p "$req"
  printf '%s\n' "$cmd" > "$req/cmd"
  printf '%s' "$tmo" > "$req/timeout"
  [ -n "$cwd" ] && printf '%s' "$cwd" > "$req/cwd"
  : > "$req/ready"
  local waited=0
  while [ ! -f "$out/done" ]; do
    serve_calls
    waited=$((waited+1))
    [ "$waited" -gt $((tmo*200)) ] && { echo "TIMEOUT $id" >&2; return 1; }
    sleep 0.01
  done
  serve_calls
  cat "$out/stdout" 2>/dev/null
}

echo "== 0) 开机从共享目录覆盖安装 guest 脚本"
out=$(run_job t0 'grep -c NPY_STAGED_BY_HOST /usr/local/bin/npy')
expect "npy 由主机版本覆盖" "1" "$(printf '%s' "$out" | tail -1)"

echo "== 1) 数值: 200k 循环"
out=$(run_job t1 'npy -c "print(sum(range(200000)))"')
expect "sum(range(200000))" "19999900000" "$(printf '%s' "$out" | tail -1)"

echo "== 2) stdin 透传"
printf 'hello bridge\n' > "$WORK/workspaces/$CONV/in.txt"
out=$(run_job t2 'npy -c "import sys; print(sys.stdin.read().strip().upper())" < in.txt')
expect "stdin 透传" "HELLO BRIDGE" "$(printf '%s' "$out" | tail -1)"

echo "== 3) argv"
cat > "$WORK/workspaces/$CONV/gen.py" <<'PY'
import sys
print('argc', len(sys.argv), 'args', sys.argv[1:])
PY
out=$(run_job t3 'npy gen.py a b')
expect "脚本 argv" "argc 3 args ['a', 'b']" "$(printf '%s' "$out" | tail -1)"

echo "== 4) 管道: npy | jq"
cat > "$WORK/workspaces/$CONV/emit.py" <<'PY'
import json
print(json.dumps({"a": 1, "b": [1, 2]}))
PY
out=$(run_job t4 'npy emit.py | jq -c .')
expect "管道进 jq" '{"a":1,"b":[1,2]}' "$(printf '%s' "$out" | tail -1)"

echo "== 5) 退出码"
out=$(run_job t5 'npy -c "raise SystemExit(7)"; echo "code=$?"')
expect "SystemExit(7) 透传" "code=7" "$(printf '%s' "$out" | tail -1)"

echo "== 6) 相对路径读写(与其它工具同一目录)"
rm -f "$WORK/workspaces/$CONV/out.txt"
out=$(run_job t6 'npy -c "open(\"out.txt\",\"w\").write(\"bridge\")" && cat out.txt')
expect "写工作区并可读" "bridge" "$(printf '%s' "$out" | tail -1)"
expect "宿主侧能看到产物" "bridge" "$(cat "$WORK/workspaces/$CONV/out.txt" 2>/dev/null)"

echo "== 7) 子目录 cwd"
rm -f "$WORK/workspaces/$CONV/sub/deep.txt"
out=$(run_job t7 'npy -c "open(\"deep.txt\",\"w\").write(\"x\")" && ls deep.txt' 120 sub)
expect "子目录内相对路径" "deep.txt" "$(printf '%s' "$out" | tail -1)"
expect "子目录产物落点" "x" "$(cat "$WORK/workspaces/$CONV/sub/deep.txt" 2>/dev/null)"

echo "== 8) 异常回传(非零退出 + stderr)"
out=$(run_job t8 'npy -c "1/0" ; echo "code=$?"')
expect "异常退出码非 0" "code=1" "$(printf '%s' "$out" | tail -1)"

echo "== 9) 单次往返开销(5 次取均值, 对比 VM 内 python3 启动)"
out=$(run_job t9 's=$(cut -d" " -f1 /proc/uptime); for i in 1 2 3 4 5; do npy -c "pass" >/dev/null; done; e=$(cut -d" " -f1 /proc/uptime); awk -v s=$s -v e=$e "BEGIN{printf \"%.0f\", (e-s)*1000/5}"')
echo "      npy 单次 ≈ ${out} ms   (VM 内 python3 启动 ≈ 3100 ms)"
[ -n "$out" ] && pass "往返开销可测" || bad "往返开销没测到"

echo
if [ "$failed" -eq 0 ]; then echo "== 全部通过 ($passed 项)"; else echo "== 有失败: $passed 通过 / $failed 失败"; fi
[ "$failed" -eq 0 ]
