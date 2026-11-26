#!/bin/sh
# Builds the full bundle: this package, the packages it depends on, Xray,
# mosdns-x and the geo data in one archive, with an install.sh that needs no
# network on the router.
#   make.sh <package.apk> <rootfs> <apk with mkndx> <out dir>
# <rootfs> is an unpacked ImmortalWrt rootfs of the firmware in `components`,
# its feeds reachable (apk update works in it): its own apk fetches the
# dependencies, signatures checked against its keys. Run as root (chroot).
set -eu
PKG=$1; R=$2; APK=$3; OUT=$4
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/components"

f=$(basename "$PKG")
ver=${f#luci-app-xray-mosdns-x-}; ver=${ver%-r[0-9]*.apk}
NAME=luci-app-xray-mosdns-x-$ver-full-x86_64
W=$(mktemp -d); B=$W/$NAME
mkdir -p "$B/apks" "$B/components" "$OUT"
trap 'rm -rf "$W" "$R/bundle-apks"' EXIT

get() { # $1 = url, $2 = file
	curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 20 --speed-limit 10240 --speed-time 60 --max-time 900 -o "$2" "$1"
}
want() { # $1 = file, $2 = sha256
	echo "$2  $1" | sha256sum -c - >/dev/null || { echo "bundle: $(basename "$1") does not match its checksum" >&2; exit 1; }
}

# ---- the dependencies, as the Makefile names them, and all of theirs
deps=$(sed -n '/^LUCI_DEPENDS:=/,/^[^\t]*$/p' "$HERE/../Makefile" | grep -o '+[a-z0-9-]*' | tr -d '+' | tr '\n' ' ')
deps="$deps $(sed -n 's/^LUCI_EXTRA_DEPENDS:=\([a-z0-9-]*\).*/\1/p' "$HERE/../Makefile")"
echo "bundle: dependencies: $deps"
[ "$(echo $deps | wc -w)" -ge 10 ]
rm -rf "$R/bundle-apks"; mkdir -p "$R/bundle-apks"
chroot "$R" apk update >/dev/null 2>&1 || echo "bundle: apk update: some feeds failed"
# shellcheck disable=SC2086
chroot "$R" apk fetch -R -o /bundle-apks $deps >/dev/null
cp "$R"/bundle-apks/*.apk "$B/apks/"
n=$(ls "$B/apks" | wc -l)
echo "bundle: $n packages fetched"
ls "$B/apks" | grep -q '^kmod-nft-tproxy-' && ls "$B/apks" | grep -q '^curl-'
# an index, so that the router's apk picks from them what it lacks
( cd "$B/apks" && "$APK" mkndx --allow-untrusted -o packages.adb ./*.apk )
[ -s "$B/apks/packages.adb" ]

# ---- this package
cp "$PKG" "$B/"

# ---- Xray, mosdns-x
get "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/$XRAY_ASSET" "$B/components/$XRAY_ASSET"
want "$B/components/$XRAY_ASSET" "$XRAY_SHA256"
get "https://github.com/pmkol/mosdns-x/releases/download/$MOSDNS_VERSION/$MOSDNS_ASSET" "$B/components/$MOSDNS_ASSET"
want "$B/components/$MOSDNS_ASSET" "$MOSDNS_SHA256"

# ---- geo data: both files of one release
GEO_VERSION=$(curl -fsSL --retry 3 --max-time 30 https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/releases/latest 2>/dev/null \
	| sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
[ -n "$GEO_VERSION" ] || { echo "bundle: cannot ask GitHub for the newest geo data" >&2; exit 1; }
for g in geosite.dat geoip.dat; do
	base=https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/$GEO_VERSION
	get "$base/$g" "$B/components/$g"
	sum=$(curl -fsSL --retry 3 --max-time 30 "$base/$g.sha256sum" | sed -n 's/^\([0-9a-fA-F]\{64\}\).*/\1/p' | head -1)
	[ -n "$sum" ]
	want "$B/components/$g" "$sum"
done

# ---- the rest
cp "$HERE/install.sh" "$HERE/README.txt" "$B/"
cat > "$B/VERSIONS" <<V
PLUGIN=$ver
PLUGIN_APK=$f
FIRMWARE="$FIRMWARE"
XRAY_VERSION=$XRAY_VERSION
XRAY_ASSET=$XRAY_ASSET
MOSDNS_VERSION=$MOSDNS_VERSION
MOSDNS_ASSET=$MOSDNS_ASSET
GEO_VERSION=$GEO_VERSION
V
( cd "$B" && find . -type f ! -name SHA256SUMS | sed 's#^\./##' | sort | xargs sha256sum > SHA256SUMS )
tar -C "$W" --owner=0 --group=0 -czf "$OUT/$NAME.tar.gz" "$NAME"
echo "bundle: $OUT/$NAME.tar.gz ($(wc -c < "$OUT/$NAME.tar.gz") bytes; geo $GEO_VERSION)"
