# toybox_parse — 用真实 toybox 输出交叉验证 applet 解析

`IecRuntime` 不抄静态 applet 清单，而是在运行时跑一次 `<sysroot>/bin/toybox`
（无参数），把输出解析成命令名，再给每个 applet 写一个指向 `libtoybox.so` 的
launcher。显式注册的命令（`add(...)` / `writeSoLauncher(...)`）优先，绝不能被
同名 toybox applet 覆盖 —— 最典型的是 `nc`：toybox 也带 `nc`，但我们要用自己
编的 `libnc.so`。

这个测试把同一份 toybox 源码在宿主 x86_64 上编出来，拿**真实输出**喂给一份
Python 复刻的解析器，验证解析规则、显式覆盖和最终 launcher 集合。不连设备、
不需要 HarmonyOS SDK、不访问网络。

## 运行

```bash
# 自动构建（源码未变时复用 /tmp/toybox-host）后检查
bash third_party/bettersh/iec/tests/toybox_parse/run.sh

# 已经手动构建过 /tmp/toybox-host
python3 third_party/bettersh/iec/tests/toybox_parse/check.py

# 指定别的产物 / 强制重编
TOYBOX_HOST=/tmp/my-toybox bash .../run.sh
TOYBOX_PARSE_FORCE_BUILD=1 bash .../run.sh
```

依赖：`bash`、`python3`、`cc`、`make`、`tar`。缺少时 `run.sh` 退出 `77`
（`scripts/check-all.sh` 记为 SKIP）；构建失败退出 `2`；断言失败退出 `1`。

`run.sh` 把源码复制到临时目录再 `make defconfig && make`，不改仓库里的 toybox
源树（那里可能留着设备交叉构建的 `.config`/`generated/`）。产物默认
`/tmp/toybox-host`，通过原子替换更新。

## 被测的解析规则（与 ArkTS 逐条对应）

`IecRuntime.listToyboxApplets()`：

1. 用 `out.replace(/[\[\]]/g, ' ')` 把方括号替换成空格；
2. 按 `\s+` 分词；
3. 只保留 `0 < part.length < 32` 且匹配 `^[a-z0-9_]+$` 的 token；
4. 不做去重、不排序。

`IecRuntime.writeToyboxApplets()`：

5. 跳过空串和 `toybox`；
6. 跳过 `IecRuntime.explicitNames` 里的名字；
7. 其余每个 applet 写 `libtoybox.so` 的 launcher。

`IecRuntime.writeLaunchers()`：

8. `add('name', 'libX.so', ...)`、`for (const name of [...]) add(name, ...)`
   与 `writeSoLauncher(BIN_DIR + 'name', BUNDLE_LIBS + 'libX.so', ...)`
   注册的显式命令进入 `explicitNames`。

## 断言

1. 复刻解析出的 applet 集合 == `toybox --long`（剥掉 `bin/`、`usr/bin/` 等
   路径前缀后）的 applet 集合；`--long` 不可用时退回无参输出。另外断言无参
   输出与 `--long` 的集合一致。
2. 从 `IecRuntime.ets` 的 `writeLaunchers()` 解析显式注册名及 so；所有与
   toybox applet 同名的显式命令都必须被跳过，不能写回 `libtoybox.so`。
3. 最终 launcher 集合 == `explicit ∪ (applets - explicit)`，且 toybox 写入与
   显式写入不重叠。
4. 关键命令最终可用：
   - `dd` / `md5sum` / `od` / `nproc`：由 toybox 提供；
   - `nc` / `hexdump` / `diff` / `jq` / `sh` / `mksh`：来自显式注册；
   - `nc` 必须同时出现在 toybox 输出里（覆盖路径被真实触发），且 launcher
     指向 `libnc.so` 而不是 `libtoybox.so`。
5. 诊断打印：toybox 有但最终不存在的 applet（按当前实现应为空）、被我们自己的
   so 覆盖的 applet、最终存在但 toybox 没有的命令。

## 宿主 defconfig 与设备 config 的差异

设备侧 `scripts/build_toybox.sh` 先在 defconfig 上做开关：

- 打开：`MOUNT`、`UMOUNT`、`GZIP`、`GUNZIP`、`ZCAT`、`WGET`、`PING`、
  `NETSTAT`、`IFCONFIG`、`AWK`、`TR`、`STTY`；
- 关闭：`LOGIN`、`SULOGIN`、`NOLOGIN`、`W`、`WHO`、`USERS`、`LAST`、
  `LASTLOG`、`UPTIME`、`UTMPDUMP`、`SU`、`AC`、`PASSWD`、`CHSH`、`CHFN`、
  `CRYPTPW`。

在宿主 defconfig 上实际能看到的 applet 集合差异（同一份源码，0.8.15）：

| 方向 | applet |
| --- | --- |
| 设备多出 | `awk`、`gzip`、`stty`、`tr` |
| 设备少掉 | `login`、`nologin`、`su`、`uptime`、`w`、`who` |

其余开关在 defconfig 里已经是目标值，不产生差异。宿主版只是解析器的输入，
不要求 applet 集合与设备完全相同；差异不影响解析规则本身。

## 已知限制

- 显式注册名是从 ArkTS 源码**静态**提取的，相当于假定 `hasSo(...)` 都为真。
  它验证的是命名与优先级，不验证实际打包了哪些 `.so`；设备上缺 so 时该命令
  只是 `command not found`，不会覆盖 toybox。
- `writeLaunchers()` 里 `hasSo` 条件之外的动态注册（当前没有）不会被识别；
  新增写法时需要同步扩展 `parse_explicit_names()`。
- 宿主 toybox 版本报 `0.8.15`；设备构建脚本用 `-DTOYBOX_VERSION="0.8.14"`
  覆盖 `main.c`，所以设备上 `toybox --version` 会报 0.8.14。解析只看 applet
  名单，与版本字符串无关。
- `toybox --long` 会给名字加路径前缀（如 `bin/[`、`usr/bin/nc`）。oracle
  先按方括号/空白规则分词，再取最后一个 `/` 之后的部分套正则；无参输出不做
  这一步。

## 当前结果（defconfig，236 个 applet）

- `--long` 与无参输出集合完全一致；`[`、`nbd-client`、`nbd-server` 被规则
  丢弃（`[` 是 toybox 的测试命令；后两个带连字符，ArkTS 同样注册不了）。
- 解析出 36 个显式注册名；与 toybox 重叠 4 个：`cpio`、`hd`、`nc`、`tar`，
  全部被跳过并使用我们自己的 so。
- 最终 launcher 268 个 = 36 显式 + 232 个未被覆盖的 applet。
- 最终存在但 toybox 没有的 32 个命令：我们的 so、`sh`/`mksh` 与 `toybox` 本体。
