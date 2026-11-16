#!/bin/sh
# Generate configs for every fixture. Runs inside an OpenWrt rootfs (ucode + uci).
# usage: tests/gen.sh <repo> <outdir>
REPO=${1:-.}; OUT=${2:-/tmp/xm-test}
rc=0
for d in "$REPO"/tests/fixtures/*/; do
	name=$(basename "$d")
	mkdir -p "$OUT/$name"
	if ucode -L "$REPO/root/usr/share/ucode" "$REPO/root/usr/share/xray-mosdns/gen-config.uc" \
		-o "$OUT/$name" -c "$d" -g "$REPO/tests/fixtures/geoip.dat" -l br-lan -n; then
		echo "gen $name: ok"
	else
		echo "gen $name: FAILED"; rc=1
	fi
done
# blocklist conversion: one sample covering every kind of line
mkdir -p "$OUT/adlist"
ucode -L "$REPO/root/usr/share/ucode" "$REPO/root/usr/libexec/xray-mosdns/adlist.uc" convert \
	"$REPO/tests/adlist/sample.txt" "$OUT/adlist/block.txt" "$OUT/adlist/allow.txt" > "$OUT/adlist/stats.json" \
	&& echo "gen adlist: ok" || { echo "gen adlist: FAILED"; rc=1; }
exit $rc
