#!/usr/bin/env python3
"""List geosite/geoip tags from v2ray .dat files (for the rules page picker).

Output: {"geosite":[...],"geoip":[...],"source":...}
"""
import json
import os

GEOSITE = "/usr/share/v2ray/geosite.dat"
GEOIP = "/usr/share/v2ray/geoip.dat"
CACHE = "/tmp/xray-mosdns-geo-tags.json"


def read_varint(buf, i):
    shift = 0
    val = 0
    while True:
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, i
        shift += 7


def fields(buf):
    i = 0
    n = len(buf)
    while i < n:
        key, i = read_varint(buf, i)
        f, wt = key >> 3, key & 7
        if wt == 0:
            _, i = read_varint(buf, i)
            yield f, None
        elif wt == 2:
            ln, i = read_varint(buf, i)
            yield f, buf[i:i + ln]
            i += ln
        elif wt == 5:
            i += 4
            yield f, None
        elif wt == 1:
            i += 8
            yield f, None
        else:
            raise ValueError("unsupported wire type %d" % wt)


def tags(path):
    out = []
    try:
        buf = open(path, "rb").read()
    except OSError:
        return out
    for f, sub in fields(buf):
        if f != 1 or sub is None:
            continue
        for f2, s in fields(sub):
            if f2 != 1 or s is None:
                continue
            try:
                t = s.decode("utf-8")
            except UnicodeDecodeError:
                continue
            if 0 < len(t) < 80 and "\n" not in t and "\r" not in t:
                out.append(t)
    return sorted(set(out))


def fresh_cache():
    try:
        if not os.path.exists(CACHE):
            return None
        if os.path.getmtime(CACHE) < max(os.path.getmtime(GEOSITE), os.path.getmtime(GEOIP)):
            return None
        with open(CACHE, "r") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def main():
    data = fresh_cache()
    if data is None:
        data = {"geosite": tags(GEOSITE), "geoip": tags(GEOIP)}
        try:
            with open(CACHE, "w") as fh:
                json.dump(data, fh, separators=(",", ":"))
        except OSError:
            pass
    print(json.dumps(data, separators=(",", ":")))


if __name__ == "__main__":
    main()
