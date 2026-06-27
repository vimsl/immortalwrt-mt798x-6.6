
#
# Copyright (C) 2026 Hiveton H5000M AIQoS Project
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-aiqos
PKG_VERSION:=1.0.1
PKG_RELEASE:=2

PKG_MAINTAINER:=Hiveton H5000M Team
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-aiqos
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=9. Applications
  TITLE:=5G AI Signal Optimization for H5000M
  DEPENDS:=+luci-base +luci-compat +kmod-sched-cake +bc +jq
  PKGARCH:=all
endef

define Package/luci-app-aiqos/description
  AIQoS - Hiveton H5000M 5G CPE AI Signal Optimization Plugin

  Intelligently optimizes 5G CPE network performance:
  - Bufferbloat prevention via cake-autorate integration
  - Signal-adaptive bandwidth tuning via SINR feedback loop
  - WiFi channel/power optimization via TriTon (conditional)
  - Night-time cell locking with watchdog rollback
  - eBPF/XDP packet drop (expert mode)
  - AI signal prediction (experimental)

  HNAT coexistence: Does NOT disable hardware flow offloading.
endef

define Build/Compile
endef

define Package/luci-app-aiqos/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/aiqos
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/www/luci-static/resources/aiqos

	# LuCI components
	$(INSTALL_DATA) ./luci/controller/aiqos.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DATA) ./luci/model/cbi/aiqos.lua $(1)/usr/lib/lua/luci/model/cbi/
	$(INSTALL_DATA) ./luci/view/aiqos/status.htm $(1)/usr/lib/lua/luci/view/aiqos/

	# Executable scripts
	$(INSTALL_BIN) ./src/aiqosd.sh $(1)/etc/init.d/aiqosd
	$(INSTALL_BIN) ./src/sinr_injector.sh $(1)/usr/bin/
	$(INSTALL_BIN) ./src/night_lock.sh $(1)/usr/bin/
	$(INSTALL_BIN) ./src/condition_detect.sh $(1)/usr/bin/

	# Default UCI config
	$(INSTALL_DATA) ./root/etc/config/aiqos $(1)/etc/config/aiqos

	# Static resources (CSS)
	$(INSTALL_DATA) ./htdocs/luci-static/resources/aiqos/style.css $(1)/www/luci-static/resources/aiqos/
endef

$(eval $(call BuildPackage,luci-app-aiqos))
