#!/bin/sh
# luci-app-xray-mosdns-x - dnsmasq integration
# Points dnsmasq at the local mosdns listener, restoring the previous
# configuration on revert. A backup is kept in /etc/xray-mosdns/.
BACKUP_DIR=/etc/xray-mosdns
BACKUP="$BACKUP_DIR/dnsmasq-backup"

get_opt() { uci -q get "xray-mosdns.$1" 2>/dev/null; }
PORT=$(get_opt 'dns.listen_port'); [ -n "$PORT" ] || PORT=5353

has_dns() {
	[ "$(uci -q get xray-mosdns.@dns[0].enabled 2>/dev/null)" = "1" ]
}

apply_dns() {
	has_dns || return 0
	mkdir -p "$BACKUP_DIR"
	if [ ! -f "$BACKUP" ]; then
		{
			printf 'noresolv=%s\n' "$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)"
			for s in $(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null); do
				printf 'server=%s\n' "$s"
			done
		} > "$BACKUP"
	fi
	uci -q delete dhcp.@dnsmasq[0].server
	uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#$PORT"
	uci set dhcp.@dnsmasq[0].noresolv='1'
	uci commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	logger -t xray-mosdns "dnsmasq now forwards to 127.0.0.1#$PORT"
}

revert_dns() {
	[ -f "$BACKUP" ] || return 0
	uci -q delete dhcp.@dnsmasq[0].server
	. "$BACKUP"
	if [ -n "$noresolv" ]; then
		uci set dhcp.@dnsmasq[0].noresolv="$noresolv"
	else
		uci -q delete dhcp.@dnsmasq[0].noresolv
	fi
	# shellcheck disable=SC2154
	for s in $server_list; do :; done
	# restore each saved server entry
	sed -n 's/^server=//p' "$BACKUP" | while IFS= read -r s; do
		[ -n "$s" ] && uci add_list dhcp.@dnsmasq[0].server="$s"
	done
	uci commit dhcp
	rm -f "$BACKUP"
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	logger -t xray-mosdns "dnsmasq configuration restored"
}

case "$1" in
	apply) apply_dns ;;
	revert) revert_dns ;;
	*) echo "usage: $0 {apply|revert}" >&2; exit 1 ;;
esac
