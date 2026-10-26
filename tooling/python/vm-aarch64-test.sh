#!/usr/bin/env bash
# 在 VM(真 aarch64) 里跑我们随包分发的 libpython + 标准库 zip + C 扩展:
# 用 OHOS clang 编出来的 embed-test(与 guncat_py.cpp 同样的 dlopen + PyRun_SimpleString),
# 验证"设备上的加载链路"在没有真机时能走到哪一步。
#
# 三个用例:
#   A. 完整布局(zip + libs 目录 + libz): 应当全部 import 成功, 用户代码跑通;
#   B. 只给 zip(模拟扩展目录没进 PYTHONPATH): 应当仍能跑纯 Python, 且诊断里明确写出
#      import _json/_csv/zlib 失败的原因 —— 这是实机排障时最需要的输出;
#   C. 打印 sys.path / import 探测结果, 供对照。
#
# 注意: 设备上是 OHOS musl, 这里是 Alpine musl; 只用于验证加载/初始化链路,
#       不代表真机最终行为(真机仍需一次实跑确认)。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="${PROJ:-$(cd "$HERE/../.." && pwd)}"
RAW="$PROJ/entry/src/main/resources/rawfile/vm"
PYRAW="$PROJ/entry/src/main/resources/rawfile/python"
LIBS="$PROJ/entry/libs/arm64-v8a"
WORK="${WORK:-/tmp/guncat-a64-test}"
CONV="a64test"
QEMU="${QEMU:-qemu-system-aarch64}"

