# musl-ohos — 一份"不做文件映射"的 musl,给 aarch64 动态 guest 当运行时

产物:`build/musl/out/lib/ld-musl-aarch64.so.1`(外加 `libc.so` → 它的相对软链),由
`scripts/build_musl.sh` 编出。musl 的 **libc.so 本身就是它的动态链接器**(同一个文件,
链的时候带了 `-Wl,-e,_dlstart`),所以"改 musl 的加载器"就是改 `ldso/dynlink.c` 这一个
文件,改出来的 libc.so 直接当 `ld-musl-aarch64.so.1` 用,不需要额外动作。

**它不写 feature/bsh_main/libs/**。以前 aarch64 动态 guest 的解释器是从工具链
(`ElfLoaderDemo/tools/aarch64-linux-musl-cross`)拷来的原厂 `libc.so`,由
`scripts/build_testprogs.sh` 复制成 `feature/bsh_main/libs/arm64-v8a/ld-musl-aarch64.so.1`;把这份
自编的换上去由上层接线(见「接线方式」)。

唯一实质改动:**动态链接器不再把库文件 mmap 进地址空间**,改成
"匿名预留 → `pread` 读入 → `mprotect` 给权限",和 `feature/bsh_main/src/main/cpp/elfloader`
装 guest 的做法一致(glibc 那份见 `scripts/glibc-ohos/README.md`,同一套思路)。

第二个实质改动(**补 DT_RELR**,见第 4 节):1.2.2 的 loader 只认 `DT_REL`/`DT_RELA`,
而 OHOS 系统库(如 `/system/lib64/platformsdk/libz.so`)用新工具链编,相对重定位
**只放在 `DT_RELR` 里** —— 看不见的后果是 `.init_array` 里的构造函数指针停在链接期残值,
一调用就跳野地址(现象:`pc == fault == 0xa0e4` 这种小地址、崩在 `do_init_fini` 的 `blr`)。

```
scripts/musl-ohos/
├── README.md      ← 本文件:症状 → 根因 → 修法 → 踩过的坑
└── patches/
    ├── 0001-dynlink-anon-segment-loading.patch   对 musl 1.2.2 的改动:不做文件映射
    └── 0002-dynlink-dt-relr.patch                对 musl 1.2.2 的改动:支持 DT_RELR
```

阶段(`scripts/build_musl.sh [src|patch|configure|build|install|pack|all]`):

| 阶段 | 干什么 |
| --- | --- |
| src | 取 musl 1.2.2(`thirdparty/musl-1.2.2.tar.gz`,钉 sha256)解到 `build/musl/musl-1.2.2`;顺带把你机器上工具链那份的 musl 版本打出来对一眼 |
| patch | 打 `patches/*.patch`(正反向 dry-run 判幂等) |
| configure | out-of-tree configure 到 `build/musl/b`(musl 的 configure 支持 out-of-tree,会生成 `config.mak` 并软链 `Makefile`) |
| build | `make -j`(日志 `build/musl/make.log`) |
| install | 挑出 `b/lib/libc.so` → `build/musl/out/lib/ld-musl-aarch64.so.1` + `libc.so` 软链,并自检(ET_DYN / 入口是 `_dlstart` / 导出 `__libc_start_main`+`dlopen`)与工具链那份对动态符号 |
| pack | 按需:把 `out/lib` 摆成 qemu 的 LD_PREFIX 形状 → `build/musl/prefix/` + `musl-ohos-prefix.tar` |

---

## 1. dlopen / 带 DT_NEEDED 的 .so 在设备上必然失败

**症状**

- aarch64 动态 musl guest 里 `dlopen("./libxxx.so")` 失败,报
  `Error loading shared library ...: Permission denied` 或
  `Operation not permitted`;后面 `dlsym` 全跟不出来。
- 不是这一个 guest 的毛病:**任何**要动态加载 .so 的 musl 程序(带 `DT_NEEDED` 的
  也好,`dlopen` 的也好)都这样,因为失败在加载器里,不在程序里。

**根因**

设备沙箱把"把非系统文件当可执行体"交给 **seccomp 用户态通知**处理:用户看到
"是否运行 xxx"确认框,拒绝即 `EACCES/EPERM`;而且 `$HOME` 这类挂载点是 noexec,从那里
做可执行的文件映射本来就该失败。原厂 musl 的 `map_library()` 干的恰恰是这件事 ——
`-strace` 实测加载一个 `libtgreet-*.so`:

```
openat(AT_FDCWD,".../libtgreet-aarch64-musl-dynamic.so",O_RDONLY) = 3
mmap(NULL,73728,PROT_EXEC|PROT_READ,MAP_PRIVATE,3,0)                 ← 代码段:文件 + r-x
mmap(0x…, 8192,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_FIXED,3,0)       ← 数据段:文件 + rw
mprotect(0x…,4096,PROT_READ)                                        ← relro
```

第一行就是"文件映射 + 可执行" → 触发闸。

**修法**(`patches/0001-dynlink-anon-segment-loading.patch`,只动 `ldso/dynlink.c`)

`map_library()` 原来是:先 `mmap` **整个文件镜像**(`MAP_PRIVATE, fd`),再对除最低地址
外的每个 `PT_LOAD` 用它自己的 `prot` + `MAP_FIXED` 重映射一段文件。改成:

1. 第一次 `mmap` 只**预留地址**:`PROT_NONE | MAP_PRIVATE | MAP_ANONYMOUS`,不带 fd;
2. 循环里**每个** `PT_LOAD`(含最低地址那个,见坑 4)交给新增的 `map_segment()`:
   `mprotect(RW)` → `pread(fd, …, off_start+done)` 读到预留区间 → `mprotect(prot)`
   (代码段到这一步才变 `r-x`)。全程没有带 fd 的 `mmap`;
3. 段尾 bss 那套(`memset` 半页 + `MAP_FIXED|MAP_ANONYMOUS` 补尾页)保持上游原样 ——
   它本来就没有 fd,不触发闸。

新增的三个小函数:

| 函数 | 干什么 |
| --- | --- |
| `map_segment(p,n,prot,fd,off)` | 把文件 `[off, off+n)` 读进 `[p,p+n)`,再设成 `prot`;`mprotect` 失败(固定地址对象/地址已被占)时就地补一块 `MAP_FIXED\|MAP_ANONYMOUS` |
| `set_prot(p,n,prot)` | 设权限;带 `PROT_EXEC` 失败时先开 HarmonyOS 的 jit 开关再试一次(见坑 3.7;**开关值 0=开、1=关**,写反过一次,musl 侧预载/dlopen 全废) |
| `flush_icache(p,n)` | aarch64:`dc cvau`/`dsb ish`/`ic ivau`/`isb`(见坑 6) |

**为什么只改 `map_library` 就够**

`dlopen()` 与 `DT_NEEDED` 两条路都汇到 `load_library() → map_library()`(源码里就那两处
调用:`dlopen` 与 `load_deps`),改这一个函数两条都覆盖。而 **ldso 自己**(以及主程序)
不经过这里:`__dls2` 里 `kernel_mapped_dso()` 只是把外面(内核,或设备上我们的
elfloader)已经映射好的段**登记**进 link map,从不重新映射自己 —— 所以自映射、
`__dls2`/`__dls2b`/`__dls3` 三段启动流程、`builtin_tls` 都不受影响。

**验证副作用**:地址空间里不再有库的文件映射,`/proc/self/maps` 里搜库名应该一条都搜
不到(设备侧自检可以按这条判)。

---

## 2. 为什么是 musl 1.2.2(release tarball),不是工具链里那份

设备以前用的解释器来自 `/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross`
(musl.cc 2021-11-23 的那套 GCC 11.2.1)。它那份 `libc.so` 自报:

```
$ strings -a .../aarch64-linux-musl/lib/libc.so | grep -m1 '^1\.2\.'
1.2.2-git-50-gb76f37fd
```

也就是 **1.2.2 之后的第 50 个 git 提交**。musl 不做符号版本化,所以编加载器用
`musl.libc.org` 的 **1.2.2 release tarball** 就 ABI 兼容,而且能钉 sha256:

```
url    https://musl.libc.org/releases/musl-1.2.2.tar.gz
sha256 9b969322012d796dc23dda27a35866034fa67d8fb67e0e2c45c913c3d43219dd
```

`install` 阶段会把我们这份导出的动态符号和工具链那份对一遍,当前差 **2 个**:

```
pthread_getname_np, qsort_r
```

这两个都是 1.2.2 **之后**那 50 个提交里加的(工具链头文件里也有声明),我们这份没有。
仓库里的 guest 源码没有用它们(实测 8 个组合 + TLS 探针全过);哪天有 guest 非要用,
要么给它打补丁,要么改用 git 快照 `b76f37fd` 编 —— 但那就不是"release + 钉 sha256"了,
所以留在这一条里明写。

---

## 3. 踩过的坑

### 3.1 `aarch64-linux-musl-ar: No such file or directory`(make 到 libm.a 就停)

musl 的 Makefile 直接用 `$(CROSS_COMPILE)ar` / `$(CROSS_COMPILE)ranlib` / `$(CC)`,
`CC` 我们显式给了绝对路径,但 `ar`/`ranlib` 是从 `PATH` 找的。修法:`build_musl.sh`
把 `$MUSL_TC/bin` 前插进 `PATH`(不是只设 `CC`)。

### 3.2 `readelf | grep -q` 在 `pipefail` 下误报"没找到符号"

`env.sh` 开了 `set -euo pipefail`。`readelf -s | grep -q _dlstart` 里 grep 命中就退出,
readelf 随即吃到 `SIGPIPE`(退出码 141),整条管道被判失败 —— 明明符号就在那儿。
和 `build_testprogs.sh` 里注明的那条是同一个坑。修法:先把 `readelf` 输出落临时文件再
grep(install 阶段就是这么写的)。

### 3.3 `_dlstart` 不在 `.dynsym` 里

`_dlstart` 是 ldso 的入口,musl 把它标成 hidden,只在 `.symtab` 里。判"这份像不像
musl 的 ldso"要用 `readelf -sW`(全部符号)而不是 `--dyn-syms`;顺带核对
`readelf -h` 的 Entry point 是否等于 `_dlstart` 的值。

### 3.4 最低地址那个 `PT_LOAD` 得自己填

上游的第一次 `mmap` 是"把整个文件镜像从 `off_start` 映射 `map_len` 字节",所以**最低
地址那个段的内容是白捡的**;循环里那句 `if ((ph->p_vaddr & -PAGE_SIZE) != addr_min || …)`
就是"跳过它"。改成匿名预留之后没人往里填了,表现会是加载器拿到段指针后一用就
SIGSEGV。修法:去掉这个跳过分支,每个段都走 `map_segment()`(对最低那一段,填进去的
内容与上游文件映射的完全一样)。

### 3.5 文件尾 / 半页 bss:哪部分要补零、哪部分不用

`map_segment()` 里 `pread` 读到 0 就 break —— 文件尾之后落在全新匿名页上,本来就是 0
(与内核在文件映射上"超出 EOF 的页读作 0"一致),**不用**补零。但"段内 `filesz` 到页边界"
之间那半页是从文件读进来的(往往是文件里下一段的数据),所以上游那句
`memset((void *)brk, 0, pgbrk-brk & PAGE_SIZE-1)` 必须留着,我们保留原样。

### 3.6 aarch64 必须清 D-cache / I-cache

段内容是 `pread` **写**进去的,可能还停在 D-cache,直接当代码执行有取到旧指令的风险。
`__builtin___clear_cache` 会引入对 libgcc `__clear_cache` 的依赖(ldso 里不方便),所以
内联了 `dc cvau` / `dsb ish` / `ic ivau` / `dsb ish` / `isb` 这一串。

### 3.7 匿名页变可执行要 HarmonyOS 的 jit 开关

这台设备的 W^X 只在 `prctl(0x6a6974 /* 'jit' */, 0, 0)` 打开之后才允许把**匿名页**设成
可执行(elfloader 的 `jit_toggle()`/`mprotect_final` 就是在做这套)。所以补丁里包了一层
`set_prot()`:先直球 `mprotect`,带 `PROT_EXEC` 且失败时开一次 jit 再重试。原生 Linux 上
这个 `prctl` 返回 `EINVAL`,重试还是失败,行为与上游一致。

**开关值是 0=开、1=关**(与 elfloader 一致)。这个值写反过一次(拿 `1` 当"开门",和
`scripts/glibc-ohos/` 那份补丁是同一个错),后果是**等于从没开过门**:musl 侧任何
"运行期加载的 .so"——`LD_PRELOAD`、`dlopen`、`DT_NEEDED`——都在 `set_prot()` 这里
`mprotect` 失败,报

```
Error loading shared library /…/libbshguest-musl.so: Invalid argument
```

而 musl 的 `load_preload()` 对预载失败是**静默跳过**(不看返回值、不打印),症状于是变成
"明明设了 LD_PRELOAD 却完全没生效":实测 `/proc/self/exe` 的替身在 glibc guest 里 8/8 全过、
在 musl guest 里一条都不生效。反汇编自证:
`prctl('jit', x2=0) → mprotect → prctl('jit', x2=1)`。

(顺带:musl 的 `load_library()` 还会**拒绝**"自己定义了 `__libc_start_main` 和 `stdin` 的
.so"——那是"第二个 libc"的判据,所以任何 `LD_PRELOAD` 的 shim 都不要去定义这两个名字。)

### 3.8 FDPIC 分支留着没改

`map_library()` 里还有一条 `if (DL_FDPIC && …)` 的分支,仍然用文件 `mmap`。aarch64 上
`DL_FDPIC` 恒为 0,是死代码 —— 改了也测不到,所以只加了一条注释说明要支持 FDPIC 目标
时得照着改。

### 3.9 out-of-tree 构建不用自己搬源码

musl 的 `configure` 支持 out-of-tree:在构建目录里跑 `../musl-1.2.2/configure`,它会生成
`config.mak`(`srcdir = ../musl-1.2.2`)并软链 `Makefile`。所以 `build/musl/b` 与源码目录
是分开的,`clean` 也互不影响。

---

## 4. 补 DT_RELR(musl 1.2.4 才有的紧凑相对重定位)

### 4.1 症状

Qt 程序经 elfloader 起来后在 **加载 OHOS 系统库**时崩,现场非常"说不通":

```
[crash] signal=0xb fault=0xa0e4 pc=0xa0e4
[crash] lr=.../ld-musl-aarch64.so.1+0x625d4      ← do_init_fini 里 blr 的下一条
```
`0xa0e4` 是**模块内的链接期偏移**,不是运行期地址 —— 说明 `.init_array` 里那个构造函数
指针从没被重定位过。

### 4.2 根因

`/system/lib64/platformsdk/libz.so` 的动态段里有 `DT_RELR/DT_RELRSZ/DT_RELRENT`
(`readelf -d` 能看到 `(RELR) 0x2570 (RELRSZ) 32 (RELRSZ) 8`),它的相对重定位**全在 RELR 表里**。
musl 1.2.2 只有 `DT_REL`/`DT_RELA` 两条路,RELR 表被整表忽略 → 那些字保持链接期残值。
(readelf 里 `DT_RELRSZ=35 / DT_RELR=36 / DT_RELRENT=37`;1.2.2 的 `elf.h` 里没有这三个宏,
`decode_vec()` 又只保留 `< DYN_CNT` 的 tag,所以**要么补宏、要么连 `DYN_CNT` 一起抬**。)

### 4.3 补法(见 `patches/0002-dynlink-dt-relr.patch`)

| 文件 | 改了什么 | 为什么 |
| --- | --- | --- |
| `src/internal/dynlink.h` | `DYN_CNT 32 → 40` | `decode_vec()` 只保留 tag < `DYN_CNT` 的项;35/36/37 必须能进来 |
| `ldso/dynlink.c` | `#ifndef DT_RELRSZ/DT_RELR/DT_RELRENT` | 1.2.2 的 `elf.h` 没有这三个宏 |
| `ldso/dynlink.c` | `reloc_all()` 里 `DT_RELA` 之后加 RELR 解码循环 | 偶数项=单地址(下一个地址 +8),奇数项=位图(bit0 是标记、bit k 对应 `where+(k-1)*8`,之后 `where += 63*8`),每个目标字 `+= base` |

