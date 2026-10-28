'use strict';

// Паритет с прежней JS-реализацией: golden.json снят с неё на тех же данных
// перед переездом на роутер, потом госномер в нём заменён на вымышленный — он
// только подставляется в текст и ссылку. Карточки, разбор адресов, платёжные
// ссылки и сравнение состояния должны совпадать байт в байт.

import * as fs from 'fs';
import { test, eq, run } from 'harness';
import { render_event, maps_query, maps_url, diff_fines } from 'autofines.notify';
import { parse_place } from 'autofines.geocode';
import { payment_url } from 'autofines.police';

let golden = json(fs.readfile(sourcepath(0, true) + '/golden.json'));

// Замыкание на каждый случай отдельно: переменная цикла общая на все итерации.
function card(c) {
	return () => eq(render_event(c.event, c.plate, c.coords), c.text);
}

function place(c) {
	return () => {
		eq(maps_query(c.place), c.query, 'mapsQuery');
		eq(maps_url(c.place), c.url, 'mapsUrl');
		eq(parse_place(c.place), c.parsed, 'parsePlace');
	};
}

function payment(c) {
	return () => eq(payment_url(c.no, c.plate), c.url);
}

for (let c in golden.render)
	test(`карточка «${c.name}» как в JS`, card(c));

for (let c in golden.maps)
	test(`адрес «${c.place}» разбирается как в JS`, place(c));

for (let c in golden.payment)
	test(`платёжная ссылка для ${c.no} как в JS`, payment(c));

test('состояние после проверки как в JS: дубли, пустой номер, пропавший протокол, напоминание', () => {
	let fine = golden.render[0].event.fine;
	let result = diff_fines({
		fines: [ fine, { ...fine, protocolNo: 'B2', remainingDays: 3 }, { ...fine, protocolNo: '' }, fine ],
		known: { OLD: { firstSeen: '2026-08-01' }, B2: { firstSeen: '2026-08-02', remindedAt: null } },
		today: '2026-08-29',
		remind_days: 7,
	});
	eq(result, golden.diff);
});

exit(run());
