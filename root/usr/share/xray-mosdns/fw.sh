#!/bin/sh
# luci-app-xray-mosdns-x - nftables + policy routing helper (IPv4 + optional IPv6)
# usage: fw.sh apply [flush-dns] | clear | status
#
# apply is safe to run repeatedly: nft.rules replaces chains and static sets
# in a single transaction, so there is no window without rules. A failed
# apply leaves the loaded table as it was, and exits non-zero, as it does
# when the policy routing is not in place afterwards.
#
# XM_RULES_DIR names the directory nft.rules and its companions are read
# from (default: the output directory); the start script loads a new set
# from where it was generated, before switching to it.
OUT=/var/etc/xray-mosdns
RULES=${XM_RULES_DIR:-$OUT}
STATE="$OUT/.fw-state"
TABLE="inet xray-mosdns"
PREF=100	# priority of the policy rule

get_opt() { uci -q get "xray-mosdns.$1" 2>/dev/null; }
FWMARK=$(get_opt '@global[0].fwmark'); [ -n "$FWMARK" ] || FWMARK=0x1
ROUTE_TABLE=$(get_opt '@global[0].route_table'); [ -n "$ROUTE_TABLE" ] || ROUTE_TABLE=100
IPV6_EN=$(get_opt '@global[0].ipv6_enabled'); [ "$IPV6_EN" = "1" ] || IPV6_EN=0

# $1 family flag (-4/-6), $2 fwmark, $3 table. Only what add_route put
# there goes: the rule at our priority and the one route. Another user of
# the same mark or table keeps theirs.
del_route() {
	i=0
	while [ $i -lt 8 ] && ip "$1" rule del fwmark "$2" lookup "$3" pref "$PREF" 2>/dev/null; do
		i=$((i + 1))
	done
	ip "$1" route del local default dev lo table "$3" 2>/dev/null || true
}

# $1 family flag. `ip rule add` refuses an identical rule, so this is
# idempotent; what counts is that both are there afterwards.
add_route() {
	ip "$1" rule add fwmark "$FWMARK" lookup "$ROUTE_TABLE" pref "$PREF" 2>/dev/null
	ip "$1" route replace local default dev lo table "$ROUTE_TABLE" 2>/dev/null
	if ip "$1" rule show 2>/dev/null | grep -qE "fwmark $(printf '0x%x' "$FWMARK") lookup $ROUTE_TABLE( |\$)" &&
		ip "$1" route show table "$ROUTE_TABLE" 2>/dev/null | grep -q '^local default dev lo'; then
		return 0
	fi
	echo "policy routing (fwmark $FWMARK, table $ROUTE_TABLE) is not in place for IPv${1#-}" >&2
	logger -t xray-mosdns "policy routing (fwmark $FWMARK, table $ROUTE_TABLE) is not in place for IPv${1#-}"
	return 1
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

# nft.rules updates the loaded table in place. A set whose definition changed
# (e.g. after an upgrade) cannot be redeclared that way, so the table is then
# rebuilt: deleted and recreated in one transaction, which keeps the old
# rules in force until the new ones are complete and leaves them untouched
# if the new ones are rejected.
load_rules() {
	nft -f "$RULES/nft.rules" 2>/dev/null && return 0

	batch="$OUT/.nft-rebuild"
	{
		echo "add table $TABLE"
		echo "delete table $TABLE"
		cat "$RULES/nft.rules"
		# with the DNS watchdog, nft.rules leaves the redirect chains to it:
		# carry an active redirect over rather than hand LAN DNS to dnsmasq
		# until the watchdog's next probe
		if ! grep -q "^flush chain $TABLE dns_redirect\$" "$RULES/nft.rules" &&
			[ -f "$RULES/nft-dns-on.rules" ] &&
			nft list chain $TABLE dns_redirect 2>/dev/null | grep -q 'redirect to'; then
			cat "$RULES/nft-dns-on.rules"
		fi
	} > "$batch"
	if err=$(nft -f "$batch" 2>&1); then
		rm -f "$batch"
		logger -t xray-mosdns "nft table rebuilt; addresses learned from DNS start over"
		return 0
	fi
	# $batch is kept: the line numbers in the error refer to it
	echo "failed to load nft rules: $err" >&2
	logger -t xray-mosdns "failed to load nft rules: $err"
	return 1
}

apply_fw() {
	[ -f "$RULES/nft.rules" ] || { echo "missing $RULES/nft.rules" >&2; exit 1; }

	load_rules || exit 1
	# per-device chains that the current ruleset no longer uses
	for c in $(nft list table $TABLE 2>/dev/null | sed -n 's/^[[:space:]]*chain \(dev_[0-9]*\) {.*/\1/p'); do
		grep -q "^add chain $TABLE $c\$" "$RULES/nft.rules" || nft delete chain $TABLE "$c" 2>/dev/null || true
	done

	if [ "$1" = "flush-dns" ] && [ -f "$RULES/nft-flush-dns.rules" ]; then
		nft -f "$RULES/nft-flush-dns.rules" 2>/dev/null || true
	fi

	if [ -f "$STATE" ] && [ "$(cat "$STATE")" != "$FWMARK $ROUTE_TABLE" ]; then
		clear_routes
	fi
	add_route -4 || exit 1
	if [ "$IPV6_EN" = "1" ]; then
		add_route -6 || exit 1
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
