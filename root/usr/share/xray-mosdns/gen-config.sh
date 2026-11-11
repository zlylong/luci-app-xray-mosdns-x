#!/bin/sh
# luci-app-xray-mosdns-x - configuration generator
# Generates: xray.json, mosdns.yaml, nft.rules and node_ips.txt
# Usage: gen-config.sh [output-dir]
set -e

CFG=xray-mosdns
OUT="${1:-/var/etc/xray-mosdns}"
mkdir -p "$OUT"

log() { logger -t xray-mosdns-gen "$*" 2>/dev/null || true; }
die() { log "ERROR: $*"; echo "ERROR: $*" >&2; exit 1; }

g()  { uci -q get "$CFG.$1" 2>/dev/null || true; }
gb() { [ "$(uci -q get "$CFG.$1" 2>/dev/null || true)" = "1" ] && echo 1 || echo 0; }
gdef() { v=$(g "$1"); [ -n "$v" ] || v="$2"; printf '%s' "$v"; }

jesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
jstr() { printf '"%s"' "$(jesc "$1")"; }
# space separated uci list -> json array (empty list -> [])
list_json() {
	out=""
	for v in $1; do
		[ -n "$v" ] || continue
		out="${out:+$out, }$(jstr "$v")"
	done
	printf '[%s]' "$out"
}

# ---------------------------------------------------------------- global
TPROXY_PORT=$(gdef global.tproxy_port 12345)
FWMARK=$(gdef global.fwmark 0x1)
LOGLEVEL=$(gdef global.log_level warning)
SNIFF_EN=$(gb global.sniffing)
DEFAULT_OUT=$(gdef global.default_outbound proxy)
BYPASS_CHN=$(gb global.bypass_chn)
SOCKS_PORT=$(gdef global.socks_port 1070)
NODE=$(g global.node)

# ---------------------------------------------------------------- dns
DNS_ENABLED=$(gb dns.enabled)
DNS_LISTEN=$(gdef dns.listen_port 5353)
CACHE_SIZE=$(gdef dns.cache_size 8192)
CACHE_ALL=$(gb dns.cache_everything)
ADBLOCK=$(gb dns.adblock)
FILTER_V6=$(gb dns.filter_proxy_ipv6)
BOOTSTRAP=$(gdef dns.bootstrap 223.5.5.5)
REMOTE_DNS=$(gdef dns.remote_dns 1.1.1.1)
MOSDNS_BIN=$(gdef dns.mosdns_bin /usr/bin/mosdns)
HOSTS_LIST=$(uci -q get "$CFG.dns.hosts" 2>/dev/null || true)

# ---------------------------------------------------------------- node
[ -n "$NODE" ] || die "no node selected (xray-mosdns.global.node)"
N_TYPE=$(g "$NODE.type");   N_TYPE=${N_TYPE:-vless}
N_ADDR=$(g "$NODE.address"); [ -n "$N_ADDR" ] || die "node $NODE: empty address"
N_PORT=$(g "$NODE.port");   N_PORT=${N_PORT:-443}
N_UUID=$(g "$NODE.uuid")
N_ALT=$(g "$NODE.alter_id"); N_ALT=${N_ALT:-0}
N_FLOW=$(g "$NODE.flow")
N_PASS=$(g "$NODE.password")
N_METHOD=$(g "$NODE.method"); N_METHOD=${N_METHOD:-aes-128-gcm}
N_TLS=$(gb "$NODE.tls")
N_SNI=$(g "$NODE.tls_server_name")
N_FP=$(g "$NODE.fingerprint"); N_FP=${N_FP:-chrome}
N_INSEC=$(gb "$NODE.allow_insecure")
N_NET=$(g "$NODE.transport"); N_NET=${N_NET:-tcp}
N_PATH=$(g "$NODE.path"); N_PATH=${N_PATH:-/}
N_HOST=$(g "$NODE.host")
N_SVC=$(g "$NODE.service_name")

# hosts list lookup: "domain ip" pairs
hosts_lookup() {
	_d=$1
	for _h in $HOSTS_LIST; do
		case "$_h" in
		"$_d"|"full:$_d"|"domain:$_d")
			set -- $_h; echo "$2"; return 0 ;;
		esac
	done
	# entries stored as "<domain> <ip>"
	for _h in $HOSTS_LIST; do
		set -- $_h
		[ "$1" = "$_d" ] && { echo "$2"; return 0; }
	done
	return 1
}

