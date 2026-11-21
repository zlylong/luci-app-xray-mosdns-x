#
# luci-app-xray-mosdns-x: LuCI front-end for an Xray + mosdns-x transparent
# proxy stack (PassWall replacement, work in progress).
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-xray-mosdns-x
PKG_VERSION:=0.9.7
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
# /etc/xray-mosdns may be shared, so only the files adlist.uc writes go.
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
dir=$$(uci -q get xray-mosdns.adblock.dir)
case "$$dir" in
	''|/etc/xray-mosdns|/etc/xray-mosdns/*) ;;
	/*) [ -d "$$dir" ] && rm -f "$$dir"/block.txt "$$dir"/allow.txt "$$dir"/state.json \
		"$$dir"/*.block "$$dir"/*.allow "$$dir"/.*.block.tmp "$$dir"/.*.allow.tmp ;;
esac
rm -rf /etc/xray-mosdns /root/pw-backup/xray-mosdns-update
rm -rf /var/etc/xray-mosdns /var/etc/xray-mosdns.new
rm -f /var/run/xray-mosdns.error /var/run/xray-mosdns-* /tmp/mosdns-x.log /tmp/xray-mosdns-*
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
