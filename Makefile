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
# What they do not know about are the daily jobs this package adds to root's
# crontab; on an upgrade the scripts are still there and the jobs stay.
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
rm -rf /var/etc/xray-mosdns /var/etc/xray-mosdns.new /var/run/xray-mosdns.error
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
