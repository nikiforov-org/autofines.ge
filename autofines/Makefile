include $(TOPDIR)/rules.mk

PKG_NAME:=autofines
PKG_VERSION:=1.1.0
PKG_RELEASE:=2
PKG_MAINTAINER:=Evgenii Nikiforov <e@nikiforov.org>

include $(INCLUDE_DIR)/package.mk

define Package/autofines
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Georgian traffic fines from police.ge to Telegram
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-log +ucode-mod-uci +ucode-mod-uclient +ucode-mod-uloop +ca-bundle
  USERID:=autofines:autofines
  PKGARCH:=all
endef

define Package/autofines/description
  Проверяет штрафы МВД Грузии по госномеру на police.ge и присылает новые
  в Telegram с кнопкой оплаты. Работает на роутере: сайт МВД отвечает
  только грузинским адресам.
endef

define Package/autofines/conffiles
/etc/config/autofines
endef

define Build/Compile
endef

define Package/autofines/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/lib/upgrade/keep.d
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/share/ucode/autofines
	$(INSTALL_CONF) ./files/autofines.config $(1)/etc/config/autofines
	$(INSTALL_BIN) ./files/autofines.init $(1)/etc/init.d/autofines
	$(INSTALL_DATA) ./files/autofines.keep $(1)/lib/upgrade/keep.d/autofines
	$(INSTALL_BIN) ./files/autofines.uc $(1)/usr/bin/autofines
	$(INSTALL_DATA) ./files/ucode/autofines/*.uc $(1)/usr/share/ucode/autofines/
endef

$(eval $(call BuildPackage,autofines))
