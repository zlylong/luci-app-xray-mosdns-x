#!/bin/sh
# What the start script, the watchdog and the package scripts rely on, with
# stand-ins for what a test rootfs cannot run (nft, ip, curl, unzip):
#   - fw.sh gate / ungate / gated / apply: each one transaction, both chains,
#     LAN DNS handed back and taken back, a refused transaction changes
#     nothing, a half-done gate is completed, a reload keeps a gate in place
#   - update.sh: checksums, replacing a running binary, the lock, backups
#   - the package's postrm, on an upgrade and on removal
# Results go to <outdir>/runtime/; tests/check.py checks them.
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
# per line with its handle. -f applies a batch all or nothing;
# FAKE_NFT_FAIL=<text> refuses a batch with a line containing it.
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
	"list table $T") [ -d "$S" ]; exit ;;
	"delete table $T") rm -rf "$S"; exit 0 ;;
	"list chain $T "*) show "$5" ;;
	"-a list chain $T "*) show "$6" handles ;;
esac
[ "$1" = "-f" ] || exit 0
src=$2; [ "$src" = "-" ] && src=/dev/stdin
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
done < "$src"
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
runtime manage
step ungate-managed ungate
echo "script fw-gate: done"

# ---------------------------------------------------------------- update.sh
U="$OUT/upd"; F="$U/fix"; ROOT="$U/root"
mkdir -p "$F" "$ROOT/usr/bin" "$ROOT/usr/share/v2ray" "$U/tmp"
head -c 1200000 /dev/urandom > "$F/geosite.dat"; head -c 1100000 /dev/urandom > "$F/geoip.dat"; echo zip > "$F/xray.zip"
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

# ---------------------------------------------------------------- postrm
# taken from the Makefile the way the build does ($$ -> $)
sed -n '/^define Package\/\$(PKG_NAME)\/postrm/,/^endef/p' "$REPO/Makefile" | sed '1d;$d' | sed 's/\$\$/$/g' > "$OUT/postrm"
S="$OUT/shared"
mkdir -p /etc/crontabs /etc/xray-mosdns/adlists /root/pw-backup/xray-mosdns-update "$S"
printf '0 4 * * * /usr/libexec/xray-mosdns/update.sh geo-auto # xray-mosdns-geo-auto\n17 5 * * * x # xray-mosdns-adlist\n0 1 * * * keep-me\n' > /etc/crontabs/root
touch /etc/xray-mosdns/adlists/block.txt /root/pw-backup/xray-mosdns-update/xray.1
for f in block.txt allow.txt state.json 1.block 1.allow mine.txt; do touch "$S/$f"; done
printf "config adblock 'adblock'\n\toption dir '%s'\n" "$S" > "$CONF"
mkdir -p "$FAKE_NFT_STATE"
pr_state() {
	echo "cron-ours $(grep -c '# xray-mosdns-' /etc/crontabs/root) cron-other $(grep -c keep-me /etc/crontabs/root)"
	echo "etc-dir $([ -d /etc/xray-mosdns ] && echo present || echo gone) backups $([ -d /root/pw-backup/xray-mosdns-update ] && echo present || echo gone) table $([ -d "$FAKE_NFT_STATE" ] && echo present || echo gone)"
	echo "shared $(ls "$S" | tr '\n' ' ')"
}
{
	# an upgrade: the package's scripts are still there
	mkdir -p /usr/libexec/xray-mosdns; touch /usr/libexec/xray-mosdns/update.sh
	sh "$OUT/postrm" >/dev/null 2>&1
	echo "[upgrade]"; pr_state
	rm -f /usr/libexec/xray-mosdns/update.sh; rmdir /usr/libexec/xray-mosdns
	sh "$OUT/postrm" >/dev/null 2>&1
	echo "[removal]"; pr_state
} > "$OUT/postrm.txt"
sed -i '/keep-me/d' /etc/crontabs/root
echo "script postrm: done"

if [ -f "$OUT/conf.saved" ]; then mv "$OUT/conf.saved" "$CONF"; else rm -f "$CONF"; fi
exit $rc
