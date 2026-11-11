#!/bin/sh
# luci-app-xray-mosdns-x - status as JSON
g() { uci -q get "xray-mosdns.$1" 2>/dev/null; }
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

enabled=$(g 'global.enabled'); [ -n "$enabled" ] || enabled=0
node=$(g 'global.node')
node_type=$(g "$node.type"); [ -n "$node_type" ] || node_type=""
node_addr=$(g "$node.address")
node_remarks=$(g "$node.remarks")
tproxy_port=$(g 'global.tproxy_port'); [ -n "$tproxy_port" ] || tproxy_port=12345
dns_enabled=$(g 'dns.enabled'); [ -n "$dns_enabled" ] || dns_enabled=0
xray_bin=$(g 'global.xray_bin'); [ -n "$xray_bin" ] || xray_bin=/usr/bin/xray

xray_running=0
ps w 2>/dev/null | grep -v grep | grep -qF "$xray_bin run -c /var/etc/xray-mosdns/xray.json" && xray_running=1
mosdns_running=0
ps w 2>/dev/null | grep -v grep | grep -qF 'mosdns start -c /var/etc/xray-mosdns/mosdns.yaml' && mosdns_running=1

printf '{'
printf '"enabled":%s,' "$enabled"
printf '"xray_running":%s,' "$xray_running"
printf '"mosdns_running":%s,' "$mosdns_running"
printf '"dns_enabled":%s,' "$dns_enabled"
printf '"tproxy_port":%s,' "$tproxy_port"
printf '"node":"%s",' "$(esc "$node")"
printf '"node_type":"%s",' "$(esc "$node_type")"
printf '"node_address":"%s",' "$(esc "$node_addr")"
printf '"node_remarks":"%s",' "$(esc "$node_remarks")"
printf '"fw":{'
nft - list >/dev/null 2>&1
printf '"nft":%s,' "$(nft list table inet xray-mosdns >/dev/null 2>&1 && echo true || echo false)"
fwmark=$(g 'global.fwmark'); [ -n "$fwmark" ] || fwmark=0x1
rtable=$(g 'global.route_table'); [ -n "$rtable" ] || rtable=100
printf '"rule":%s' "$(ip rule show 2>/dev/null | grep -q "fwmark $fwmark lookup $rtable" && echo true || echo false)"
printf '}'
printf '}\n'
