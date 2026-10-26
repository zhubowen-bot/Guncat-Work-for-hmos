"""Guncat Work 自带的小工具: 网络分层自检 + 抓取。

放在 site-packages 里, AI 在 run_python 中可直接用：

    import guncat_net
    guncat_net.check()                  # 打印 DNS / TCP / TLS 分段结果与结论
    guncat_net.diagnose()               # 同上, 只返回 dict(不打印), 便于程序判断
    guncat_net.get('https://example.com')          # 取文本
    guncat_net.download('https://x/a.png', 'a.png')  # 下载到文件

为什么要它: 沙箱里"能不能上网"经常不是权限问题, 而是 DNS 解析不到、目标不可达、
或证书链/系统时间不对。分层测一次就能判断断在哪一层, 省得反复猜。
"""

from __future__ import annotations

import os
import socket
import ssl
import time

# 默认探测目标: 优先国内可达的站点, 避免 1.1.1.1 这类在部分地区不可达的地址造成误判
DNS_HOSTS = ("www.baidu.com", "www.bing.com", "pypi.org")
TCP_TARGETS = (("www.baidu.com", 443), ("www.bing.com", 443))
HTTPS_URL = "https://www.baidu.com/"
UA = "GuncatWork/1.0"

PROXY_ENV_KEYS = ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                  "http_proxy", "https_proxy", "all_proxy", "NO_PROXY", "no_proxy")


def _timed(fn, *args, **kwargs):
    started = time.time()
    try:
        value = fn(*args, **kwargs)
        return True, value, (time.time() - started) * 1000.0
    except BaseException as exc:  # noqa: BLE001 - 诊断工具, 任何异常都要报出来
        return False, exc, (time.time() - started) * 1000.0


def _loopback() -> dict:
    """本机回环: 证明 socket 栈本身没问题(与外部网络无关)。"""
    srv = sock = None
    try:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.settimeout(2)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        host, port = srv.getsockname()[:2]
        sock = socket.create_connection((host, port), timeout=2)
        return {"ok": True, "detail": "127.0.0.1:%d" % port}
    except BaseException as exc:  # noqa: BLE001
        return {"ok": False, "detail": repr(exc)}
    finally:
        for s in (sock, srv):
            try:
                s.close()
            except BaseException:
                pass


def _resolve(host: str) -> dict:
    """解析一个域名, 同时报告 A/AAAA 记录条数。"""
    ok, value, ms = _timed(socket.getaddrinfo, host, 443, type=socket.SOCK_STREAM)
    if not ok:
        return {"ok": False, "ms": round(ms), "detail": repr(value)}
    v4, v6 = set(), set()
    for family, _type, _proto, _canon, sockaddr in value:
        if family == socket.AF_INET:
            v4.add(sockaddr[0])
        elif family == socket.AF_INET6:
            v6.add(sockaddr[0])
    return {"ok": True, "ms": round(ms),
            "detail": "IPv4=%s IPv6=%s" % (sorted(v4) or "-", sorted(v6) or "-"),
            "ipv4": sorted(v4), "ipv6": sorted(v6)}


def _tcp(host: str, port: int, timeout: float = 5.0) -> dict:
    ok, value, ms = _timed(
        lambda: socket.create_connection((host, port), timeout))
    if ok:
        try:
            value.close()
        except BaseException:
            pass
        return {"ok": True, "ms": round(ms), "detail": "connected"}
    return {"ok": False, "ms": round(ms), "detail": repr(value)}


