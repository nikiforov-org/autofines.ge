'use strict';

import { test, eq, ok, like, unlike, run, FINE } from 'harness';
import { diff_fines, maps_query, render_event } from 'autofines.notify';
import { parse_place } from 'autofines.geocode';

const TODAY = '2026-08-29';
const NO = FINE.protocolNo;

function diff(extra) {
	return diff_fines({ today: TODAY, remind_days: 7, fines: [ FINE ], known: {}, ...(extra ?? {}) });
}

function types(events) {
	return map(events, (e) => e.type);
}

function href(text) {
	return match(text, /Место: <a href="([^"]+)">/)?.[1];
}

test('новый протокол даёт событие new и попадает в состояние', () => {
	let result = diff();
	eq(types(result.events), [ 'new' ]);
	eq(result.known[NO].firstSeen, TODAY);
	eq(result.known[NO].amount, 50);
});

test('уже известный протокол молчит', () => {
	let first = diff();
	eq(diff({ known: first.known }).events, []);
});

test('напоминание срабатывает у дедлайна и не дублируется в тот же день', () => {
	let soon = { ...FINE, remainingDays: 5 };
	let first = diff();
	let remind = diff({ fines: [ soon ], known: first.known });
	eq(types(remind.events), [ 'remind' ]);
	eq(remind.known[NO].remindedAt, TODAY);
	eq(diff({ fines: [ soon ], known: remind.known }).events, []);
});

test('напоминание выключено при remind_days = 0', () => {
	let first = diff();
	eq(diff({ remind_days: 0, fines: [ { ...FINE, remainingDays: 1 } ], known: first.known }).events, []);
});

test('notify_always повторяет известный штраф', () => {
	let first = diff();
	eq(types(diff({ known: first.known, notify_always: true }).events), [ 'repeat' ]);
});

test('оплаченный протокол даёт paid вместо new и не тревожит повторно', () => {
	let paid = { [NO]: true };
	let first = diff({ paid: paid });
	eq(types(first.events), [ 'paid' ]);
	eq(first.known[NO].paid, TODAY);
	eq(diff({ known: first.known, paid: paid }).events, []);
});

test('оплата известного штрафа отменяет напоминание о сроке', () => {
	let first = diff();
	let result = diff({ fines: [ { ...FINE, remainingDays: 1 } ], known: first.known, paid: { [NO]: true } });
	eq(types(result.events), [ 'paid' ]);
});

test('ручная проверка повторяет и оплаченный штраф', () => {
	let paid = { [NO]: true };
	let first = diff({ paid: paid });
	eq(types(diff({ known: first.known, paid: paid, notify_always: true }).events), [ 'paid' ]);
});

test('оплаченный штраф ушёл из базы — про это уже сказано, gone не дублируем', () => {
	let first = diff({ paid: { [NO]: true } });
	let result = diff({ fines: [], known: first.known });
	eq(result.events, []);
	eq(result.known, {});
});

test('исчезнувший протокол даёт gone и убирается из состояния', () => {
	let first = diff();
	let result = diff({ fines: [], known: first.known });
	eq(types(result.events), [ 'gone' ]);
	eq(result.known, {});
});

test('удвоение штрафа за просрочку обновляет сумму без нового уведомления', () => {
	let first = diff();
	let doubled = { ...FINE, protocolAmount: 100, lastDate: '2026-11-17', remainingDays: 80 };
	let result = diff({ fines: [ doubled ], known: first.known });
	eq(result.events, []);
	eq(result.known[NO].amount, 100);
	eq(result.known[NO].lastDate, '2026-11-17');
});

test('карточка штрафа собирается с русской статьёй и склонением дней', () => {
	let text = render_event({ type: 'new', protocolNo: NO, fine: FINE }, 'AB123CD');
	like(text, /<b>🚨 Новый штраф<\/b> — <code>AB123CD<\/code>/);
	like(text, /Превышение скорости на 15–30 км\/ч/);
	like(text, /Дата: 19\.08\.2026/);
	like(text, /Сумма без скидки: <b>50 ₾<\/b>/);
	like(text, /Оплатить до: 18\.10\.2026 \(осталось 50 дней\)/);

	let one = render_event({ type: 'new', protocolNo: NO, fine: { ...FINE, remainingDays: 1 } }, 'AB123CD');
	like(one, /осталось 1 день\)/);
});

