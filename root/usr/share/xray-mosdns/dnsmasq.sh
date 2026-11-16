#!/bin/sh
# luci-app-xray-mosdns-x - dnsmasq migration helper
#
# Versions <= 0.8 rewrote /etc/config/dhcp so dnsmasq forwarded to mosdns and
# kept a backup of the previous values. Since 0.9 LAN DNS is redirected to
# mosdns in nftables and dnsmasq is not touched any more. `revert` restores
# such a leftover backup; it is a no-op when there is none.
BACKUP=/etc/xray-mosdns/dnsmasq-backup

revert_dns() {
	[ -f "$BACKUP" ] || return 0
	noresolv=$(sed -n 's/^noresolv=//p' "$BACKUP" | head -1)
	uci -q delete dhcp.@dnsmasq[0].server
	if [ -n "$noresolv" ]; then
		uci set dhcp.@dnsmasq[0].noresolv="$noresolv"
	else
		uci -q delete dhcp.@dnsmasq[0].noresolv
	fi
	sed -n 's/^server=//p' "$BACKUP" | while IFS= read -r s; do
		[ -n "$s" ] && uci add_list dhcp.@dnsmasq[0].server="$s"
	done
	uci commit dhcp
	rm -f "$BACKUP"
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	logger -t xray-mosdns "dnsmasq configuration restored (pre-0.9 backup)"
}

case "$1" in
	revert) revert_dns ;;
	*) echo "usage: $0 revert" >&2; exit 1 ;;
esac
