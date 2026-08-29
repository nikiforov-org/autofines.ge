/** Отправка в Telegram. Ссылку на оплату кладём кнопкой, с откатом в текст. */

const API = (token, method) => `https://api.telegram.org/bot${token}/${method}`;

export async function sendMessage(env, text, payUrl = null) {
  const base = {
    chat_id: env.TELEGRAM_CHAT_ID,
    text,
    parse_mode: "HTML",
    disable_web_page_preview: true,
  };

  const attempts = payUrl
    ? [
        { ...base, reply_markup: { inline_keyboard: [[{ text: "💳 Оплатить", url: payUrl }]] } },
        // Telegram придирчив к ссылкам в кнопках: не принял — уводим её в текст.
        { ...base, text: `${text}\n\n<a href="${payUrl}">💳 Оплатить онлайн</a>` },
      ]
    : [base];

  let lastError = "";
  for (const payload of attempts) {
    const response = await fetch(API(env.TELEGRAM_BOT_TOKEN, "sendMessage"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (response.ok) return;
    lastError = `${response.status} ${(await response.text()).slice(0, 300)}`;
  }
  throw new Error(`Telegram отклонил сообщение: ${lastError}`);
}