test('карточка оплаченного штрафа — без срока оплаты и без пояснений', () => {
	let text = render_event({ type: 'paid', protocolNo: NO, fine: FINE }, 'AB123CD');
	like(text, /<b>✅ Штраф оплачен<\/b> — <code>AB123CD<\/code>/);
	// Заголовок уже всё сказал: срок оплаты и объяснения только сбивали бы с толку.
	unlike(text, /Оплатить до/);
	like(text, /Сумма без скидки: <b>50 ₾<\/b>$/, 'карточка кончается суммой');
});

test('адрес нарушения становится ссылкой в карты', () => {
	let link = href(render_event({ type: 'new', protocolNo: NO, fine: FINE }, 'AB123CD'));
	ok(link, 'адрес должен быть ссылкой');
	like(link, /&query=%E1%83%90%E1%83%9C.*%20N83%2C%20%E1%83%91%E1%83%90%E1%83%97%E1%83%A3%E1%83%9B%E1%83%98%2C%20Georgia$/,
		'в запросе «ანწუხელიძის ქუჩა N83, ბათუმი, Georgia»');
});

test('с координатами ссылка ведёт прямо в точку', () => {
	let link = href(render_event({ type: 'new', protocolNo: NO, fine: FINE }, 'AB123CD',
		{ lat: 41.6148394, lon: 41.5959743 }));
	like(link, /&query=41\.6148394%2C41\.5959743$/);
});

test('адрес нормализуется под геокодер', () => {
	// «(წრიული) 2» — тип и номер камеры, для карты это мусор;
	// «ქ. ბათუმი» впереди улицы геокодер не понимает.
	eq(maps_query('ქ. ბათუმი ანწუხელიძის ქუჩა N83 (წრიული) 2'), 'ანწუხელიძის ქუჩა N83, ბათუმი, Georgia');
	// Без префикса «ქ.» строку оставляем как есть, только добавляем страну.
	eq(maps_query('Rustaveli Ave 12'), 'Rustaveli Ave 12, Georgia');
	// Страна уже названа — не дублируем.
	eq(maps_query('Tbilisi, Georgia'), 'Tbilisi, Georgia');
});

test('адреса нет — ссылки тоже нет, прочерк', () => {
	let text = render_event({ type: 'new', protocolNo: 'X', fine: { ...FINE, protocolPlace: null } }, 'A1');
	like(text, /Место: —/);
});

test('HTML в данных экранируется', () => {
	let text = render_event({ type: 'new', protocolNo: 'X', fine: { ...FINE, protocolPlace: '<b>боом</b>' } }, 'A1');
	like(text, /&lt;b&gt;боом&lt;\/b&gt;/);
});

test('адрес МВД разбирается на город и улицу с номером дома впереди', () => {
	eq(parse_place('ქ. ბათუმი ანწუხელიძის ქუჩა N83 (წრიული) 2'), {
		city: 'ბათუმი',
		street: '83 ანწუხელიძის ქუჩა',
		cleaned: 'ქ. ბათუმი ანწუხელიძის ქუჩა N83',
	});
});

test('адрес без номера дома тоже разбирается', () => {
	let parsed = parse_place('ქ. თბილისი რუსთაველის გამზირი');
	eq(parsed.city, 'თბილისი');
	eq(parsed.street, 'რუსთაველის გამზირი');
});

test('строка без префикса «ქ.» уходит в свободный поиск целиком', () => {
	let parsed = parse_place('Rustaveli Ave 12');
	eq(parsed.city, '');
	eq(parsed.street, 'Rustaveli Ave 12');
});

test('пустой адрес не ломает разбор', () => {
	eq(parse_place(null), { city: '', street: '', cleaned: '' });
});

exit(run());
