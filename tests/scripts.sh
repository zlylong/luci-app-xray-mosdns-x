#!/bin/sh
# The helpers behind the node and overview pages: latency.sh against a local
# listener, traffic.sh against a stand-in for `xray api statsquery`, the
# JSON that update.sh prints, log.sh and querylog.uc against sample log
# files. tests/check.py checks the results.
# Runs inside an OpenWrt rootfs with ucode-mod-socket; it replaces
# /etc/config/xray-mosdns for the duration of the run.
# usage: tests/scripts.sh <repo> <outdir>
REPO=${1:-.}; OUT=${2:-/tmp/xm-test}/scripts
LX="$REPO/root/usr/libexec/xray-mosdns"
CONF=/etc/config/xray-mosdns
PORT=47231
rc=0
rm -rf "$OUT"; mkdir -p "$OUT"

# $1 result name (.json unless it has an extension), then the command;
# stdout is the result
run() {
	name=$1; shift
	case $name in *.*) f=$name ;; *) f=$name.json ;; esac
	if "$@" > "$OUT/$f" 2> "$OUT/$name.err"; then
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
config global 'global'
	option xray_bin '/opt/bin/xray-core'

config node 'n1'
	option type 'vless'
	option address '127.0.0.1'
	option port '$PORT'

config dns 'dns'
	option query_log '1'
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
# this package's version: from apk, or from opkg where there is no apk
mkdir -p "$OUT/pm-apk" "$OUT/pm-opkg"
cat > "$OUT/pm-apk/apk" <<'EOF'
#!/bin/sh
[ "$*" = "info -e -v luci-app-xray-mosdns-x" ] && echo luci-app-xray-mosdns-x-9.9.9-r1
exit 0
EOF
printf '#!/bin/sh\nexit 1\n' > "$OUT/pm-opkg/apk"
cat > "$OUT/pm-opkg/opkg" <<'EOF'
#!/bin/sh
if [ "$*" = "status luci-app-xray-mosdns-x" ]; then
	echo "Package: luci-app-xray-mosdns-x"
	echo "Version: 8.8.8-r2"
	echo "Status: install user installed"
fi
exit 0
EOF
chmod +x "$OUT/pm-apk/apk" "$OUT/pm-opkg/apk" "$OUT/pm-opkg/opkg"
run update-versions-apk  env PATH="$OUT/pm-apk:$PATH" UPD_TEST_DIR="$OUT/upd" "$LX/update.sh" versions
run update-versions-opkg env PATH="$OUT/pm-opkg:$PATH" UPD_TEST_DIR="$OUT/upd" "$LX/update.sh" versions

# the geo schedule: day of the week and hour from the config; junk means
# every day at 4, and the line is replaced, not added again
CR="$OUT/cron-root"
uci set xray-mosdns.global.geo_update_hour='6'
uci set xray-mosdns.global.geo_update_day='1'
uci commit xray-mosdns
run cron-weekly        env UPD_TEST_DIR="$CR" "$LX/update.sh" cron-install
grep 'xray-mosdns-geo-auto' "$CR/etc/crontabs/root" > "$OUT/cron-weekly.txt"
run cron-weekly-status env UPD_TEST_DIR="$CR" "$LX/update.sh" cron-status
uci set xray-mosdns.global.geo_update_hour='x'
uci set xray-mosdns.global.geo_update_day='9'
uci commit xray-mosdns
run cron-junk          env UPD_TEST_DIR="$CR" "$LX/update.sh" cron-install
grep 'xray-mosdns-geo-auto' "$CR/etc/crontabs/root" > "$OUT/cron-junk.txt"
# jstr on its own, with every character that needs escaping
eval "$(grep '^jstr()' "$LX/update.sh")"
jstr "$(printf 'quote " backslash \\ tab \t newline \n end')" > "$OUT/jstr.json"

# log.sh against a stand-in for logread and a mosdns log file; xray_bin is
# /opt/bin/xray-core in the config above
cat > "$OUT/syslog.txt" <<'EOF'
Sat Nov 21 13:00:00 2026 daemon.info procd: Instance xray-mosdns::xray s in a crash loop 6 crashes, 0 seconds since last crash
Sat Nov 21 13:00:01 2026 daemon.err xray-core[101]: Xray started
Sat Nov 21 13:00:02 2026 daemon.err xray[102]: some other xray binary
Sat Nov 21 13:00:03 2026 daemon.err mosdns[201]: failed to load config
Sat Nov 21 13:00:04 2026 daemon.info procd: Instance xray-mosdns::mosdns s in a crash loop 6 crashes, 0 seconds since last crash
Sat Nov 21 13:00:05 2026 user.notice xray-mosdns: nft table rebuilt
Sat Nov 21 13:00:06 2026 user.notice xray-mosdns-gen: ERROR: bad config
Sat Nov 21 13:00:07 2026 daemon.err groups.uc[301]: watcher warning
Sat Nov 21 13:00:08 2026 daemon.err dns-watchdog.sh[401]: watchdog warning
Sat Nov 21 13:00:09 2026 daemon.info procd: Instance xray-mosdns::dnswatch s in a crash loop 6 crashes, 0 seconds since last crash
Sat Nov  1 13:00:10 2026 daemon.info dnsmasq[501]: xray-mosdns: not ours
Sat Nov 21 13:00:11 2026 daemon.info procd: Instance other::xray s in a crash loop 6 crashes, 0 seconds since last crash
Sat Nov 21 13:00:12 2026 kern.info kernel: [    1.000000] xray-mosdns: not ours either
not a log line
EOF
printf '#!/bin/sh\ncat %s/syslog.txt\n' "$OUT" > "$OUT/fake-logread"
chmod +x "$OUT/fake-logread"
cat > "$OUT/mosdns-x.log" <<'EOF'
2026-11-21T13:00:00.000+0800	INFO	server started
{"level":"info","ts":1763730000.5,"logger":"cache","msg":"cache hit rate","rate":0.5}
{"level":"info","time":"2025-11-21T13:00:01.000Z","logger":"_query_summary","msg":"query summary","uqid":7,"client":"192.168.1.2","protocol":"udp","qname":"example.com.","qtype":1,"qclass":1,"resp_rcode":0,"elapsed":"2.1ms"}
{"level":"warn","ts":1763730002.25,"msg":"upstream error","error":"timeout"}
{"level":"warn","time":"2025-11-21T21:00:03.500+08:00","logger":"forward_remote","msg":"upstream err","addr":"tcp://8.8.8.8:53"}
EOF
logsh() { env TZ=UTC LOGREAD="$OUT/fake-logread" MOSDNS_LOG="$OUT/mosdns-x.log" "$LX/log.sh" "$@"; }

