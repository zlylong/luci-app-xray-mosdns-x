#!/bin/sh
# Import proxy share links (vless / vmess / trojan / shadowsocks) into UCI nodes.
# Imported nodes are created DISABLED; select one in the Nodes page afterwards.
# Usage: import-links.sh <file-with-one-link-per-line>
FILE="${1:-/tmp/xray-mosdns-import.txt}"
CFG=xray-mosdns
TMPJ=/tmp/.xray-mosdns-import.json

[ -f "$FILE" ] || { printf '{"ok":false,"error":"file not found"}\n'; exit 1; }

b64dec() {
	v=$(printf '%s' "$1" | tr '_-' '/+' | tr -d '\r\n')
	case $(( ${#v} % 4 )) in
		2) v="$v==" ;;
		3) v="$v=" ;;
	esac
	# ucode decodes it: BusyBox on OpenWrt has no base64 applet
	V="$v" ucode -e 'const d = b64dec(getenv("V")); if (d != null) print(d);' 2>/dev/null
}

urldec() {
	s=$(printf '%s' "$1" | sed 's/+/ /g')
	printf '%b' "$(printf '%s' "$s" | sed 's/%/\\x/g')"
}

jf() {
	[ -f "$TMPJ" ] || { echo ""; return 0; }
	jsonfilter -i "$TMPJ" -e "$1" 2>/dev/null | sed -n '1p'
}

uci_set() { uci -q set "$CFG.$1=$2" 2>/dev/null; }

new_section() {
	# named section (sub_<epoch>_<pid>_<index>) so that UI node selection is unambiguous
	sec="sub_$(date +%s)_$$_$3"
	uci set "$CFG.$sec=node" 2>/dev/null || return 1
	uci_set "$sec.enabled" '0'
	uci_set "$sec.remarks" "$1"
	uci_set "$sec.type" "$2"
	echo "$sec"
}

# split "a=1&b=2" query string and expose via shell vars for the caller
parse_query() {
	Q_TLS=0; Q_SNI=""; Q_FP=""; Q_NET=""; Q_PATH=""; Q_HOST=""; Q_SVC=""; Q_FLOW=""; Q_INSEC=0
	for kv in $(printf '%s' "$1" | sed 's/&/ /g'); do
		k=${kv%%=*}; v=${kv#*=}
		case "$k" in
			security) [ "$v" != "none" ] && [ "$v" != "" ] && Q_TLS=1 ;;
			sni) Q_SNI=$(urldec "$v") ;;
			fp) Q_FP=$v ;;
			type) Q_NET=$v ;;
			path) Q_PATH=$(urldec "$v") ;;
			host) Q_HOST=$(urldec "$v") ;;
			serviceName) Q_SVC=$(urldec "$v") ;;
			flow) Q_FLOW=$v ;;
			allowInsecure) [ "$v" = "1" ] && Q_INSEC=1 ;;
		esac
	done
}

