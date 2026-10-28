'use strict';

// Чистая логика уведомлений: что делать с найденными протоколами и как их
// показать. Без сети и без состояния — поэтому целиком покрывается тестами.

import { uri_encode } from 'autofines.http';
import { escape_html } from 'autofines.text';

// Сервис отдаёт название статьи только по-грузински. Ключ — поле protocolLaw;
// незнакомый код уходит в сообщение как есть, оттуда его и можно сюда добавить.
const ARTICLES = {
	'125-1-0': 'Превышение скорости на 15–30 км/ч',
};

// Адрес в базе МВД выглядит как «ქ. <город> <улица> N<дом> (<тип камеры>) <номер>».
// Геокодеры такую строку не берут: мешает префикс «ქ.», хвост с камерой и порядок,
// в котором город идёт раньше улицы. Приводим к виду «улица, город, Georgia» —
// в такой форме адрес находится.
function maps_query(place) {
	let cleaned = trim(replace(replace(`${place ?? ''}`, /\s*\([^)]*\)\s*\d*\s*$/, ''), /\s+/g, ' '));
	let parts = match(cleaned, /^ქ\.\s*(\S+)\s+(.+)$/);
	let address = parts ? `${parts[2]}, ${parts[1]}` : cleaned;
	return match(address, /საქართველო|georgia/i) ? address : `${address}, Georgia`;
}

// Адрес нарушения — ссылкой в карты. С координатами пин ставится точно;
// без них (геокодер не нашёл) остаётся текстовый поиск, который может промахнуться.
function maps_url(place, coords) {
	let query = coords ? `${coords.lat},${coords.lon}` : maps_query(place);
	return 'https://www.google.com/maps/search/?api=1&query=' + uri_encode(query);
}

const TITLES = {
	'new': '🚨 Новый штраф',
	'repeat': '🔁 Штраф не оплачен',
	'remind': '⏰ Скоро истекает срок оплаты',
	'paid': '✅ Штраф оплачен',
};

function is_integer(value) {
	return type(value) == 'int' || (type(value) == 'double' && value == int(value));
}

// Сравнивает свежую выдачу с запомненным состоянием.
// paid — протоколы, которые на самом деле уже оплачены ({ номер: true }): МВД
// держит их в базе ещё несколько дней после оплаты.
// Возвращает { events, known }, где known — уже обновлённое состояние.
function diff_fines(args) {
	let today = args.today;
	let remind_days = args.remind_days ?? 0;
	let notify_always = args.notify_always ?? false;
	let paid = args.paid ?? {};

	// Как Map в JS-версии: дубликаты схлопываются, порядок — по первому появлению.
	let current = {}, order = [];
	for (let fine in args.fines) {
		let protocol_no = fine?.protocolNo;
		if (!protocol_no)
			continue;
		if (!exists(current, protocol_no))
			push(order, protocol_no);
		current[protocol_no] = fine;
	}

	let next = { ...(args.known ?? {}) };
	let events = [];

	for (let protocol_no in order) {
		let fine = current[protocol_no];
		let record = next[protocol_no];
		let left = fine.remainingDays;

		if (paid[protocol_no]) {
			// Оплаченный штраф тревоги не стоит: говорим о нём один раз и замолкаем.
			// Обратно в неоплаченные он не вернётся, поэтому отметка в состоянии вечная.
			if (!record?.paid || notify_always)
				push(events, { type: 'paid', protocolNo: protocol_no, fine: fine });
			next[protocol_no] = { ...(record ?? { firstSeen: today }), paid: today };
		}
		else if (!record) {
			push(events, { type: 'new', protocolNo: protocol_no, fine: fine });
			next[protocol_no] = { firstSeen: today, remindedAt: null };
		}
		else if (notify_always) {
			push(events, { type: 'repeat', protocolNo: protocol_no, fine: fine });
		}
		else if (remind_days > 0 && is_integer(left) && left <= remind_days && record.remindedAt !== today) {
			push(events, { type: 'remind', protocolNo: protocol_no, fine: fine });
			next[protocol_no] = { ...record, remindedAt: today };
		}

		// Сумма и срок меняются, когда штраф удваивается за просрочку.
		next[protocol_no] = {
			...next[protocol_no],
			amount: fine.protocolAmount ?? null,
			lastDate: fine.lastDate ?? null,
		};
	}

	for (let protocol_no in keys(next)) {
		if (!exists(current, protocol_no)) {
			// Про оплаченный уже сказали — то, что он ушёл из базы, ничего не добавляет.
			if (!next[protocol_no]?.paid)
				push(events, { type: 'gone', protocolNo: protocol_no });
			delete next[protocol_no];
		}
	}

	return { events: events, known: next };
}

function ru_date(value) {
	let parts = match(`${value ?? ''}`, /^(\d{4})-(\d{2})-(\d{2})/);
	return parts ? `${parts[3]}.${parts[2]}.${parts[1]}` : (value || '—');
}

function plural_days(count) {
	let n = count < 0 ? -count : count;
	if (n % 10 == 1 && n % 100 != 11)
		return 'день';
	if (n % 10 >= 2 && n % 10 <= 4 && !(n % 100 >= 12 && n % 100 <= 14))
		return 'дня';
	return 'дней';
}

function render_event(event, plate, coords) {
	if (event.type == 'gone')
		return `✅ Штраф <code>${escape_html(event.protocolNo)}</code> по <b>${escape_html(plate)}</b> ` +
			'пропал из базы МВД — скорее всего, оплачен.';

	let fine = event.fine;
	let georgian = escape_html(fine.protocolLawDescription || fine.protocolLaw || '—');
	let russian = ARTICLES[fine.protocolLaw ?? ''];
	let law = russian ? `${escape_html(russian)}\n<i>${georgian}</i>` : georgian;

	let place = fine.protocolPlace
		? `<a href="${maps_url(fine.protocolPlace, coords)}">${escape_html(fine.protocolPlace)}</a>`
		: '—';

	let lines = [
		// Номер протокола и госномер — в <code>: в Telegram копируются одним тапом.
		`<b>${TITLES[event.type]}</b> — <code>${escape_html(plate)}</code>`,
		'',
		`Протокол: <code>${escape_html(fine.protocolNo)}</code>`,
		`Дата: ${ru_date(fine.violationDate || fine.protocolDate)}`,
		`Место: ${place}`,
		`Статья: ${law}`,
		// Камерные штрафы дешевеют на 20%, если заплатить за 10 дней, но police.ge
		// всё это время показывает полную сумму: скидку знает только платёжный шлюз,
		// и на его странице она уже подставлена. Поэтому подписываем цифру честно.
		`Сумма без скидки: <b>${escape_html(fine.protocolAmount ?? '—')} ₾</b>`,
	];

	// Срок оплаты у оплаченного штрафа только сбивал бы с толку.
	if (event.type != 'paid' && fine.lastDate) {
		let left = fine.remainingDays;
		let tail = is_integer(left) ? ` (осталось ${left} ${plural_days(left)})` : '';
		push(lines, `Оплатить до: ${ru_date(fine.lastDate)}${tail}`);
	}

	return join('\n', lines);
}

export { ARTICLES, maps_query, maps_url, diff_fines, render_event };
