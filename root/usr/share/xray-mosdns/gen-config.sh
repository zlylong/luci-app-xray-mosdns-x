#!/bin/sh
# luci-app-xray-mosdns-x - configuration generator
# Generates: xray.json, mosdns.yaml, nft.rules, node_ips.txt
# Usage: gen-config.sh [output-dir]
set -eu

CFG=xray-mosdns
OUT="${1:-/var/etc/xray-mosdns}"
mkdir -p "$OUT"
NODEDIR="$OUT/.nodes"
rm -rf "$NODEDIR"
mkdir -p "$NODEDIR"
rm -f "$OUT/.resolved" "$OUT/.resolved6"

log() { logger -t xray-mosdns-gen "$*" 2>/dev/null || true; }
die() { log "ERROR: $*"; echo "ERROR: $*" >&2; exit 1; }

g()  { uci -q get "$CFG.$1" 2>/dev/null || true; }
gb() { [ "$(uci -q get "$CFG.$1" 2>/dev/null || true)" = "1" ] && echo 1 || echo 0; }
gdef() { v=$(g "$1"); [ -n "$v" ] || v="$2"; printf '%s' "$v"; }

jesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
jstr() { printf '"%s"' "$(jesc "$1")"; }
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
RULE_MODE=$(gdef global.rule_mode chnroute)
case "$RULE_MODE" in
	chnroute) BYPASS_CHN=1; DEFAULT_OUT=proxy ;;
	gfw)      BYPASS_CHN=0; DEFAULT_OUT=direct ;;
	global)   BYPASS_CHN=0; DEFAULT_OUT=proxy ;;
	custom)   BYPASS_CHN=$(gb global.bypass_chn); DEFAULT_OUT=$(gdef global.default_outbound proxy) ;;
	*)        RULE_MODE=chnroute; BYPASS_CHN=1; DEFAULT_OUT=proxy ;;
esac
SOCKS_PORT=$(gdef global.socks_port 1070)
NODE=$(g global.node)
NODE_MODE=$(gdef global.node_mode single)
BAL_STRATEGY=$(gdef global.balancer_strategy leastLoad)
FALLBACK_NODE=$(g global.fallback_node)
IPV6_EN=$(gb global.ipv6_enabled)

# ---------------------------------------------------------------- dns
DNS_LISTEN=$(gdef dns.listen_port 5353)
CACHE_SIZE=$(gdef dns.cache_size 8192)
CACHE_ALL=$(gb dns.cache_everything)
ADBLOCK=$(gb dns.adblock)
FILTER_V6=$(gb dns.filter_proxy_ipv6)
BOOTSTRAP=$(gdef dns.bootstrap 223.5.5.5)
REMOTE_DNS=$(gdef dns.remote_dns 1.1.1.1)
HOSTS_LIST=$(uci -q get "$CFG.dns.hosts" 2>/dev/null || true)

# ---------------------------------------------------------------- node helpers
node_names() {
	uci -q show "$CFG" 2>/dev/null | sed -n "s/^${CFG}\.\([^.=]*\)=node$/\1/p"
}

hosts_lookup() {
	_d=$1
	for _h in $HOSTS_LIST; do
		set -- $_h
		[ "$1" = "$_d" ] && { echo "$2"; return 0; }
	done
	return 1
}

resolve_v4() {
	_a=$1
	case "$_a" in
		*:*) echo "$_a"; return 0 ;;		# IPv6 literal
		''|*[!0-9.]*) ;;
		*) echo "$_a"; return 0 ;;
	esac
	_ip=$(hosts_lookup "$_a" || true)
	[ -n "$_ip" ] && { echo "$_ip"; return 0; }
	_ip=$(nslookup "$_a" "$BOOTSTRAP" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1)
	[ -n "$_ip" ] && { echo "$_ip"; return 0; }
	return 1
}

resolve_v6() {
	_a=$1
	case "$_a" in
		*:*) echo "$_a"; return 0 ;;
	esac
	nslookup "$_a" "$BOOTSTRAP" 2>/dev/null | grep -oE '([0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F:]+' | grep -v '^:' | tail -1
}

