include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-autofines
PKG_VERSION:=1.0.0
PKG_RELEASE:=2
PKG_MAINTAINER:=Evgenii Nikiforov <e@nikiforov.org>

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-autofines
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI page for autofines
  DEPENDS:=+luci-base +autofines
  PKGARCH:=all
endef

define Package/luci-app-autofines/description
  Страница «Службы → Штрафы МВД» в LuCI: токен бота, ID чата, госномера,
  интервал проверки police.ge и состояние службы.
endef

define Build/Compile
endef

define Package/luci-app-autofines/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/autofines.js $(1)/www/luci-static/resources/view/
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-autofines.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-autofines.json $(1)/usr/share/rpcd/acl.d/
endef

# Новый пункт меню и права LuCI видит, только когда сброшены его кэши
# и rpcd перечитал ACL, — как делает luci.mk у штатных приложений.
define Package/luci-app-autofines/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
}
exit 0
endef

Package/luci-app-autofines/postrm = $(Package/luci-app-autofines/postinst)

$(eval $(call BuildPackage,luci-app-autofines))
