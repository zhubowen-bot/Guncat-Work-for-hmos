# npm.tar.gz 解包回归（宿主）

验证设备首次启动时 `IecRuntime.unpackNpm()` 走的那条路径：
`unpackResource('tools/npm.tar.gz', SYSROOT)` → 读 rawfile → libarchive 解包。
这条路径原来只在设备上跑过，本目录把它搬到宿主：`UnpackResource()` 里与平台
无关的核心已经抽到 `common/archive_extract.cpp` 的 `IecExtractTar()`，harness
直接编译同一份源码，用真实的 `npm.tar.gz` 跑。

被测文件：
`third_party/bettersh/iec/platform/ohos/har/src/main/resources/rawfile/tools/npm.tar.gz`
（npm 10.9.3 的 deps/npm 树，随包 rawfile，git 已跟踪）。

被测实现：
`third_party/bettersh/iec/common/archive_extract.cpp`
（设备侧 `platform/ohos/har/src/main/cpp/napi_init.cpp` 的 `UnpackResource()`
只保留 rawfile 读取与字符串参数转换）。

## 运行

```bash
bash third_party/bettersh/iec/tests/npm_unpack/run.sh

NPM_TAR=/path/to/npm.tar.gz bash .../run.sh   # 验证别的 tar（负向对照用）
BSDTAR=/path/to/bsdtar bash .../run.sh        # bsdtar 不在 PATH 时
CXX=clang++ bash .../run.sh                   # 指定 C++17 编译器
IEC_NPM_TEST_VERBOSE=1 bash .../run.sh        # 打开 IecExtractTar 的 stderr 日志
```

依赖 `python3`、宿主 libarchive 运行库与 C++17 编译器；`bsdtar` 可选：

```bash
# Ubuntu
sudo apt-get install libarchive-tools libarchive13 python3 g++
# 没有 bsdtar 时会自动用 python3 的 tarfile 作参考解包（结果等价，只是少一个
# 独立实现交叉验证）；装了 bsdtar 则优先用它：
apt-get download libarchive-tools
dpkg-deb -x libarchive-tools_*.deb /tmp/la-tools
BSDTAR=/tmp/la-tools/usr/bin/bsdtar bash .../run.sh
```

**不需要 libarchive 头文件**：被测核心与设备一致，是运行期
`dlopen("libarchive.so.13")`，不是链接 `-larchive`。因此宿主只要能加载
`libarchive.so.13`（或 `libarchive.so`）即可，harness 不需要 `libarchive-dev`。
`bsdtar` 只用来产出一棵独立的参考树。

退出码：

| 码 | 含义 |
| --- | --- |
| 0 | 全部 PASS |
| 1 | 有断言失败 |
| 77 | SKIP：缺 python3 / bsdtar / libarchive 运行库 / C++ 编译器（或 tar 不存在以外的环境问题） |

`check-all.sh` 把 77 记为 SKIP、1 记为 FAIL。

## 用例

| # | 用例 | 断言 |
| --- | --- | --- |
| 1 | 归档条目数 | `npm.tar.gz` 恰好 2697 个条目（目录 559 + 文件 2138） |
| 2 | 顶层结构 | 只有一个顶层目录 `npm/` |
| 3 | package.json | `npm/package.json` 的 `version` 为 `10.9.3` |
| 4 | 入口文件 | `npm/bin/npm-cli.js`、`npm/bin/npx-cli.js` 存在且非空 |
| 5 | 非压缩总量 | 解包后所有普通文件字节数之和 = 归档条目 size 之和（10,715,830 字节） |
| 6 | 参考树 | bsdtar 解出的条目路径集合与归档逐条一致 |
| 7 | 实现树 | harness 调 `IecExtractTar()` 解出的条目集合 / 总字节数与参考树一致 |
| 8 | 逐文件 | 固定种子抽 200 个文件 + 两个入口，与参考树比 sha256 |
| 9 | 完成标记 | 成功路径写出 `npm/.unpack-complete`，内容 `ok\n` |
| 10 | 截断 tar | 取前 1KB 的 tar 返回非 0，且不留 `.unpack-complete` 与 `npm-cli.js` |
| 11 | 只读目标 | 目标目录 `chmod 0555` 时解包返回非 0（root 下跳过） |

## 完成标记为什么由 harness 写

`.unpack-complete` 不是 C 核心写的：ArkTS 的 `IecRuntime.unpackNpm()` 在
`unpackResource()` 返回 0 后写 `<sysroot>/npm/.unpack-complete`，失败或异常时
`dropIncompleteNpm()` 删标记和 `npm-cli.js`。宿主没有 ArkTS，所以
`harness.cpp` 原样复刻这段调用方协议，失败路径的"不留标记/入口"才有意义。
`check.py` 比对归档树时会把这个标记文件排除（它不属于 tar 内容）。

## 与设备行为的对应

- 核心仍然用 `archive_read_open_memory()` 读内存里的 tar，filter/format 全开；
  设备上 rawfile 读取失败在 `UnpackResource()` 里就会返回 1，不会进核心。
- 核心仍然运行期 `dlopen` libarchive，候选名与原来一致（`libarchive.so.13`、
  `libarchive.so`、HAR libs 下的绝对路径）。
- `archive_write_disk_set_options(TIME | PERM | SECURE_NO_DOTDOT)` 未变；
  条目路径仍过 `SafeJoin()` 的 `..` 检查，`ARCHIVE_WARN` 只记日志。
- 设备上 libarchive 被 `fs/shim.c` 接管 `symlink()`；npm 树里没有符号链接，
  宿主与设备的差异不影响本测试。日志文案未变，hilog grep 关键词不受影响。
