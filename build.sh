#!/bin/sh
# Собирает пакет luci-app-autofines.ge — бот и его страницу в LuCI — в SDK
# OpenWrt 25.12.6 для mediatek/filogic, target роутера RT-AX59U. Бинарников в
# пакете нет (noarch), так что он ставится на любой OpenWrt 25.12.
# Результат — dist/luci-app-autofines.ge-<версия>.apk.
#
# Аргументы уходят в make как есть.
set -eu
cd "$(dirname "$0")"

SDK="${SDK:-openwrt/sdk:mediatek-filogic-25.12.6}"
PKG=luci-app-autofines.ge
mkdir -p dist

docker run --rm \
	-v "$PWD/$PKG:/builder/package/$PKG:ro" \
	-v "$PWD/dist:/out" \
	"$SDK" sh -euc '
		# Фидов с ucode-модулями и LuCI в SDK нет, и defconfig предупреждает, что
		# зависимостей не существует. В .apk они всё равно записываются.
		make defconfig > /dev/null 2>&1
		make "package/$0/compile" "$@" > /tmp/build.log 2>&1 || {
			tail -40 /tmp/build.log
			exit 1
		}
		cp bin/packages/*/base/"$0"-*.apk /out/
	' "$PKG" "$@"

ls -l dist/
