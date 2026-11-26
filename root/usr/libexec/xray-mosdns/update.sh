#!/bin/sh
# Update helper for luci-app-xray-mosdns-x:
#   versions | check | geo | xray | mosdns
#   xray-file <zip> | mosdns-file <zip> | geo-dir <dir> [version]: the same
#   installs from files already here (the offline bundle's install.sh)
# This package itself is not updated from here: `check` (and the scheduled
# geo update) only look up whether GitHub has a newer release of it.
# UPD_TEST_DIR=<dir> installs into a test root (used by the build VM tests).
set -u

ROOT="${UPD_TEST_DIR:-}"
BACKUP_DIR="$ROOT/root/pw-backup/xray-mosdns-update"
TMP="${TMPDIR:-/tmp}/xray-mosdns-update"
# downloads, backups and the files put in place are root's alone
umask 077
mkdir -p "$BACKUP_DIR" "$TMP"
chmod 700 "$BACKUP_DIR" "$TMP"

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

# ---- this package's own releases: only looked up, never installed from here
APP_REPO=zlylong/luci-app-xray-mosdns-x
# The newest release a check has seen ("v1.2.3"), for the pages. In RAM:
# asked again after a reboot.
app_latest_file() { echo "$ROOT/var/run/xray-mosdns-app-latest"; }
# a tag is a version number and nothing else, or it is not used
is_tag() { printf '%s' "$1" | grep -qE '^v?[0-9]+(\.[0-9]+)*$'; }
app_latest_read() {
	f=$(app_latest_file)
	[ -f "$f" ] || return 0
	t=$(head -n 1 "$f")
	is_tag "$t" && echo "$t"
	return 0
}
# asks GitHub, remembers the answer and prints it; nothing without an answer
app_latest_fetch() {
	t=$(remote_tag "$APP_REPO")
	is_tag "$t" || return 0
	f=$(app_latest_file)
	mkdir -p "$(dirname "$f")" && printf '%s\n' "$t" > "$f"
	echo "$t"
}
# "v1.2.3" and "1.2.3-r1" -> "1.2.3"
app_num() { printf '%s' "$1" | sed 's/^v//; s/-r[0-9]*$//'; }
# $1, $2 = dotted numbers: true when $1 is the higher one
ver_gt() {
	a=$1; b=$2
	while [ -n "$a" ] || [ -n "$b" ]; do
		x=${a%%.*}; y=${b%%.*}
		case "$a" in *.*) a=${a#*.} ;; *) a="" ;; esac
		case "$b" in *.*) b=${b#*.} ;; *) b="" ;; esac
		case "$x" in ''|*[!0-9]*) x=0 ;; esac
		case "$y" in ''|*[!0-9]*) y=0 ;; esac
		# no leading zeros: the shell would read them as octal
		x=$(printf '%s' "$x" | sed 's/^0*//'); y=$(printf '%s' "$y" | sed 's/^0*//')
		[ "${x:-0}" -gt "${y:-0}" ] && return 0
		[ "${x:-0}" -lt "${y:-0}" ] && return 1
	done
	return 1
}
# $1 = release tag, $2 = installed version: "true" when the release is newer
app_newer() {
	[ -n "$1" ] && [ -n "$2" ] && ver_gt "$(app_num "$1")" "$(app_num "$2")" && echo true || echo false
}

geo_marker() { echo "$ROOT/etc/xray-mosdns/geo-version"; }
geo_marker_read() { f=$(geo_marker); [ -f "$f" ] && head -1 "$f" || true; }
geo_marker_write() { f=$(geo_marker); mkdir -p "$(dirname "$f")"; printf '%s\n%s\n' "$1" "$(date +%Y-%m-%dT%H:%M:%S)" > "$f"; }

cron_file() { echo "$ROOT/etc/crontabs/root"; }
# $1 hour, $2 day of the week (0 = Sunday ... 6) or * for every day
cron_line() {
	printf '0 %s * * %s /usr/libexec/xray-mosdns/update.sh geo-auto >>/tmp/xray-mosdns-geo-update.log 2>&1 # xray-mosdns-geo-auto' "$1" "$2"
}

# the scheduled update's hour (0-23, default 4) and day of the week (0-6, or
# * for every day: the default, and what configs without the option mean)
geo_hour() {
	h=$(ug '@global[0].geo_update_hour')
	case "$h" in ''|*[!0-9]*) h=4 ;; esac
	[ "$h" -ge 0 ] 2>/dev/null && [ "$h" -le 23 ] || h=4
	echo "$h"
}
geo_day() {
	d=$(ug '@global[0].geo_update_day')
	case "$d" in [0-6]) echo "$d" ;; *) echo '*' ;; esac
}
day_name() {
	case "$1" in
		0) echo 每周日 ;; 1) echo 每周一 ;; 2) echo 每周二 ;; 3) echo 每周三 ;;
		4) echo 每周四 ;; 5) echo 每周五 ;; 6) echo 每周六 ;; *) echo 每天 ;;
	esac
}

