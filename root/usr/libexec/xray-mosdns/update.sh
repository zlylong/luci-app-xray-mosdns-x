#!/bin/sh
# Update helper for luci-app-xray-mosdns-x:
#   versions | geo | xray | mosdns
# UPD_TEST_DIR=<dir> installs into a test root (used by the build VM tests).
set -u

ROOT="${UPD_TEST_DIR:-}"
BACKUP_DIR="$ROOT/root/pw-backup/xray-mosdns-update"
TMP="${TMPDIR:-/tmp}/xray-mosdns-update"
mkdir -p "$BACKUP_DIR" "$TMP"

jstr() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null || printf '"%s"' "$1"; }
ok() { printf '{"ok":true,"message":%s,"detail":%s}\n' "$(jstr "$1")" "$(jstr "${2:-}")"; }
err() { printf '{"ok":false,"error":%s}\n' "$(jstr "$1")"; }

ug() { uci -q get "xray-mosdns.$1" 2>/dev/null || true; }
xray_bin() { v=$(ug '@global[0].xray_bin'); echo "$ROOT${v:-/usr/bin/xray}"; }
mosdns_bin() { v=$(ug '@dns[0].mosdns_bin'); echo "$ROOT${v:-/usr/bin/mosdns}"; }
v2ray_dir() { echo "$ROOT/usr/share/v2ray"; }

asset_name() { # $1 = xray|mosdns
	case "$(uname -m)" in
		x86_64|amd64) [ "$1" = xray ] && echo "Xray-linux-64.zip" || echo "mosdns-linux-amd64.zip" ;;
		aarch64|arm64) [ "$1" = xray ] && echo "Xray-linux-arm64-v8a.zip" || echo "mosdns-linux-arm64.zip" ;;
		*) echo "" ;;
	esac
}

latest_url() { # $1 = repo, $2 = asset name
	curl -fsSL --max-time 30 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
		| grep -o '"browser_download_url": "[^"]*"' \
		| sed 's/.*"\(http[^"]*\)"/\1/' \
		| grep -F "/$2" | head -1
}

backup_file() { # $1 = path
	[ -f "$1" ] || return 0
	d="$BACKUP_DIR/$(basename "$1").$(date +%Y%m%d-%H%M%S)"
	cp -a "$1" "$d" && echo "$d"
}

geo_size() { [ -f "$1" ] && wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

cmd_versions() {
	xb=$(xray_bin); mb=$(mosdns_bin)
	xv=$("$xb" version 2>/dev/null | head -1)
	[ -n "$xv" ] || xv="not installed"
	mv=$("$mb" version 2>/dev/null | head -1)
	[ -n "$mv" ] || mv="not installed"
	gd=$(v2ray_dir)
	printf '{"ok":true,"xray":%s,"mosdns":%s,"geosite":%s,"geoip":%s}\n' \
		"$(jstr "$xv")" "$(jstr "$mv")" \
		"$(jstr "$(geo_size "$gd/geosite.dat")")" "$(jstr "$(geo_size "$gd/geoip.dat")")"
}

cmd_geo() {
	gd=$(v2ray_dir)
	mkdir -p "$gd"
	curl -fsSL --max-time 600 -o "$TMP/geosite.dat" \
		https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat || { err "geosite.dat download failed"; return; }
	curl -fsSL --max-time 600 -o "$TMP/geoip.dat" \
		https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat || { err "geoip.dat download failed"; return; }
	gs=$(geo_size "$TMP/geosite.dat"); gp=$(geo_size "$TMP/geoip.dat")
	[ "$gs" -gt 1000000 ] && [ "$gp" -gt 1000000 ] || { err "downloaded geo data looks invalid"; return; }
	backup_file "$gd/geosite.dat" >/dev/null
	backup_file "$gd/geoip.dat" >/dev/null
	mv -f "$TMP/geosite.dat" "$gd/geosite.dat" && mv -f "$TMP/geoip.dat" "$gd/geoip.dat" || { err "install failed"; return; }
	ok "geo data updated (geosite ${gs} bytes, geoip ${gp} bytes). Restart xray/passwall to reload."
}

cmd_xray() {
	xb=$(xray_bin)
	asset=$(asset_name xray); [ -n "$asset" ] || { err "unsupported architecture"; return; }
	url=$(latest_url XTLS/Xray-core "$asset")
	[ -n "$url" ] || { err "cannot find release asset $asset"; return; }
	curl -fL --max-time 600 -o "$TMP/xray.zip" "$url" || { err "download failed"; return; }
	rm -rf "$TMP/xray-new"; mkdir -p "$TMP/xray-new"
	unzip -o -q "$TMP/xray.zip" -d "$TMP/xray-new" || { err "unzip failed"; return; }
	chmod +x "$TMP/xray-new/xray" 2>/dev/null || { err "no xray binary in archive"; return; }
	newver=$("$TMP/xray-new/xray" version 2>/dev/null | head -1)
	[ -n "$newver" ] || { err "downloaded xray does not run"; return; }
	oldver=$("$xb" version 2>/dev/null | head -1)
	backup_file "$xb" >/dev/null
	mkdir -p "$(dirname "$xb")"
	if cp -f "$TMP/xray-new/xray" "$xb" && chmod 755 "$xb" && "$xb" version >/dev/null 2>&1; then
		ok "xray updated: $oldver -> $newver. Restart the service (and PassWall) to use it."
	else
		err "install failed"
	fi
}

cmd_mosdns() {
	mb=$(mosdns_bin)
	asset=$(asset_name mosdns); [ -n "$asset" ] || { err "unsupported architecture"; return; }
	url=$(latest_url pmkol/mosdns-x "$asset")
	[ -n "$url" ] || { err "cannot find release asset $asset"; return; }
	curl -fL --max-time 600 -o "$TMP/mosdns.zip" "$url" || { err "download failed"; return; }
	rm -rf "$TMP/mosdns-new"; mkdir -p "$TMP/mosdns-new"
	unzip -o -q "$TMP/mosdns.zip" -d "$TMP/mosdns-new" || { err "unzip failed"; return; }
	newbin="$TMP/mosdns-new/mosdns"
	[ -f "$newbin" ] || { err "no mosdns binary in archive"; return; }
	chmod +x "$newbin"
	newver=$("$newbin" version 2>/dev/null | head -1)
	[ -n "$newver" ] || { err "downloaded mosdns does not run"; return; }
	oldver=$("$mb" version 2>/dev/null | head -1)
	backup_file "$mb" >/dev/null
	mkdir -p "$(dirname "$mb")"
	if cp -f "$newbin" "$mb" && chmod 755 "$mb" && "$mb" version >/dev/null 2>&1; then
		ok "mosdns updated: $oldver -> $newver. Restart the service to use it."
	else
		err "install failed"
	fi
}

case "${1:-versions}" in
	versions) cmd_versions ;;
	geo) cmd_geo ;;
	xray) cmd_xray ;;
	mosdns) cmd_mosdns ;;
	*) err "unknown action" ;;
esac
