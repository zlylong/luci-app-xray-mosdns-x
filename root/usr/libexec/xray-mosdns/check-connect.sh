#!/bin/sh
# Connectivity check for the dashboard tiles.
# usage: check-connect.sh aliyun|google|github|youtube
# When the proxy is running the check goes through the local SOCKS inbound,
# otherwise it falls back to a direct request.
CFG=xray-mosdns
case "${1:-}" in
	aliyun)  URL="https://www.aliyun.com";  NAME="阿里连接" ;;
	google)  URL="https://www.google.com";  NAME="谷歌连接" ;;
	github)  URL="https://github.com";      NAME="GitHub 连接" ;;
	youtube) URL="https://www.youtube.com"; NAME="YouTube 连接" ;;
	*)       URL="$1"; NAME="$1" ;;
esac

# the SOCKS port and binary in effect (runtime.env next to the running
# config), else the configured ones
SOCKS_PORT=$(uci -q get "$CFG.@global[0].socks_port" 2>/dev/null || true)
XRAY_BIN=$(uci -q get "$CFG.@global[0].xray_bin" 2>/dev/null || true)
[ -f /var/etc/xray-mosdns/runtime.env ] && . /var/etc/xray-mosdns/runtime.env
[ -n "$SOCKS_PORT" ] || SOCKS_PORT=1070
XRAY=${XRAY_BIN:-/usr/bin/xray}

VIA="direct"
if ps w 2>/dev/null | grep -v grep | grep -qF "$XRAY run -c /var/etc/xray-mosdns/xray.json"; then
	VIA="proxy"
fi

if [ "$VIA" = "proxy" ]; then
	OUT=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 12 \
		-x "socks5h://127.0.0.1:$SOCKS_PORT" "$URL" 2>/dev/null)
else
	OUT=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 12 "$URL" 2>/dev/null)
fi

CODE=$(printf '%s' "$OUT" | awk '{print $1}')
TIME=$(printf '%s' "$OUT" | awk '{print $2}')
MS=$(printf '%s' "$TIME" | awk '{ if ($0 == "") print 0; else printf "%.0f", $0 * 1000 }')
OK=false
[ -n "$CODE" ] && [ "$CODE" != "000" ] && OK=true

printf '{"name":"%s","url":"%s","via":"%s","ok":%s,"http":"%s","ms":%s}\n' \
	"$NAME" "$URL" "$VIA" "$OK" "${CODE:-000}" "${MS:-0}"
