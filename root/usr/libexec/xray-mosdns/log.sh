#!/bin/sh
# luci-app-xray-mosdns-x - recent log lines (xray + mosdns)
lines="${1:-200}"
logread 2>/dev/null | grep -E 'xray-mosdns|/usr/bin/xray|/usr/bin/mosdns|mosdns-x' | tail -n "$lines"