# this package's installed version (apk, or opkg on older releases)
app_version() {
	v=$(apk info -e -v luci-app-xray-mosdns-x 2>/dev/null | head -1 | sed -n 's/^luci-app-xray-mosdns-x-//p')
	[ -n "$v" ] || v=$(opkg status luci-app-xray-mosdns-x 2>/dev/null | sed -n 's/^Version: *//p' | head -1)
	echo "$v"
}

KEEP_BACKUPS=3
LOCK="$TMP.lock"

# one update at a time: a second one is told so instead of racing the first
lock() {
	exec 9>"$LOCK" && flock -n 9 && return 0
	err "another update is running"
	exit 0
}

# $1 = path; prints the copy's path. Keeps the newest $KEEP_BACKUPS of each file.
backup_file() {
	[ -f "$1" ] || return 0
	b=$(basename "$1")
	d="$BACKUP_DIR/$b.$(date +%Y%m%d-%H%M%S)"
	cp -a "$1" "$d" || return 1
	ls -1t "$BACKUP_DIR/$b".* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old; do
		rm -f "$old"
	done
	echo "$d"
}

# $1 = backup from backup_file (may be empty), $2 = where it belongs
restore() {
	[ -n "$1" ] && [ -f "$1" ] || return 1
	cp -a "$1" "$2.restore.$$" && mv -f "$2.restore.$$" "$2"
}

# $1 = file, $2 = expected sha256 (hex)
sha256_ok() {
	[ -n "$2" ] && [ "$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$(printf '%s' "$2" | tr 'A-F' 'a-f')" ]
}

# $1 = new binary, $2 = target. The copy is made next to the target and
# renamed over it, so the target is never half-written, and a running
# daemon keeps its old file.
install_bin() {
	new="$2.new.$$"
	mkdir -p "$(dirname "$2")"
	if cp -f "$1" "$new" && chmod 755 "$new" && "$new" version >/dev/null 2>&1 && mv -f "$new" "$2"; then
		return 0
	fi
	rm -f "$new"
	return 1
}

# $1 = xray|mosdns: no prebuilt archive for this machine
no_asset() {
	err "no prebuilt $1 for $(uname -m) here: update it with the package manager or by hand"
}

