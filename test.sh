#!/bin/sh
# Тесты в Docker, на OpenWrt 25.12.6:
#   1. юнит-тесты на ucode (test/test_*.uc) прямо из исходников;
#   2. установка собранного dist/luci-app-autofines.ge-*.apk в чистый контейнер
#      с LuCI и включение службы — в браузере через страницу LuCI
#      (test/luci_ui.py), если есть образ Playwright, иначе через uci;
#   3. служба под пользователем autofines и её разговор с поддельным Bot API
#      (test/fake_telegram.py); police.ge при этом настоящий.
# Шаги 2–3 пропускаются, если пакет не собран (./build.sh).
set -eu
cd "$(dirname "$0")"

IMAGE="${IMAGE:-openwrt/rootfs:x86-64-25.12.6}"
# Образ большой, сам скрипт его не качает: docker pull, если нужен тест LuCI.
PLAYWRIGHT="${PLAYWRIGHT:-mcr.microsoft.com/playwright/python:v1.64.1-noble}"
RUN="autofines-test-$$"
NET="$RUN-net"

cleanup() {
	docker rm -f "$RUN" "$RUN-tg" > /dev/null 2>&1 || true
	docker network rm "$NET" > /dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$NET" > /dev/null
# Поддельный Telegram — заранее: иначе первый запрос бота упрётся в закрытый
# порт, и бот уйдёт в паузу перед повтором.
docker run -d --name "$RUN-tg" --network "$NET" -v "$PWD/test:/t:ro" python:3-alpine python3 /t/fake_telegram.py > /dev/null
docker run -d --name "$RUN" --network "$NET" -v "$PWD:/src:ro" "$IMAGE" /sbin/init > /dev/null
sleep 3
docker exec "$RUN" sh -c 'apk update > /dev/null && apk add ucode ucode-mod-fs ucode-mod-log ucode-mod-uci ucode-mod-uclient ucode-mod-uloop > /dev/null'

failed=0
for t in test/test_*.uc; do
	docker exec "$RUN" ucode -L '/src/luci-app-autofines.ge/files/ucode/*.uc' -L '/src/test/*.uc' "/src/$t" | grep -v '^✔' || failed=1
done

pkg=$(ls dist/luci-app-autofines.ge-*.apk 2> /dev/null | tail -1)
if [ -z "$pkg" ]; then
	echo "# пакет не собран — установку не проверяю (./build.sh)"
	exit $failed
fi

docker exec "$RUN" sh -euc "
	apk add --allow-untrusted /src/$pkg > /dev/null
	printf 'test\ntest\n' | passwd root > /dev/null 2>&1
"

if docker image inspect "$PLAYWRIGHT" > /dev/null 2>&1; then
	mkdir -p dist/screens
	docker run --rm --network "$NET" --ipc=host -v "$PWD/test:/t:ro" -v "$PWD/dist/screens:/out" "$PLAYWRIGHT" sh -c "
		pip install -q --break-system-packages playwright==1.64.1 > /dev/null 2>&1
		python3 /t/luci_ui.py http://$RUN test http://$RUN-tg:8081 /out
	" || failed=1
	echo "# скриншоты страницы — dist/screens/"
else
	echo "# нет образа $PLAYWRIGHT — страницу LuCI не проверяю, включаю службу через uci"
	docker exec "$RUN" sh -euc "
		uci set autofines.main.enabled=1
		uci set autofines.main.bot_token=123456789:fake-token-for-tests-only-0000000
		uci set autofines.main.chat_id=1001
		uci add_list autofines.main.plate=TEST000
		uci set autofines.main.api=http://$RUN-tg:8081
		uci commit autofines
		service autofines restart > /dev/null 2>&1
	"
fi

docker exec "$RUN" sh -euc "
	sleep 3
	pid=\$(ubus call service list '{\"name\":\"autofines\"}' | jsonfilter -e '@.autofines.instances.*.pid')
	[ \"\$(awk '/^Uid:/ { print \$2 }' /proc/\$pid/status)\" = \"\$(id -u autofines)\" ] || { echo '✖ служба не под пользователем autofines'; exit 1; }
	echo '✔ служба запущена procd под пользователем autofines'
" || failed=1

docker exec "$RUN-tg" python3 -c '
import json, sys, time, urllib.request
REPLY = "✅ Неоплаченных штрафов нет."
for _ in range(45):
    log = json.load(urllib.request.urlopen("http://127.0.0.1:8081/_log"))
    if any(e["payload"].get("text") == REPLY for e in log):
        break
    time.sleep(1)
methods = [e["method"] for e in log]
replies = [e["payload"] for e in log if e["payload"].get("text") == REPLY]
checks = [
    (methods[:2] == ["deleteWebhook", "getUpdates"], "сначала снимает вебхук, потом опрашивает"),
    ("answerCallbackQuery" in methods, "отвечает на нажатие инлайн-кнопки"),
    (len(replies) == 1, "одна ручная проверка на пачку нажатий, чужой чат проигнорирован"),
    (replies and replies[0]["chat_id"] == "1001", "ответ в свой чат"),
    (replies and "keyboard" in replies[0].get("reply_markup", {}), "с постоянной клавиатурой"),
]
for ok, name in checks:
    print(("✔ " if ok else "✖ ") + name)
sys.exit(0 if all(ok for ok, _ in checks) else 1)
' || failed=1

# То же событие, что шлёт rpcd после «Сохранить и применить» в LuCI. Последним:
# после перезапуска поддельный Telegram снова отдаст старые нажатия.
docker exec "$RUN" sh -euc "
	ipid() { ubus call service list '{\"name\":\"autofines\"}' | jsonfilter -e '@.autofines.instances.*.pid'; }
	pid=\$(ipid)
	uci set autofines.main.interval=45
	uci commit autofines
	ubus call service event '{\"type\":\"config.change\",\"data\":{\"package\":\"autofines\"}}'
	sleep 4
	[ \"\$(ipid)\" != \"\$pid\" ] && logread | grep -q 'запущен: .*раз в 45 мин' || { echo '✖ правка настроек не перезапустила бота'; exit 1; }
	echo '✔ правка настроек сразу перезапускает бота с новыми значениями'
" || failed=1

exit $failed
