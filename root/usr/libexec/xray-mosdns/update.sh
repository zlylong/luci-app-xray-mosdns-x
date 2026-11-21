#!/bin/sh
# Update helper for luci-app-xray-mosdns-x:
#   versions | geo | xray | mosdns
# UPD_TEST_DIR=<dir> installs into a test root (used by the build VM tests).
set -u

ROOT="${UPD_TEST_DIR:-}"
BACKUP_DIR="$ROOT/root/pw-backup/xray-mosdns-update"
TMP="${TMPDIR:-/tmp}/xray-mosdns-update"
mkdir -p "$BACKUP_DIR" "$TMP"

jstr() { V="$1" ucode -e 'print(sprintf("%J", getenv("V")))'; }
ok() { printf '{"ok":true,"message":%s,"detail":%s}\n' "$(jstr "$1")" "$(jstr "${2:-}")"; }
err() { printf '{"ok":false,"error":%s}\n' "$(jstr "$1")"; }

ug() { uci -q get "xray-mosdns.$1" 2>/dev/null || true; }
xray_bin() { v=$(ug '@global[0].xray_bin'); echo "$ROOT${v:-/usr/bin/xray}"; }
mosdns_bin() { v=$(ug '@dns[0].mosdns_bin'); echo "$ROOT${v:-/usr/bin/mosdns}"; }
v2ray_dir() { v=$(ug '@global[0].geo_dir'); v=${v%/}; echo "$ROOT${v:-/usr/share/v2ray}"; }

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

remote_tag() { # $1 = repo -> latest release tag
	curl -fsSL --max-time 20 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
		| grep -o '"tag_name": "[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/'
}

geo_marker() { echo "$ROOT/etc/xray-mosdns/geo-version"; }
geo_marker_read() { f=$(geo_marker); [ -f "$f" ] && head -1 "$f" || true; }
geo_marker_write() { f=$(geo_marker); mkdir -p "$(dirname "$f")"; printf '%s\n%s\n' "$1" "$(date +%Y-%m-%dT%H:%M:%S)" > "$f"; }

cron_file() { echo "$ROOT/etc/crontabs/root"; }
cron_line() {
	hour=$1
	printf '%s %s * * * /usr/libexec/xray-mosdns/update.sh geo-auto >>/tmp/xray-mosdns-geo-update.log 2>&1 # xray-mosdns-geo-auto' "0" "$hour"
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
	printf '{"ok":true,"xray":%s,"mosdns":%s,"geosite":%s,"geoip":%s,"geo_version":%s}\n' \
		"$(jstr "$xv")" "$(jstr "$mv")" \
		"$(jstr "$(geo_size "$gd/geosite.dat")")" "$(jstr "$(geo_size "$gd/geoip.dat")")" \
		"$(jstr "$(geo_marker_read)")"
}

# normalize version strings for the update page
xray_num() { printf '%s' "$1" | sed -n 's/.*Xray \([0-9][0-9.]*\).*/\1/p' | head -1; }
mosdns_kind() {
	case "$1" in
		*"build time:"*) echo "mosdns-x" ;;
		*) echo "mosdns" ;;
	esac
}
mosdns_date() {
	printf '%s' "$1" | sed -n 's/.*build time: \([0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]\).*/\1/p' | head -1
}