resolve_node_ip() {
	_a=$1
	case "$_a" in
		''|*[!0-9.]*) ;;
		*) echo "$_a"; return 0 ;;
	esac
	_ip=$(hosts_lookup "$_a" || true)
	[ -n "$_ip" ] && { echo "$_ip"; return 0; }
	_ip=$(nslookup "$_a" "$BOOTSTRAP" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1)
	[ -n "$_ip" ] && { echo "$_ip"; return 0; }
	return 1
}

NODE_IP=$(resolve_node_ip "$N_ADDR") || die "cannot resolve node address $N_ADDR (add it to DNS hosts)"
[ -n "$NODE_IP" ] || die "cannot resolve node address $N_ADDR"
NODE_IP_JSON=$(jstr "$NODE_IP")

# ---------------------------------------------------------------- stream settings
stream_json() {
	NET="$N_NET"
	SEC="none"; TLSJ=""; NJ=""
	if [ "$N_TLS" = "1" ]; then
		SEC="tls"
		SNI="$N_SNI"; [ -n "$SNI" ] || SNI="$N_ADDR"
		TLSJ="\"tlsSettings\":{\"serverName\":$(jstr "$SNI"),\"fingerprint\":$(jstr "$N_FP"),\"allowInsecure\":$([ "$N_INSEC" = 1 ] && echo true || echo false)}"
	fi
	HOSTV="$N_HOST"; [ -n "$HOSTV" ] || HOSTV="$N_SNI"
	[ -n "$HOSTV" ] || HOSTV="$N_ADDR"
	case "$NET" in
		tcp) ;;
		ws)      NJ="\"wsSettings\":{\"path\":$(jstr "$N_PATH"),\"headers\":{\"Host\":$(jstr "$HOSTV")}}" ;;
		grpc)    NJ="\"grpcSettings\":{\"serviceName\":$(jstr "$N_SVC")}" ;;
		http)    NJ="\"httpSettings\":{\"path\":$(jstr "$N_PATH"),\"host\":[$(jstr "$HOSTV")]}" ;;
		xhttp)   NJ="\"xhttpSettings\":{\"path\":$(jstr "$N_PATH"),\"host\":$(jstr "$HOSTV")}" ;;
		*) die "unsupported transport '$NET'" ;;
	esac
	printf '{"network":%s,"security":%s%s%s}' "$(jstr "$NET")" "$(jstr "$SEC")" "${TLSJ:+,$TLSJ}" "${NJ:+,$NJ}"
}

node_outbound_json() {
	STREAM=$(stream_json)
	case "$N_TYPE" in
	vless)
		[ -n "$N_UUID" ] || die "vless node needs uuid"
		printf '{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":%s,"port":%s,"users":[{"id":%s,"encryption":"none","flow":%s}]}]},"streamSettings":%s}' \
			"$(jstr "$NODE_IP")" "$N_PORT" "$(jstr "$N_UUID")" "$(jstr "$N_FLOW")" "$STREAM"
		;;
	vmess)
		[ -n "$N_UUID" ] || die "vmess node needs uuid"
		printf '{"tag":"proxy","protocol":"vmess","settings":{"vnext":[{"address":%s,"port":%s,"users":[{"id":%s,"alterId":%s,"security":"auto"}]}]},"streamSettings":%s}' \
			"$(jstr "$NODE_IP")" "$N_PORT" "$(jstr "$N_UUID")" "$N_ALT" "$STREAM"
		;;
	trojan)
		[ -n "$N_PASS" ] || die "trojan node needs password"
		printf '{"tag":"proxy","protocol":"trojan","settings":{"servers":[{"address":%s,"port":%s,"password":%s}]},"streamSettings":%s}' \
			"$(jstr "$NODE_IP")" "$N_PORT" "$(jstr "$N_PASS")" "$STREAM"
		;;
	shadowsocks)
		[ -n "$N_PASS" ] || die "shadowsocks node needs password"
		printf '{"tag":"proxy","protocol":"shadowsocks","settings":{"servers":[{"address":%s,"port":%s,"method":%s,"password":%s}]},"streamSettings":%s}' \
			"$(jstr "$NODE_IP")" "$N_PORT" "$(jstr "$N_METHOD")" "$(jstr "$N_PASS")" "$STREAM"
		;;
	*) die "unsupported node type '$N_TYPE'" ;;
	esac
}

