#
# luci-app-xray-mosdns-x: LuCI front-end for an Xray + mosdns-x transparent
# proxy stack (PassWall replacement, work in progress).
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-xray-mosdns-x
PKG_VERSION:=0.7.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=zly

LUCI_TITLE:=LuCI support for Xray + mosdns-x transparent proxy
LUCI_DESCRIPTION:=Manage an Xray TProxy transparent proxy with mosdns-x DNS split, cache and ad blocking.
LUCI_DEPENDS:=+luci-base +nftables +ip-full +resolveip +ucode
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
