#!/bin/sh
# luci-app-xray-mosdns-x - DNS watchdog
#
# LAN DNS reaches mosdns-x through one nftables redirect rule. If mosdns-x is
# down or stops answering, that rule would turn every lookup on the LAN into
# a timeout. This loop owns the rule: it is installed only while mosdns-x
# answers queries, and removed after a couple of failed probes so that
# dnsmasq, which never stopped listening on port 53, serves the LAN again.
#
# While dnsmasq is answering, the kernel sets are not being filled, so
# domain rules only apply to addresses learned earlier; IP rules and the
# default still work. That is the price of keeping the network usable.
OUT=/var/etc/xray-mosdns
ON="$OUT/nft-dns-on.rules"
OFF="$OUT/nft-dns-off.rules"
STAMP=/var/run/xray-mosdns-dns.stamp
INTERVAL=5	# seconds between probes
FAILS=2		# consecutive failed probes before falling back

PORT=$(uci -q get 'xray-mosdns.@dns[0].listen_port'); [ -n "$PORT" ] || PORT=5335

# Any DNS reply counts, including SERVFAIL or NXDOMAIN: a dead uplink is not
# something dnsmasq would handle better. Only silence means mosdns-x is gone.
healthy() {
	out=$(nslookup -port="$PORT" -timeout=2 -retry=1 localhost 127.0.0.1 2>&1)
	case "$out" in
		*"timed out"*|*"no servers could be reached"*) return 1 ;;
	esac
	return 0
}

active() {
	nft list chain inet xray-mosdns dns_redirect 2>/dev/null | grep -q "redirect to"
}

fail=0
while :; do
	if healthy; then
		fail=0
		if ! active; then
			nft -f "$ON" 2>/dev/null && {
				touch "$STAMP"
				logger -t xray-mosdns "mosdns-x is answering: LAN DNS redirected to :$PORT"
			}
		elif [ "$ON" -nt "$STAMP" ]; then
			# the rule changed (port, interfaces): swap it in place
			nft -f "$ON" 2>/dev/null && touch "$STAMP"
		fi
	else
		fail=$((fail + 1))
		if [ "$fail" -ge "$FAILS" ] && active; then
			nft -f "$OFF" 2>/dev/null
			logger -p daemon.warn -t xray-mosdns "mosdns-x is not answering on :$PORT - LAN DNS handed back to dnsmasq"
		fi
	fi
	sleep "$INTERVAL"
done
