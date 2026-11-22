#!/bin/sh
# What the start script, the watchdog and the package scripts rely on, with
# stand-ins for what a test rootfs cannot run (nft, ip, curl, unzip):
#   - fw.sh gate / ungate / gated / apply: each one transaction, both chains,
#     LAN DNS handed back and taken back, a refused transaction changes
#     nothing, a half-done gate is completed, a reload keeps a gate in place;
#     fw.sh status
#   - switch.sh: a new set of files in place whole, or the old one back whole
#   - groups.uc and status.sh go by runtime.env, not UCI
#   - update.sh: checksums, replacing a running binary, the lock, backups
#   - adlist.uc update: a shared directory, merged lists that cannot be written
#     or replaced, no hard links (vfat); migrate (and not during an update);
#     ensure
#   - the package's postrm, on an upgrade and on removal
# Results go to <outdir>/runtime/; tests/check.py checks them. nft syntax
# is not checked here (the stand-in takes any rule): that needs a kernel,
# `nft -c -f` on a router or in a container with NET_ADMIN.
# Runs inside a throwaway OpenWrt rootfs: it writes /var/etc/xray-mosdns,
# /var/run, /etc/crontabs/root and removes /etc/xray-mosdns, as the package
# scripts do. It refuses to run where the package is installed.
# usage: tests/runtime.sh <repo> <outdir>
REPO=${1:-.}; OUT=${2:-/tmp/xm-test}/runtime
FW="$REPO/root/usr/share/xray-mosdns/fw.sh"
UPD="$REPO/root/usr/libexec/xray-mosdns/update.sh"
CONF=/etc/config/xray-mosdns
if [ -e /usr/libexec/xray-mosdns/update.sh ]; then
	echo "runtime: the package is installed here; run this in a test rootfs" >&2
	exit 1
fi
rc=0
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/rules" /var/run /var/etc/xray-mosdns
export FAKE_NFT_STATE="$OUT/nft"
export PATH="$OUT/bin:$PATH"
[ -f "$CONF" ] && cp "$CONF" "$OUT/conf.saved"

# ---------------------------------------------------------------- stand-ins
cat > "$OUT/bin/nft" <<'EOF'
#!/bin/sh
# stand-in for nft: the chains of table inet xray-mosdns as files, one rule
# per line with its handle, sets as set.<name> files, one element per line.
# -f applies a batch all or nothing; FAKE_NFT_FAIL=<text> refuses a batch
# with a line containing it.
S=$FAKE_NFT_STATE
T='inet xray-mosdns'
set -f
show() { # $1 chain, $2 non-empty: with handles
	[ -f "$S/$1" ] || exit 1
	printf 'table %s {\n\tchain %s {\n' "$T" "$1"
	while IFS= read -r l; do
		if [ -n "$2" ]; then printf '\t\t%s # handle %s\n' "${l% #H*}" "${l##* #H}"
		else printf '\t\t%s\n' "${l% #H*}"; fi
	done < "$S/$1"
	printf '\t}\n}\n'
	exit 0
}
case "$*" in
	"list table $T")
		[ -d "$S" ] || exit 1
		printf 'table %s {\n' "$T"
		for s in $(ls "$S" | sed -n 's/^set\.//p'); do printf '\tset %s {\n\t\ttype ipv4_addr\n\t}\n' "$s"; done
		printf '}\n'
		exit 0 ;;
	"list set $T "*)
		[ -f "$S/set.$5" ] || exit 1
		printf 'table %s {\n\tset %s {\n\t\ttype ipv4_addr\n\t\telements = { %s }\n\t}\n}\n' "$T" "$5" \
			"$(tr '\n' ',' < "$S/set.$5" | sed 's/,$//; s/,/, /g')"
		exit 0 ;;
	"delete table $T") rm -rf "$S"; exit 0 ;;
	"list chain $T "*) show "$5" ;;
	"-a list chain $T "*) show "$6" handles ;;
