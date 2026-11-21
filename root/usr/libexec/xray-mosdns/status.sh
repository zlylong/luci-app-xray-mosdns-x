#!/bin/sh
# luci-app-xray-mosdns-x - run state as JSON, for the overview page
g() { uci -q get "xray-mosdns.$1" 2>/dev/null; }
# a JSON string body: no control characters, quotes and backslashes escaped
esc() { printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
yes() { "$@" >/dev/null 2>&1 && echo true || echo false; }

enabled=$(g '@global[0].enabled'); [ "$enabled" = "1" ] || enabled=0
# what is in effect, from the files the service runs on (runtime.env); UCI
# only when there are none: a reload that fell back keeps the old values
MAIN_TARGET=$(g '@global[0].main_target')
XRAY_BIN=$(g '@global[0].xray_bin'); [ -n "$XRAY_BIN" ] || XRAY_BIN=/usr/bin/xray
FWMARK=$(g '@global[0].fwmark'); [ -n "$FWMARK" ] || FWMARK=0x1
ROUTE_TABLE=$(g '@global[0].route_table'); [ -n "$ROUTE_TABLE" ] || ROUTE_TABLE=100
[ -f /var/etc/xray-mosdns/runtime.env ] && . /var/etc/xray-mosdns/runtime.env
[ -n "$MAIN_TARGET" ] || MAIN_TARGET=direct

running() { ps w 2>/dev/null | grep -v grep | grep -qF -- "$1" && echo 1 || echo 0; }

printf '{"ok":true,'
printf '"enabled":%s,' "$enabled"
# why the last start did not go as planned, if it did not (written by the init script)
printf '"last_error":"%s",' "$(esc "$(head -c 600 /var/run/xray-mosdns.error 2>/dev/null)")"
printf '"xray_running":%s,' "$(running "$XRAY_BIN run -c /var/etc/xray-mosdns/xray.json")"
printf '"mosdns_running":%s,' "$(running 'start -c /var/etc/xray-mosdns/mosdns.yaml')"
# is LAN port 53 currently redirected to mosdns (false = dnsmasq is answering)
printf '"dns_redirect":%s,' "$(nft list chain inet xray-mosdns dns_redirect 2>/dev/null | grep -q 'redirect to' && echo true || echo false)"
printf '"main_target":"%s",' "$(esc "$MAIN_TARGET")"
printf '"fw":{"nft":%s,"rule":%s,"gated":%s}' \
	"$(yes nft list table inet xray-mosdns)" \
	"$(ip rule show 2>/dev/null | grep -qE "fwmark $(printf '0x%x' "$FWMARK") lookup $ROUTE_TABLE( |\$)" && echo true || echo false)" \
	"$(yes /usr/share/xray-mosdns/fw.sh gated)"
printf '}\n'
