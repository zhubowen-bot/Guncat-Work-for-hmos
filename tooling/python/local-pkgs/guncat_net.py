"""Guncat Work 自带的小工具: 网络三层自检。

放在 site-packages 里, AI 在 run_python 中可直接用：

    import guncat_net
    guncat_net.check()          # 打印 DNS / TCP / TLS 三段结果与结论
    guncat_net.get('https://example.com')   # 抓一个页面（requests 可用时走 requests）

为什么要它: 沙箱里"能不能上网"经常不是权限问题, 而是 DNS 解析不到、或目标机不可达。
分段测一次就能判断到底断在哪一层, 省得反复猜。
"""

from __future__ import annotations

import socket
import time

# 默认探测目标: 优先国内可达的站点, 避免 1.1.1.1 这类在部分地区不可达的地址造成误判
DNS_HOSTS = ("www.baidu.com", "www.bing.com", "pypi.org")
TCP_TARGETS = (("www.baidu.com", 443), ("www.bing.com", 443))
HTTPS_URL = "https://www.baidu.com/"


def _timed(fn, *args, **kwargs):
    started = time.time()
    try:
        value = fn(*args, **kwargs)
        return True, value, (time.time() - started) * 1000.0
    except BaseException as exc:  # noqa: BLE001 - 诊断工具, 任何异常都要报出来
        return False, exc, (time.time() - started) * 1000.0


def check(verbose: bool = True) -> dict:
    """三段式网络自检, 返回 dict; verbose=True 时顺手打印。"""
    result = {"dns": {}, "tcp": {}, "https": {}, "verdict": ""}

    for host in DNS_HOSTS:
        ok, value, ms = _timed(socket.gethostbyname, host)
        result["dns"][host] = {"ok": ok, "value": value if ok else repr(value), "ms": round(ms)}
        if verbose:
            print("DNS   %-16s %s %.0fms %s" % (host, "OK" if ok else "FAIL", ms,
                                                value if ok else value))

    for host, port in TCP_TARGETS:
        ok, value, ms = _timed(lambda h=host, p=port: socket.create_connection((h, p), 4))
        result["tcp"]["%s:%d" % (host, port)] = {"ok": ok, "ms": round(ms),
                                                 "value": "connected" if ok else repr(value)}
        if verbose:
            print("TCP   %-16s %s %.0fms" % (host + ":" + str(port), "OK" if ok else "FAIL", ms))
        if ok:
            try:
                value.close()
            except BaseException:
                pass

    try:
        import ssl
        import http.client
        ok, value, ms = _timed(lambda: _https_probe(http.client, ssl))
        result["https"][HTTPS_URL] = {"ok": ok, "ms": round(ms),
                                      "value": value if ok else repr(value)}
        if verbose:
            print("HTTPS %-16s %s %.0fms %s" % (HTTPS_URL, "OK" if ok else "FAIL", ms,
                                                value if ok else value))
    except BaseException as exc:  # noqa: BLE001
        result["https"][HTTPS_URL] = {"ok": False, "ms": 0, "value": repr(exc)}
        if verbose:
            print("HTTPS %-16s FAIL (ssl/http.client 不可用: %r)" % (HTTPS_URL, exc))

    dns_ok = any(v["ok"] for v in result["dns"].values())
    tcp_ok = any(v["ok"] for v in result["tcp"].values())
    https_ok = any(v["ok"] for v in result["https"].values())
    if https_ok:
        result["verdict"] = "出网正常: DNS + TCP + TLS 都通, 可以放心用 requests / urllib 抓数据"
    elif tcp_ok:
        result["verdict"] = ("TCP 能连但 HTTPS 不通: 多半是证书/中间设备拦截; "
                             "检查 SSL_CERT_FILE(应用已自带 cacert.pem)")
    elif dns_ok:
        result["verdict"] = ("DNS 能解析但连不上: 目标被网络策略拦截或当前无外网; "
                             "换国内地址再试, 不要用 1.1.1.1 这类可能不可达的地址做判断")
    else:
        result["verdict"] = ("DNS 失败: 要么当前设备没有网络, 要么应用拿不到解析服务; "
                             "本机回环 socket 可用就说明解释器本身没问题")
    if verbose:
        print("\n结论:", result["verdict"])
    return result


def _https_probe(http_client, ssl):
    conn = http_client.HTTPSConnection("www.baidu.com", timeout=6,
                                       context=ssl.create_default_context())
    conn.request("HEAD", "/")
    status = conn.getresponse().status
    conn.close()
    return status


def get(url: str, timeout: int = 20) -> str:
    """抓一个 URL 的文本（优先 requests，缺了就退回 urllib）。"""
    try:
        import requests
        resp = requests.get(url, timeout=timeout,
                            headers={"User-Agent": "GuncatWork/1.0"})
        resp.raise_for_status()
        return resp.text
    except ImportError:
        import urllib.request
        req = urllib.request.Request(url, headers={"User-Agent": "GuncatWork/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            return resp.read().decode("utf-8", "replace")
