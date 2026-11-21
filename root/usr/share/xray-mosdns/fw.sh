#!/bin/sh
# luci-app-xray-mosdns-x - nftables + policy routing helper (IPv4 + optional IPv6)
# usage: fw.sh apply [flush-dns] | clear | status | gate | ungate | gated
#
# apply is safe to run repeatedly: nft.rules replaces chains and static sets
# in a single transaction, so there is no window without rules. A failed
# apply leaves the loaded table as it was, and exits non-zero, as it does
# when the policy routing is not in place afterwards.
#
# gate / ungate take the transparent proxy out of the path and put it back
# while the table stays loaded: with Xray not listening, traffic goes out
# directly instead of into a closed port. A first rule returning from the
# prerouting and output chains does that, and LAN DNS is handed back to
# dnsmasq, since mosdns resolves proxied names through Xray. Each is one
# transaction. An apply while gated stays gated, in the same transaction.
# gated tells (exit status) whether both rules are in place.
#
# XM_RULES_DIR names the directory nft.rules and its companions are read
# from (default: the output directory); the start script loads a new set
# from where it was generated, before switching to it. The mark, table and
# ports come from the runtime.env next to those rules, so a replayed older
# set gets its own values back, not whatever UCI says now.
OUT=/var/etc/xray-mosdns
RULES=${XM_RULES_DIR:-$OUT}
STATE="$OUT/.fw-state"
TABLE="inet xray-mosdns"
PREF=100	# priority of the policy rule
GATE="xray-mosdns: Xray not listening"
ERR=/var/run/xray-mosdns.error	# shown on the overview (the start script's error file)

get_opt() { uci -q get "xray-mosdns.$1" 2>/dev/null; }
# a set from before runtime.env existed goes by UCI
FWMARK=$(get_opt '@global[0].fwmark'); [ -n "$FWMARK" ] || FWMARK=0x1
ROUTE_TABLE=$(get_opt '@global[0].route_table'); [ -n "$ROUTE_TABLE" ] || ROUTE_TABLE=100
IPV6=$(get_opt '@global[0].ipv6_enabled'); [ "$IPV6" = "1" ] || IPV6=0
TPROXY_PORT=$(get_opt '@global[0].tproxy_port'); [ -n "$TPROXY_PORT" ] || TPROXY_PORT=12345
DNS_REDIRECT=1; [ "$(get_opt '@dns[0].redirect')" = "0" ] && DNS_REDIRECT=0
DNS_WATCH=log-only
[ "$DNS_REDIRECT" = "1" ] && [ "$(get_opt '@dns[0].fallback')" != "0" ] && DNS_WATCH=manage
[ -f "$RULES/runtime.env" ] && . "$RULES/runtime.env"
GATE_MSG="Xray 没有在 TProxy 端口 $TPROXY_PORT 上监听：已撤下透明代理，LAN DNS 暂时交给 dnsmasq，流量直连；Xray 恢复监听后自动恢复（见“日志 → Xray”）"

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