esac
[ "$1" = "-f" ] || exit 0
# the test rootfs is entered with chroot: no /dev/stdin there
[ "$2" = "-" ] || exec < "$2"
W="$S.tx"; rm -rf "$W"; mkdir -p "$W"
[ -d "$S" ] && cp -a "$S"/. "$W"/
n=$(cat "$W/.h" 2>/dev/null || echo 0)
while IFS= read -r line; do
	if [ -n "${FAKE_NFT_FAIL:-}" ]; then
		case "$line" in *"$FAKE_NFT_FAIL"*) echo "Error: stand-in refuses: $line" >&2; rm -rf "$W"; exit 1 ;; esac
	fi
	set -- $line
	c=$5
	case "$1 $2" in
		"insert rule") n=$((n + 1)); { echo "${line#insert rule $T $c } #H$n"; cat "$W/$c" 2>/dev/null; } > "$W/.t"; mv "$W/.t" "$W/$c" ;;
		"add rule") n=$((n + 1)); echo "${line#add rule $T $c } #H$n" >> "$W/$c" ;;
		"delete rule") grep -v " #H$7\$" "$W/$c" > "$W/.t"; mv "$W/.t" "$W/$c" ;;
		"flush chain") : > "$W/$c" ;;
		"add chain") [ -f "$W/$c" ] || : > "$W/$c" ;;
	esac
done
echo "$n" > "$W/.h"
rm -rf "$S"; mv "$W" "$S"
exit 0
EOF
cat > "$OUT/bin/ip" <<'EOF'
#!/bin/sh
# stand-in for ip: the policy rule and route fw.sh adds are there
case "$*" in
	*"rule show"*) printf '0:\tfrom all lookup local\n100:\tfrom all fwmark 0x1 lookup 100\n' ;;
	*"route show table 100"*) printf 'local default dev lo scope host\n' ;;
esac
exit 0
EOF
chmod +x "$OUT/bin/nft" "$OUT/bin/ip"

# ---------------------------------------------------------------- fw.sh gate
T='inet xray-mosdns'
R="$OUT/rules"
cat > "$R/nft.rules" <<EOF
add table $T
add chain $T prerouting
add chain $T output
add chain $T dns_redirect
add chain $T dns_redirect_out
flush chain $T prerouting
flush chain $T output
flush chain $T dns_redirect
flush chain $T dns_redirect_out
add rule $T prerouting iifname != "br-lan" return
add rule $T prerouting meta l4proto tcp goto do_tproxy
add rule $T output meta mark 0xff return
add rule $T dns_redirect udp dport 53 redirect to :5335
EOF
printf 'flush chain %s dns_redirect\nflush chain %s dns_redirect_out\nadd rule %s dns_redirect udp dport 53 redirect to :5335\n' "$T" "$T" "$T" > "$R/nft-dns-on.rules"
printf 'flush chain %s dns_redirect\nflush chain %s dns_redirect_out\n' "$T" "$T" > "$R/nft-dns-off.rules"
runtime() { # $1 = DNS_WATCH
	printf "TPROXY_PORT=12345\nDNS_PORT=5335\nDNS_REDIRECT=1\nDNS_WATCH=%s\nFWMARK=0x1\nROUTE_TABLE=100\nIPV6=0\n" "$1" > "$R/runtime.env"
}
fw() { XM_RULES_DIR="$R" sh "$FW" "$@"; }
# the chains (rules only, no handles), whether gated, and the overview's message
dump() {
	{
		for c in prerouting output dns_redirect; do
			echo "[$c]"
			sed 's/ #H[0-9]*$//' "$FAKE_NFT_STATE/$c" 2>/dev/null
		done
		echo "[gated] $(fw gated && echo yes || echo no)"
		echo "[error] $(cat /var/run/xray-mosdns.error 2>/dev/null)"
	} > "$OUT/$1.txt"
}
step() { # $1 name, then the fw.sh arguments; records the exit status
	name=$1; shift
	fw "$@" > /dev/null 2> "$OUT/$name.err"
	echo "$name=$?" >> "$OUT/status.txt"
	dump "$name"
}
rm -f /var/run/xray-mosdns.error
runtime log-only
step apply apply
step gate gate
step gate-again gate
# a start clears the overview's message: gating again puts it back, without
# covering another message
rm -f /var/run/xray-mosdns.error
step gate-msg gate
echo "another problem" > /var/run/xray-mosdns.error
step gate-other gate
rm -f /var/run/xray-mosdns.error; fw gate >/dev/null 2>&1
step apply-gated apply
step ungate ungate
# the second half of the gate is refused: nothing may change
export FAKE_NFT_FAIL="insert rule $T output"
step gate-refused gate
unset FAKE_NFT_FAIL
# half a gate, as an older version could leave it
printf 'insert rule %s prerouting return comment "xray-mosdns: Xray not listening"\n' "$T" | nft -f -
step half gated
step half-gate gate
# a gate in place with the LAN DNS redirect back: gating again takes it off
nft -f "$R/nft-dns-on.rules"
step gate-dns gate
runtime manage
step ungate-managed ungate
# status: the sets there are and how full they are
printf '10.0.0.1\n10.0.0.2\n' > "$FAKE_NFT_STATE/set.bypass4"
: > "$FAKE_NFT_STATE/set.proxy4_dns"
printf '1.1.1.1\n' > "$FAKE_NFT_STATE/set.ipg4_0"
printf '9.9.9.9\n' > "$FAKE_NFT_STATE/set.somebody_else"
fw status > "$OUT/fw-status.txt" 2>&1
echo "script fw-gate: done"