node_outbound_json() {
	_n=$1
	_ntag=$2
	N_TYPE=$(g "$_n.type"); N_TYPE=${N_TYPE:-vless}
	N_ADDR=$(g "$_n.address"); [ -n "$N_ADDR" ] || die "node $_n: empty address"
	N_PORT=$(g "$_n.port"); N_PORT=${N_PORT:-443}
	N_UUID=$(g "$_n.uuid")
	N_ALT=$(g "$_n.alter_id"); N_ALT=${N_ALT:-0}
	N_FLOW=$(g "$_n.flow")
	N_PASS=$(g "$_n.password")
	N_METHOD=$(g "$_n.method"); N_METHOD=${N_METHOD:-aes-128-gcm}
	N_TLS=$(gb "$_n.tls")
	N_SNI=$(g "$_n.tls_server_name")
	N_FP=$(g "$_n.fingerprint"); N_FP=${N_FP:-chrome}
	N_INSEC=$(gb "$_n.allow_insecure")
	N_NET=$(g "$_n.transport"); N_NET=${N_NET:-tcp}
	N_PATH=$(g "$_n.path"); N_PATH=${N_PATH:-/}
	N_HOST=$(g "$_n.host")
	N_SVC=$(g "$_n.service_name")

	NODE_IP=$(resolve_v4 "$N_ADDR") || die "cannot resolve node address $N_ADDR (add it to DNS hosts)"
	[ -n "$NODE_IP" ] || die "cannot resolve node address $N_ADDR"
	case "$NODE_IP" in
		*:*) echo "$NODE_IP" >> "$OUT/.resolved6" ;;
		*)   echo "$NODE_IP" >> "$OUT/.resolved" ;;
	esac

	if [ "$N_TYPE" = "hysteria2" ]; then
		# Xray >= 26: protocol "hysteria" + hysteria transport (Hysteria2 compatible)
		[ -n "$N_PASS" ] || die "hysteria2 node $_n needs password"
		SNI="$N_SNI"; [ -n "$SNI" ] || SNI="$N_ADDR"
		printf '{"tag":%s,"protocol":"hysteria","settings":{"version":2,"address":%s,"port":%s},"streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"serverName":%s,"alpn":["h3"]},"hysteriaSettings":{"version":2,"auth":%s}}}' \
			"$(jstr "$_ntag")" "$(jstr "$NODE_IP")" "$N_PORT" "$(jstr "$SNI")" "$(jstr "$N_PASS")"
		return 0
	fi
	SEC="none"; TLSJ=""; NJ=""
	if [ "$N_TLS" = "1" ]; then
		SEC="tls"
		SNI="$N_SNI"; [ -n "$SNI" ] || SNI="$N_ADDR"
		# allowInsecure was removed from Xray 26.x; do not emit it
		TLSJ="\"tlsSettings\":{\"serverName\":$(jstr "$SNI"),\"fingerprint\":$(jstr "$N_FP")}"
	fi
	HOSTV="$N_HOST"; [ -n "$HOSTV" ] || HOSTV="$N_SNI"
	[ -n "$HOSTV" ] || HOSTV="$N_ADDR"
	case "$N_NET" in
		tcp) ;;
		ws)      NJ="\"wsSettings\":{\"path\":$(jstr "$N_PATH"),\"headers\":{\"Host\":$(jstr "$HOSTV")}}" ;;
		grpc)    NJ="\"grpcSettings\":{\"serviceName\":$(jstr "$N_SVC")}" ;;
		http)    NJ="\"httpSettings\":{\"path\":$(jstr "$N_PATH"),\"host\":[$(jstr "$HOSTV")]}" ;;
		xhttp)   NJ="\"xhttpSettings\":{\"path\":$(jstr "$N_PATH"),\"host\":$(jstr "$HOSTV")}" ;;
		*) die "unsupported transport '$N_NET'" ;;
	esac
	STREAM=$(printf '{"network":%s,"security":%s%s%s}' "$(jstr "$N_NET")" "$(jstr "$SEC")" "${TLSJ:+,$TLSJ}" "${NJ:+,$NJ}")

	case "$N_TYPE" in
	vless)
		[ -n "$N_UUID" ] || die "vless node $_n needs uuid"
		printf '{"tag":%s,"protocol":"vless","settings":{"vnext":[{"address":%s,"port":%s,"users":[{"id":%s,"encryption":"none","flow":%s}]}]},"streamSettings":%s}' \
			"$(jstr "$_ntag")" "$(jstr "$NODE_IP")" "$N_PORT" "$(jstr "$N_UUID")" "$(jstr "$N_FLOW")" "$STREAM"
		;;
	vmess)
		[ -n "$N_UUID" ] || die "vmess node $_n needs uuid"
		printf '{"tag":%s,"protocol":"vmess","settings":{"vnext":[{"address":%s,"port":%s,"users":[{"id":%s,"alterId":%s,"security":"auto"}]}]},"streamSettings":%s}' \
			"$(jstr "$_ntag")" "$(jstr "$NODE_IP")" "$N_PORT" "$(jstr "$N_UUID")" "$N_ALT" "$STREAM"
		;;
	trojan)
		[ -n "$N_PASS" ] || die "trojan node $_n needs password"
		printf '{"tag":%s,"protocol":"trojan","settings":{"servers":[{"address":%s,"port":%s,"password":%s}]},"streamSettings":%s}' \
			"$(jstr "$_ntag")" "$(jstr "$NODE_IP")" "$N_PORT" "$(jstr "$N_PASS")" "$STREAM"
		;;
	shadowsocks)
		[ -n "$N_PASS" ] || die "shadowsocks node $_n needs password"
		printf '{"tag":%s,"protocol":"shadowsocks","settings":{"servers":[{"address":%s,"port":%s,"method":%s,"password":%s}]},"streamSettings":%s}' \
			"$(jstr "$_ntag")" "$(jstr "$NODE_IP")" "$N_PORT" "$(jstr "$N_METHOD")" "$(jstr "$N_PASS")" "$STREAM"
		;;
	*) die "unsupported node type '$N_TYPE'" ;;
	esac
}

