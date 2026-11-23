#!/bin/sh
# luci-app-xray-mosdns-x - a new set of routing rules into the running Xray
#
#   xray-rules.sh apply <rules in use> <new rules>
#
# Both are xray-rules.json files (gen-config.uc: Xray's "routing" with the
# rules alone). Xray's API takes rules while it runs, so a change to the
# rules needs no restart: connections stay, and so does what the node
# groups have learned. Every rule carries a ruleTag that starts with the
# hash of its whole set: the new set never has a tag of the old one, so it
# is added first, behind the old rules, and takes over the moment those are
# removed. There is no time without rules.
#
# From the environment: XRAY_BIN, API_PORT, GEO_DIR (runtime.env's).
# Exit status: 0 Xray routes by the new rules (or already did), 1 it does
# not: the caller restarts it, and a start reads the same rules from
# xray.json. What failed is on stderr.
tags() { sed -n 's/^[[:space:]]*"ruleTag": *"\([A-Za-z0-9_]*\)".*/\1/p' "$1"; }

[ "$1" = apply ] && [ -f "$2" ] && [ -f "$3" ] || { echo "usage: xray-rules.sh apply <rules in use> <new rules>" >&2; exit 2; }
old=$(tags "$2")
new=$(tags "$3")
[ -n "$new" ] || { echo "no tagged rules in $3" >&2; exit 1; }
[ -n "$old" ] || { echo "no tagged rules in $2: what Xray has cannot be removed" >&2; exit 1; }
# the tags are the set's hash: one in common, and the sets are the same
first=${new%%[!A-Za-z0-9_]*}
for t in $old; do
	[ "$t" = "$first" ] && exit 0
done

XRAY_BIN=${XRAY_BIN:-/usr/bin/xray}
S=127.0.0.1:${API_PORT:-10085}
# the command line tool reads geosite.dat / geoip.dat itself to build the rules
XRAY_LOCATION_ASSET=${GEO_DIR:-/usr/share/v2ray} "$XRAY_BIN" api adrules --server="$S" -t 30 -append "$3" >/dev/null || {
	echo "adding the new rules failed" >&2
	exit 1
}
# shellcheck disable=SC2086
"$XRAY_BIN" api rmrules --server="$S" -t 30 $old >/dev/null || {
	echo "removing the old rules failed" >&2
	exit 1
}
exit 0