# ---------------------------------------------------------------- switch.sh
SW="$REPO/root/usr/share/xray-mosdns/switch.sh"
X="$OUT/sw"
mkdir -p "$X/bin"
# stand-in for mv: refuses a move with one of the words of FAKE_MV_FAIL in a path
cat > "$X/bin/mv" <<'EOF'
#!/bin/sh
for a in "$@"; do
	for p in $FAKE_MV_FAIL; do
		case "$a" in *"$p"*) echo "mv: stand-in refuses $a" >&2; exit 1 ;; esac
	done
done
exec busybox mv "$@"
EOF
chmod +x "$X/bin/mv"
sw_seed() {
	rm -rf "$X/out" "$X/new"; mkdir -p "$X/out" "$X/new"
	echo old-a > "$X/out/a.json"; echo old-b > "$X/out/b.yaml"; echo state > "$X/out/.fw-state"
	echo new-a > "$X/new/a.json"; echo new-b > "$X/new/b.yaml"; echo new-c > "$X/new/c.rules"; echo new-h > "$X/new/.h.env"
}
sw_state() { # $1 name, $2 exit status
	{
		echo "rc $2"
		for f in a.json b.yaml c.rules .h.env .fw-state; do echo "out $f $(cat "$X/out/$f" 2>/dev/null || echo -)"; done
		echo "new $(ls -A "$X/new" | tr '\n' ' ')"
		echo "prev $([ -e "$X/out/.prev" ] && echo yes || echo no)"
	} > "$OUT/switch-$1.txt"
}
sw_seed; sh "$SW" "$X/new" "$X/out" 2> "$OUT/switch-ok.err"; sw_state ok $?
# the second file cannot be moved: the first goes back
sw_seed; PATH="$X/bin:$PATH" FAKE_MV_FAIL=b.yaml sh "$SW" "$X/new" "$X/out" 2> "$OUT/switch-fail.err"; sw_state fail $?
# ... and the old first file cannot be put back either: neither set is whole
sw_seed; PATH="$X/bin:$PATH" FAKE_MV_FAIL="b.yaml .prev/a.json" sh "$SW" "$X/new" "$X/out" 2> "$OUT/switch-broken.err"
sw_state broken $?
echo "prev-files $(ls -A "$X/out/.prev" 2>/dev/null | tr '\n' ' ')" >> "$OUT/switch-broken.txt"
echo "script switch: done"

# ---------------------------------------------------------------- groups.uc, status.sh
# Xray's API as a stand-in: answers on whichever port, logs what was asked
cat > "$OUT/bin/xray-api" <<EOF
#!/bin/sh
echo "\$*" >> "$OUT/groups-api.log"
case "\$2" in
	bi) printf 'Balancer: %s\n  - Selecting Override:\n  - Selects:\n    0 b.node\n' "\$4" ;;
esac
exit 0
EOF
chmod +x "$OUT/bin/xray-api"
printf '[{"name":"hk","tag":"hk.group","strategy":"ordered","failback":false,"members":[{"name":"a","tag":"a.node"},{"name":"b","tag":"b.node"}],"fallback":"direct"}]\n' \
	> /var/etc/xray-mosdns/groups.json