run log-xray.txt   logsh xray
run log-mosdns.txt logsh mosdns
run log-app.txt    logsh app
run log-all.txt    logsh
run log-legacy.txt logsh 300
run log-tail.txt   logsh app 2
if logsh nonsense >/dev/null 2>&1; then
	echo "script log-bad: an unknown source was accepted"; rc=1
else
	echo "script log-bad: ok"
fi

# querylog.uc: the preset _query_summary's lines, newest first; other lines
# (another message, no name, not JSON) are not queries. The time and the
# duration as mosdns-x writes them, and once as plain zap does (seconds).
cat > "$OUT/querylog.log" <<'EOF'
{"level":"info","time":"2025-11-21T13:00:01.000Z","logger":"_query_summary","msg":"query summary","uqid":1,"client":"192.168.1.2","protocol":"udp","qname":"example.com.","qtype":1,"qclass":1,"resp_rcode":0,"elapsed":"2.1ms"}
{"level":"info","time":"2025-11-21T13:00:02.000Z","logger":"cache","msg":"cache hit rate","rate":0.5}
not json
{"level":"info","time":"2025-11-21T21:00:03.250+08:00","logger":"_query_summary","msg":"query summary","uqid":2,"client":"192.168.1.3","protocol":"tcp","qname":"ads.example.net.","qtype":28,"qclass":1,"resp_rcode":3,"elapsed":"500µs"}
{"level":"info","time":"2025-11-21T13:00:04.000Z","logger":"_query_summary","msg":"query summary","uqid":3,"client":"192.168.1.2","protocol":"udp","qclass":1,"resp_rcode":0}
{"level":"info","ts":1763730005,"logger":"_query_summary","msg":"query summary","uqid":4,"client":"192.168.1.2","protocol":"udp","qname":"slow.example.org.","qtype":65,"qclass":1,"resp_rcode":-1,"elapsed":5.0,"error":"context deadline exceeded"}
EOF
run querylog        env MOSDNS_LOG="$OUT/querylog.log" "$LX/querylog.uc" 200
run querylog-filter env MOSDNS_LOG="$OUT/querylog.log" "$LX/querylog.uc" 200 192.168.1.3
run querylog-limit  env MOSDNS_LOG="$OUT/querylog.log" "$LX/querylog.uc" 1

# stats.uc: counters as mosdns-x serves them (a file here), the time given;
# RAM and flash files in the output directory
ST="$OUT/stats"; mkdir -p "$ST"
stv() { # $1 all, $2 blocked, $3 process start
	printf '# HELP x\nmosdns_plugin_metrics_all_query_total %s\nmosdns_plugin_metrics_block_query_total %s\nprocess_start_time_seconds %s\n' "$1" "$2" "$3" > "$ST/metrics"
}
stu() { env STATS_METRICS="$ST/metrics" STATS_RAM="$ST/ram.json" STATS_DISK="$ST/disk.json" STATS_LOCK="$ST/lock" TZ=UTC STATS_NOW="$1" ucode "$LX/stats.uc" "$2"; }
D1=1763683200	# 2025-11-21 00:00 UTC
stv 10 2 1.7636832e+09; stu $((D1 + 3600)) sample > "$OUT/stats-s1.txt"
stv 15 3 1.7636832e+09; run stats-s2 stu $((D1 + 7200)) show
# mosdns restarted (a new start time): everything it counted is new, even
# when more than before
stv 22 5 1.7636999e+09; run stats-s3 stu $((D1 + 9000)) show
stv 1.234567e+06 7 1.7636999e+09; run stats-big stu $((D1 + 9600)) show
stv 1234570 8 1.7636999e+09
run stats-flush stu $((D1 + 10800)) flush
# a reboot: RAM is gone, the flash copy carries on (same process start = no new counts)
rm -f "$ST/ram.json"; run stats-reboot stu $((D1 + 11000)) show
# the next day, and 31 days later (the first day is out of the 30)
stv 1234580 9 1.7636999e+09; run stats-day2 stu $((D1 + 86400 + 60)) show
stv 1234581 9 1.7636999e+09; run stats-day31 stu $((D1 + 30 * 86400 + 60)) show
# no counters to read (mosdns down, an older config): the counts as they were
rm -f "$ST/metrics"; run stats-down stu $((D1 + 30 * 86400 + 120)) show

kill "$LISTENER" 2>/dev/null
if [ -f "$OUT/conf.saved" ]; then mv "$OUT/conf.saved" "$CONF"; else rm -f "$CONF"; fi
exit $rc
