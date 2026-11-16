#!/bin/sh
# The uci-defaults migration must not change behaviour: for every fixture,
# the config generated before and after migrating has to be identical.
# Runs inside an OpenWrt rootfs. usage: tests/migrate.sh <repo>
REPO=${1:-.}
gen() { # $1 confdir  $2 outdir
	mkdir -p "$2"
	ucode -L "$REPO/root/usr/share/ucode" "$REPO/root/usr/share/xray-mosdns/gen-config.uc" \
		-o "$2" -c "$1" -g "$REPO/tests/fixtures/geoip.dat" -l br-lan -n 2>/dev/null
}
rc=0
for d in "$REPO"/tests/fixtures/*/; do
	name=$(basename "$d")
	gen "$d" "/tmp/mig/$name/before" || { echo "migrate $name: generation failed"; rc=1; continue; }
	cp "$d/xray-mosdns" /etc/config/xray-mosdns
	sh "$REPO/root/etc/uci-defaults/90_xray-mosdns" >/dev/null 2>&1
	sh "$REPO/root/etc/uci-defaults/90_xray-mosdns" >/dev/null 2>&1	# must be idempotent
	[ -z "$(uci -q get xray-mosdns.global.rule_mode)" ] || { echo "migrate $name: rule_mode left behind"; rc=1; }
	gen /etc/config "/tmp/mig/$name/after" || { echo "migrate $name: generation failed after migration"; rc=1; continue; }
	same=1
	for f in xray.json mosdns.yaml nft.rules; do
		cmp -s "/tmp/mig/$name/before/$f" "/tmp/mig/$name/after/$f" || { same=0; echo "migrate $name: $f differs"; }
	done
	[ $same = 1 ] && echo "migrate $name: identical ($(uci show xray-mosdns | grep -c '=rule$') rules)" || rc=1
done
exit $rc