cleanup() { [ -n "${VM_PID:-}" ] && kill "$VM_PID" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

rm -rf "$WORK"; mkdir -p "$WORK/vm/keymaps" "$WORK/workspaces/$CONV/run" "$WORK/ipc"
cp "$RAW/kernel_aarch64" "$RAW/efi-virtio.rom" "$WORK/vm/"
cp "$RAW/keymaps/en-us" "$WORK/vm/keymaps/"
cp "$RAW/rootfs_guncat.qcow2" "$WORK/rootfs.qcow2"

S="$WORK/workspaces/$CONV"
cp "$LIBS/libpython3.12.so" "$LIBS/libz.so" "$S/"
# 新依赖库(ssl/sqlite/bz2/lzma)也要放进 LD_LIBRARY_PATH 能搜到的目录
for extra in "$LIBS"/libssl.so.3 "$LIBS"/libcrypto.so.3 "$LIBS"/libsqlite3.so "$LIBS"/libbz2.so "$LIBS"/liblzma.so.5; do
  [ -f "$extra" ] && cp -f "$extra" "$S/"
done
cp "$PYRAW/cacert.pem" "$S/" 2>/dev/null || true

# OpenSSL 在 OHOS 头文件下会引用 libc 的 __fd_chk(FD_SET 硬化); 设备侧由 OHOS libc 提供,
# 但 Alpine musl 没有。为了让 VM 里能验证 ssl, 这里编一个 no-op 存根并用 LD_PRELOAD 挂上。
cat > "$WORK/fdchk.c" <<'EOF'
void __fd_chk(int fd) { (void) fd; }
EOF
TC_PATH="${TOOL_HOME:-/opt/ohos-cmdline/command-line-tools}/sdk/default/openharmony/native"
"$TC_PATH/llvm/bin/aarch64-unknown-linux-ohos-clang" --sysroot="$TC_PATH/sysroot" \
  -shared -fPIC -o "$S/libfdchk.so" "$WORK/fdchk.c"
mkdir -p "$S/libs"
cp "$LIBS"/*.cpython-312-*.so "$S/libs/" 2>/dev/null || true
cp "$PYRAW/python312.zip" "$S/"
cp /tmp/embed-a64 "$S/" 2>/dev/null || { echo "ERROR: 先编 /tmp/embed-a64"; exit 1; }
awk '/R"PYSRC\(/{f=1;next} /\)PYSRC"/{f=0} f' "$PROJ/entry/src/main/cpp/python/guncat_py.cpp" > "$S/launcher.py"
printf 'import sys\nprint("hello", 1 + 1)\nimport json, csv, zlib, binascii, math, hashlib\nprint(json.dumps({"a": 1}))\nprint("crc32", hex(zlib.crc32(b"abc")))\nprint("sqrt", math.sqrt(9))\n' > "$S/run/code.py"

"$QEMU" \
  -machine virt,acpi=on,gic-version=max,iommu=none,its=off,usb=off,virtualization=off \
  -cpu max,pauth-impdef=on,sve=off,pmu=off -accel tcg,thread=single -smp 1 -m 2048 \
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
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci-non-transitional,rng=rng0 \
  -serial file:"$WORK/serial.log" -display none -monitor none -no-reboot > "$WORK/qemu.out" 2>&1 &
VM_PID=$!

for _ in $(seq 1 1800); do [ -f "$WORK/ipc/.ready" ] && break; sleep 0.1; done
[ -f "$WORK/ipc/.ready" ] || { echo "ERROR: 客人未就绪"; tail -20 "$WORK/serial.log"; exit 1; }
echo "== 客人就绪"

run_job() {  # id, cmd, timeout
  local id="$1" cmd="$2" tmo="${3:-300}"
  local req="$WORK/ipc/$CONV/in/$id" out="$WORK/ipc/$CONV/out/$id"
  mkdir -p "$req"
  printf '%s\n' "$cmd" > "$req/cmd"
  printf '%s' "$tmo" > "$req/timeout"
  : > "$req/ready"
  for _ in $(seq 1 $((tmo * 10))); do [ -f "$out/done" ] && break; sleep 0.1; done
  echo "--- [$id] exit=$(cat "$out/code" 2>/dev/null)"
  cat "$out/stdout" 2>/dev/null
  [ -s "$out/stderr" ] && { echo "--- stderr:"; head -20 "$out/stderr"; }
}

PREP='cd /workspace
ln -sf /lib/libc.musl-aarch64.so.1 /workspace/libc.so
rm -rf /workspace/pyhome && mkdir -p /workspace/pyhome/lib/python3.12
cp /workspace/python312.zip /workspace/pyhome/lib/python3.12/
rm -rf /workspace/run && mkdir -p /workspace/run
cat > /workspace/run/code.py <<"PY"
import json, csv, zlib, binascii, math, hashlib
print("hello", 1 + 1)
print(json.dumps({"a": 1}))
print("crc32", hex(zlib.crc32(b"abc")))
print("sqrt", math.sqrt(9))
import sqlite3
con = sqlite3.connect(":memory:")
con.execute("create table t(x int)")
con.executemany("insert into t values (?)", [(1,), (2,), (3,)])
print("sqlite3", con.execute("select sum(x) from t").fetchone()[0])
_pb = getattr(hashlib, "pbkdf2_hmac", None)
print("pbkdf2", _pb("sha256", b"pw", b"salt", 1000).hex()[:16] if _pb else "MISSING")
_sc = getattr(hashlib, "scrypt", None)
print("scrypt", _sc(b"pw", salt=b"salt", n=1024, r=8, p=1, dklen=8).hex() if _sc else "MISSING")
import bz2, lzma
print("bz2", bz2.decompress(bz2.compress(b"abc")))
print("lzma", lzma.decompress(lzma.compress(b"xyz")))
for _m in ("_hashlib", "_ssl"):
    try:
        __import__(_m)
        print(_m, "ok")
    except BaseException as _e:
        print(_m, "FAIL", repr(_e))
try:
    import ssl
    ctx = ssl.create_default_context()
    print("ssl", ctx.protocol, "certs", len(ctx.get_ca_certs()))
except BaseException as _e:
    print("ssl FAIL", repr(_e))
PY
export LD_LIBRARY_PATH=/workspace
export SSL_CERT_FILE=/workspace/cacert.pem
export LD_PRELOAD=/workspace/libfdchk.so'

echo "== A) 完整布局(zip + libs + libz)"
run_job a "$PREP
cp /workspace/../a64test/run/code.py /workspace/run/code.py 2>/dev/null || true
/workspace/embed-a64 /workspace/libpython3.12.so /workspace/launcher.py /workspace/run/code.py /workspace/run \
  /workspace/pyhome \"/workspace/pyhome/lib/python3.12/python312.zip:/workspace/libs\" 2>&1" 600

echo "== C) 硬超时(AST 截止检查: 条件式 while 应在 1.5s 抛 TimeoutError)"
run_job c "$PREP
mkdir -p /workspace/run/c2
cat > /workspace/run/c2/code.py <<'GCODE'
import time
t0 = time.time()
n = 0
while time.time() - t0 < 6:
    n += 1
print('NOT INTERRUPTED', n)
GCODE
/workspace/embed-a64 /workspace/libpython3.12.so /workspace/launcher.py /workspace/run/c2/code.py /workspace/run/c2 \
  /workspace/pyhome \"/workspace/pyhome/lib/python3.12/python312.zip:/workspace/libs\" 1500 2>&1 | head -12" 600

echo "== B) 只给 zip(模拟扩展目录没并进 PYTHONPATH)"
run_job b "$PREP
/workspace/embed-a64 /workspace/libpython3.12.so /workspace/launcher.py /workspace/run/code.py /workspace/run \
  /workspace/pyhome \"/workspace/pyhome/lib/python3.12/python312.zip\" 2>&1" 600
