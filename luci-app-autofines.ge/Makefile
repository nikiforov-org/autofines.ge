include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-autofines.ge
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Evgenii Nikiforov <e@nikiforov.org>

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-autofines.ge
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Georgian traffic fines from police.ge to Telegram
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-log +ucode-mod-uci +ucode-mod-uclient +ucode-mod-uloop +ca-bundle +luci-base
  USERID:=autofines:autofines
  PKGARCH:=all
endef

define Package/luci-app-autofines.ge/description
  Проверяет штрафы МВД Грузии по госномеру на police.ge и присылает новые
  в Telegram с кнопкой оплаты. Работает на роутере: сайт МВД отвечает
  только грузинским адресам. Настройки — в LuCI, «Службы → Штрафы МВД».
endef

define Package/luci-app-autofines.ge/conffiles
/etc/config/autofines
endef

define Build/Compile
endef

define Package/luci-app-autofines.ge/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/lib/upgrade/keep.d
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/share/ucode/autofines
	$(INSTALL_CONF) ./files/autofines.config $(1)/etc/config/autofines
	$(INSTALL_BIN) ./files/autofines.init $(1)/etc/init.d/autofines
	$(INSTALL_DATA) ./files/autofines.keep $(1)/lib/upgrade/keep.d/autofines
	$(INSTALL_BIN) ./files/autofines.uc $(1)/usr/bin/autofines
	$(INSTALL_DATA) ./files/ucode/autofines/*.uc $(1)/usr/share/ucode/autofines/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/autofines.js $(1)/www/luci-static/resources/view/
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-autofines.ge.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-autofines.ge.json $(1)/usr/share/rpcd/acl.d/
endef

# Новый пункт меню и права LuCI видит, только когда сброшены его кэши
# и rpcd перечитал ACL, — как делает luci.mk у штатных приложений.
define Package/luci-app-autofines.ge/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
}
exit 0
endef

Package/luci-app-autofines.ge/postrm = $(Package/luci-app-autofines.ge/postinst)

$(eval $(call BuildPackage,luci-app-autofines.ge))