# $1 family flag. Another program using the same mark or routing table
# makes the two step on each other: say so in the log (the values can be
# changed under System > Ports and paths).
warn_shared() {
	hex=$(printf '0x%x' "$FWMARK")
	others=$(ip "$1" rule show 2>/dev/null | grep -vE "^$PREF:" | grep -E "fwmark $hex( |/)|lookup $ROUTE_TABLE( |\$)")
	[ -n "$others" ] && logger -p daemon.warn -t xray-mosdns \
		"fwmark $FWMARK / table $ROUTE_TABLE are also used by: $(printf '%s' "$others" | tr '\n\t' '; ')"
	others=$(ip "$1" route show table "$ROUTE_TABLE" 2>/dev/null | grep -v '^local default dev lo')
	[ -n "$others" ] && logger -p daemon.warn -t xray-mosdns \
		"routing table $ROUTE_TABLE also holds: $(printf '%s' "$others" | head -3 | tr '\n' ';')"
	return 0
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

# ------------------------------------------------------------------ gate
# what takes the proxy out of the path, as nft commands
gate_lines() {
	echo "insert rule $TABLE prerouting return comment \"$GATE\""
	echo "insert rule $TABLE output return comment \"$GATE\""
	if [ "$DNS_REDIRECT" = "1" ] && [ -f "$RULES/nft-dns-off.rules" ]; then
		cat "$RULES/nft-dns-off.rules"
	fi
}

# commands deleting the gate rules there are now (none, one or both)
gate_deletes() {
	for c in prerouting output; do
		nft -a list chain $TABLE "$c" 2>/dev/null |
			sed -n "s/.*comment \"$GATE\" # handle \([0-9]*\)\$/delete rule $TABLE $c handle \1/p"
	done
}

gated() {
	nft list chain $TABLE prerouting 2>/dev/null | grep -qF "comment \"$GATE\"" &&
		nft list chain $TABLE output 2>/dev/null | grep -qF "comment \"$GATE\""
}

gate() {
	nft list table $TABLE >/dev/null 2>&1 || return 0
	# already out: the reason goes back on the overview if a start cleared
	# it, without covering another message
	if gated; then
		[ -s "$ERR" ] || printf '%s\n' "$GATE_MSG" > "$ERR"
		return 0
	fi
	# what is left of a half-done gate goes in the same transaction
	if err=$({ gate_deletes; gate_lines; } | nft -f - 2>&1); then
		printf '%s\n' "$GATE_MSG" > "$ERR"
		return 0
	fi
	echo "could not take the transparent proxy out of the path: $err" >&2
	return 1
}

# A static DNS redirect comes back with the proxy; one the watchdog manages
# is put back by the watchdog once mosdns answers.
ungate() {
	dels=$(gate_deletes)
	if [ -n "$dels" ]; then
		if ! err=$({
			printf '%s\n' "$dels"
			if [ "$DNS_REDIRECT" = "1" ] && [ "$DNS_WATCH" != "manage" ] && [ -f "$RULES/nft-dns-on.rules" ]; then
				cat "$RULES/nft-dns-on.rules"
			fi
		} | nft -f - 2>&1); then
			echo "could not put the transparent proxy back: $err" >&2
			return 1
		fi
	fi
	# the message goes with its reason; anything else in the file stays
	grep -qF "Xray 没有在 TProxy 端口" "$ERR" 2>/dev/null && rm -f "$ERR"
	return 0
}

# ------------------------------------------------------------------ apply
# nft.rules updates the loaded table in place. A set whose definition changed
# (e.g. after an upgrade) cannot be redeclared that way, so the table is then
# rebuilt: deleted and recreated in one transaction, which keeps the old
# rules in force until the new ones are complete and leaves them untouched
# if the new ones are rejected. $1 = commands to add in the same
# transaction (a gate that has to stay).
load_rules() {
	{ cat "$RULES/nft.rules"; [ -n "$1" ] && printf '%s\n' "$1"; } | nft -f - 2>/dev/null && return 0

	batch="$OUT/.nft-rebuild"
	{
		echo "add table $TABLE"
		echo "delete table $TABLE"
		cat "$RULES/nft.rules"
		# with the DNS watchdog, nft.rules leaves the redirect chains to it:
		# carry an active redirect over rather than hand LAN DNS to dnsmasq
		# until the watchdog's next probe (not while gated: DNS is with
		# dnsmasq then on purpose)
		if [ -z "$1" ] &&
			! grep -q "^flush chain $TABLE dns_redirect\$" "$RULES/nft.rules" &&
			[ -f "$RULES/nft-dns-on.rules" ] &&
			nft list chain $TABLE dns_redirect 2>/dev/null | grep -q 'redirect to'; then
			cat "$RULES/nft-dns-on.rules"
		fi
		[ -n "$1" ] && printf '%s\n' "$1"
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

	# a gate in place (even a half-done one) stays in place
	keep=""
	[ -n "$(gate_deletes)" ] && keep=$(gate_lines)
	load_rules "$keep" || exit 1
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
	warn_shared -4
	add_route -4 || exit 1
	if [ "$IPV6" = "1" ]; then
		add_route -6 || exit 1
	else
		del_route -6 "$FWMARK" "$ROUTE_TABLE"
	fi
	echo "$FWMARK $ROUTE_TABLE" > "$STATE"
}

# ------------------------------------------------------------------ status
# $1 = set: how many elements it holds
set_size() {
	nft list set $TABLE "$1" 2>/dev/null | tr ',' '\n' | grep -c '[0-9a-fA-F][.:][0-9a-fA-F]'
}

status_fw() {
	if nft list table $TABLE >/dev/null 2>&1; then
		echo "nft: loaded"
		gated && echo "proxy: out of the path (Xray not listening)" || echo "proxy: in the path"
		sets=$(nft list table $TABLE 2>/dev/null | sed -nE 's/^[[:space:]]*set (bypass[46]|proxy[46]_dns|direct[46]_dns|ipg[46]_[0-9]+) \{.*/\1/p')
		for s in $sets; do
			echo "set $s: $(set_size "$s")"
		done
	else
		echo "nft: absent"
	fi
	ip rule show 2>/dev/null | grep -q "lookup $ROUTE_TABLE" && echo "rule4: present" || echo "rule4: absent"
	ip route show table "$ROUTE_TABLE" 2>/dev/null | grep -q 'local default dev lo' && echo "route4: present" || echo "route4: absent"
	if [ "$IPV6" = "1" ]; then
		ip -6 rule show 2>/dev/null | grep -q "lookup $ROUTE_TABLE" && echo "rule6: present" || echo "rule6: absent"
		ip -6 route show table "$ROUTE_TABLE" 2>/dev/null | grep -q 'local default dev lo' && echo "route6: present" || echo "route6: absent"
	fi
}

case "$1" in
	apply) apply_fw "$2" ;;
	clear) clear_fw ;;
	status) status_fw ;;
	gate) gate ;;
	ungate) ungate ;;
	gated) gated ;;
	*) echo "usage: $0 {apply [flush-dns]|clear|status|gate|ungate|gated}" >&2; exit 1 ;;
esac
