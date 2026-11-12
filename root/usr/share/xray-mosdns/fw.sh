#!/bin/sh
# luci-app-xray-mosdns-x - nftables + policy routing helper (IPv4 + optional IPv6)
# usage: fw.sh apply | clear | status
OUT=/var/etc/xray-mosdns

get_opt() { uci -q get "xray-mosdns.$1" 2>/dev/null; }
FWMARK=$(get_opt 'global.fwmark'); [ -n "$FWMARK" ] || FWMARK=0x1
ROUTE_TABLE=$(get_opt 'global.route_table'); [ -n "$ROUTE_TABLE" ] || ROUTE_TABLE=100
IPV6_EN=$(get_opt 'global.ipv6_enabled'); [ "$IPV6_EN" = "1" ] || IPV6_EN=0

clear_fw() {
	nft delete table inet xray-mosdns 2>/dev/null || true

	i=0
	while [ $i -lt 8 ] && ip rule del fwmark "$FWMARK" lookup "$ROUTE_TABLE" 2>/dev/null; do
		i=$((i + 1))
	done
	ip route flush table "$ROUTE_TABLE" 2>/dev/null || true

	i=0
	while [ $i -lt 8 ] && ip -6 rule del fwmark "$FWMARK" lookup "$ROUTE_TABLE" 2>/dev/null; do
		i=$((i + 1))
	done
	ip -6 route flush table "$ROUTE_TABLE" 2>/dev/null || true
}

apply_fw() {
	[ -f "$OUT/nft.rules" ] || { echo "missing $OUT/nft.rules" >&2; exit 1; }
	clear_fw
	nft -f "$OUT/nft.rules" || { echo "failed to load nft rules" >&2; exit 1; }

	ip rule add fwmark "$FWMARK" lookup "$ROUTE_TABLE" pref 100 2>/dev/null || true
	ip route add local default dev lo table "$ROUTE_TABLE" scope host 2>/dev/null || true

	if [ "$IPV6_EN" = "1" ]; then
		ip -6 rule add fwmark "$FWMARK" lookup "$ROUTE_TABLE" pref 100 2>/dev/null || true
		ip -6 route add local default dev lo table "$ROUTE_TABLE" scope host 2>/dev/null || true
	fi
}

status_fw() {
	if nft list table inet xray-mosdns >/dev/null 2>&1; then
		echo "nft: loaded"
	else
		echo "nft: absent"
	fi
	ip rule show 2>/dev/null | grep -q "fwmark $FWMARK lookup $ROUTE_TABLE" && echo "rule4: present" || echo "rule4: absent"
	ip route show table "$ROUTE_TABLE" 2>/dev/null | grep -q 'local default dev lo' && echo "route4: present" || echo "route4: absent"
	if [ "$IPV6_EN" = "1" ]; then
		ip -6 rule show 2>/dev/null | grep -q "fwmark $FWMARK lookup $ROUTE_TABLE" && echo "rule6: present" || echo "rule6: absent"
		ip -6 route show table "$ROUTE_TABLE" 2>/dev/null | grep -q 'local default dev lo' && echo "route6: present" || echo "route6: absent"
	fi
}

case "$1" in
	apply) apply_fw ;;
	clear) clear_fw ;;
	status) status_fw ;;
	*) echo "usage: $0 {apply|clear|status}" >&2; exit 1 ;;
esac
