import { test } from "node:test";
import assert from "node:assert/strict";
import { diffFines, mapsQuery, mapsUrl, renderEvent } from "../src/notify.js";

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

const TODAY = "2026-08-29";
const base = { today: TODAY, remindDays: 7 };

test("новый протокол даёт событие new и попадает в состояние", () => {
  const { events, known } = diffFines({ ...base, fines: [FINE], known: {} });
  assert.deepEqual(events.map((e) => e.type), ["new"]);
  assert.equal(known["კვ000474970"].firstSeen, TODAY);
  assert.equal(known["კვ000474970"].amount, 50);
});

test("уже известный протокол молчит", () => {
  const first = diffFines({ ...base, fines: [FINE], known: {} });
  const second = diffFines({ ...base, fines: [FINE], known: first.known });
  assert.deepEqual(second.events, []);
});

test("напоминание срабатывает у дедлайна и не дублируется в тот же день", () => {
  const soon = { ...FINE, remainingDays: 5 };
  const first = diffFines({ ...base, fines: [FINE], known: {} });
  const remind = diffFines({ ...base, fines: [soon], known: first.known });
  assert.deepEqual(remind.events.map((e) => e.type), ["remind"]);
  assert.equal(remind.known["კვ000474970"].remindedAt, TODAY);

  const again = diffFines({ ...base, fines: [soon], known: remind.known });
  assert.deepEqual(again.events, []);
});

test("напоминание выключено при remindDays = 0", () => {
  const first = diffFines({ ...base, fines: [FINE], known: {} });
  const { events } = diffFines({
    ...base,
    remindDays: 0,
    fines: [{ ...FINE, remainingDays: 1 }],
    known: first.known,
  });
  assert.deepEqual(events, []);
});

test("notifyAlways повторяет известный штраф", () => {
  const first = diffFines({ ...base, fines: [FINE], known: {} });
  const { events } = diffFines({ ...base, fines: [FINE], known: first.known, notifyAlways: true });
  assert.deepEqual(events.map((e) => e.type), ["repeat"]);
});

test("исчезнувший протокол даёт gone и убирается из состояния", () => {
  const first = diffFines({ ...base, fines: [FINE], known: {} });
  const { events, known } = diffFines({ ...base, fines: [], known: first.known });
  assert.deepEqual(events.map((e) => e.type), ["gone"]);
  assert.deepEqual(known, {});
});

test("удвоение штрафа за просрочку обновляет сумму без нового уведомления", () => {
  const first = diffFines({ ...base, fines: [FINE], known: {} });
  const doubled = { ...FINE, protocolAmount: 100, lastDate: "2026-11-17", remainingDays: 80 };
  const { events, known } = diffFines({ ...base, fines: [doubled], known: first.known });
  assert.deepEqual(events, []);
  assert.equal(known["კვ000474970"].amount, 100);
  assert.equal(known["კვ000474970"].lastDate, "2026-11-17");
});

test("карточка штрафа собирается с русской статьёй и склонением дней", () => {
  const text = renderEvent({ type: "new", protocolNo: FINE.protocolNo, fine: FINE }, "A354OC797");
  assert.match(text, /<b>🚨 Новый штраф<\/b> — <code>A354OC797<\/code>/);
  assert.match(text, /Превышение скорости на 15–30 км\/ч/);
  assert.match(text, /Дата: 19\.08\.2026/);
  assert.match(text, /Сумма: <b>50 ₾<\/b>/);
  assert.match(text, /Оплатить до: 18\.10\.2026 \(осталось 50 дней\)/);

  const one = renderEvent(
    { type: "new", protocolNo: FINE.protocolNo, fine: { ...FINE, remainingDays: 1 } },
    "A354OC797",
  );
  assert.match(one, /осталось 1 день\)/);
});

test("адрес нарушения становится ссылкой в карты", () => {
  const text = renderEvent({ type: "new", protocolNo: FINE.protocolNo, fine: FINE }, "A354OC797");
  const href = /Место: <a href="([^"]+)">/.exec(text)?.[1];
  assert.ok(href, "адрес должен быть ссылкой");
  const query = new URL(href).searchParams.get("query");
  assert.equal(query, "ანწუხელიძის ქუჩა N83, ბათუმი, Georgia");
});

test("с координатами ссылка ведёт прямо в точку", () => {
  const text = renderEvent(
    { type: "new", protocolNo: FINE.protocolNo, fine: FINE },
    "A354OC797",
    { lat: 41.6148394, lon: 41.5959743 },
  );
  const href = /Место: <a href="([^"]+)">/.exec(text)[1];
  assert.equal(new URL(href).searchParams.get("query"), "41.6148394,41.5959743");
});

test("адрес нормализуется под геокодер", () => {
  // «(წრიული) 2» — тип и номер камеры, для карты это мусор;
  // «ქ. ბათუმი» впереди улицы геокодер не понимает.
  assert.equal(
    mapsQuery("ქ. ბათუმი ანწუხელიძის ქუჩა N83 (წრიული) 2"),
    "ანწუხელიძის ქუჩა N83, ბათუმი, Georgia",
  );
  // Без префикса «ქ.» строку оставляем как есть, только добавляем страну.
  assert.equal(mapsQuery("Rustaveli Ave 12"), "Rustaveli Ave 12, Georgia");
  // Страна уже названа — не дублируем.
  assert.equal(mapsQuery("Tbilisi, Georgia"), "Tbilisi, Georgia");
});

test("адреса нет — ссылки тоже нет, прочерк", () => {
  const text = renderEvent(
    { type: "new", protocolNo: "X", fine: { ...FINE, protocolPlace: null } },
    "A1",
  );
  assert.match(text, /Место: —/);
});

test("HTML в данных экранируется", () => {
  const text = renderEvent(
    { type: "new", protocolNo: "X", fine: { ...FINE, protocolPlace: "<b>боом</b>" } },
    "A1",
  );
  assert.match(text, /&lt;b&gt;боом&lt;\/b&gt;/);
});