# collect nodes: single mode -> selected node, balance mode -> all enabled nodes
NODE_LIST=""
if [ "$NODE_MODE" = "balance" ]; then
	for n in $(node_names); do
		[ "$(gb "$n.enabled")" = "1" ] && NODE_LIST="$NODE_LIST $n"
	done
	[ -n "$NODE_LIST" ] || die "balance mode: no enabled node"
else
	[ -n "$NODE" ] || die "no node selected (xray-mosdns.global.node)"
	NODE_LIST="$NODE"
fi

i=0
for n in $NODE_LIST; do
	i=$((i + 1))
	if [ "$NODE_MODE" = "balance" ]; then
		node_outbound_json "$n" "proxy-$n" > "$NODEDIR/$i.json"
	else
		node_outbound_json "$n" "proxy" > "$NODEDIR/$i.json"
	fi
done

# node IP set for the nftables bypass rule (all resolved addresses)
NODE_IPS=$(sort -u "$OUT/.resolved" 2>/dev/null | tr '\n' ' ')
NODE_IPS_JSON=$(printf '%s' "$NODE_IPS" | awk '{for(i=1;i<=NF;i++){printf "%s\"%s\"",(i>1?",":""),$i}}')

# ---------------------------------------------------------------- routing rules
RULES=""
add_rule() { RULES="${RULES:+$RULES,
    }$1"; }
proxy_target() {
	if [ "$NODE_MODE" = "balance" ]; then printf ',"balancerTag":"balancer"'; else printf ',"outboundTag":"proxy"'; fi
}

add_rule '{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}'
[ -n "$NODE_IPS_JSON" ] && add_rule "{\"type\":\"field\",\"ip\":[$(printf '%s' "$NODE_IPS_JSON")],\"outboundTag\":\"direct\"}"
if [ "$BYPASS_CHN" = "1" ]; then
	add_rule '{"type":"field","domain":["geosite:cn"],"outboundTag":"direct"}'
	add_rule '{"type":"field","ip":["geoip:cn"],"outboundTag":"direct"}'
fi
if [ "$RULE_MODE" = "gfw" ]; then
	# PassWall "GFW list" mode: only the GFW domain list is proxied, everything else direct
	add_rule "{\"type\":\"field\",\"domain\":[\"geosite:gfw\"]$(proxy_target)}"
fi