### 4.4 踩过的坑(值得单独记一笔)

- **`1 << DT_RELR` 会被编译器折成 0**:`DT_RELR=36`,而字面量 `1` 是 32 位 `int`,
  `1<<36` 是 UB,GCC 直接折成 `0` → 整个 `if` 块被当**死代码删掉**。症状极具误导性:
  `strings` 里"分支外的打印"还在、"分支内的打印"没了;设备行为与"补丁没生效"完全一样。
  必须是 **`1UL << DT_RELR`**(`decode_vec()` 自己也是用 `1UL<<v[0]` 置位的)。
  自检:`grep -ac "RELR" feature/bsh_main/libs/arm64-v8a/ld-musl-aarch64.so.1` 之类的字符串检查不够,
  要 `llvm-objdump -d … | grep -c "tbnz.*#0x24"`(bit 36 的位测试)才算证据。
- **改了 musl 就一定重跑 `install`**:`install` 才是把它交付到
  `feature/bsh_main/libs/arm64-v8a/ld-musl-aarch64.so.1` 的那一步;只 `build` 不 `install`,
  设备上跑的仍是旧加载器。
- **hvigor 的 strip 缓存不刷新**:换掉 `feature/bsh_main/libs/arm64-v8a/*.so` 后,若
  `feature/bsh_main/build/default/intermediates/stripped_native_libs/` 还在,HAP 里可能仍是旧产物。
  打包前 `rm -rf feature/bsh_main/build/default/intermediates/stripped_native_libs`。

