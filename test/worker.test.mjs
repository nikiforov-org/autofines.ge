import { test } from "node:test";
import assert from "node:assert/strict";
import { runCheck } from "../src/worker.js";
import { paymentUrl } from "../src/police.js";

const FINE = {
  protocolAuto: "A354OC797",
  violationDate: "2026-08-19",
  protocolPlace: "ქ. ბათუმი ანწუხელიძის ქუჩა N83 (წრიული) 2",
  protocolLaw: "125-1-0",
  protocolLawDescription: "ასკ 125-ე მუხლის პირველი ნაწილი",
  protocolAmount: 50,
  lastDate: "2026-10-18",
  remainingDays: 50,
  protocolDate: "2026-08-19",
  protocolNo: "კვ000474970",
};

/** KV в памяти — тот же интерфейс, что у Cloudflare KV в объёме, который нужен воркеру. */
function memoryKv(initial = {}) {
  const store = new Map(Object.entries(initial));
  return {
    get: async (key, type) => {
      const raw = store.get(key);
      if (raw === undefined) return null;
      return type === "json" ? JSON.parse(raw) : raw;
    },
    put: async (key, value) => void store.set(key, value),
    dump: () => Object.fromEntries(store),
  };
}

/** Подменяет глобальный fetch: police.ge отвечает заготовкой, Telegram — копится. */
function stubFetch({ fines = [FINE], telegramStatus = 200 } = {}) {
  const sent = [];
  const original = globalThis.fetch;

  globalThis.fetch = async (url, init = {}) => {
    const target = String(url);

    if (target.includes("protocols/searchByAuto")) {
      const body = new URLSearchParams(init.body ?? "");
      assert.equal(body.get("csrf_token"), "a".repeat(32), "csrf должен уехать на сервер");
      assert.ok(init.headers.Cookie?.includes("PHPSESSID=zzz"), "cookie сессии должна уехать");
      const page = Number(body.get("firstResult"));
      const results = page === 0 ? fines : [];
      return new Response(JSON.stringify({ success: true, data: { count: results.length, results } }));
    }

    if (target.includes("police.ge/protocol/index.php")) {
      return new Response(`<input type="hidden" name="csrf_token" value="${"a".repeat(32)}">`, {
        headers: { "set-cookie": "PHPSESSID=zzz; path=/; HttpOnly" },
      });
    }

    if (target.includes("nominatim.openstreetmap.org")) {
      // Nominatim отдаёт улицу кусками — воркер должен усреднить их в одну точку.
      return new Response(JSON.stringify([
        { lat: "41.6100000", lon: "41.6000000", display_name: "გიორგი ანწუხელიძის ქუჩა, ბათუმი",
          address: { road: "გიორგი ანწუხელიძის ქუჩა" } },
        { lat: "41.6200000", lon: "41.6100000", display_name: "გიორგი ანწუხელიძის ქუჩა, ბათუმი",
          address: { road: "გიორგი ანწუხელიძის ქუჩა" } },
        { lat: "41.9999999", lon: "41.9999999", display_name: "სხვა ქუჩა",
          address: { road: "სხვა ქუჩა" } },
      ]));
    }

    if (target.includes("api.telegram.org")) {
      sent.push(JSON.parse(init.body));
      return new Response(JSON.stringify({ ok: telegramStatus === 200 }), { status: telegramStatus });
    }

    throw new Error(`неожиданный запрос: ${target}`);
  };

  return { sent, restore: () => void (globalThis.fetch = original) };
}

const env = (STATE, extra = {}) => ({
  STATE,
  PLATES: "a354oc797",
  TELEGRAM_BOT_TOKEN: "token",
  TELEGRAM_CHAT_ID: "chat",
  REMIND_DAYS: "7",
  ...extra,
});

test("полный проход: находит штраф, шлёт карточку с кнопкой, пишет состояние", async () => {
  const kv = memoryKv();
  const { sent, restore } = stubFetch();
  try {
    const report = await runCheck(env(kv));
    assert.equal(report.sent, 1);
    assert.deepEqual(report.plates.A354OC797, { found: 1, events: ["new"] });

    assert.equal(sent.length, 1);
    assert.match(sent[0].text, /<b>🚨 Новый штраф<\/b> — <code>A354OC797<\/code>/);
    assert.equal(sent[0].parse_mode, "HTML");
    assert.equal(
      sent[0].reply_markup.inline_keyboard[0][0].url,
      paymentUrl("კვ000474970", "A354OC797"),
    );

    assert.match(
      sent[0].text,
      /href="https:\/\/www\.google\.com\/maps\/search\/\?api=1&query=41\.615%2C41\.605"/,
      "в ссылку уходит центр сегментов нужной улицы, чужая улица отброшена",
    );

    const state = JSON.parse(kv.dump().state);
    assert.ok(state.A354OC797["კვ000474970"], "протокол должен запомниться");
    assert.ok(
      kv.dump()["geo:ქ. ბათუმი ანწუხელიძის ქუჩა N83"],
      "координаты кэшируются, чтобы не ходить в Nominatim каждый раз",
    );
  } finally {
    restore();
  }
});

