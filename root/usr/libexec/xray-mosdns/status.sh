#!/bin/sh
# luci-app-xray-mosdns-x - status as JSON
g() { uci -q get "xray-mosdns.$1" 2>/dev/null; }
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

enabled=$(g 'global.enabled'); [ -n "$enabled" ] || enabled=0
main=$(g 'global.main_target'); [ -n "$main" ] || main=$(g 'global.node'); [ -n "$main" ] || main=direct
case "$main" in
	direct)  node="";        node_type="direct";   node_addr=""; node_remarks="直连" ;;
	balance)  node="balance";  node_type="balancer"; node_addr=""; node_remarks="负载均衡" ;;
	failover) node="failover"; node_type="failover"; node_addr=""; node_remarks="主备" ;;
	*)       node="$main";   node_type=$(g "$main.type"); [ -n "$node_type" ] || node_type=""
	         node_addr=$(g "$main.address"); node_remarks=$(g "$main.remarks") ;;
esac
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
# is LAN port 53 currently redirected to mosdns (false = dnsmasq is answering)
printf '"dns_redirect":%s,' "$(nft list chain inet xray-mosdns dns_redirect 2>/dev/null | grep -q "redirect to" && echo true || echo false)"
printf '"tproxy_port":%s,' "$tproxy_port"
printf '"main_target":"%s",' "$(esc "$main")"
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