---

## 验证方式速查(本机,不碰设备)

```bash
# 编(各阶段幂等,可单独重跑)
./scripts/build_musl.sh all

# 1) 造两个 qemu 前缀:新编的 与 工具链原厂的(做前后对照)
./scripts/build_musl.sh pack                     # → build/musl/prefix/lib/{ld-musl-aarch64.so.1, libc.so}
mkdir -p build/musl/prefix-tc/lib
cp /workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross/aarch64-linux-musl/lib/libc.so \
   build/musl/prefix-tc/lib/ld-musl-aarch64.so.1
ln -sf ld-musl-aarch64.so.1 build/musl/prefix-tc/lib/libc.so

# 2) 8 个组合的产物
./scripts/build_testprogs.sh
cd build/testprogs/testprogs

# 3) 全套用例(没 pty 时 tty 那格 SKIP)
QEMU_LD_PREFIX=$PWD/../../musl/prefix   qemu-aarch64-static ./aarch64-musl-dynamic < /dev/null
#    → blocks=32  pass=31  fail=0  skip=1,退出码 42
#    有 pty 时(run_testprogs_host.sh 的跑法)是 pass=32 fail=0 skip=0

# 4) 判据:新加载器不再对 .so 做带 fd 的 mmap
QEMU_LD_PREFIX=$PWD/../../musl/prefix    qemu-aarch64-static -strace ./dlhost-aarch64-musl-dynamic 2>/tmp/new.txt
QEMU_LD_PREFIX=$PWD/../../musl/prefix-tc qemu-aarch64-static -strace ./dlhost-aarch64-musl-dynamic 2>/tmp/tc.txt
grep -aE ' mmap\(' /tmp/tc.txt  | grep -av ',\-1,'   # 原厂 2 条(其中 1 条带 PROT_EXEC)
grep -aE ' mmap\(' /tmp/new.txt | grep -av ',\-1,'   # 新编 0 条
grep -ac ' pread64(' /tmp/new.txt                    # 新编 3 条

# 5) 回归:走工具链原厂加载器的那圈(脚本行为不变)
./scripts/run_testprogs_host.sh
```