test("второй запуск по тем же данным молчит", async () => {
  const kv = memoryKv();
  let stub = stubFetch();
  try {
    await runCheck(env(kv));
  } finally {
    stub.restore();
  }

  stub = stubFetch();
  try {
    const report = await runCheck(env(kv));
    assert.equal(report.sent, 0);
    assert.equal(stub.sent.length, 0);
  } finally {
    stub.restore();
  }
});

test("госномер нормализуется в верхний регистр", async () => {
  const kv = memoryKv();
  const { restore } = stubFetch();
  try {
    const report = await runCheck(env(kv, { PLATES: "  a354oc797 " }));
    assert.ok(report.plates.A354OC797);
  } finally {
    restore();
  }
});

test("PLATES принимается массивом — так он лежит в wrangler.toml", async () => {
  const kv = memoryKv();
  const { restore } = stubFetch();
  try {
    const report = await runCheck(env(kv, { PLATES: ["a354oc797", " B123CD456 "] }));
    assert.deepEqual(Object.keys(report.plates), ["A354OC797", "B123CD456"]);
    assert.equal(report.sent, 2, "по одному уведомлению на номер");
  } finally {
    restore();
  }
});

test("пустой PLATES — внятная ошибка, а не тихий простой", async () => {
  const kv = memoryKv();
  await assert.rejects(runCheck(env(kv, { PLATES: [] })), /не задан PLATES/);
  await assert.rejects(runCheck(env(kv, { PLATES: "  " })), /не задан PLATES/);
});

test("NOTIFY_EMPTY даёт пульс, когда штрафов нет", async () => {
  const kv = memoryKv();
  const { sent, restore } = stubFetch({ fines: [] });
  try {
    await runCheck(env(kv, { NOTIFY_EMPTY: "1" }));
    assert.equal(sent.length, 1);
    assert.match(sent[0].text, /неоплаченных штрафов нет/);
  } finally {
    restore();
  }
});

test("Telegram с кнопкой не принял — уходит второй попыткой со ссылкой в тексте", async () => {
  const kv = memoryKv();
  const { sent, restore } = stubFetch({ telegramStatus: 400 });
  try {
    await assert.rejects(runCheck(env(kv)), /Telegram отклонил/);
    assert.equal(sent.length, 2, "две попытки по одному штрафу");
    assert.ok(sent[0].reply_markup, "первая — с кнопкой");
    assert.equal(sent[1].reply_markup, undefined, "вторая — без кнопки, ссылка в тексте");
    assert.match(sent[1].text, /💳 Оплатить</);
  } finally {
    restore();
  }
});

test("падение проверки уходит отдельным сообщением в Telegram", async () => {
  const kv = memoryKv();
  const sent = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    if (String(url).includes("api.telegram.org")) {
      sent.push(JSON.parse(init.body));
      return new Response("{}", { status: 200 });
    }
    return new Response("<html>без токена</html>");
  };
  try {
    const { default: worker } = await import("../src/worker.js");
    const request = new Request("https://x/run?key=s3cret");
    const response = await worker.fetch(request, env(kv, { TRIGGER_SECRET: "s3cret" }));
    assert.equal(response.status, 500);
    assert.match(sent.at(-1).text, /Проверка штрафов упала/);
    assert.match(sent.at(-1).text, /csrf_token/);
  } finally {
    globalThis.fetch = original;
  }
});

test("ручка /run закрыта без правильного секрета", async () => {
  const { default: worker } = await import("../src/worker.js");
  const kv = memoryKv();
  const withSecret = env(kv, { TRIGGER_SECRET: "s3cret" });

  assert.equal((await worker.fetch(new Request("https://x/run"), withSecret)).status, 404);
  assert.equal((await worker.fetch(new Request("https://x/run?key=nope"), withSecret)).status, 404);
  // Без TRIGGER_SECRET ручка выключена совсем, даже с пустым key.
  assert.equal((await worker.fetch(new Request("https://x/run?key="), env(kv))).status, 404);
});