cmd_check() {
	xb=$(xray_bin); mb=$(mosdns_bin)
	xv=$("$xb" version 2>/dev/null | head -1)
	[ -n "$xv" ] || xv="not installed"
	mv=$("$mb" version 2>/dev/null | head -1)
	[ -n "$mv" ] || mv="not installed"
	gd=$(v2ray_dir)
	xr=$(remote_tag XTLS/Xray-core)
	mr=$(remote_tag pmkol/mosdns-x)
	gr=$(remote_tag Loyalsoldier/v2ray-rules-dat)
	printf '{"ok":true,"local":{"xray":%s,"xray_num":%s,"mosdns":%s,"mosdns_path":%s,"mosdns_kind":%s,"mosdns_date":%s,"geosite":%s,"geoip":%s,"geo_version":%s},"remote":{"xray":%s,"xray_num":%s,"mosdns":%s,"mosdns_date":%s,"geo":%s,"geo_auto":%s,"geo_hour":%s}}\n' \
		"$(jstr "$xv")" "$(jstr "$(xray_num "$xv")")" \
		"$(jstr "$mv")" "$(jstr "$mb")" "$(jstr "$(mosdns_kind "$mv")")" "$(jstr "$(mosdns_date "$mv")")" \
		"$(jstr "$(geo_size "$gd/geosite.dat")")" "$(jstr "$(geo_size "$gd/geoip.dat")")" \
		"$(jstr "$(geo_marker_read)")" \
		"$(jstr "$xr")" "$(jstr "$(printf '%s' "$xr" | sed 's/^v//')")" \
		"$(jstr "$mr")" "$(jstr "$(printf '%s' "$mr" | sed 's/^v//')")" \
		"$(jstr "$gr")" \
		"$(jstr "$(ug '@global[0].geo_auto_update')")" "$(jstr "$(ug '@global[0].geo_update_hour')")"
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
	_ver="${1:-$(remote_tag Loyalsoldier/v2ray-rules-dat)}"
	[ -n "$_ver" ] || _ver="manual-$(date +%Y%m%d-%H%M%S)"
	geo_marker_write "$_ver"
	ok "geo data updated ($_ver; geosite ${gs} bytes, geoip ${gp} bytes). Restart xray/passwall to reload."
}

cmd_geo_auto() {
	remote=$(remote_tag Loyalsoldier/v2ray-rules-dat)
	[ -n "$remote" ] || { err "cannot query remote geo version"; return; }
	local_ver=$(geo_marker_read)
	if [ -n "$local_ver" ] && [ "${local_ver%%|*}" = "$remote" ]; then
		ok "geo already up to date ($remote)"
		return
	fi
	cmd_geo "$remote"
}

cmd_cron_install() {
	hour=$(ug '@global[0].geo_update_hour')
	case "$hour" in ''|*[!0-9]*) hour=4 ;; esac
	[ "$hour" -ge 0 ] 2>/dev/null && [ "$hour" -le 23 ] || hour=4
	cf=$(cron_file)
	mkdir -p "$(dirname "$cf")"
	[ -f "$cf" ] && cp -a "$cf" "$BACKUP_DIR/crontab.$(date +%Y%m%d-%H%M%S)"
	if [ -f "$cf" ]; then
		sed -i '/# xray-mosdns-geo-auto/d' "$cf"
	else
		: > "$cf"
	fi
	printf '\n%s\n' "$(cron_line "$hour")" >> "$cf"
	[ -n "$ROOT" ] || /etc/init.d/cron restart >/dev/null 2>&1 || true
	ok "geo 定时更新已启用（每天 ${hour}:00）"
}

cmd_cron_remove() {
	cf=$(cron_file)
	if [ -f "$cf" ]; then
		cp -a "$cf" "$BACKUP_DIR/crontab.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
		sed -i '/# xray-mosdns-geo-auto/d' "$cf"
	fi
	[ -n "$ROOT" ] || /etc/init.d/cron restart >/dev/null 2>&1 || true
	ok "geo 定时更新已关闭"
}

cmd_cron_status() {
	cf=$(cron_file)
	on=0
	[ -f "$cf" ] && grep -q '# xray-mosdns-geo-auto' "$cf" && on=1
	printf '{"ok":true,"enabled":%s,"hour":%s,"marker":%s}\n' "$on" \
		"$(jstr "$(ug '@global[0].geo_update_hour')")" "$(jstr "$(geo_marker_read)")"
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
	check) cmd_check ;;
	geo) cmd_geo "${2:-}" ;;
	geo-auto) cmd_geo_auto ;;
	xray) cmd_xray ;;
	mosdns) cmd_mosdns ;;
	cron-install) cmd_cron_install ;;
	cron-remove) cmd_cron_remove ;;
	cron-status) cmd_cron_status ;;
	*) err "unknown action" ;;
esac