本次验收用的产物(可复现:同样的源码 + 补丁 + 工具链编两遍 sha256 一样):

```
build/musl/out/lib/ld-musl-aarch64.so.1
sha256 2faec981b8f34065092de60640d0ee2685e8dc43f17cd42baaa0dcee4454f715  (937512 字节)
```

实测数字(2026-09-28,宿主 x86_64 + qemu-aarch64 8.2.2,< /dev/null):

| 场景 | 原厂 libc.so | 新编 ld-musl-aarch64.so.1 |
| --- | --- | --- |
| `dlhost-…`(DT_NEEDED 一个 .so)全程 mmap 总数 | 3 | 2 |
| 其中**带 fd 的** mmap | 2 | **0** |
| 其中带 `PROT_EXEC` 的 | 1 | **0** |
| `pread64` 次数 | 0 | 3 |
| `aarch64-musl-dynamic` 全程带 fd 的 mmap | 2 | **0** |
| \| 全程 `mmap` 总数 | 27 | 26 |
| \| 全程 `pread64` | 0 | 3 |

新编那份加载一个 .so 的完整过程(截自 `/tmp/new.txt`):

```
openat(AT_FDCWD,".../libtgreet-aarch64-musl-dynamic.so",O_RDONLY) = 3
mmap(NULL,73728,PROT_NONE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0)            ← 匿名预留
mprotect(0x…,4096,PROT_READ|PROT_WRITE)                              ← 代码段先可写
pread64(3,0x…cf000,4096,0) = 4096                                    ← 读入
mprotect(0x…cf000,4096,PROT_EXEC|PROT_READ)                          ← 再变 r-x
mprotect(0x…df000,8192,PROT_READ|PROT_WRITE)
pread64(3,0x…df000,8192,0) = 8136
pread64(3,0x…e0fc8,56,8136) = 0                                      ← 文件尾,剩下留 0
mprotect(0x…df000,8192,PROT_READ|PROT_WRITE)
close(3) ; mprotect(0x…df000,4096,PROT_READ)                         ← relro
```