def _tls(host: str, port: int = 443, timeout: float = 8.0) -> dict:
    """握手 + 取证书信息。证书过期时给出"系统时间"提示 —— 这是设备上最常见的坑。"""
    ctx = ssl.create_default_context()
    started = time.time()
    try:
        with socket.create_connection((host, port), timeout=timeout) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as tls:
                cert = tls.getpeercert()
                not_after = cert.get("notAfter", "?")
                expires = None
                try:
                    expires = ssl.cert_time_to_seconds(not_after)
                except BaseException:
                    pass
                days_left = None
                if expires is not None:
                    days_left = int((expires - time.time()) // 86400)
                cipher = tls.cipher()
                return {
                    "ok": True,
                    "ms": round((time.time() - started) * 1000.0),
                    "detail": "%s %s | 证书到期 %s(%s天)" % (
                        tls.version(), (cipher[0] if cipher else "?"), not_after,
                        "+" if days_left is None else days_left),
                    "subject": dict(x[0] for x in cert.get("subject", ())),
                    "issuer": dict(x[0] for x in cert.get("issuer", ())),
                    "not_after": not_after,
                    "days_left": days_left,
                    "protocol": tls.version(),
                    "cipher": cipher[0] if cipher else "",
                }
    except ssl.SSLCertVerificationError as exc:
        return {"ok": False, "ms": round((time.time() - started) * 1000.0),
                "detail": "证书校验失败: %s | 常见原因: 设备系统时间不对, 或中间设备替换了证书"
                          % exc.verify_message}
    except BaseException as exc:  # noqa: BLE001
        return {"ok": False, "ms": round((time.time() - started) * 1000.0),
                "detail": "%s: %s" % (type(exc).__name__, exc)}


def _https_probe(http_client, ssl_mod) -> int:
    """真正发一个 HEAD 请求, 验证"能握手"之外还能拿到响应。"""
    host = HTTPS_URL.split("//", 1)[1].split("/", 1)[0]
    conn = http_client.HTTPSConnection(host, timeout=8,
                                       context=ssl_mod.create_default_context())
    try:
        conn.request("HEAD", "/", headers={"User-Agent": UA})
        return conn.getresponse().status
    finally:
        conn.close()


def _proxies() -> dict:
    """报告代理相关环境变量, 并说明 requests 会不会自动使用。"""
    found = {k: os.environ[k] for k in PROXY_ENV_KEYS if os.environ.get(k)}
    return {"env": found, "used_by_requests": bool(found)}


def check(verbose: bool = True) -> dict:
    """分层网络自检, 返回 dict; verbose=True 时顺手打印。"""
    result = {
        "loopback": _loopback(),
        "dns": {},
        "tcp": {},
        "tls": {},
        "https": {},
        "proxies": _proxies(),
        "verdict": "",
    }

    for host in DNS_HOSTS:
        info = _resolve(host)
        result["dns"][host] = info
        if verbose:
            print("DNS   %-16s %s %.0fms %s" % (host, "OK  " if info["ok"] else "FAIL",
                                                info["ms"], info["detail"]))

    for host, port in TCP_TARGETS:
        info = _tcp(host, port)
        result["tcp"]["%s:%d" % (host, port)] = info
        if verbose:
            print("TCP   %-20s %s %.0fms %s" % (host + ":" + str(port),
                                                "OK  " if info["ok"] else "FAIL",
                                                info["ms"], info["detail"]))

    tls_host = HTTPS_URL.split("//", 1)[1].split("/", 1)[0]
    info = _tls(tls_host)
    result["tls"][tls_host] = info
    if verbose:
        print("TLS   %-20s %s %.0fms %s" % (tls_host, "OK  " if info["ok"] else "FAIL",
                                            info["ms"], info["detail"]))

    try:
        import http.client
        ok, value, ms = _timed(lambda: _https_probe(http.client, ssl))
        result["https"][HTTPS_URL] = {"ok": ok, "ms": round(ms),
                                      "detail": ("HTTP %s" % value) if ok else repr(value)}
    except BaseException as exc:  # noqa: BLE001
        result["https"][HTTPS_URL] = {"ok": False, "ms": 0,
                                      "detail": "ssl/http.client 不可用: %r" % exc}
    if verbose:
        probe = result["https"][HTTPS_URL]
        print("HTTPS %-20s %s %.0fms %s" % (HTTPS_URL, "OK  " if probe["ok"] else "FAIL",
                                            probe["ms"], probe["detail"]))

    result["verdict"] = _verdict(result)
    if verbose:
        if result["proxies"]["env"]:
            print("\n代理环境变量:", ", ".join(sorted(result["proxies"]["env"])))
        print("\n结论:", result["verdict"])
    return result


def _verdict(result: dict) -> str:
    dns_ok = any(v["ok"] for v in result["dns"].values())
    tcp_ok = any(v["ok"] for v in result["tcp"].values())
    tls_info = next(iter(result["tls"].values()), {})
    tls_ok = bool(tls_info.get("ok"))
    https_ok = any(v["ok"] for v in result["https"].values())

    if https_ok:
        return "出网正常: DNS + TCP + TLS 全通, 可以放心用 requests / urllib 抓数据"
    if not result["loopback"]["ok"]:
        return ("本机回环 socket 都不通: 解释器/沙箱本身有问题, 与外部网络无关; "
                "把这段输出反馈给开发者")
    if tcp_ok and not tls_ok:
        detail = str(tls_info.get("detail", ""))
        if "证书" in detail:
            return ("TCP 通但 TLS 证书校验失败: 检查设备系统时间是否正确(证书有有效期); "
                    "若在代理后面, 需要把代理的根证书加进 SSL_CERT_FILE")
        return "TCP 通但 TLS 握手失败: 多半被中间设备拦截, 换一个站点再试以区分目标问题"
    if dns_ok and not tcp_ok:
        return ("DNS 能解析但连不上: 目标被网络策略拦截或当前无外网; "
                "换国内地址再试, 不要用 1.1.1.1 这类可能不可达的地址做判断")
    if not dns_ok:
        return ("DNS 失败: 设备没联网, 或应用拿不到解析服务; "
                "本机回环若正常, 说明解释器没问题, 缺的是网络")
    return "部分目标可达部分不可达: 按上面逐行结果定位具体站点"


def diagnose() -> dict:
    """同 check(), 但不打印 —— 适合在代码里判断"现在能不能联网"。"""
    return check(verbose=False)


def _headers(extra: dict | None = None) -> dict:
    headers = {"User-Agent": UA, "Accept": "*/*"}
    if extra:
        headers.update(extra)
    return headers


def get(url: str, timeout: int = 20, headers: dict | None = None) -> str:
    """抓一个 URL 的文本（优先 requests，缺了就退回 urllib）。"""
    try:
        import requests
        resp = requests.get(url, timeout=timeout, headers=_headers(headers))
        resp.raise_for_status()
        if not resp.encoding or resp.encoding.lower() == "iso-8859-1":
            resp.encoding = resp.apparent_encoding or "utf-8"
        return resp.text
    except ImportError:
        import urllib.request
        req = urllib.request.Request(url, headers=_headers(headers))
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            raw = resp.read()
            charset = resp.headers.get_content_charset() or "utf-8"
            return raw.decode(charset, "replace")


def download(url: str, path: str, timeout: int = 60) -> dict:
    """下载到文件, 返回 {bytes, status}。大文件不会整个读进内存。"""
    try:
        import requests
        with requests.get(url, timeout=timeout, headers=_headers(), stream=True) as resp:
            resp.raise_for_status()
            size = 0
            with open(path, "wb") as handle:
                for chunk in resp.iter_content(65536):
                    if chunk:
                        handle.write(chunk)
                        size += len(chunk)
            return {"bytes": size, "status": resp.status_code, "path": path}
    except ImportError:
        import shutil
        import urllib.request
        req = urllib.request.Request(url, headers=_headers())
        with urllib.request.urlopen(req, timeout=timeout) as resp, \
                open(path, "wb") as handle:  # noqa: S310
            shutil.copyfileobj(resp, handle)
            return {"bytes": os.path.getsize(path), "status": resp.status, "path": path}
