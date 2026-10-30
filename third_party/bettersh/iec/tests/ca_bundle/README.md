# CA bundle（cacert.pem）可用性与接线测试

验证 IEC 随包的那份 CA bundle 本身能用，以及它从 CMake 嵌入到设备落盘、再到
`git` / `curl` / `openssl` 环境变量的整条接线是对的。

被测文件：`third_party/bettersh/iec/assets/cacert.pem`（Mozilla 根证书，
curl.se 的 `cacert.pem` 格式，构建期由 `tools/embed_file.py` 转成
`cacert_pem.h` 编进 `libiec_server.so`）。

## 运行

```bash
bash third_party/bettersh/iec/tests/ca_bundle/run.sh

CA_BUNDLE=/path/to/cacert.pem bash .../run.sh   # 验证别的 bundle（负向对照用）
CA_REQUIRE_NET=1 bash .../run.sh                # 没有可达主机时也算 FAIL
```

依赖 `curl`、`openssl`、`python3`、`git`、`bash`。**不连设备、不需要 HarmonyOS
SDK**，但会访问 `pypi.org` / `gitcode.com` / `mirrors.tuna.tsinghua.edu.cn` 做真握手。

退出码：

| 码 | 含义 |
| --- | --- |
| 0 | 离线检查 + 至少一台主机用该 bundle 真握手通过 |
| 1 | 有断言失败（**证书错误一定走这里**） |
| 77 | SKIP：缺 curl/openssl/python3/git，或所有候选主机都不可达 |

`check-all.sh` 把 77 记为 SKIP、1 记为 FAIL。

## 判据：证书错误 vs 网络不可达

这是本检查最容易做歪的地方——把"网不通"判成 FAIL 会天天误报，把"证书错"判成
SKIP 就等于没测。脚本按下面这张表分类：

| 现象 | 判定 |
| --- | --- |
| curl `rc=60/51/58/59/77/83/90/91`，或 stderr 含 certificate / unable to get local issuer / self-signed / verify failed | **FAIL** |
| python `ssl.SSLCertVerificationError` | **FAIL** |
| git stderr 含 `SSL certificate problem` / `certificate (verification) failed` / `certificate signer not trusted` / `unable to get local issuer` | **FAIL** |
| curl `rc=6/7/28/35/56`（DNS/拒连/超时），python `gaierror`/`timeout`/`SSLError` | SKIP（仅记录） |
| git `Could not resolve host` / `Failed to connect` / `Connection timed out` | SKIP（仅记录） |
| curl 握手成功但 HTTP 4xx/5xx | PASS（证书校验已通过） |

`github.com` 在很多网络环境下直连不通，此时是 `rc=7`，只记 INFO；脚本会继续试
`gitcode.com` / `gitee.com` / 清华镜像。

## 用例

| # | 用例 | 断言 |
| --- | --- | --- |
| 1 | 文件存在且非空 | 字节数 > 0，打印 sha256 |
| 2 | 行尾 | 纯 LF 才算 PASS，CRLF 只记录（设备按字节落盘，CR 不影响 OpenSSL） |
| 3 | PEM 块配对 | `BEGIN CERTIFICATE` 与 `END CERTIFICATE` 数量相等且 > 0 |
| 4 | 无私钥 | 不含 `PRIVATE KEY` 块 |
| 5 | 头部元数据 | 打印 `Certificate data from Mozilla as of: …`，无时间戳只记录 |
| 6 | 全部证书可解析 | `openssl crl2pkcs7 \| openssl pkcs7 -print_certs` 解析出的张数等于 PEM 块数 |
| 7 | 无过期根 | 逐张 `openssl x509 -checkend 0`；过期只记录，不判失败 |
| 8 | 关键根在不在 | **必须**有 `ISRG Root X1`、`ISRG Root X2`（Let's Encrypt）与 `DigiCert Global Root G2`（GitHub）；USERTrust/GTS/Amazon 等只报告 |
| 9 | 根数量量级 | ≥ 80 张（截断的 bundle 通常远少于这个数） |
| 10 | python 能加载 | `ssl.create_default_context(cafile=…)` 加载的根数等于 PEM 块数 |
| 11 | CMake 嵌入源 | `IEC_CA_SOURCE "${IEC_ROOT}/assets/cacert.pem"` 且符号名 `iec_cacert_pem` |
| 12 | C++ 落盘路径 | 用的是嵌入数组的 `iec_cacert_pem_size`，文件名 `<dir>/cacert.pem` |
| 13 | ArkTS 落盘目录 | `<sysroot>/etc/ssl/certs` + 调用 `installCaBundle(dir)` |
| 14 | 三个环境变量 | `GIT_SSL_CAINFO` / `SSL_CERT_FILE` / `CURL_CA_BUNDLE` 都赋值为同一个 `ca` |
| 15 | 嵌入流程预演 | 真跑 `tools/embed_file.py`，把生成头的十六进制还原回字节，与源文件逐字节比对 |
| 16 | curl 真握手 | `curl --cacert <bundle>` 对 pypi / gitcode / 清华镜像（GitHub 常不通） |
| 17 | CURL_CA_BUNDLE | 用环境变量代替 `--cacert`，再验一台已通的主机 |
| 18 | python 真握手 | `ssl.create_default_context(cafile=…)` 对候选主机逐个尝试 |
| 19 | SSL_CERT_FILE | 不传 cafile，只靠环境变量，再验一次 |
| 20 | git 真握手 | `GIT_SSL_CAINFO=<bundle> git ls-remote … HEAD`，输出里要有 40 位 commit |

## 为什么要把 capath 指到空目录

`curl --cacert` / `SSL_CERT_FILE` / `GIT_SSL_CAINFO` 都只设置 **CAfile**，而
Ubuntu 的 curl 与 OpenSSL 还会同时加载编译期的 **CApath**（`/etc/ssl/certs`），
两边是**并集**。于是只给一个残缺的 bundle，校验仍可能被系统库救活，测出来是假
PASS。脚本因此额外传 `--capath` / `SSL_CERT_DIR` / `GIT_SSL_CAPATH` 指向临时空
目录，信任锚只剩被测文件——这也更接近设备现场：假根 `<sysroot>` 里没有系统 CA 库。

用单张无关根做负向对照时，这三条都会给出证书错误（curl 60、python
`SSLCertVerificationError`、git `certificate signer not trusted`），确认脚本不是
"怎么都能过"。

## 当前 bundle 的事实

- 大小 188900 字节，121 张根证书（全部 `CA:TRUE`，121 个不同 subject）
- 头部时间戳 `Fri Sep 25 03:12:01 2026 GMT`，`mk-ca-bundle.pl version 1.33`
- 与上游 curl.se 2026-10-20 版（118 张）相比，只多 3 张 eMudhra 的 emSign 根
  （上游后来移除）；GitHub / PyPI / 清华镜像用的根都在
- 无过期根
