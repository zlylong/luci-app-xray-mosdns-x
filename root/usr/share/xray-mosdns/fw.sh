#!/bin/sh
# luci-app-xray-mosdns-x - nftables + policy routing helper (IPv4 + optional IPv6)
# usage: fw.sh apply [flush-dns] | clear | status
#
# apply is safe to run repeatedly: nft.rules replaces chains and static sets
# in a single transaction, so there is no window without rules.
OUT=/var/etc/xray-mosdns
STATE="$OUT/.fw-state"
TABLE="inet xray-mosdns"

get_opt() { uci -q get "xray-mosdns.$1" 2>/dev/null; }
FWMARK=$(get_opt '@global[0].fwmark'); [ -n "$FWMARK" ] || FWMARK=0x1
ROUTE_TABLE=$(get_opt '@global[0].route_table'); [ -n "$ROUTE_TABLE" ] || ROUTE_TABLE=100
IPV6_EN=$(get_opt '@global[0].ipv6_enabled'); [ "$IPV6_EN" = "1" ] || IPV6_EN=0

# $1 family flag (-4/-6), $2 fwmark, $3 table
del_route() {
	i=0
	while [ $i -lt 8 ] && ip "$1" rule del fwmark "$2" lookup "$3" 2>/dev/null; do
		i=$((i + 1))
	done
	ip "$1" route flush table "$3" 2>/dev/null || true
}

# $1 family flag. `ip rule add` refuses an identical rule, so this is idempotent.
add_route() {
	ip "$1" rule add fwmark "$FWMARK" lookup "$ROUTE_TABLE" pref 100 2>/dev/null || true
	ip "$1" route replace local default dev lo table "$ROUTE_TABLE" 2>/dev/null || true
}

# remove the routing set up by a previous apply (which may have used other values)
clear_routes() {
	old_mark=$FWMARK; old_table=$ROUTE_TABLE
	if [ -f "$STATE" ]; then
		read -r old_mark old_table < "$STATE"
		[ -n "$old_mark" ] && [ -n "$old_table" ] || { old_mark=$FWMARK; old_table=$ROUTE_TABLE; }
	fi
	del_route -4 "$old_mark" "$old_table"
	del_route -6 "$old_mark" "$old_table"
	rm -f "$STATE"
}

clear_fw() {
	nft delete table $TABLE 2>/dev/null || true
	clear_routes
}

apply_fw() {
	[ -f "$OUT/nft.rules" ] || { echo "missing $OUT/nft.rules" >&2; exit 1; }

	if ! err=$(nft -f "$OUT/nft.rules" 2>&1); then
		# a set whose definition changed (e.g. after an upgrade) cannot be
		# redeclared in place: rebuild the table once
		nft delete table $TABLE 2>/dev/null || true
		nft -f "$OUT/nft.rules" || {
			echo "failed to load nft rules: $err" >&2
			logger -t xray-mosdns "failed to load nft rules: $err"
			exit 1
		}
	fi
	# per-device chains that the current ruleset no longer uses
	for c in $(nft list table $TABLE 2>/dev/null | sed -n 's/^[[:space:]]*chain \(dev_[0-9]*\) {.*/\1/p'); do
		grep -q "^add chain $TABLE $c\$" "$OUT/nft.rules" || nft delete chain $TABLE "$c" 2>/dev/null || true
	done

	if [ "$1" = "flush-dns" ] && [ -f "$OUT/nft-flush-dns.rules" ]; then
		nft -f "$OUT/nft-flush-dns.rules" 2>/dev/null || true
	fi

	if [ -f "$STATE" ] && [ "$(cat "$STATE")" != "$FWMARK $ROUTE_TABLE" ]; then
		clear_routes
	fi
	add_route -4
	if [ "$IPV6_EN" = "1" ]; then
		add_route -6
	else
		del_route -6 "$FWMARK" "$ROUTE_TABLE"
	fi
	echo "$FWMARK $ROUTE_TABLE" > "$STATE"
}

status_fw() {
	if nft list table $TABLE >/dev/null 2>&1; then
		echo "nft: loaded"
		for s in proxy4_dns direct4_dns chnroute4; do
			n=$(nft list set $TABLE $s 2>/dev/null | tr ',' '\n' | grep -c '[0-9]\.[0-9]')
			echo "set $s: $n"
		done
	else
		echo "nft: absent"
	fi
	ip rule show 2>/dev/null | grep -q "lookup $ROUTE_TABLE" && echo "rule4: present" || echo "rule4: absent"
	ip route show table "$ROUTE_TABLE" 2>/dev/null | grep -q 'local default dev lo' && echo "route4: present" || echo "route4: absent"
	if [ "$IPV6_EN" = "1" ]; then
		ip -6 rule show 2>/dev/null | grep -q "lookup $ROUTE_TABLE" && echo "rule6: present" || echo "rule6: absent"
		ip -6 route show table "$ROUTE_TABLE" 2>/dev/null | grep -q 'local default dev lo' && echo "route6: present" || echo "route6: absent"
	fi
}

case "$1" in
	apply) apply_fw "$2" ;;
	clear) clear_fw ;;
	status) status_fw ;;
	*) echo "usage: $0 {apply [flush-dns]|clear|status}" >&2; exit 1 ;;
esac