grt() { # $1 = API port in effect
	printf "XRAY_BIN='%s'\nAPI_PORT=%s\nPROBE_INTERVAL=30s\nPROBE_BACKUP=1\nDEFAULT_ACTION=direct\nKERNEL_SPLIT=0\nDNS_REDIRECT=0\nDNS_PORT=5353\n" \
		"$OUT/bin/xray-api" "$1" > /var/etc/xray-mosdns/runtime.env
}
# what UCI says differs from what is in effect in every value
printf "config global 'global'\n\toption xray_bin '/usr/bin/xray-missing'\n\toption api_port '10085'\n\toption default_action 'proxy'\n\toption kernel_split '1'\nconfig dns 'dns'\n\toption redirect '1'\n\toption listen_port '5335'\n" > "$CONF"
: > "$OUT/groups-api.log"
grt 20001
ucode "$REPO/root/usr/libexec/xray-mosdns/groups.uc" list > "$OUT/groups-list.json" 2>&1
# the watcher takes a changed port on its next round, without a restart
: > "$OUT/groups-api.log"
ucode "$REPO/root/usr/libexec/xray-mosdns/groups.uc" watch > "$OUT/groups-watch.log" 2>&1 & gw=$!
sleep 3; grt 20002; sleep 12
kill "$gw" 2>/dev/null
cp "$OUT/groups-api.log" "$OUT/groups-watch-api.log"
sh "$REPO/root/usr/libexec/xray-mosdns/status.sh" > "$OUT/status.json" 2>&1
# update.sh below goes by the configured binary: not this one
rm -f /var/etc/xray-mosdns/groups.json /var/etc/xray-mosdns/runtime.env "$CONF"
echo "script groups-status: done"

# ---------------------------------------------------------------- update.sh
U="$OUT/upd"; F="$U/fix"; ROOT="$U/root"
mkdir -p "$F" "$ROOT/usr/bin" "$ROOT/usr/share/v2ray" "$U/tmp"
# big enough to pass update.sh's size check; no /dev/urandom in a chroot
yes geosite | head -c 1200000 > "$F/geosite.dat"; yes geoip | head -c 1100000 > "$F/geoip.dat"; echo zip > "$F/xray.zip"
printf '#!/bin/sh\n[ "$1" = version ] && echo "Xray 99.0.0 (new)"\n[ "$1" = run ] && sleep 30\nexit 0\n' > "$F/xray-new"
printf '#!/bin/sh\n[ "$1" = version ] && echo "Xray 1.0.0 (old)"\n[ "$1" = run ] && sleep 30\nexit 0\n' > "$ROOT/usr/bin/xray"
chmod 755 "$F/xray-new" "$ROOT/usr/bin/xray"
echo OLD > "$ROOT/usr/share/v2ray/geosite.dat"; echo OLD > "$ROOT/usr/share/v2ray/geoip.dat"
cat > "$OUT/bin/curl" <<EOF
#!/bin/sh
# stand-in for curl: fixtures by URL; BAD=<what> serves a wrong checksum for it
out=; url=
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift 2 ;; -*) shift ;; *) url=\$1; shift ;; esac; done
emit() { if [ -n "\$out" ]; then cat "\$1" > "\$out"; else cat "\$1"; fi; }
zero=0000000000000000000000000000000000000000000000000000000000000000
case "\$url" in
	*/repos/XTLS/Xray-core/releases/latest) printf '{"tag_name": "v99.0.0", "assets": [{"browser_download_url": "https://gh/v99/Xray-linux-64.zip"}, {"browser_download_url": "https://gh/v99/Xray-linux-arm64-v8a.zip"}]}\n' ;;
	*/repos/Loyalsoldier/v2ray-rules-dat/releases/latest) printf '{"tag_name": "202611210000"}\n' ;;
	*.zip.dgst) s=\$(sha256sum "$F/xray.zip" | cut -d' ' -f1); [ "\${BAD:-}" = dgst ] && s=\$zero; printf 'MD5= x\nSHA2-256= %s\n' "\$s" ;;
	*.zip) emit "$F/xray.zip" ;;
	*.dat.sha256sum) f=\${url##*/}; f=\${f%.sha256sum}; s=\$(sha256sum "$F/\$f" | cut -d' ' -f1); [ "\${BAD:-}" = "\$f" ] && s=\$zero; printf '%s  %s\n' "\$s" "\$f" ;;
	*/geosite.dat|*/geoip.dat) emit "$F/\${url##*/}" ;;
	*/lists.test/list1.txt) emit "$F/list1.txt" ;;
	*) exit 22 ;;
