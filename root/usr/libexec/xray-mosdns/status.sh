#!/bin/sh
# luci-app-xray-mosdns-x - run state as JSON, for the overview page
g() { uci -q get "xray-mosdns.$1" 2>/dev/null; }
# a JSON string body: no control characters, quotes and backslashes escaped
esc() { printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
yes() { "$@" >/dev/null 2>&1 && echo true || echo false; }

enabled=$(g '@global[0].enabled'); [ "$enabled" = "1" ] || enabled=0
main=$(g '@global[0].main_target'); [ -n "$main" ] || main=direct
xray_bin=$(g '@global[0].xray_bin'); [ -n "$xray_bin" ] || xray_bin=/usr/bin/xray
fwmark=$(g '@global[0].fwmark'); [ -n "$fwmark" ] || fwmark=0x1
rtable=$(g '@global[0].route_table'); [ -n "$rtable" ] || rtable=100

running() { ps w 2>/dev/null | grep -v grep | grep -qF -- "$1" && echo 1 || echo 0; }

printf '{"ok":true,'
printf '"enabled":%s,' "$enabled"
# why the last start did not go as planned, if it did not (written by the init script)
printf '"last_error":"%s",' "$(esc "$(head -c 600 /var/run/xray-mosdns.error 2>/dev/null)")"
printf '"xray_running":%s,' "$(running "$xray_bin run -c /var/etc/xray-mosdns/xray.json")"
printf '"mosdns_running":%s,' "$(running 'start -c /var/etc/xray-mosdns/mosdns.yaml')"
# is LAN port 53 currently redirected to mosdns (false = dnsmasq is answering)
printf '"dns_redirect":%s,' "$(nft list chain inet xray-mosdns dns_redirect 2>/dev/null | grep -q 'redirect to' && echo true || echo false)"
printf '"main_target":"%s",' "$(esc "$main")"
printf '"fw":{"nft":%s,"rule":%s}' \
	"$(yes nft list table inet xray-mosdns)" \
	"$(ip rule show 2>/dev/null | grep -qE "fwmark $(printf '0x%x' "$fwmark") lookup $rtable( |\$)" && echo true || echo false)"
printf '}\n'