geo_size() { [ -f "$1" ] && wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

cmd_versions() {
	xb=$(xray_bin); mb=$(mosdns_bin)
	xv=$("$xb" version 2>/dev/null | head -1)
	[ -n "$xv" ] || xv="not installed"
	mv=$("$mb" version 2>/dev/null | head -1)
	[ -n "$mv" ] || mv="not installed"
	gd=$(v2ray_dir)
	av=$(app_version); al=$(app_latest_read)
	printf '{"ok":true,"app":%s,"app_latest":%s,"app_newer":%s,"xray":%s,"mosdns":%s,"geosite":%s,"geoip":%s,"geo_version":%s}\n' \
		"$(jstr "$av")" "$(jstr "$al")" "$(app_newer "$al" "$av")" "$(jstr "$xv")" "$(jstr "$mv")" \
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
	av=$(app_version); ar=$(app_latest_fetch)
	printf '{"ok":true,"local":{"app":%s,"xray":%s,"xray_num":%s,"mosdns":%s,"mosdns_path":%s,"mosdns_kind":%s,"mosdns_date":%s,"geosite":%s,"geoip":%s,"geo_version":%s},"remote":{"app":%s,"app_newer":%s,"xray":%s,"xray_num":%s,"mosdns":%s,"mosdns_date":%s,"geo":%s,"geo_auto":%s,"geo_hour":%s,"geo_day":%s}}\n' \
		"$(jstr "$av")" "$(jstr "$xv")" "$(jstr "$(xray_num "$xv")")" \
		"$(jstr "$mv")" "$(jstr "$mb")" "$(jstr "$(mosdns_kind "$mv")")" "$(jstr "$(mosdns_date "$mv")")" \
		"$(jstr "$(geo_size "$gd/geosite.dat")")" "$(jstr "$(geo_size "$gd/geoip.dat")")" \
		"$(jstr "$(geo_marker_read)")" \
		"$(jstr "$ar")" "$(app_newer "$ar" "$av")" \
		"$(jstr "$xr")" "$(jstr "$(printf '%s' "$xr" | sed 's/^v//')")" \
		"$(jstr "$mr")" "$(jstr "$(printf '%s' "$mr" | sed 's/^v//')")" \
		"$(jstr "$gr")" \
		"$(jstr "$(ug '@global[0].geo_auto_update')")" "$(jstr "$(geo_hour)")" "$(jstr "$(geo_day)")"
}

cmd_geo() {
	gd=$(v2ray_dir)
	mkdir -p "$gd"
	# both files and their checksums from one release, not whatever "latest" is per request
	_ver="${1:-$(remote_tag Loyalsoldier/v2ray-rules-dat)}"
	if [ -n "$_ver" ]; then
		base="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/$_ver"
	else
		base="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
		_ver="manual-$(date +%Y%m%d-%H%M%S)"
	fi
	for f in geosite.dat geoip.dat; do
		curl -fsSL --max-time 600 -o "$TMP/$f" "$base/$f" || { err "$f download failed"; return; }
		sum=$(curl -fsSL --max-time 30 "$base/$f.sha256sum" 2>/dev/null | sed -n 's/^\([0-9a-fA-F]\{64\}\).*/\1/p' | head -1)
		[ -n "$sum" ] || { err "cannot download the checksum of $f"; return; }
		sha256_ok "$TMP/$f" "$sum" || { err "$f does not match its published checksum: not installed"; return; }
	done
	put_geo "$TMP" "$_ver"
}

# $1 = directory with geosite.dat and geoip.dat, $2 = what to note as their version
put_geo() {
	gd=$(v2ray_dir)
	mkdir -p "$gd"
	_src=$1; _ver=$2
	[ -f "$_src/geosite.dat" ] && [ -f "$_src/geoip.dat" ] || { err "no geosite.dat and geoip.dat in $_src"; return; }
	gs=$(geo_size "$_src/geosite.dat"); gp=$(geo_size "$_src/geoip.dat")
	[ "$gs" -gt 1000000 ] && [ "$gp" -gt 1000000 ] || { err "the geo data looks invalid"; return; }
	bs=$(backup_file "$gd/geosite.dat") && bp=$(backup_file "$gd/geoip.dat") || { err "cannot back up the current geo data"; return; }
	# copies next to the targets, renamed over them; the first is undone if the second fails
	if ! { cp -f "$_src/geosite.dat" "$gd/.geosite.dat.new" && cp -f "$_src/geoip.dat" "$gd/.geoip.dat.new"; }; then
		rm -f "$gd/.geosite.dat.new" "$gd/.geoip.dat.new"
		err "install failed (disk full?)"
		return
	fi
	mv -f "$gd/.geosite.dat.new" "$gd/geosite.dat" || { rm -f "$gd/.geoip.dat.new"; err "install failed"; return; }
	if ! mv -f "$gd/.geoip.dat.new" "$gd/geoip.dat"; then
		rm -f "$gd/.geoip.dat.new"
		restore "$bs" "$gd/geosite.dat"
		err "install failed; the previous geo data is back in place"
		return
	fi
	geo_marker_write "$_ver"
	ok "geo data updated ($_ver; geosite ${gs} bytes, geoip ${gp} bytes). mosdns-x reloads it by itself; restart the service so Xray does too."
}

cmd_geo_auto() {
	# while asking GitHub anyway: is there a newer release of this package?
	# Only noted for the update page.
	app_latest_fetch >/dev/null
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
	hour=$(geo_hour); day=$(geo_day)
	cf=$(cron_file)
	mkdir -p "$(dirname "$cf")"
	backup_file "$cf" >/dev/null
	if [ -f "$cf" ]; then
		sed -i '/# xray-mosdns-geo-auto/d' "$cf"
	else
		: > "$cf"
	fi
	printf '\n%s\n' "$(cron_line "$hour" "$day")" >> "$cf"
	[ -n "$ROOT" ] || /etc/init.d/cron restart >/dev/null 2>&1 || true
	ok "geo 定时更新已启用（$(day_name "$day") ${hour}:00）"
}

cmd_cron_remove() {
	cf=$(cron_file)
	if [ -f "$cf" ]; then
		backup_file "$cf" >/dev/null || true
		sed -i '/# xray-mosdns-geo-auto/d' "$cf"
	fi
	[ -n "$ROOT" ] || /etc/init.d/cron restart >/dev/null 2>&1 || true
	ok "geo 定时更新已关闭"
}

cmd_cron_status() {
	cf=$(cron_file)
	on=0
	[ -f "$cf" ] && grep -q '# xray-mosdns-geo-auto' "$cf" && on=1
	printf '{"ok":true,"enabled":%s,"hour":%s,"day":%s,"marker":%s}\n' "$on" \
		"$(jstr "$(geo_hour)")" "$(jstr "$(geo_day)")" "$(jstr "$(geo_marker_read)")"
}

cmd_xray() {
	xb=$(xray_bin)
	asset=$(asset_name xray); [ -n "$asset" ] || { no_asset xray; return; }
	url=$(latest_url XTLS/Xray-core "$asset")
	[ -n "$url" ] || { err "cannot find release asset $asset"; return; }
	curl -fL --max-time 600 -o "$TMP/xray.zip" "$url" || { err "download failed"; return; }
	# every Xray archive comes with a .dgst listing its hashes
	sum=$(curl -fsSL --max-time 30 "$url.dgst" 2>/dev/null | sed -n 's/^SHA2-256= *\([0-9a-fA-F]\{64\}\).*/\1/p' | head -1)
	[ -n "$sum" ] || { err "cannot download the checksum of $asset"; return; }
	sha256_ok "$TMP/xray.zip" "$sum" || { err "$asset does not match its published checksum: not installed"; return; }
	put_xray "$TMP/xray.zip"
}

# $1 = an Xray release archive
put_xray() {
	xb=$(xray_bin)
	[ -f "$1" ] || { err "no such file: $1"; return; }
	rm -rf "$TMP/xray-new"; mkdir -p "$TMP/xray-new"
	unzip -o -q "$1" -d "$TMP/xray-new" || { err "unzip failed"; return; }
	chmod +x "$TMP/xray-new/xray" 2>/dev/null || { err "no xray binary in archive"; return; }
	newver=$("$TMP/xray-new/xray" version 2>/dev/null | head -1)
	[ -n "$newver" ] || { err "this xray does not run here"; return; }
	oldver=$("$xb" version 2>/dev/null | head -1)
	bk=$(backup_file "$xb") || { err "cannot back up $xb"; return; }
	if install_bin "$TMP/xray-new/xray" "$xb" && "$xb" version >/dev/null 2>&1; then
		ok "xray updated: $oldver -> $newver. Restart the service to use it."
	elif restore "$bk" "$xb"; then
		err "install failed; the previous xray is back in place"
	else
		err "install failed"
	fi
}

# pmkol/mosdns-x publishes no checksums: the archive is only checked by
# running the binary it contains
cmd_mosdns() {
	mb=$(mosdns_bin)
	asset=$(asset_name mosdns); [ -n "$asset" ] || { no_asset mosdns-x; return; }
	url=$(latest_url pmkol/mosdns-x "$asset")
	[ -n "$url" ] || { err "cannot find release asset $asset"; return; }
	curl -fL --max-time 600 -o "$TMP/mosdns.zip" "$url" || { err "download failed"; return; }
	put_mosdns "$TMP/mosdns.zip" " (no published checksum to verify against)"
}

# $1 = a mosdns-x release archive, $2 = a note for the message
put_mosdns() {
	mb=$(mosdns_bin)
	[ -f "$1" ] || { err "no such file: $1"; return; }
	rm -rf "$TMP/mosdns-new"; mkdir -p "$TMP/mosdns-new"
	unzip -o -q "$1" -d "$TMP/mosdns-new" || { err "unzip failed"; return; }
	newbin="$TMP/mosdns-new/mosdns"
	[ -f "$newbin" ] || { err "no mosdns binary in archive"; return; }
	chmod +x "$newbin"
	newver=$("$newbin" version 2>/dev/null | head -1)
	[ -n "$newver" ] || { err "this mosdns does not run here"; return; }
	oldver=$("$mb" version 2>/dev/null | head -1)
	bk=$(backup_file "$mb") || { err "cannot back up $mb"; return; }
	if install_bin "$newbin" "$mb" && "$mb" version >/dev/null 2>&1; then
		ok "mosdns updated: $oldver -> $newver${2:-}. Restart the service to use it."
	elif restore "$bk" "$mb"; then
		err "install failed; the previous mosdns is back in place"
	else
		err "install failed"
	fi
}

case "${1:-versions}" in
	versions) cmd_versions ;;
	check) cmd_check ;;
	geo) lock; cmd_geo "${2:-}" ;;
	# the cron job appends this to its log: with the time, for logs.uc
	geo-auto) lock; printf '%s ' "$(date +%Y-%m-%dT%H:%M:%S%z)"; cmd_geo_auto ;;
	xray) lock; cmd_xray ;;
	mosdns) lock; cmd_mosdns ;;
	xray-file) lock; put_xray "${2:-}" ;;
	mosdns-file) lock; put_mosdns "${2:-}" ;;
	geo-dir) lock; put_geo "${2:-}" "${3:-local-$(date +%Y%m%d-%H%M%S)}" ;;
	cron-install) lock; cmd_cron_install ;;
	cron-remove) lock; cmd_cron_remove ;;
	cron-status) cmd_cron_status ;;
	*) err "unknown action" ;;
esac
