"""Страница LuCI в настоящем браузере: вход, валидация, «Сохранить и применить»,
состояние службы и кнопка «Настроить чат». Скриншоты — в каталог из аргумента.

    python3 luci_ui.py http://<роутер> <пароль root> <адрес Bot API> <каталог>
"""
import sys
import time

from playwright.sync_api import expect, sync_playwright

base, password, api, out = sys.argv[1:5]
page_url = f"{base}/cgi-bin/luci/admin/services/autofines"
results = []


def check(name, condition):
    results.append((bool(condition), name))
    print(("✔ " if condition else "✖ ") + name, flush=True)


def field(name):
    return page.locator(f"#cbi-autofines-main-{name}")


def step(name, action):
    """Шаг сценария; упал — скриншот страницы в этот момент, дальше не идём."""
    try:
        action()
        check(name, True)
    except Exception as e:
        page.screenshot(path=f"{out}/fail.png", full_page=True)
        check(f"{name}: {str(e).splitlines()[0]}", False)
        raise SystemExit(1)


with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1280, "height": 900}, locale="ru-RU")
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))

    def open_page():
        page.goto(page_url)
        page.fill("input[name=luci_username]", "root")
        page.fill("input[name=luci_password]", password)
        page.keyboard.press("Enter")
        expect(page.get_by_role("heading", name="Штрафы МВД Грузии")).to_be_visible(timeout=20000)
        expect(page.get_by_text("выключена", exact=True)).to_be_visible()
        page.screenshot(path=f"{out}/1-initial.png", full_page=True)
        # Страница входа сама дёргает uci и file без сессии и получает отказ —
        # это шум LuCI, а не страницы autofines.
        errors.clear()

    step("страница открылась, служба выключена", open_page)

    field("enabled").locator("input[type=checkbox]").check()
    field("bot_token").locator("input").fill("abc")
    field("chat_id").locator("input").fill("12x")
    field("chat_id").locator("input").press("Tab")
    time.sleep(0.5)
    check("кривой токен подсвечен", field("bot_token").locator(".cbi-input-invalid").count() > 0)
    check("кривой ID чата подсвечен", field("chat_id").locator(".cbi-input-invalid").count() > 0)
    page.screenshot(path=f"{out}/2-invalid.png", full_page=True)

    def no_plate():
        field("bot_token").locator("input").fill("123456789:fake-token-for-tests-only-0000000")
        field("chat_id").locator("input").fill("1001")
        page.locator(".cbi-page-actions .cbi-button-apply").first.click()
        expect(page.get_by_text("Добавьте хотя бы один госномер")).to_be_visible(timeout=10000)
        page.screenshot(path=f"{out}/3-no-plate.png", full_page=True)
        page.get_by_role("button", name="Dismiss").click()
        expect(page.get_by_text("выключена", exact=True)).to_be_visible()
        # Отказ сохранить LuCI показывает окном, а в консоль он всё равно уходит
        # необработанным reject — так LuCI ведёт себя с любой ошибкой сохранения.
        errors.clear()

    step("включить без госномера не даёт: окно с объяснением, служба не тронута", no_plate)

    def fill_and_apply():
        # Заведомо несуществующий номер: police.ge настоящий, чужой номер дёргать незачем.
        field("plate").locator("input").last.fill("TEST000")
        field("plate").locator("input").last.press("Enter")
        field("interval").locator(".cbi-dropdown").click()
        field("interval").locator("li[data-value='15']").first.click()
        page.get_by_text("Дополнительно", exact=True).click()
        field("api").locator("input").fill(api)
        page.locator(".cbi-page-actions .cbi-button-apply").first.click()
        expect(page.get_by_text("работает", exact=True)).to_be_visible(timeout=60000)

    step("«Сохранить и применить» запустил службу", fill_and_apply)

    def status_updates():
        expect(page.get_by_text("на связи", exact=True)).to_be_visible(timeout=60000)
        expect(page.get_by_text("(по кнопке)")).to_be_visible(timeout=60000)
        page.screenshot(path=f"{out}/4-applied.png", full_page=True)

    step("состояние обновилось: Telegram на связи, нажатие кнопки обработано", status_updates)

    def setup_chat():
        page.get_by_text("Основное", exact=True).click()
        page.get_by_role("button", name="Настроить чат").click()
        expect(page.get_by_text("В чат отправлены клавиатура")).to_be_visible(timeout=30000)
        page.screenshot(path=f"{out}/5-setup.png", full_page=True)

    step("«Настроить чат» отработал", setup_chat)

    check("в консоли браузера нет ошибок JS", not errors)
    for e in errors:
        print("   ", e)
    browser.close()

sys.exit(0 if all(ok for ok, _ in results) else 1)