# ---------------------------------------------------------------- routing rules
RULES=""
add_rule() { RULES="${RULES:+$RULES,
    }$1"; }

add_rule '{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}'
add_rule "{\"type\":\"field\",\"ip\":[$NODE_IP_JSON],\"outboundTag\":\"direct\"}"
if [ "$BYPASS_CHN" = "1" ]; then
	add_rule '{"type":"field","domain":["geosite:cn"],"outboundTag":"direct"}'
	add_rule '{"type":"field","ip":["geoip:cn"],"outboundTag":"direct"}'
fi
for _d in $(uci -q get "$CFG.global.direct_domains" 2>/dev/null || true); do
	add_rule "{\"type\":\"field\",\"domain\":[$(jstr "$_d")],\"outboundTag\":\"direct\"}"
done
for _d in $(uci -q get "$CFG.global.proxy_domains" 2>/dev/null || true); do
	add_rule "{\"type\":\"field\",\"domain\":[$(jstr "$_d")],\"outboundTag\":\"proxy\"}"
done
for _d in $(uci -q get "$CFG.global.block_domains" 2>/dev/null || true); do
	add_rule "{\"type\":\"field\",\"domain\":[$(jstr "$_d")],\"outboundTag\":\"block\"}"
done
add_rule "{\"type\":\"field\",\"network\":\"tcp,udp\",\"outboundTag\":$(jstr "$DEFAULT_OUT")}"

SNIFFJSON=''
if [ "$SNIFF_EN" = "1" ]; then
	SNIFFJSON='"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}'
fi

# ---------------------------------------------------------------- xray.json
{
	printf '{\n'
	printf '  "log": {"loglevel": %s},\n' "$(jstr "$LOGLEVEL")"
	printf '  "dns": {"queryStrategy": "UseIPv4", "servers": [%s]},\n' "$(jstr "$BOOTSTRAP")"
	printf '  "inbounds": [\n'
	printf '    {"tag": "tproxy-in", "port": %s, "protocol": "tunnel", "listen": "0.0.0.0",\n' "$TPROXY_PORT"
	printf '     "settings": {"allowedNetwork": "tcp,udp"},\n'
	printf '     "streamSettings": {"sockopt": {"tproxy": "tproxy"}}%s},\n' "${SNIFFJSON:+,$SNIFFJSON}"
	printf '    {"tag": "socks-in", "port": %s, "protocol": "socks", "listen": "127.0.0.1",\n' "$SOCKS_PORT"
	printf '     "settings": {"udp": true, "auth": "noauth"}%s}\n' "${SNIFFJSON:+,$SNIFFJSON}"
	printf '  ],\n'
	printf '  "outbounds": [\n'
	printf '    %s,\n' "$(node_outbound_json)"
	printf '    {"tag": "direct", "protocol": "freedom"},\n'
	printf '    {"tag": "block", "protocol": "blackhole"}\n'
	printf '  ],\n'
	printf '  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [\n'
	printf '    %s\n' "$RULES"
	printf '  ]}\n'
	printf '}\n'
} > "$OUT/xray.json"

# ---------------------------------------------------------------- nftables rules
BYPASS_EXTRA=""
for _ip in $(uci -q get "$CFG.global.bypass_ips" 2>/dev/null || true); do
	[ -n "$_ip" ] && BYPASS_EXTRA="$BYPASS_EXTRA, $_ip"
done
{
	printf 'table inet xray-mosdns {\n'
	printf '\tset node_ips {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\tauto-merge\n\t\telements = { %s }\n\t}\n' "$NODE_IP"
	printf '\tchain prerouting {\n'
	printf '\t\ttype filter hook prerouting priority mangle; policy accept;\n'
	printf '\t\tmeta mark %s return\n' "$FWMARK"
	printf '\t\tip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4%s } return\n' "$BYPASS_EXTRA"
	printf '\t\tip daddr @node_ips return\n'
	printf '\t\tip protocol { tcp, udp } meta mark set %s tproxy ip to :%s counter comment "xray-mosdns"\n' "$FWMARK" "$TPROXY_PORT"
	printf '\t}\n'
	printf '}\n'
} > "$OUT/nft.rules"

printf '%s\n' "$NODE_IP" > "$OUT/node_ips.txt"