# user defined rules (config rule sections, file order)
rule_names() {
	uci -q show "$CFG" 2>/dev/null | sed -n "s/^${CFG}\.\([^.=]*\)=rule$/\1/p"
}
for r in $(rule_names); do
	[ "$(gb "$r.enabled")" = "1" ] || continue
	rtype=$(g "$r.rule_type"); [ -n "$rtype" ] || rtype=domain
	rvalue=$(g "$r.value")
	rout=$(g "$r.outbound"); [ -n "$rout" ] || rout=proxy
	[ -n "$rvalue" ] || continue
	case "$rout" in
		proxy) tgt=$(proxy_target) ;;
		direct) tgt=',"outboundTag":"direct"' ;;
		block)  tgt=',"outboundTag":"block"' ;;
		*) tgt=$(proxy_target) ;;
	esac
	case "$rtype" in
		domain) add_rule "{\"type\":\"field\",\"domain\":$(list_json "$(echo "$rvalue" | tr ',' ' ')")${tgt}}" ;;
		ip)     add_rule "{\"type\":\"field\",\"ip\":$(list_json "$(echo "$rvalue" | tr ',' ' ')")${tgt}}" ;;
		port)   add_rule "{\"type\":\"field\",\"port\":$(jstr "$rvalue")${tgt}}" ;;
		network) add_rule "{\"type\":\"field\",\"network\":$(jstr "$rvalue")${tgt}}" ;;
		*) log "rule $r: unknown type $rtype, skipped" ;;
	esac
done

# legacy domain lists
for _d in $(uci -q get "$CFG.global.direct_domains" 2>/dev/null || true); do
	add_rule "{\"type\":\"field\",\"domain\":[$(jstr "$_d")],\"outboundTag\":\"direct\"}"
done
for _d in $(uci -q get "$CFG.global.proxy_domains" 2>/dev/null || true); do
	add_rule "{\"type\":\"field\",\"domain\":[$(jstr "$_d")]$(proxy_target)}"
done
for _d in $(uci -q get "$CFG.global.block_domains" 2>/dev/null || true); do
	add_rule "{\"type\":\"field\",\"domain\":[$(jstr "$_d")],\"outboundTag\":\"block\"}"
done
if [ "$DEFAULT_OUT" = "direct" ]; then
	add_rule '{"type":"field","network":"tcp,udp","outboundTag":"direct"}'
else
	add_rule "{\"type\":\"field\",\"network\":\"tcp,udp\"$(proxy_target)}"
fi

SNIFFJSON=''
if [ "$SNIFF_EN" = "1" ]; then
	SNIFFJSON='"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}'
fi
TPROXY_LISTEN="0.0.0.0"
[ "$IPV6_EN" = "1" ] && TPROXY_LISTEN="::"

