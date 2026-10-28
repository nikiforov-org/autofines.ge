#!/bin/sh
# Собирает пакеты autofines и luci-app-autofines в SDK OpenWrt 25.12.6 для
# mediatek/filogic — target роутера RT-AX59U. Бинарников в них нет (noarch), так
# что они ставятся на любой OpenWrt 25.12. Результат — dist/*.apk.
#
# Аргументы уходят в make как есть: ./build.sh PKG_RELEASE=2
set -eu
cd "$(dirname "$0")"

SDK="${SDK:-openwrt/sdk:mediatek-filogic-25.12.6}"
mkdir -p dist

docker run --rm \
	-v "$PWD/autofines:/builder/package/autofines:ro" \
	-v "$PWD/luci-app-autofines:/builder/package/luci-app-autofines:ro" \
	-v "$PWD/dist:/out" \
	"$SDK" sh -euc '
		# Фидов с ucode-модулями и LuCI в SDK нет, и defconfig предупреждает, что
		# зависимостей не существует. В .apk они всё равно записываются.
		make defconfig > /dev/null 2>&1
		for pkg in autofines luci-app-autofines; do
			make "package/$pkg/compile" "$@" > /tmp/build.log 2>&1 || {
				tail -40 /tmp/build.log
				exit 1
			}
		done
		cp bin/packages/*/base/*.apk /out/
	' sh "$@"

ls -l dist/
