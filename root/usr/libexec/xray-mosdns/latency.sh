#!/usr/bin/env python3
"""Node latency test for luci-app-xray-mosdns-x.

Usage: latency.sh <uci-section> | latency.sh --target host:port
Output: {"ok":bool,"ms":float|null,"target":"ip:port","via":"tcp|icmp","type":"..."}
"""
import json
import re
import socket
import subprocess
import sys
import time

CONF = "xray-mosdns"


def uci(section, opt):
    try:
        out = subprocess.run(
            ["uci", "-q", "get", "%s.%s.%s" % (CONF, section, opt)],
            capture_output=True, text=True, timeout=5)
        return out.stdout.strip()
    except Exception:
        return ""


IPV4_RE = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}$")
IPV6_RE = re.compile(r"^[0-9a-fA-F:]+$")


def resolve(addr):
    """Resolve with nslookup instead of getaddrinfo (python3-light lacks idna)."""
    if IPV4_RE.match(addr) or ":" in addr:
        return [addr]
    try:
        out = subprocess.run(["nslookup", addr], capture_output=True, text=True, timeout=6).stdout
    except Exception:
        return []
    ips = []
    for tok in re.findall(r"[0-9a-fA-F:.]+", out):
        tok = tok.rstrip(".")
        if not (IPV4_RE.match(tok) or (":" in tok and IPV6_RE.match(tok))):
            continue
        if tok in ("127.0.0.1", "::1"):
            continue
        if tok not in ips:
            ips.append(tok)
    return ips


def tcp_rtt(ip, port, timeout=2.0):
    family = socket.AF_INET6 if ":" in ip else socket.AF_INET
    sock = socket.socket(family, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    start = time.time()
    try:
        sock.connect((ip, port))
        return (time.time() - start) * 1000.0
    finally:
        sock.close()


def ping_rtt(ip, timeout=2):
    try:
        out = subprocess.run(
            ["ping", "-c", "1", "-W", str(timeout), ip],
            capture_output=True, text=True, timeout=timeout + 3).stdout
        for line in out.splitlines():
            if "time=" in line:
                return float(line.split("time=")[1].split()[0])
    except Exception:
        return None
    return None


def main():
    target = None
    ntype = ""
    section = ""
    if len(sys.argv) > 2 and sys.argv[1] == "--target":
        target = sys.argv[2]
        addr, _, port = target.rpartition(":")
        if not addr:
            print(json.dumps({"ok": False, "error": "bad target"}))
            return
    else:
        section = sys.argv[1] if len(sys.argv) > 1 else ""
        addr = uci(section, "address")
        port = uci(section, "port") or "443"
        ntype = uci(section, "type")
        if not addr:
            print(json.dumps({"ok": False, "section": section, "error": "node not found"}))
            return

    try:
        port = int(port)
    except ValueError:
        port = 443

    try:
        ips = resolve(addr)
        ips.sort(key=lambda x: 1 if ":" in x else 0)
    except Exception as exc:
        print(json.dumps({"ok": False, "section": section, "error": "resolve failed: %s" % exc}))
        return

    if not ips:
        print(json.dumps({"ok": False, "section": section, "error": "no address"}))
        return

    best = None
    used_ip = ""
    via = "tcp"
    for ip in ips[:3]:
        if ":" in ip and ":" not in addr and not ntype.startswith("hysteria"):
            continue
        for _ in range(2):
            try:
                ms = tcp_rtt(ip, port)
                if best is None or ms < best:
                    best = ms
                    used_ip = ip
            except Exception:
                break

    if best is None:
        via = "icmp"
        for ip in ips[:2]:
            ms = ping_rtt(ip)
            if ms is not None and (best is None or ms < best):
                best = ms
                used_ip = ip
        if best is None:
            print(json.dumps({"ok": False, "section": section,
                              "target": "%s:%s" % (addr, port), "type": ntype,
                              "error": "unreachable (tcp/icmp)"}))
            return

    result = {
        "ok": True,
        "section": section,
        "type": ntype,
        "target": "%s:%s" % (used_ip, port),
        "via": via,
        "ms": round(best, 1),
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()