# ---------------------------------------------------------------- xray.json
{
	printf '{\n'
	printf '  "log": {"loglevel": %s},\n' "$(jstr "$LOGLEVEL")"
	printf '  "dns": {"queryStrategy": "UseIPv4", "servers": [%s]},\n' "$(jstr "$BOOTSTRAP")"
	printf '  "inbounds": [\n'
	printf '    {"tag": "tproxy-in", "port": %s, "protocol": "tunnel", "listen": %s,\n' "$TPROXY_PORT" "$(jstr "$TPROXY_LISTEN")"
	printf '     "settings": {"allowedNetwork": "tcp,udp"},\n'
	printf '     "streamSettings": {"sockopt": {"tproxy": "tproxy"}}%s},\n' "${SNIFFJSON:+,$SNIFFJSON}"
	printf '    {"tag": "socks-in", "port": %s, "protocol": "socks", "listen": "127.0.0.1",\n' "$SOCKS_PORT"
	printf '     "settings": {"udp": true, "auth": "noauth"}%s}\n' "${SNIFFJSON:+,$SNIFFJSON}"
	printf '  ],\n'
	printf '  "outbounds": [\n'
	for f in "$NODEDIR"/*.json; do
		printf '    %s,\n' "$(cat "$f")"
	done
	printf '    {"tag": "direct", "protocol": "freedom"},\n'
	printf '    {"tag": "block", "protocol": "blackhole"}\n'
	printf '  ],\n'
	FB_TAG="direct"
	if [ "$NODE_MODE" = "balance" ] && [ -n "$FALLBACK_NODE" ] && [ "$(gb "$FALLBACK_NODE.enabled")" = "1" ]; then
		FB_TAG="proxy-$FALLBACK_NODE"
	fi
	if [ "$NODE_MODE" = "balance" ]; then
		# the observatory also registers the balancer members as used outbounds,
		# otherwise fallbackTag/selector members may be pruned as unresolved deps
		printf '  "burstObservatory": {"subjectSelector": ["proxy-"], "pingConfig": {"destination": "https://www.gstatic.com/generate_204", "interval": "1m", "timeout": "5s", "sampling": 3}},\n'
	fi
	printf '  "routing": {"domainStrategy": "IPIfNonMatch",\n'
	if [ "$NODE_MODE" = "balance" ]; then
		printf '    "balancers": [{"tag": "balancer", "selector": ["proxy-"], "strategy": {"type": %s}, "fallbackTag": %s}],\n' \
			"$(jstr "$BAL_STRATEGY")" "$(jstr "$FB_TAG")"
	fi
	printf '    "rules": [\n'
	printf '    %s\n' "$RULES"
	printf '  ]}\n'
	printf '}\n'
} > "$OUT/xray.json"

# ---------------------------------------------------------------- nftables rules
BYPASS_EXTRA=""
for _ip in $(uci -q get "$CFG.global.bypass_ips" 2>/dev/null || true); do
	[ -n "$_ip" ] && BYPASS_EXTRA="$BYPASS_EXTRA, $_ip"
done
V6_IPS=$(for n in $NODE_LIST; do a=$(g "$n.address"); [ -n "$a" ] && resolve_v6 "$a"; done 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' | grep ':' | sort -u | tr '\n' ' ')
[ -f "$OUT/.resolved6" ] && V6_IPS=$(printf '%s\n%s\n' "$V6_IPS" "$(cat "$OUT/.resolved6")" | grep -E '^[0-9a-fA-F:]+$' | grep ':' | sort -u | tr '\n' ' ')
{
	printf 'table inet xray-mosdns {\n'
	if [ -n "$NODE_IPS_JSON" ]; then
		printf '\tset node_ips {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\tauto-merge\n\t\telements = { %s }\n\t}\n' "${NODE_IPS_JSON//\"/}"
	fi
	if [ "$IPV6_EN" = "1" ] && [ -n "$V6_IPS" ]; then
		printf '\tset node_ips6 {\n\t\ttype ipv6_addr\n\t\tflags interval\n\t\tauto-merge\n\t\telements = { %s }\n\t}\n' "$V6_IPS"
	fi
	printf '\tchain prerouting {\n'
	printf '\t\ttype filter hook prerouting priority mangle; policy accept;\n'
	printf '\t\tmeta mark %s return\n' "$FWMARK"
	printf '\t\tip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4%s } return\n' "$BYPASS_EXTRA"
	[ -n "$NODE_IPS_JSON" ] && printf '\t\tip daddr @node_ips return\n'
	if [ "$IPV6_EN" = "1" ]; then
		printf '\t\tip6 daddr { ::1/128, fc00::/7, fe80::/10, ff00::/8 } return\n'
		[ -n "$V6_IPS" ] && printf '\t\tip6 daddr @node_ips6 return\n'
	fi
	printf '\t\tip protocol { tcp, udp } meta mark set %s tproxy ip to :%s counter comment "xray-mosdns"\n' "$FWMARK" "$TPROXY_PORT"
	if [ "$IPV6_EN" = "1" ]; then
		printf '\t\tmeta nfproto ipv6 meta l4proto { tcp, udp } meta mark set %s tproxy ip6 to :%s counter comment "xray-mosdns-v6"\n' "$FWMARK" "$TPROXY_PORT"
	fi
	printf '\t}\n'
	printf '}\n'
} > "$OUT/nft.rules"
printf '%s\n' "$NODE_IPS" > "$OUT/node_ips.txt"

# ---------------------------------------------------------------- mosdns.yaml
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

log "config generated in $OUT (mode=$NODE_MODE nodes=$(printf '%s' "$NODE_LIST" | wc -w) tproxy=$TPROXY_PORT ipv6=$IPV6_EN dns=$DNS_LISTEN)"
exit 0
