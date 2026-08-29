/**
 * Cloudflare Worker: раз в сутки проверяет штрафы МВД Грузии по госномеру
 * и шлёт новые в Telegram. Cron-триггер Cloudflare, в отличие от GitHub Actions,
 * не отключается за неактивность.
 *
 * Состояние (какие протоколы уже отправлены) лежит в KV под ключом "state".
 */

import { fetchPlate, paymentUrl } from "./police.js";
import { diffFines, renderEvent } from "./notify.js";
import { sendMessage } from "./telegram.js";

const STATE_KEY = "state";

const flag = (value) => ["1", "true", "yes", "on"].includes(String(value ?? "").trim().toLowerCase());

const parsePlates = (raw) =>
  String(raw ?? "")
    .split(/[,\s]+/)
    .filter(Boolean)
    .map((plate) => plate.toUpperCase());

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
      await sendMessage(env, renderEvent(event, plate), payUrl);
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

  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/") {
      return new Response("autofines.ge — проверка штрафов МВД Грузии. Работает по cron.\n");
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
