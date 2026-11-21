#!/bin/sh
# The helpers behind the node and overview pages: latency.sh against a local
# listener, traffic.sh against a stand-in for `xray api statsquery`, and the
# JSON that update.sh prints. tests/check.py checks the results.
# Runs inside an OpenWrt rootfs with ucode-mod-socket; it replaces
# /etc/config/xray-mosdns for the duration of the run.
# usage: tests/scripts.sh <repo> <outdir>
REPO=${1:-.}; OUT=${2:-/tmp/xm-test}/scripts
LX="$REPO/root/usr/libexec/xray-mosdns"
CONF=/etc/config/xray-mosdns
PORT=47231
rc=0
rm -rf "$OUT"; mkdir -p "$OUT"

# $1 result name, then the command; stdout is the result
run() {
	name=$1; shift
	if "$@" > "$OUT/$name.json" 2> "$OUT/$name.err"; then
		echo "script $name: ok"
	else
		echo "script $name: exit $?"; cat "$OUT/$name.err"; rc=1
	fi
}

# the kernel completes handshakes on a listening socket without accept();
# the socket has to stay referenced, or it is closed right away
ucode -l socket -e "
	const s = socket.listen('127.0.0.1', $PORT);
	if (!s) {
		warn('listen: ', socket.error(), '\n');
		exit(1);
	}
	sleep(60000);
" &
LISTENER=$!
sleep 1
echo "$PORT" > "$OUT/port"

[ -f "$CONF" ] && cp "$CONF" "$OUT/conf.saved"
cat > "$CONF" <<EOF
config node 'n1'
	option type 'vless'
	option address '127.0.0.1'
	option port '$PORT'
EOF

run lat-target  "$LX/latency.sh" --target "127.0.0.1:$PORT"
run lat-node    "$LX/latency.sh" n1
run lat-missing "$LX/latency.sh" nosuch
run lat-bad     "$LX/latency.sh" --target nonsense

cat > "$OUT/fake-xray" <<'EOF'
#!/bin/sh
[ "$1 $2" = "api statsquery" ] || exit 1
cat <<'JSON'
{"stat":[
 {"name":"outbound>>>a.node>>>traffic>>>uplink","value":"100"},
 {"name":"outbound>>>a.node>>>traffic>>>downlink","value":"900"},
 {"name":"outbound>>>b.node>>>traffic>>>uplink","value":5000},
 {"name":"outbound>>>b.node>>>traffic>>>downlink"},
 {"name":"outbound>>>direct>>>traffic>>>uplink","value":"7"},
 {"name":"outbound>>>hk.group>>>traffic>>>uplink","value":"7"},
 {"name":"inbound>>>tproxy>>>traffic>>>uplink","value":"7"},
 {"name":"bogus","value":"1"}
]}
JSON
EOF
printf '#!/bin/sh\necho "not json"\n' > "$OUT/garbage-xray"
chmod +x "$OUT/fake-xray" "$OUT/garbage-xray"

run traffic      env XRAY="$OUT/fake-xray" "$LX/traffic.sh"
run traffic-bad  env XRAY="$OUT/garbage-xray" "$LX/traffic.sh"
run traffic-down env XRAY="$OUT/no-such-xray" "$LX/traffic.sh"

run update-versions env UPD_TEST_DIR="$OUT/upd" "$LX/update.sh" versions
# jstr on its own, with every character that needs escaping
eval "$(grep '^jstr()' "$LX/update.sh")"
jstr "$(printf 'quote " backslash \\ tab \t newline \n end')" > "$OUT/jstr.json"

kill "$LISTENER" 2>/dev/null
if [ -f "$OUT/conf.saved" ]; then mv "$OUT/conf.saved" "$CONF"; else rm -f "$CONF"; fi
exit $rc
