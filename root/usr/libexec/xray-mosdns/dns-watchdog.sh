#!/bin/sh
# luci-app-xray-mosdns-x - DNS and Xray watchdog
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
#
# The same goes for Xray: the rules send proxied traffic to its TProxy port.
# When nothing has listened there for a while (Xray crashed and procd gave
# up, say), the transparent proxy is taken out of the path (fw.sh gate) and
# that traffic goes out directly; it is put back as soon as Xray listens
# again. A single crash that procd restarts within the grace period does
# not trigger it.
#
# usage: dns-watchdog.sh [manage|log-only]
#   log-only: do not touch the redirect (it is static, or there is none);
#             only keep the mosdns log file from growing without bound
#             (Xray is watched in both modes)
MODE=${1:-manage}
umask 077	# the log trim writes a copy of the query log
OUT=/var/etc/xray-mosdns
LOG=/tmp/mosdns-x.log
LOG_MAX=4194304		# bytes (runtime.env's QUERY_LOG_MAX); trimmed back to the newer half
ON="$OUT/nft-dns-on.rules"
OFF="$OUT/nft-dns-off.rules"
STAMP=/var/run/xray-mosdns-dns.stamp
INTERVAL=5	# seconds between probes
FAILS=2		# consecutive failed probes before falling back

FW=/usr/share/xray-mosdns/fw.sh
XFAILS=4	# probes without Xray listening before the proxy is taken out (15-20 s;
		# procd waits 5 s before restarting a crashed daemon)

# Read on every round, as the files in effect have them (runtime.env): a
# reload can change them without restarting this loop, and a reload that
# fell back to the previous files keeps the previous ports.
ports() {
	DNS_PORT=$(uci -q get 'xray-mosdns.@dns[0].listen_port'); [ -n "$DNS_PORT" ] || DNS_PORT=5335
	TPROXY_PORT=$(uci -q get 'xray-mosdns.@global[0].tproxy_port'); [ -n "$TPROXY_PORT" ] || TPROXY_PORT=12345
	[ -f "$OUT/runtime.env" ] && . "$OUT/runtime.env"
	PORT=$DNS_PORT
	TPORT=$TPROXY_PORT
}

# Any DNS reply counts, including SERVFAIL or NXDOMAIN: a dead uplink is not
# something dnsmasq would handle better. Only silence means mosdns-x is gone.
# A reserved name that mosdns-x answers first thing, without logging or
# counting it (the DNS counts and the query log are the LAN's queries).
PROBE=xray-mosdns-probe.invalid
healthy() {
	out=$(nslookup -port="$PORT" -timeout=2 -retry=1 "$PROBE" 127.0.0.1 2>&1)
	case "$out" in
		*"timed out"*|*"no servers could be reached"*) return 1 ;;
	esac
	return 0
}

active() {
	nft list chain inet xray-mosdns dns_redirect 2>/dev/null | grep -q "redirect to"
}

# mosdns appends to its log (every query, with the query log on) and never
# rotates it; /tmp is RAM
trim_log() {
	[ -f "$LOG" ] || return 0
	max=${QUERY_LOG_MAX:-$LOG_MAX}
	[ "$(wc -c < "$LOG")" -gt "$max" ] || return 0
	# the newer half, from its first whole line; in place, mosdns keeps writing to the file
	tail -c $((max / 2)) "$LOG" 2>/dev/null | sed 1d > "$LOG.trim" && cat "$LOG.trim" > "$LOG"
	rm -f "$LOG.trim"
}

# $1 = port: a TCP socket is listening on it (IPv4 or IPv6)
listening() {
	hex=$(printf '%04X' "$1")
	grep -qE "^ *[0-9]+: [0-9A-F]+:$hex [0-9A-F]+:0000 0A " /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

xfail=0
gate_err=""	# the last gate/ungate failure, logged once rather than every round
watch_xray() {
	# no rules loaded (service stopped or torn down): nothing points at Xray
	nft list table inet xray-mosdns >/dev/null 2>&1 || { xfail=0; return; }
	if listening "$TPORT"; then
		xfail=0
		"$FW" gated || return 0
		if e=$("$FW" ungate 2>&1); then
			gate_err=""
			logger -t xray-mosdns "Xray is listening on :$TPORT again: transparent proxy back in the path"
		elif [ "$e" != "$gate_err" ]; then
			gate_err=$e
			logger -p daemon.err -t xray-mosdns "$e"
		fi
	else
		xfail=$((xfail + 1))
		if "$FW" gated; then
			# Out of the path already. A LAN DNS redirect back in the meantime
			# (put back by hand, say) would send names to a mosdns that cannot
			# reach its foreign upstreams: gating again takes it off. Only then:
			# a gate that holds costs one look at the chain per round.
			active || return 0
			if e=$("$FW" gate 2>&1); then
				gate_err=""
				logger -p daemon.warn -t xray-mosdns "LAN DNS redirect found while the transparent proxy is out of the path: handed back to dnsmasq"
			elif [ "$e" != "$gate_err" ]; then
				gate_err=$e
				logger -p daemon.err -t xray-mosdns "$e"
			fi
			return 0
		fi
		[ "$xfail" -ge "$XFAILS" ] || return 0
		if e=$("$FW" gate 2>&1); then
			gate_err=""
			logger -p daemon.warn -t xray-mosdns "Xray is not listening on :$TPORT: transparent proxy taken out, LAN DNS with dnsmasq, traffic goes out directly until it is back"
		elif [ "$e" != "$gate_err" ]; then
			gate_err=$e
			logger -p daemon.err -t xray-mosdns "Xray is not listening on :$TPORT and $e"
		fi
	fi
}

# the DNS counts (stats.uc): a sample every 10 minutes, onto flash every hour;
# the plugin's logs cut to global.log_days (logs.uc): now, then every 6 hours
STATS=/usr/libexec/xray-mosdns/stats.uc
LOGS=/usr/libexec/xray-mosdns/logs.uc
SAMPLE_ROUNDS=$((600 / INTERVAL)); FLUSH_ROUNDS=$((3600 / INTERVAL)); PRUNE_ROUNDS=$((21600 / INTERVAL))
round=0
stats() {
	[ $((round % PRUNE_ROUNDS)) -eq 0 ] && ucode "$LOGS" prune >/dev/null 2>&1
	round=$((round + 1))
	if [ $((round % FLUSH_ROUNDS)) -eq 0 ]; then
		ucode "$STATS" flush >/dev/null 2>&1
	elif [ $((round % SAMPLE_ROUNDS)) -eq 0 ]; then
		ucode "$STATS" sample >/dev/null 2>&1
	fi
}

fail=0
while :; do
	ports
	trim_log
	watch_xray
	stats
	if [ "$MODE" != "manage" ]; then
		sleep "$INTERVAL"
		continue
	fi
	if healthy; then
		fail=0
		# with the proxy out of the path, LAN DNS stays with dnsmasq on purpose
		if "$FW" gated; then
			:
		elif ! active; then
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