`run_testprogs_host.sh`(仍用工具链原厂加载器,脚本行为未改)8 行汇总:

```
x86_64-glibc-dynamic   rc=42  blocks=32 pass=32 fail=0 skip=0
x86_64-glibc-static    rc=42  blocks=32 pass=32 fail=0 skip=0
x86_64-musl-dynamic    rc=42  blocks=32 pass=32 fail=0 skip=0
x86_64-musl-static     rc=42  blocks=32 pass=31 fail=0 skip=1
aarch64-musl-dynamic   rc=42  blocks=32 pass=32 fail=0 skip=0
aarch64-musl-static    rc=42  blocks=32 pass=31 fail=0 skip=1
aarch64-glibc-dynamic  rc=42  blocks=32 pass=32 fail=0 skip=0
aarch64-glibc-static   rc=42  blocks=32 pass=32 fail=0 skip=0
✅ 8 个组合本地全过(0 FAIL)
```

把 `build/testprogs-host/prefix-musl/lib/ld-musl-aarch64.so.1` 换成新编那份再跑一遍
8 行,结果完全一样(0 FAIL) —— 也就是"换了运行时之后整圈没退化"。本机 qemu 里
**两**份加载器都能过,因为 qemu 没有沙箱那道闸;"能不能绕开闸"要等真机。

