#
# luci-app-xray-mosdns-x: LuCI front-end for an Xray + mosdns-x transparent
# proxy stack (PassWall replacement, work in progress).
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-xray-mosdns-x
PKG_VERSION:=1.0.6
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=zly

LUCI_TITLE:=LuCI support for Xray + mosdns-x transparent proxy
LUCI_DESCRIPTION:=Manage an Xray TProxy transparent proxy with mosdns-x DNS split, cache and ad blocking.
LUCI_DEPENDS:=+luci-base +nftables +ip-full +resolveip +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +ucode-mod-socket \
	+curl +unzip
# the tproxy expression needs this module; as an install-time dependency it
# comes from the kmods feed, without making the SDK build a kernel module.
# Extra dependencies must carry a version constraint: any version will do.
LUCI_EXTRA_DEPENDS:=kmod-nft-tproxy (>=0)
LUCI_PKGARCH:=all

# Stopping on removal and starting after an upgrade are done by the default
# package scripts (the init script's stop clears the nft table and routes).
# What they do not know about: the daily jobs this package adds to root's
# crontab, and what it downloaded and generated (blocklists, the catalogue,
# backups of replaced binaries; tens of MB on a small flash). On removal
# those go; the config file stays. On an upgrade the scripts are still
# there and everything stays. A blocklist directory outside
# /etc/xray-mosdns may be shared: adlist.uc keeps everything in its own
# subdirectory there, xray-mosdns/, and that goes whole. What a version up
# to 0.9.7 left at the top of it goes by name (the merged lists, the state,
# per subscription in UCI or list in that state <id>.block / .allow and
# temporaries), and only when the state file there is ours.
define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ -e /usr/libexec/xray-mosdns/update.sh ] && exit 0
if grep -qs '# xray-mosdns-' /etc/crontabs/root; then
	sed -i '/# xray-mosdns-/d' /etc/crontabs/root
	/etc/init.d/cron restart 2>/dev/null
fi
# stop has cleared the table already; in case it could not
nft delete table inet xray-mosdns 2>/dev/null
# A blocklist update started in the background (not by procd, so stop has
# left it) holds the lock and would go on writing what goes below: it,
# and what it started (curl, cat: they inherit the open lock), go first,
# and are gone before anything is removed: asked to stop, then, after up
# to 5 seconds, made to. The lock file can then go too.
lock=/var/run/xray-mosdns-adlist.lock
# /var is a link to /tmp: a descriptor shows where the file really is
real=$$(readlink -f "$$lock" 2>/dev/null)
holders() {
	for p in /proc/[0-9]*; do
		for fd in "$$p"/fd/*; do
			l=$$(readlink "$$fd" 2>/dev/null)
			if [ -n "$$l" ] && { [ "$$l" = "$$lock" ] || [ "$$l" = "$$real" ]; }; then
				echo "$${p#/proc/}"
				break
			fi
		done
	done
}
pids=$$(holders)
if [ -n "$$pids" ]; then
	kill $$pids 2>/dev/null
	i=0
	while [ $$i -lt 5 ] && [ -n "$$(holders)" ]; do
		sleep 1
		i=$$((i + 1))
	done
	pids=$$(holders)
	[ -n "$$pids" ] && kill -9 $$pids 2>/dev/null
	i=0
	while [ $$i -lt 3 ] && [ -n "$$(holders)" ]; do
		sleep 1
		i=$$((i + 1))
	done
fi
dir=$$(uci -q get 'xray-mosdns.@adblock[0].dir')
case "$$dir" in
	# ours whole, or one adlist.uc did not use either (it falls back then)
	''|/etc/xray-mosdns|/etc/xray-mosdns/*|*..*|*[!A-Za-z0-9_./-]*) ;;
	/*) if [ -d "$$dir" ]; then
		rm -rf "$$dir/xray-mosdns"
		if grep -qs '"lists"' "$$dir/state.json"; then
			# the subscriptions in UCI and the lists that state names (one
			# unsubscribed since): its only objects are "lists" and one per list
			ids="$$(uci -q -X show xray-mosdns | sed -n 's/^xray-mosdns\.\([A-Za-z0-9_]*\)=adlist$$/\1/p')
$$(grep -o '"[A-Za-z0-9_]*":{' "$$dir/state.json" | sed 's/^"\(.*\)":{$$/\1/' | grep -v '^lists$$')"
			for id in $$ids; do
				rm -f "$$dir/$$id.block" "$$dir/$$id.allow" "$$dir/.$$id.raw" "$$dir/.$$id.block.tmp" "$$dir/.$$id.allow.tmp"
			done
			rm -f "$$dir/block.txt" "$$dir/allow.txt" "$$dir/state.json" "$$dir/.block.tmp" "$$dir/.allow.tmp"
		fi
	fi ;;
esac
rm -rf /etc/xray-mosdns /root/pw-backup/xray-mosdns-update
rm -rf /var/etc/xray-mosdns /var/etc/xray-mosdns.new
rm -f /var/run/xray-mosdns.error /var/run/xray-mosdns-* /tmp/mosdns-x.log /tmp/xray-mosdns-*
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