parse_vless() {
	idx=$2
	url=${1#vless://}
	ref=""
	case "$url" in *'#'*) ref=$(urldec "${url##*#}"); url=${url%#*} ;; esac
	q=""
	case "$url" in *'?'*) q=${url#*\?}; url=${url%%\?*} ;; esac
	uuid=${url%%@*}; hp=${url#*@}
	case "$hp" in *:*) ;; *) return 1 ;; esac
	host=${hp%:*}; port=${hp##*:}
	host=${host#[}; host=${host%]}
	[ -n "$uuid" ] && [ -n "$host" ] && [ -n "$port" ] || return 1
	parse_query "$q"
	flow=$Q_FLOW; [ -n "$flow" ] || flow=""
	sec=$(new_section "${ref:-vless-$host}" vless "$idx") || return 1
	uci_set "$sec.address" "$host"
	uci_set "$sec.port" "$port"
	uci_set "$sec.uuid" "$uuid"
	uci_set "$sec.tls" "$Q_TLS"
	uci_set "$sec.transport" "${Q_NET:-tcp}"
	[ -n "$Q_SNI" ] && uci_set "$sec.tls_server_name" "$Q_SNI"
	[ -n "$Q_FP" ] && uci_set "$sec.fingerprint" "$Q_FP"
	[ -n "$Q_PATH" ] && uci_set "$sec.path" "$Q_PATH"
	[ -n "$Q_HOST" ] && uci_set "$sec.host" "$Q_HOST"
	[ -n "$Q_SVC" ] && uci_set "$sec.service_name" "$Q_SVC"
	[ -n "$flow" ] && uci_set "$sec.flow" "$flow"
	[ "$Q_INSEC" = "1" ] && uci_set "$sec.allow_insecure" '1'
	echo "$sec"
}

parse_vmess() {
	idx=$2
	payload=${1#vmess://}
	payload=${payload%%#*}
	json=$(b64dec "$payload")
	[ -n "$json" ] || return 1
	printf '%s' "$json" > "$TMPJ"
	add=$(jf '@.add'); port=$(jf '@.port'); id=$(jf '@.id')
	ps=$(jf '@.ps'); aid=$(jf '@.aid'); net=$(jf '@.net'); hostv=$(jf '@.host'); pathv=$(jf '@.path')
	tlsv=$(jf '@.tls'); sni=$(jf '@.sni'); fp=$(jf '@.fp')
	[ -n "$add" ] && [ -n "$port" ] && [ -n "$id" ] || return 1
	[ -n "$aid" ] || aid=0
	[ -n "$net" ] || net=tcp
	sec=$(new_section "${ps:-vmess-$add}" vmess "$idx") || return 1
	uci_set "$sec.address" "$add"
	uci_set "$sec.port" "$port"
	uci_set "$sec.uuid" "$id"
	uci_set "$sec.alter_id" "$aid"
	uci_set "$sec.transport" "$net"
	if [ -n "$tlsv" ] && [ "$tlsv" != "none" ]; then
		uci_set "$sec.tls" '1'
		[ -n "$sni" ] && uci_set "$sec.tls_server_name" "$sni"
	else
		uci_set "$sec.tls" '0'
	fi
	[ -n "$fp" ] && uci_set "$sec.fingerprint" "$fp"
	[ -n "$hostv" ] && uci_set "$sec.host" "$hostv"
	[ -n "$pathv" ] && uci_set "$sec.path" "$pathv"
	echo "$sec"
}

parse_trojan() {
	idx=$2
	url=${1#trojan://}
	ref=""
	case "$url" in *'#'*) ref=$(urldec "${url##*#}"); url=${url%#*} ;; esac
	q=""
	case "$url" in *'?'*) q=${url#*\?}; url=${url%%\?*} ;; esac
	pass=${url%%@*}; hp=${url#*@}
	case "$hp" in *:*) ;; *) return 1 ;; esac
	host=${hp%:*}; port=${hp##*:}
	host=${host#[}; host=${host%]}
	[ -n "$pass" ] && [ -n "$host" ] && [ -n "$port" ] || return 1
	pass=$(urldec "$pass")
	parse_query "$q"
	sec=$(new_section "${ref:-trojan-$host}" trojan "$idx") || return 1
	uci_set "$sec.address" "$host"
	uci_set "$sec.port" "$port"
	uci_set "$sec.password" "$pass"
	uci_set "$sec.tls" '1'
	uci_set "$sec.transport" "${Q_NET:-tcp}"
	[ -n "$Q_SNI" ] && uci_set "$sec.tls_server_name" "$Q_SNI"
	[ -n "$Q_FP" ] && uci_set "$sec.fingerprint" "$Q_FP"
	[ -n "$Q_PATH" ] && uci_set "$sec.path" "$Q_PATH"
	[ -n "$Q_HOST" ] && uci_set "$sec.host" "$Q_HOST"
	[ -n "$Q_SVC" ] && uci_set "$sec.service_name" "$Q_SVC"
	[ "$Q_INSEC" = "1" ] && uci_set "$sec.allow_insecure" '1'
	echo "$sec"
}

parse_hysteria2() {
	idx=$2
	url=${1#hysteria2://}
	url=${url#hy2://}
	ref=""
	case "$url" in *'#'*) ref=$(urldec "${url##*#}"); url=${url%#*} ;; esac
	q=""
	case "$url" in *'?'*) q=${url#*\?}; url=${url%%\?*} ;; esac
	pass=${url%%@*}; hp=${url#*@}
	case "$hp" in *:*) ;; *) return 1 ;; esac
	host=${hp%:*}; port=${hp##*:}
	host=${host#[}; host=${host%]}
	[ -n "$pass" ] && [ -n "$host" ] && [ -n "$port" ] || return 1
	pass=$(urldec "$pass")
	parse_query "$q"
	sec=$(new_section "${ref:-hysteria2-$host}" hysteria2 "$idx") || return 1
	uci_set "$sec.address" "$host"
	uci_set "$sec.port" "$port"
	uci_set "$sec.password" "$pass"
	uci_set "$sec.tls" '1'
	[ -n "$Q_SNI" ] && uci_set "$sec.tls_server_name" "$Q_SNI"
	echo "$sec"
}

parse_ss() {
	idx=$2
	rest=${1#ss://}
	ref=""
	case "$rest" in *'#'*) ref=$(urldec "${rest##*#}"); rest=${rest%#*} ;; esac
	case "$rest" in *'?'*) rest=${rest%%\?*} ;; esac
	hp=""; userinfo=""
	case "$rest" in
		*@*) userinfo=${rest%@*}; hp=${rest##*@} ;;
	esac
	if [ -n "$userinfo" ]; then
		decoded=$(b64dec "$userinfo"); [ -n "$decoded" ] || decoded=$userinfo
	else
		decoded=$(b64dec "$rest")
	fi
	case "$decoded" in
		*@*) method=${decoded%%:*}; pw=$(printf '%s' "$decoded" | sed 's/^[^:]*://; s/@.*$//'); hp=${decoded#*@} ;;
		*)   method=${decoded%%:*}; pw=${decoded#*:} ;;
	esac
	case "$hp" in *:*) ;; *) return 1 ;; esac
	host=${hp%:*}; port=${hp##*:}
	[ -n "$method" ] && [ -n "$pw" ] && [ -n "$host" ] && [ -n "$port" ] || return 1
	sec=$(new_section "${ref:-ss-$host}" shadowsocks "$idx") || return 1
	uci_set "$sec.address" "$host"
	uci_set "$sec.port" "$port"
	uci_set "$sec.method" "$method"
	uci_set "$sec.password" "$pw"
	echo "$sec"
}

imported=0; skipped=0; secs=""; idx=0
while IFS= read -r line || [ -n "$line" ]; do
	line=$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	[ -n "$line" ] || continue
	idx=$((idx + 1))
	case "$line" in
		vless://*) sec=$(parse_vless "$line" "$idx") || sec="" ;;
		vmess://*) sec=$(parse_vmess "$line" "$idx") || sec="" ;;
		trojan://*) sec=$(parse_trojan "$line" "$idx") || sec="" ;;
		hysteria2://*|hy2://*) sec=$(parse_hysteria2 "$line" "$idx") || sec="" ;;
		ss://*) sec=$(parse_ss "$line" "$idx") || sec="" ;;
		*) sec="" ;;
	esac
	if [ -n "$sec" ]; then
		imported=$((imported + 1))
		secs="$secs${secs:+,}$sec"
	else
		skipped=$((skipped + 1))
	fi
done < "$FILE"
uci -q commit "$CFG"
rm -f "$TMPJ"
printf '{"ok":true,"imported":%s,"skipped":%s,"sections":[%s]}\n' "$imported" "$skipped" "$(printf '%s' "$secs" | sed 's/\([^,]*\)/"\1"/g')"