额外两条针对"TLS/自映射仍然正确"的探针(用工具链编,`/tmp/tlstest`,不随仓库走):

```
# dlopen 一个带 __thread 的 .so:主线程初值/写回、新线程初值/写回、线程隔离
$ QEMU_LD_PREFIX=build/musl/prefix    qemu-aarch64-static ./tls-main
who()=libtls
TLS 全部 PASS(初值/写回/线程隔离)                                    rc=0
# DT_NEEDED 一条:主程序自己的 __thread 与库里 TTLS 互不干扰
$ QEMU_LD_PREFIX=build/musl/prefix    qemu-aarch64-static ./tls-need
动态依赖(TTLS/DT_NEEDED) TLS 初值正确 (get0()=7, 本程序 tls0=5)      rc=0
# ldso 被当命令直接跑一个 ET_EXEC(固定地址那条路,`-no-pie` 编的)
$ QEMU_LD_PREFIX=build/musl/prefix    qemu-aarch64-static build/musl/prefix/lib/ld-musl-aarch64.so.1 ./exec-nopie
动态依赖(TTLS/DT_NEEDED) TLS 初值正确 (get0()=7, 本程序 tls0=5)      rc=0
```

ET_EXEC 那条的 strace 也干净:预留就落在 `0x400000`(`mmap(0x400000,73728,PROT_NONE,
MAP_PRIVATE|MAP_ANONYMOUS,-1,0) = 0x400000`),然后 `pread` + `mprotect`,没有文件映射。

