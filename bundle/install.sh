#!/bin/sh
# Installs luci-app-xray-mosdns-x and what it needs from this directory,
# without a network:
#   sh install.sh             what is missing: the package and its
#                             dependencies, Xray, mosdns-x, the geo data
#   sh install.sh --replace   also replaces Xray, mosdns-x and geo data that
#                             are already there with the ones from here
#   sh install.sh --online    lets apk use the configured feeds as well
# The plugin stays disabled after a first install.
D=$(cd "$(dirname "$0")" && pwd)
replace=; online=
for a in "$@"; do
	case "$a" in
		--replace) replace=1 ;;
		--online) online=1 ;;
		*) echo "用法: sh install.sh [--replace] [--online]"; exit 2 ;;
	esac
done
say() { echo "== $*"; }
die() { echo "!! $*" >&2; exit 1; }

. "$D/VERSIONS" || die "缺少 VERSIONS 文件：压缩包不完整"
[ "$(id -u)" = 0 ] || die "需要以 root 运行"
arch=$(cat /etc/apk/arch 2>/dev/null)
[ "$arch" = x86_64 ] || die "这个包只适用于 x86_64，本机是 ${arch:-未知（没有 apk）}"

say "校验文件"
( cd "$D" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) || die "文件校验失败：压缩包损坏或不完整，什么都没有安装"

say "安装插件和依赖（$PLUGIN_APK）"
if [ -n "$online" ]; then
	apk add --allow-untrusted -X "$D/apks/packages.adb" "$D/$PLUGIN_APK"
else
	apk add --allow-untrusted --repositories-file /dev/null -X "$D/apks/packages.adb" "$D/$PLUGIN_APK"
fi || {
	echo "!! 插件没有装上。" >&2
	echo "   包里的依赖取自 $FIRMWARE；内核模块 kmod-nft-tproxy 只能配这个固件的内核。" >&2
	echo "   本机：$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-未知}")，内核 $(uname -r)。" >&2
	echo "   固件不同时，联网后用 sh install.sh --online 让 apk 从软件源补齐依赖。" >&2
	exit 1
}

U=/usr/libexec/xray-mosdns/update.sh
[ -x "$U" ] || die "插件装上了，但找不到 $U"
ug() { uci -q get "xray-mosdns.$1" 2>/dev/null; }
# $1 = what, the rest = an update.sh call; prints its message
put() {
	what=$1; shift
	out=$("$U" "$@" 2>&1)
	case "$out" in
		*'"ok":true'*) echo "   $what：已安装" ;;
		*) echo "!! $what 没有装上：$out" >&2; failed=1 ;;
	esac
}
failed=

say "Xray（$XRAY_VERSION）"
xb=$(ug '@global[0].xray_bin'); xb=${xb:-/usr/bin/xray}
have=$("$xb" version 2>/dev/null | head -1)
if [ -n "$have" ] && [ -z "$replace" ]; then
	echo "   已有：$have，保留（--replace 可替换）"
else
	put Xray xray-file "$D/components/$XRAY_ASSET"
fi

say "mosdns-x（$MOSDNS_VERSION）"
mb=$(ug '@dns[0].mosdns_bin'); mb=${mb:-/usr/bin/mosdns}
have=$("$mb" version 2>/dev/null | head -1)
case "$have" in
	*"build time:"*) is_x=1 ;;
	*) is_x= ;;
esac
if [ -n "$is_x" ] && [ -z "$replace" ]; then
	echo "   已有：$have，保留（--replace 可替换）"
else
	[ -n "$have" ] && [ -z "$is_x" ] && echo "   已有的 $mb 不是 mosdns-x（$have），替换；原文件备份在 /root/pw-backup/xray-mosdns-update"
	put mosdns-x mosdns-file "$D/components/$MOSDNS_ASSET"
fi

say "geosite.dat / geoip.dat（$GEO_VERSION）"
gd=$(ug '@global[0].geo_dir'); gd=${gd%/}; gd=${gd:-/usr/share/v2ray}
if [ -s "$gd/geosite.dat" ] && [ -s "$gd/geoip.dat" ] && [ -z "$replace" ]; then
	echo "   $gd 里已有，保留（--replace 可替换）"
else
	put "geo 数据" geo-dir "$D/components" "$GEO_VERSION"
fi

[ -z "$failed" ] || die "有组件没有装上，见上面的信息"
say "完成"
if [ "$(ug '@global[0].enabled')" = 1 ]; then
	echo "   插件已启用。替换了 Xray、mosdns-x 或 geo 数据时，执行 /etc/init.d/xray-mosdns restart 才会用上新的。"
else
	echo "   插件默认不启用：在 LuCI → 服务 → Xray + mosdns-x 里添加节点后再启用。"
fi
