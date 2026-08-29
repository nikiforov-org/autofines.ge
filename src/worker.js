/**
 * Cloudflare Worker: раз в сутки проверяет штрафы МВД Грузии по госномеру
 * и шлёт новые в Telegram. Cron-триггер Cloudflare, в отличие от GitHub Actions,
 * не отключается за неактивность.
 *
 * Состояние (какие протоколы уже отправлены) лежит в KV под ключом "state".
 */

import { fetchPlate, paymentUrl } from "./police.js";
import { diffFines, renderEvent } from "./notify.js";
import { geocodeCached } from "./geocode.js";
import { callTelegram, sendMessage } from "./telegram.js";

const STATE_KEY = "state";

/** Подпись кнопки на постоянной клавиатуре бота. */
const CHECK_BUTTON = "🔄 Проверить штрафы";

const flag = (value) => ["1", "true", "yes", "on"].includes(String(value ?? "").trim().toLowerCase());

// В wrangler.toml PLATES — массив, но в .dev.vars и в секретах бывает только
// строка, поэтому принимаем оба вида.
const parsePlates = (raw) =>
  (Array.isArray(raw) ? raw : String(raw ?? "").split(/[,\s]+/))
    .map((plate) => String(plate).trim().toUpperCase())
    .filter(Boolean);

/** Один проход проверки. Возвращает короткий отчёт для логов и ручного запуска. */
export async function runCheck(env, overrides = {}) {
  const plates = parsePlates(env.PLATES);
  if (plates.length === 0) throw new Error("не задан PLATES");
  if (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_CHAT_ID) {
    throw new Error("не заданы TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID");
  }

  const remindDays = Number(env.REMIND_DAYS ?? 7) || 0;
  const notifyAlways = overrides.notifyAlways ?? flag(env.NOTIFY_ALWAYS);
  const today = new Date().toISOString().slice(0, 10);

  const state = (await env.STATE.get(STATE_KEY, "json")) ?? {};
  const report = { today, plates: {}, sent: 0 };
  let totalFines = 0;

  for (const plate of plates) {
    const fines = await fetchPlate(plate);
    totalFines += fines.length;

    const { events, known } = diffFines({
      fines,
      known: state[plate] ?? {},
      today,
      remindDays,
      notifyAlways,
    });

    for (const event of events) {
      const payUrl = event.type === "gone" ? null : paymentUrl(event.protocolNo, plate);
      const coords = event.fine?.protocolPlace
        ? await geocodeCached(env.STATE, event.fine.protocolPlace)
        : null;
      await sendMessage(env, renderEvent(event, plate, coords), payUrl);
      report.sent++;
    }

    if (Object.keys(known).length > 0) state[plate] = known;
    else delete state[plate];

    report.plates[plate] = { found: fines.length, events: events.map((e) => e.type) };
  }

  if (flag(env.NOTIFY_EMPTY) && totalFines === 0) {
    await sendMessage(env, "✅ Проверка прошла: неоплаченных штрафов нет.");
    report.sent++;
  }

  await env.STATE.put(STATE_KEY, JSON.stringify(state));
  return report;
}

/** Короткий итог ручной проверки — чтобы нажатие кнопки не оставалось без ответа. */
async function reportManualRun(env) {
  try {
    const report = await runCheck(env);
    const found = Object.values(report.plates).reduce((sum, p) => sum + p.found, 0);
    if (report.sent === 0) {
      const text = found === 0
        ? "✅ Проверил: неоплаченных штрафов нет."
        : `✅ Проверил: штрафов ${found}, новых нет.`;
      await sendMessage(env, text);
    }
  } catch (error) {
    await sendMessage(env, `⚠️ Проверка упала:\n<code>${String(error.message).slice(0, 500)}</code>`)
      .catch(() => {});
  }
}

/**
 * У Cloudflare нет писем о падении cron, поэтому об ошибке сообщаем сами.
 * Если не удалось даже это — пусть падает, останется в логах Worker'а.
 */
async function runAndReport(env, overrides) {
  try {
    return await runCheck(env, overrides);
  } catch (error) {
    const text = `⚠️ Проверка штрафов упала:\n<code>${String(error.message).slice(0, 500)}</code>`;
    await sendMessage(env, text).catch(() => {});
    throw error;
  }
}

export default {
  async scheduled(event, env, ctx) {
    ctx.waitUntil(runAndReport(env));
  },

  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/") {
      return new Response("autofines.ge — проверка штрафов МВД Грузии. Работает по cron.\n");
    }

    // Разовая настройка: вешает вебхук, команду /check и постоянную клавиатуру.
    if (url.pathname === "/setup") {
      if (!env.TRIGGER_SECRET || url.searchParams.get("key") !== env.TRIGGER_SECRET) {
        return new Response("not found\n", { status: 404 });
      }
      try {
        await callTelegram(env, "setWebhook", {
          url: `${url.origin}/telegram`,
          secret_token: env.TRIGGER_SECRET,
          allowed_updates: ["message"],
        });
        await callTelegram(env, "setMyCommands", {
          commands: [{ command: "check", description: "Проверить штрафы сейчас" }],
        });
        await callTelegram(env, "sendMessage", {
          chat_id: env.TELEGRAM_CHAT_ID,
          text: "Кнопка проверки готова.",
          reply_markup: {
            keyboard: [[{ text: CHECK_BUTTON }]],
            resize_keyboard: true,
            is_persistent: true,
          },
        });
        return Response.json({ ok: true, webhook: `${url.origin}/telegram`, button: CHECK_BUTTON });
      } catch (error) {
        return Response.json({ error: String(error.message) }, { status: 500 });
      }
    }

    // Вебхук Telegram. Подлинность — по секретному заголовку, который задаёт сам Telegram.
    if (url.pathname === "/telegram" && request.method === "POST") {
      if (
        !env.TRIGGER_SECRET ||
        request.headers.get("X-Telegram-Bot-Api-Secret-Token") !== env.TRIGGER_SECRET
      ) {
        return new Response("not found\n", { status: 404 });
      }

      const update = await request.json().catch(() => ({}));
      const message = update.message ?? {};
      const text = (message.text ?? "").trim();
      // Отвечаем только своему чату: вебхук открыт наружу.
      const own = String(message.chat?.id ?? "") === String(env.TELEGRAM_CHAT_ID);

      if (own && (text === CHECK_BUTTON || text === "/check" || text.startsWith("/check@"))) {
        // Telegram ждёт быстрый 200, поэтому проверка уходит в фон.
        ctx.waitUntil(reportManualRun(env));
      }
      return new Response("ok\n");
    }

    if (url.pathname === "/run") {
      // Ручной запуск закрыт секретом; без TRIGGER_SECRET ручка выключена совсем.
      if (!env.TRIGGER_SECRET || url.searchParams.get("key") !== env.TRIGGER_SECRET) {
        return new Response("not found\n", { status: 404 });
      }
      try {
        const report = await runAndReport(env, {
          notifyAlways: url.searchParams.has("always") ? true : undefined,
        });
        return Response.json(report);
      } catch (error) {
        return Response.json({ error: String(error.message) }, { status: 500 });
      }
    }

    return new Response("not found\n", { status: 404 });
  },
};
