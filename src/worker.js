/**
 * Cloudflare Worker: раз в сутки проверяет штрафы МВД Грузии по госномеру
 * и шлёт новые в Telegram. Cron-триггер Cloudflare, в отличие от GitHub Actions,
 * не отключается за неактивность.
 *
 * Состояние (какие протоколы уже отправлены) лежит в KV под ключом "state".
 */

import { fetchPlate, isPaid, paymentUrl } from "./police.js";
import { diffFines, renderEvent } from "./notify.js";
import { geocodeCached } from "./geocode.js";
import { callTelegram, sendMessage } from "./telegram.js";

const STATE_KEY = "state";

/** Подпись кнопки на постоянной клавиатуре бота. */
const CHECK_BUTTON = "🔄 Проверить штрафы";

/**
 * Клавиатура отваливается, если её не подтверждать: Telegram показывает её
 * ровно до тех пор, пока бот присылает сообщения с этой разметкой. Поэтому
 * прикладываем её к последнему сообщению каждой ручной проверки.
 */
const KEYBOARD = {
  keyboard: [[{ text: CHECK_BUTTON }]],
  resize_keyboard: true,
  is_persistent: true,
};

const flag = (value) => ["1", "true", "yes", "on"].includes(String(value ?? "").trim().toLowerCase());

// В wrangler.toml PLATES — массив, но в .dev.vars и в секретах бывает только
// строка, поэтому принимаем оба вида.
const parsePlates = (raw) =>
  (Array.isArray(raw) ? raw : String(raw ?? "").split(/[,\s]+/))
    .map((plate) => String(plate).trim().toUpperCase())
    .filter(Boolean);

/**
 * Какие из найденных протоколов на самом деле оплачены. Шлюз спрашиваем только
 * про те, что ещё не помечены оплаченными: обратно из оплаченных штраф не выходит.
 * Неуверенный ответ шлюза (null) считаем «не оплачен» — лучше лишняя тревога,
 * чем пропущенный штраф.
 */
async function findPaid(fines, plate, known) {
  const paid = new Set();
  for (const { protocolNo } of fines) {
    if (!protocolNo) continue;
    if (known[protocolNo]?.paid || (await isPaid(protocolNo, plate))) paid.add(protocolNo);
  }
  return paid;
}

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
  let totalUnpaid = 0;

  for (const plate of plates) {
    const fines = await fetchPlate(plate);
    const paid = await findPaid(fines, plate, state[plate] ?? {});
    totalUnpaid += fines.length - paid.size;

    const { events, known } = diffFines({
      fines,
      paid,
      known: state[plate] ?? {},
      today,
      remindDays,
      notifyAlways,
    });

    for (const event of events) {
      // Оплачивать нечего ни у оплаченного, ни у пропавшего из базы.
      const settled = event.type === "gone" || event.type === "paid";
      const payUrl = settled ? null : paymentUrl(event.protocolNo, plate);
      const coords = event.fine?.protocolPlace
        ? await geocodeCached(env.STATE, event.fine.protocolPlace)
        : null;
      await sendMessage(env, renderEvent(event, plate, coords), payUrl);
      report.sent++;
    }

    if (Object.keys(known).length > 0) state[plate] = known;
    else delete state[plate];

    report.plates[plate] = {
      found: fines.length,
      unpaid: fines.length - paid.size,
      events: events.map((e) => e.type),
    };
  }

  if (flag(env.NOTIFY_EMPTY) && totalUnpaid === 0) {
    await sendMessage(env, "✅ Проверка прошла: неоплаченных штрафов нет.");
    report.sent++;
  }

  await env.STATE.put(STATE_KEY, JSON.stringify(state));
  return report;
}

/**
 * Ручная проверка. В отличие от cron присылает все висящие штрафы, а не только
 * новые: кнопку жмут именно чтобы увидеть, что сейчас в системе и что можно
 * оплатить.
 */
async function reportManualRun(env) {
  try {
    const report = await runCheck(env, { notifyAlways: true });
    // Отвечаем сами, только если проверка промолчала: после карточек штрафов
    // «неоплаченных нет» — лишняя строка. Заодно это единственное сообщение,
    // к которому можно приложить клавиатуру: у карточек занято кнопкой оплаты.
    if (report.sent === 0) {
      await sendMessage(env, "✅ Неоплаченных штрафов нет.", null, KEYBOARD);
    }
  } catch (error) {
    await sendMessage(
      env,
      `⚠️ Проверка упала:\n<code>${String(error.message).slice(0, 500)}</code>`,
      null,
      KEYBOARD,
    ).catch(() => {});
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
          allowed_updates: ["message", "callback_query"],
        });
        // Команду видит только владелец: для всех остальных меню бота пустое.
        await callTelegram(env, "setMyCommands", {
          commands: [{ command: "check", description: "Проверить штрафы сейчас" }],
          scope: { type: "chat", chat_id: Number(env.TELEGRAM_CHAT_ID) },
        });
        await callTelegram(env, "setMyCommands", { commands: [], scope: { type: "default" } })
          .catch(() => {});
        await callTelegram(env, "setMyDescription", {
          description: "Личный бот. Посторонним не отвечает.",
        }).catch(() => {});
        // Клавиатура: живёт, пока Telegram её не свернёт.
        await callTelegram(env, "sendMessage", {
          chat_id: env.TELEGRAM_CHAT_ID,
          text: "Кнопка проверки готова.",
          reply_markup: KEYBOARD,
        });

        // Закреплённое сообщение с инлайн-кнопкой: висит вверху чата всегда.
        const pinned = await callTelegram(env, "sendMessage", {
          chat_id: env.TELEGRAM_CHAT_ID,
          text: "<b>Штрафы МВД Грузии</b>\nПроверка каждый день в 12:00 по Тбилиси.",
          parse_mode: "HTML",
          reply_markup: { inline_keyboard: [[{ text: CHECK_BUTTON, callback_data: "check" }]] },
        });
        await callTelegram(env, "pinChatMessage", {
          chat_id: env.TELEGRAM_CHAT_ID,
          message_id: pinned.message_id,
          disable_notification: true,
        }).catch(() => {});

        return Response.json({
          ok: true,
          webhook: `${url.origin}/telegram`,
          button: CHECK_BUTTON,
          pinnedMessageId: pinned.message_id,
        });
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
      const callback = update.callback_query;
      const message = callback?.message ?? update.message ?? {};
      const text = (callback?.data ?? update.message?.text ?? "").trim();
      // Отвечаем только своему чату: вебхук открыт наружу.
      const own = String(message.chat?.id ?? "") === String(env.TELEGRAM_CHAT_ID);
      const asked = ["check", CHECK_BUTTON, "/check"].includes(text) || text.startsWith("/check@");

      if (own && asked) {
        // Telegram ждёт быстрый 200, поэтому проверка уходит в фон.
        if (callback) {
          ctx.waitUntil(
            callTelegram(env, "answerCallbackQuery", {
              callback_query_id: callback.id,
              text: "Проверяю…",
            }).catch(() => {}),
          );
        }
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