esac
EOF
cat > "$OUT/bin/unzip" <<EOF
#!/bin/sh
# stand-in for unzip -o -q ZIP -d DIR: puts the new xray into DIR
while [ \$# -gt 0 ]; do case "\$1" in -d) d=\$2; shift 2 ;; *) shift ;; esac; done
cp "$F/xray-new" "\$d/xray"
EOF
chmod +x "$OUT/bin/curl" "$OUT/bin/unzip"
upd() { env UPD_TEST_DIR="$ROOT" TMPDIR="$U/tmp" sh "$UPD" "$@"; }
{
	echo "geo-good $(upd geo)"
	cp "$ROOT/usr/share/v2ray/geoip.dat" "$U/ip.before"
	echo "geo-bad $(BAD=geoip.dat upd geo)"
	echo "geoip-kept $(cmp -s "$U/ip.before" "$ROOT/usr/share/v2ray/geoip.dat" && echo yes || echo no)"
	"$ROOT/usr/bin/xray" run & running=$!
	echo "xray-bad $(BAD=dgst upd xray)"
	echo "xray-after-bad $("$ROOT/usr/bin/xray" version)"
	echo "xray-good $(upd xray)"
	echo "xray-after-good $("$ROOT/usr/bin/xray" version)"
	echo "old-still-running $(kill -0 "$running" 2>/dev/null && echo yes || echo no)"
	echo "leftovers $(ls "$ROOT/usr/bin" | grep -c '\.new\.')"
	kill "$running" 2>/dev/null
	exec 9>"$U/tmp/xray-mosdns-update.lock"; flock -n 9
	echo "locked $(upd geo)"
	exec 9>&-
	for i in 1 2 3 4; do sleep 1; upd geo >/dev/null; upd xray >/dev/null; done
	B="$ROOT/root/pw-backup/xray-mosdns-update"
	echo "backups-geosite $(ls "$B" | grep -c '^geosite.dat\.')"
	echo "backups-xray $(ls "$B" | grep -c '^xray\.')"
	echo "mode-backups $(ls -ld "$B" | cut -c1-10)"
	echo "mode-geo $(ls -l "$ROOT/usr/share/v2ray/geosite.dat" | cut -c1-10)"
} > "$OUT/update.txt" 2>&1
echo "script update: done"

# ---------------------------------------------------------------- adlist.uc
# A directory set in the options, shared with another program: our files
# go into its xray-mosdns/ subdirectory. It starts the way 0.9.8 left it,
# our lists at the top (one of them no longer subscribed).
AD="$OUT/adlists"; ADS="$AD/xray-mosdns"
mkdir -p "$AD"
list1() { # $1 = one more rule, so that each update changes the merged list
	printf '||ads.test^\n||more-ads.test^\n%b@@||fine.test^\n' "${1:+||$1^\n}" > "$F/list1.txt"
}
list1
echo theirs > "$AD/mine.block"; echo theirs > "$AD/mine.allow"
echo old > "$AD/l1.block"; echo old > "$AD/l1.allow"; echo old > "$AD/block.txt"; echo old > "$AD/allow.txt"
echo old > "$AD/gone1.block"; echo old > "$AD/gone1.allow"
printf '{"lists":{"l1":{"name":"l1","rules":1},"gone1":{"name":"gone1","rules":1}},"total":2}' > "$AD/state.json"
printf "config adblock\n\toption dir '%s'\nconfig adlist 'l1'\n\toption url 'https://lists.test/list1.txt'\n" "$AD" > "$CONF"
adl() { ucode "$REPO/root/usr/libexec/xray-mosdns/adlist.uc" "$@" 2>&1; }
same() { cmp -s "$1" "$2" && echo yes || echo no; }
{
	# an update writes into the subdirectory and leaves the top alone: a
	# configuration still running reads its lists there
	echo "update1 $(adl update)"
	echo "top1 $(ls -A "$AD" | tr '\n' ' ')"
	echo "sub1 $(ls -A "$ADS" | tr '\n' ' ')"
	# the start script's move once a new configuration is in place: what the
	# subdirectory has already just goes, the rest moves
	echo "migrate1 $(adl migrate)"
	echo "top1m $(ls -A "$AD" | tr '\n' ' ')"
	echo "sub1m $(ls -A "$ADS" | tr '\n' ' ')"
	echo "migrate1b $(adl migrate)"
	# another program's lists and state under the same names at the top
	echo theirs-block > "$AD/block.txt"; echo theirs-allow > "$AD/allow.txt"; echo '{"theirs":1}' > "$AD/state.json"
	cp "$AD/block.txt" "$OUT/theirs.block"
	list1 new1.test
	echo "update2 $(adl update)"
	echo "theirs2 $(same "$OUT/theirs.block" "$AD/block.txt") $(cat "$AD/allow.txt") $(cat "$AD/state.json")"
	echo "new2 $(grep -c new1.test "$ADS/block.txt")"
	echo "sub2u $(ls -A "$ADS" | tr '\n' ' ')"
	cp "$ADS/block.txt" "$OUT/block.before"
	# the merged block list cannot be written: both lists in use stay
	mkdir "$ADS/.block.tmp"; list1 new2.test
	echo "update3 $(adl update)"
	echo "kept3 $(same "$OUT/block.before" "$ADS/block.txt")"
	echo "status3 $(adl status)"
	rmdir "$ADS/.block.tmp"
	# the exception list cannot be replaced: the block list is not replaced either
	rm -f "$ADS/allow.txt"; mkdir "$ADS/allow.txt"; list1 new3.test
	echo "update4 $(adl update)"
	echo "kept4 $(same "$OUT/block.before" "$ADS/block.txt") $(ls -A "$ADS" | grep -c '\.prev$')"
	rmdir "$ADS/allow.txt"
	# a directory where the copy of a list in use goes: no copy, no replacing
	mkdir "$ADS/.allow.prev"; list1 new4.test
	echo "update5 $(adl update)"
	echo "kept5 $(same "$OUT/block.before" "$ADS/block.txt") $(ls -A "$ADS/.allow.prev" | wc -l)"
	rmdir "$ADS/.allow.prev"
	echo "update6 $(adl update)"
	echo "new6 $(grep -c new4.test "$ADS/block.txt") $([ -f "$ADS/allow.txt" ] && echo allow)"
	echo "status6 $(adl status)"
	echo "theirs6 $(same "$OUT/theirs.block" "$AD/block.txt") $(adl migrate) $(cat "$AD/state.json")"
	# a file system without hard links (vfat, exfat): the lists in use are copied
	mkdir -p "$OUT/noln"; printf '#!/bin/sh\necho "ln: Operation not permitted" >&2\nexit 1\n' > "$OUT/noln/ln"; chmod +x "$OUT/noln/ln"
	list1 new5.test
	echo "update7 $(PATH="$OUT/noln:$PATH" adl update)"
	echo "new7 $(grep -c new5.test "$ADS/block.txt") $(ls -A "$ADS" | grep -c '\.prev$')"
	# rewritten in place, the same file: mosdns watches the one it opened. A
	# link made before shows the new list only if the file is the same one
	# (inode numbers alone can be reused).
	ln -f "$ADS/block.txt" "$OUT/block.link"; list1 new6.test
	echo "update8 $(adl update)"
	echo "inplace8 $(grep -q new6.test "$OUT/block.link" && echo same || echo replaced) $(grep -c new6.test "$ADS/block.txt")"
	# the exception list cannot be rewritten (cut short): both go back as they were
	cp "$ADS/block.txt" "$OUT/block.before9"; cp "$ADS/allow.txt" "$OUT/allow.before9"
	mkdir -p "$OUT/badcat"
	printf '#!/bin/sh\nfor a in "$@"; do case "$a" in */.allow.tmp) head -c 3 "$a"; exit 1 ;; esac; done\nexec busybox cat "$@"\n' > "$OUT/badcat/cat"
	chmod +x "$OUT/badcat/cat"; list1 new7.test
	echo "update9 $(PATH="$OUT/badcat:$PATH" adl update)"
	echo "kept9 $(same "$OUT/block.before9" "$ADS/block.txt") $(same "$OUT/allow.before9" "$ADS/allow.txt") $(ls -A "$ADS" | grep -c '\.prev$\|\.tmp$')"
	# At start, mosdns does not start without the merged lists: nothing
	# missing, nothing done; one missing, made from the lists there are (no
	# download, no update started)
	echo "ensure1 $(adl ensure)"
	cat "$ADS/l1.block" > "$OUT/merged.expected"
	mv "$ADS/block.txt" "$OUT/block.saved"
	echo "ensure2 $(adl ensure)"
	echo "ensure2-made $(same "$OUT/merged.expected" "$ADS/block.txt")"
	# an empty one (a stand-in an earlier version made) while the lists have data: made again
	: > "$ADS/block.txt"
	echo "ensure2b $(adl ensure)"
	echo "ensure2b-made $(same "$OUT/merged.expected" "$ADS/block.txt")"
	# a subscribed list with no data yet: fetched in the background
	mv "$ADS/l1.block" "$OUT/l1.saved"
	echo "ensure3 $(adl ensure)"
	mv "$OUT/l1.saved" "$ADS/l1.block"
	# one that cannot be made: said on stderr
	mv "$ADS/allow.txt" "$OUT/allow.saved"; mkdir "$ADS/allow.txt"
	echo "ensure4 $(ucode "$REPO/root/usr/libexec/xray-mosdns/adlist.uc" ensure 2>&1 >/dev/null)"
	rmdir "$ADS/allow.txt"; mv "$OUT/allow.saved" "$ADS/allow.txt"
} > "$OUT/adlist.txt"
# One writer of the list directory at a time: an update holds the lock (here
# the test does, with flock on fd 7). A move is left to the next start,
# another update refuses, missing merged lists get empty stand-ins for the
# update to replace, never written over a file that is there.
AD3="$OUT/adlists3"; AD3S="$AD3/xray-mosdns"
mkdir -p "$AD3S"; echo old > "$AD3/block.txt"; echo kept > "$AD3S/allow.txt"
printf '{"lists":{"l1":{"name":"l1","rules":1}},"total":1}' > "$AD3/state.json"
printf "config adblock\n\toption dir '%s'\nconfig adlist 'l1'\n\toption url 'https://lists.test/list1.txt'\n" "$AD3" > "$CONF"
LOCKF=/var/run/xray-mosdns-adlist.lock
exec 7>"$LOCKF"; flock -x 7
{
	o=$(adl migrate); echo "locked $? $o"
	echo "locked-top $(ls -A "$AD3" | tr '\n' ' ')"
	echo "locked-update $(adl update)"
	echo "locked-status $(adl status | grep -o '"running": [a-z]*')"
	echo "locked-ensure $(ucode "$REPO/root/usr/libexec/xray-mosdns/adlist.uc" ensure 2>&1 >/dev/null)"
	echo "locked-standins $(ls -A "$AD3S" | tr '\n' ' ') block $(wc -c < "$AD3S/block.txt") allow $(cat "$AD3S/allow.txt")"
} >> "$OUT/adlist.txt"
exec 7>&-
{
	o=$(adl migrate); echo "unlocked $? $o"
	echo "unlocked-top $(ls -A "$AD3" | tr '\n' ' ') lock $([ -e "$LOCKF" ] && echo kept || echo gone)"
	echo "unlocked-status $(adl status | grep -o '"running": [a-z]*')"
} >> "$OUT/adlist.txt"
# A move that cannot finish: the state stays at the top, and the next start
# moves the rest.
AD2="$OUT/adlists2"
mkdir -p "$AD2/xray-mosdns/l1.allow"
echo old > "$AD2/l1.block"; echo old > "$AD2/l1.allow"; echo old > "$AD2/block.txt"
printf '{"lists":{"l1":{"name":"l1","rules":1}},"total":1}' > "$AD2/state.json"
printf "config adblock\n\toption dir '%s'\nconfig adlist 'l1'\n\toption url 'https://lists.test/list1.txt'\n" "$AD2" > "$CONF"
{
	echo "migrate2 $(ucode "$REPO/root/usr/libexec/xray-mosdns/adlist.uc" migrate 2>"$OUT/migrate2.err")"
	echo "migrate2-err $(cat "$OUT/migrate2.err")"
	echo "top2 $(ls -A "$AD2" | tr '\n' ' ')"
	echo "sub2 $(ls -A "$AD2/xray-mosdns" | tr '\n' ' ')"
	rmdir "$AD2/xray-mosdns/l1.allow"
	echo "migrate3 $(adl migrate)"
	echo "top3 $(ls -A "$AD2" | tr '\n' ' ')"
	echo "sub3 $(ls -A "$AD2/xray-mosdns" | tr '\n' ' ')"
} >> "$OUT/adlist.txt"
echo "script adlist: done"

# ---------------------------------------------------------------- postrm
# taken from the Makefile the way the build does ($$ -> $)
sed -n '/^define Package\/\$(PKG_NAME)\/postrm/,/^endef/p' "$REPO/Makefile" | sed '1d;$d' | sed 's/\$\$/$/g' > "$OUT/postrm"
S="$OUT/shared"
mkdir -p /etc/crontabs /etc/xray-mosdns/adlists /root/pw-backup/xray-mosdns-update "$S"
printf '0 4 * * * /usr/libexec/xray-mosdns/update.sh geo-auto # xray-mosdns-geo-auto\n17 5 * * * x # xray-mosdns-adlist\n0 1 * * * keep-me\n' > /etc/crontabs/root
touch /etc/xray-mosdns/adlists/block.txt /root/pw-backup/xray-mosdns-update/xray.1
# The blocklist options in an anonymous section, one named and one
# anonymous subscription. The directory is shared with another program; it
# has our subdirectory (with the files of a list unsubscribed since the
# last update) and, at the top, what 0.9.8 left there.
adconf() { # $1 = directory
	printf "config adblock\n\toption dir '%s'\nconfig adlist 'l1'\n\toption url 'https://a.test/1'\nconfig adlist\n\toption url 'https://a.test/2'\n" "$1" > "$CONF"
}
adconf "$S"
anon=$(uci -q -X show xray-mosdns | sed -n 's/^xray-mosdns\.\(cfg[0-9a-f]*\)=adlist$/\1/p')
mkdir -p "$S/xray-mosdns"
for f in block.txt allow.txt state.json l1.block gone2.block .gone2.raw; do touch "$S/xray-mosdns/$f"; done
# gone3: a list 0.9.8 wrote, unsubscribed since; only its state names it
for f in block.txt allow.txt .block.tmp l1.block l1.allow .l1.raw "$anon.block" "$anon.allow" gone3.block .gone3.raw \
	mine.txt mine.block mine.allow; do
	touch "$S/$f"
done
printf '{"lists":{"l1":{"name":"l1","rules":1,"error":null},"gone3":{"name":"gone3","rules":1,"error":null}},"total":2,"finished":1,"error":null}' > "$S/state.json"
# another shared directory: there the generic names at the top are the other program's
S2="$OUT/shared2"
mkdir -p "$S2/xray-mosdns"
touch "$S2/xray-mosdns/block.txt" "$S2/block.txt" "$S2/allow.txt" "$S2/l1.block"
echo '{"theirs":1}' > "$S2/state.json"
mkdir -p "$FAKE_NFT_STATE"
pr_state() { # $1 = shared directory
	echo "cron-ours $(grep -c '# xray-mosdns-' /etc/crontabs/root) cron-other $(grep -c keep-me /etc/crontabs/root)"
	echo "etc-dir $([ -d /etc/xray-mosdns ] && echo present || echo gone) backups $([ -d /root/pw-backup/xray-mosdns-update ] && echo present || echo gone) table $([ -d "$FAKE_NFT_STATE" ] && echo present || echo gone)"
	echo "shared $(ls -A "$1" | sed "s/^$anon\./ANON./" | sort | tr '\n' ' ')"
	[ -d "$1/xray-mosdns" ] && echo "sub $(ls -A "$1/xray-mosdns" | sort | tr '\n' ' ')"
}
{
	# an upgrade: the package's scripts are still there
	mkdir -p /usr/libexec/xray-mosdns; touch /usr/libexec/xray-mosdns/update.sh
	sh "$OUT/postrm" >/dev/null 2>&1
	echo "[upgrade]"; pr_state "$S"
	rm -f /usr/libexec/xray-mosdns/update.sh; rmdir /usr/libexec/xray-mosdns
	sh "$OUT/postrm" >/dev/null 2>&1
	echo "[removal]"; pr_state "$S"
	adconf "$S2"
	sh "$OUT/postrm" >/dev/null 2>&1
	echo "[removal-theirs]"; pr_state "$S2"
} > "$OUT/postrm.txt"
sed -i '/keep-me/d' /etc/crontabs/root
echo "script postrm: done"

if [ -f "$OUT/conf.saved" ]; then mv "$OUT/conf.saved" "$CONF"; else rm -f "$CONF"; fi
exit $rc
