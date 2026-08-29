/**
 * Чистая логика уведомлений: что делать с найденными протоколами и как их
 * показать. Без сети и без KV — поэтому целиком покрывается тестами.
 */

// Сервис отдаёт название статьи только по-грузински. Ключ — поле protocolLaw;
// незнакомый код уходит в сообщение как есть, оттуда его и можно сюда добавить.
export const ARTICLES = {
  "125-1-0": "Превышение скорости на 15–30 км/ч",
};

// Сервис 1205 «Patrol Fine», режим «Payment with bill and vehicle state number»:
// просит только номер квитанции и госномер, авторизация не нужна, комиссии нет.
export const TBC_PAY_URL = "https://tbcpay.ge/en/services/jarimebi/patrulis-jarima";

/**
 * Адрес в базе МВД выглядит как «ქ. <город> <улица> N<дом> (<тип камеры>) <номер>».
 * Геокодеры такую строку не берут: мешает префикс «ქ.», хвост с камерой и порядок,
 * в котором город идёт раньше улицы. Приводим к виду «улица, город, Georgia» —
 * в такой форме адрес находится.
 */
export function mapsQuery(place) {
  const cleaned = String(place ?? "")
    .replace(/\s*\([^)]*\)\s*\d*\s*$/, "")
    .replace(/\s+/g, " ")
    .trim();
  const parts = /^ქ\.\s*(\S+)\s+(.+)$/.exec(cleaned);
  const address = parts ? `${parts[2]}, ${parts[1]}` : cleaned;
  return /საქართველო|georgia/i.test(address) ? address : `${address}, Georgia`;
}

/**
 * Адрес нарушения — ссылкой в карты. С координатами пин ставится точно;
 * без них (геокодер не нашёл) остаётся текстовый поиск, который может промахнуться.
 */
export function mapsUrl(place, coords = null) {
  const query = coords ? `${coords.lat},${coords.lon}` : mapsQuery(place);
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(query)}`;
}

const TITLES = {
  new: "🚨 Новый штраф",
  repeat: "🔁 Штраф не оплачен",
  remind: "⏰ Скоро истекает срок оплаты",
};

/**
 * Сравнивает свежую выдачу с запомненным состоянием.
 * @returns {{events: Array, known: object}} known — уже обновлённое состояние
 */
export function diffFines({ fines, known = {}, today, remindDays = 0, notifyAlways = false }) {
  const current = new Map(fines.filter((f) => f.protocolNo).map((f) => [f.protocolNo, f]));
  const next = { ...known };
  const events = [];

  for (const [protocolNo, fine] of current) {
    const record = next[protocolNo];
    const left = fine.remainingDays;

    if (!record) {
      events.push({ type: "new", protocolNo, fine });
      next[protocolNo] = { firstSeen: today, remindedAt: null };
    } else if (notifyAlways) {
      events.push({ type: "repeat", protocolNo, fine });
    } else if (
      remindDays > 0 &&
      Number.isInteger(left) &&
      left <= remindDays &&
      record.remindedAt !== today
    ) {
      events.push({ type: "remind", protocolNo, fine });
      next[protocolNo] = { ...record, remindedAt: today };
    }

    // Сумма и срок меняются, когда штраф удваивается за просрочку.
    next[protocolNo] = {
      ...next[protocolNo],
      amount: fine.protocolAmount ?? null,
      lastDate: fine.lastDate ?? null,
    };
  }

  for (const protocolNo of Object.keys(next)) {
    if (!current.has(protocolNo)) {
      events.push({ type: "gone", protocolNo });
      delete next[protocolNo];
    }
  }

  return { events, known: next };
}

const escapeHtml = (value) =>
  String(value ?? "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);

function ruDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(value ?? "");
  return match ? `${match[3]}.${match[2]}.${match[1]}` : (value || "—");
}

function pluralDays(count) {
  const n = Math.abs(count);
  if (n % 10 === 1 && n % 100 !== 11) return "день";
  if (n % 10 >= 2 && n % 10 <= 4 && !(n % 100 >= 12 && n % 100 <= 14)) return "дня";
  return "дней";
}

export function renderEvent(event, plate, coords = null) {
  if (event.type === "gone") {
    return (
      `✅ Штраф <code>${escapeHtml(event.protocolNo)}</code> по <b>${escapeHtml(plate)}</b> ` +
      "пропал из базы МВД — скорее всего, оплачен."
    );
  }

  const fine = event.fine;
  const georgian = escapeHtml(fine.protocolLawDescription || fine.protocolLaw || "—");
  const russian = ARTICLES[fine.protocolLaw ?? ""];
  const law = russian ? `${escapeHtml(russian)}\n<i>${georgian}</i>` : georgian;

  const place = fine.protocolPlace
    ? `<a href="${mapsUrl(fine.protocolPlace, coords)}">${escapeHtml(fine.protocolPlace)}</a>`
    : "—";

  const lines = [
    // Номер протокола и госномер — в <code>: в Telegram они копируются одним тапом,
    // а форма TBC Pay просит ровно эти два поля.
    `<b>${TITLES[event.type]}</b> — <code>${escapeHtml(plate)}</code>`,
    "",
    `Протокол: <code>${escapeHtml(fine.protocolNo)}</code>`,
    `Дата: ${ruDate(fine.violationDate || fine.protocolDate)}`,
    `Место: ${place}`,
    `Статья: ${law}`,
    `Сумма: <b>${escapeHtml(fine.protocolAmount ?? "—")} ₾</b>`,
  ];

  if (fine.lastDate) {
    const left = fine.remainingDays;
    const tail = Number.isInteger(left) ? ` (осталось ${left} ${pluralDays(left)})` : "";
    lines.push(`Оплатить до: ${ruDate(fine.lastDate)}${tail}`);
  }

  lines.push("", `<i>Не открылось — <a href="${TBC_PAY_URL}">TBC Pay</a>, режим «bill and vehicle state number».</i>`);

  return lines.join("\n");
}