## 接线方式(留给上层,本脚本不碰)

设备侧只按 **basename** 从 bundle libs 找解释器(`procmgr.cpp` 的 `ChildRunElf`),
所以要把这份换上去,就是把

```
build/musl/out/lib/ld-musl-aarch64.so.1   →   feature/bsh_main/libs/arm64-v8a/ld-musl-aarch64.so.1
```

(现在那一步是 `build_testprogs.sh` 从工具链 `.../aarch64-linux-musl/lib/libc.so` 拷的;
把它换成读 `build/musl/out/lib/` 即可 —— 本仓库目前**没有**改,保持原样移交。)

## 与上游的差异清单

| 文件 | 改了什么 | 为什么 |
| --- | --- | --- |
| `ldso/dynlink.c` | `map_library()` 第一次 mmap 改成匿名 `PROT_NONE` 预留 | 沙箱拦 file-backed 的可执行映射;noexec 挂载 |
| `ldso/dynlink.c` | 每个 `PT_LOAD`(含最低那个)改走新的 `map_segment()`:mprotect + pread + mprotect | 同上(内容改从 fd 读进匿名页) |
| `ldso/dynlink.c` | `DT_TEXTREL` 那句 `mprotect(RWX)` 改走 `set_prot()` | jit 开关(坑 3.7) |
| `ldso/dynlink.c` | 新增 `flush_icache()`(aarch64) | pread 写进去的代码要先清 cache(坑 3.6) |
| `src/internal/dynlink.h` | `DYN_CNT 32 → 40` | 让 `decode_vec()` 保留 `DT_RELRSZ/DT_RELR/DT_RELRENT`(35/36/37) |
| `ldso/dynlink.c` | 补 `DT_RELRSZ/DT_RELR/DT_RELRENT` 三个宏;`reloc_all()` 里加 RELR 解码 | OHOS 系统库的相对重定位只在 RELR 表里(第 4 节) |

**上游基线**:`thirdparty/musl-1.2.2.tar.gz`(sha256 钉在 `build_musl.sh` 里)+ 上面两个 patch。
自检口径:全新解包 → 打这两个 patch → `build`+`install`,产出的
`ld-musl-aarch64.so.1` 应与已交付那份**逐字节相同**(本仓库当前是
`md5 = 2a99058833ff80d9a00c5b0a33b1331a`)。

configure 侧的差异(不是 patch,写在 `build_musl.sh` 里):`--target=aarch64-linux-musl`、
`--prefix=/usr`、`--syslibdir=/lib`(解释器真名/路径按 `PT_INTERP` 写的那条来)、
`--disable-static`(只要那份能当解释器的 libc.so)、以及把工具链 `bin/` 前插 `PATH`。