# ---------------------------------------------------------------- mosdns.yaml
if [ "$DNS_ENABLED" = "1" ]; then
	{
		printf 'log:\n  level: info\n  file: /tmp/mosdns-x.log\n\n'
		printf 'data_providers:\n'
		printf '  - tag: geosite\n    file: /usr/share/v2ray/geosite.dat\n    auto_reload: true\n'
		printf '  - tag: geoip\n    file: /usr/share/v2ray/geoip.dat\n    auto_reload: true\n\n'
		printf 'plugins:\n'
		printf '  - tag: edns_cookie_filter\n    type: edns0_filter\n    args:\n      discard: [10]\n\n'
		printf '  - tag: cache\n    type: cache\n    args:\n      size: %s\n      lazy_cache_ttl: 86400\n' "$CACHE_SIZE"
		[ "$CACHE_ALL" = "1" ] && printf '      cache_everything: true\n'
		printf '\n'
		if [ -n "$HOSTS_LIST" ]; then
			printf '  - tag: hosts\n    type: hosts\n    args:\n      hosts:\n'
			for _h in $HOSTS_LIST; do printf '        - %s\n' "$_h"; done
			printf '\n'
		fi
		printf '  - tag: forward_local\n    type: fast_forward\n    args:\n      upstream:\n'
		for _u in $(uci -q get "$CFG.dns.domestic_dns" 2>/dev/null || true); do
			printf '        - addr: %s\n          bootstrap: %s\n          idle_timeout: 10\n' "$_u" "$BOOTSTRAP"
		done
		printf '\n'
		printf '  - tag: forward_remote\n    type: fast_forward\n    args:\n      upstream:\n'
		printf '        - addr: "tcp://%s:53"\n          socks5: "127.0.0.1:%s"\n          enable_pipeline: true\n          idle_timeout: 10\n\n' "$REMOTE_DNS" "$SOCKS_PORT"
		printf '  - tag: query_is_ad_domain\n    type: query_matcher\n    args:\n      domain:\n        - %s\n\n' "'provider:geosite:category-ads-all'"
		printf '  - tag: query_is_local_domain\n    type: query_matcher\n    args:\n      domain:\n        - %s\n\n' "'provider:geosite:cn'"
		printf '  - tag: query_is_non_local_domain\n    type: query_matcher\n    args:\n      domain:\n        - %s\n\n' "'provider:geosite:geolocation-!cn'"
		printf '  - tag: response_has_local_ip\n    type: response_matcher\n    args:\n      ip:\n        - %s\n\n' "'provider:geoip:cn'"
		if [ "$FILTER_V6" = "1" ]; then
			printf '  - tag: query_is_aaaa\n    type: query_matcher\n    args:\n      qtype: [28]\n\n'
		fi
		printf '  - tag: main_sequence\n    type: sequence\n    args:\n      exec:\n'
		printf '        - edns_cookie_filter\n        - cache\n'
		[ -n "$HOSTS_LIST" ] && printf '        - hosts\n'
		if [ "$ADBLOCK" = "1" ]; then
			printf '        - if: query_is_ad_domain\n          exec:\n            - _new_nxdomain_response\n            - _return\n'
		fi
		printf '        - if: query_is_local_domain\n          exec:\n            - forward_local\n            - _return\n'
		printf '        - if: query_is_non_local_domain\n          exec:\n'
		if [ "$FILTER_V6" = "1" ]; then
			printf '            - if: query_is_aaaa\n              exec:\n                - _new_empty_response\n                - _return\n'
		fi
		printf '            - forward_remote\n            - _return\n'
		printf '        - primary:\n            - forward_local\n            - if: "(! response_has_local_ip) && [_response_valid_answer]"\n              exec:\n                - _drop_response\n'
		printf '          secondary:\n            - _prefer_ipv4\n            - forward_remote\n          fast_fallback: 200\n\n'
		printf 'servers:\n  - exec: main_sequence\n    listeners:\n'
		printf '      - protocol: udp\n        addr: 127.0.0.1:%s\n' "$DNS_LISTEN"
		printf '      - protocol: tcp\n        addr: 127.0.0.1:%s\n' "$DNS_LISTEN"
		printf '      - protocol: udp\n        addr: "[::1]:%s"\n' "$DNS_LISTEN"
		printf '      - protocol: tcp\n        addr: "[::1]:%s"\n' "$DNS_LISTEN"
	} > "$OUT/mosdns.yaml"
fi

log "config generated in $OUT (node=$NODE addr=$N_ADDR resolved=$NODE_IP tproxy=$TPROXY_PORT dns=$DNS_ENABLED)"
exit 0
