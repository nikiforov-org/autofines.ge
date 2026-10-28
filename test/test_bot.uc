'use strict';

import { test, eq, ok, like, unlike, throws, run, FINE, CSRF, memory_store, respond, stub_network, config } from 'harness';
import { run_check, scheduled_run, manual_run, wants_check, setup, CHECK_BUTTON } from 'autofines.bot';
import { payment_url } from 'autofines.police';
import { parse_plates } from 'autofines.config';

const NO = FINE.protocolNo;
const TODAY = '2026-08-29';

function check(store, extra, overrides) {
	return run_check(config(extra), store, { today: TODAY, ...(overrides ?? {}) });
}

test('полный проход: находит штраф, шлёт карточку с кнопкой, пишет состояние', () => {
	let store = memory_store();
	let net = stub_network();
	let report = check(store);

	eq(report.sent, 1);
	eq(report.plates.AB123CD, { found: 1, unpaid: 1, events: [ 'new' ] });
	eq(length(net.sent), 1);
	like(net.sent[0].text, /<b>🚨 Новый штраф<\/b> — <code>AB123CD<\/code>/);
	eq(net.sent[0].parse_mode, 'HTML');
	eq(net.sent[0].reply_markup.inline_keyboard[0][0].url, payment_url(NO, 'AB123CD'));
	like(net.sent[0].text, /href="https:\/\/www\.google\.com\/maps\/search\/\?api=1&query=41\.615%2C41\.605"/,
		'в ссылку уходит центр сегментов нужной улицы, чужая улица отброшена');

	ok(store.get('state').AB123CD[NO], 'протокол должен запомниться');
	ok(store.get('geo:ქ. ბათუმი ანწუხელიძის ქუჩა N83'), 'координаты кэшируются, чтобы не ходить в Nominatim каждый раз');
});

test('второй запуск по тем же данным молчит', () => {
	let store = memory_store();
	stub_network();
	check(store);

	let net = stub_network();
	eq(check(store).sent, 0);
	eq(length(net.sent), 0);
});

test('оплаченный штраф не поднимает тревогу, а приходит отметкой об оплате', () => {
	let net = stub_network({ paid: [ NO ] });
	let report = check(memory_store());
	eq(report.plates.AB123CD, { found: 1, unpaid: 0, events: [ 'paid' ] });
	eq(length(net.sent), 1);
	like(net.sent[0].text, /<b>✅ Штраф оплачен<\/b>/);
	eq(net.sent[0].reply_markup, null, 'платить нечего — кнопки оплаты нет');
	unlike(net.sent[0].text, /Оплатить до/);
});

test('про оплату говорим один раз, дальше молчим', () => {
	let store = memory_store();
	stub_network({ paid: [ NO ] });
	check(store);

	stub_network({ paid: [ NO ] });
	let report = check(store);
	eq(report.sent, 0);
	eq(report.plates.AB123CD.events, []);
});

test('оплата запомнена — шлюз больше не спрашиваем', () => {
	let store = memory_store();
	stub_network({ paid: [ NO ] });
	check(store);

	// Шлюз, который развалил бы проверку, если бы к нему пошли.
	let asked = [];
	stub_network({ gateway: (url) => {
		push(asked, url);
		return respond(502, 'bad gateway');
	} });
	let report = check(store);
	eq(asked, [], 'оплаченный штраф обратно в неоплаченные не выходит');
	eq(report.plates.AB123CD.unpaid, 0);
});

test('оплаченный штраф исчез из базы — второй раз об этом не пишем', () => {
	let store = memory_store();
	stub_network({ paid: [ NO ] });
	check(store);

	stub_network({ fines: [] });
	eq(check(store).sent, 0, 'про «пропал из базы» уже сказано словом «оплачен»');
	eq(store.get('state'), {}, 'и из состояния он убран');
});

test('отказ шлюза с чужим кодом — не повод считать штраф оплаченным', () => {
	let net = stub_network({ gateway: (url) => respond(200, match(url, /\/token$/)
		? '{"token":"TKN"}'
		// Не биллинг полиции, а сбой на стороне шлюза: про долг это ничего не говорит.
		: '{"state":"result","result":{"status":"FAILED","extendedCode":"MERCHANT_DISABLED"}}') });
	let report = check(memory_store());
	eq(report.plates.AB123CD, { found: 1, unpaid: 1, events: [ 'new' ] });
	like(net.sent[0].text, /🚨 Новый штраф/);
});

test('шлюз ответил непонятно — штраф остаётся неоплаченным', () => {
	// Заглушка вместо JSON: по такому судить об оплате нельзя.
	let net = stub_network({ gateway: () => respond(403, '<html>are you a robot?</html>') });
	let report = check(memory_store());
	eq(report.plates.AB123CD, { found: 1, unpaid: 1, events: [ 'new' ] });
	like(net.sent[0].text, /🚨 Новый штраф/, 'лучше лишняя тревога, чем пропущенный штраф');
	ok(net.sent[0].reply_markup?.inline_keyboard, 'с кнопкой оплаты');
});

test('шлюз недоступен вовсе — штраф остаётся неоплаченным', () => {
	let net = stub_network({ gateway: () => die('mpi.gc.ge: таймаут') });
	eq(check(memory_store()).plates.AB123CD.unpaid, 1);
	ok(net.sent[0].reply_markup?.inline_keyboard, 'с кнопкой оплаты');
});

test('госномер нормализуется в верхний регистр', () => {
	eq(parse_plates('  ab123cd '), [ 'AB123CD' ]);
	eq(parse_plates('ab123cd, b123cd456'), [ 'AB123CD', 'B123CD456' ]);
});

test('госномера списком — как list plate в UCI', () => {
	eq(parse_plates([ 'ab123cd', ' B123CD456 ' ]), [ 'AB123CD', 'B123CD456' ]);
	stub_network();
	let report = check(memory_store(), { plates: [ 'AB123CD', 'B123CD456' ] });
	eq(sort(keys(report.plates)), [ 'AB123CD', 'B123CD456' ]);
	eq(report.sent, 2, 'по одному уведомлению на номер');
});

test('пустой список номеров — внятная ошибка, а не тихий простой', () => {
	throws(() => check(memory_store(), { plates: [] }), /не задан госномер/);
	throws(() => check(memory_store(), { plates: parse_plates('  ') }), /не задан госномер/);
});

test('без токена бота — внятная ошибка', () => {
	throws(() => check(memory_store(), { telegram: { token: '', chat_id: 'chat' } }), /не заданы bot_token и chat_id/);
});

test('notify_empty даёт пульс, когда штрафов нет', () => {
	let net = stub_network({ fines: [] });
	check(memory_store(), { notify_empty: true });
	eq(length(net.sent), 1);
	like(net.sent[0].text, /неоплаченных штрафов нет/);
});

test('Telegram с кнопкой не принял — уходит второй попыткой со ссылкой в тексте', () => {
	let net = stub_network({ telegram_status: 400 });
	throws(() => check(memory_store()), /Telegram отклонил/);
	eq(length(net.sent), 2, 'две попытки по одному штрафу');
	ok(net.sent[0].reply_markup, 'первая — с кнопкой');
	eq(net.sent[1].reply_markup, null, 'вторая — без кнопки, ссылка в тексте');
	like(net.sent[1].text, /💳 Оплатить</);
});

test('падение плановой проверки уходит отдельным сообщением в Telegram', () => {
	let net = stub_network({ police: () => respond(200, '<html>без токена</html>') });
	throws(() => scheduled_run(config(), memory_store(), { today: TODAY }), /csrf_token/);
	like(net.sent[length(net.sent) - 1].text, /Проверка штрафов упала/);
	like(net.sent[length(net.sent) - 1].text, /csrf_token/);
});

test('HTML в тексте ошибки экранируется, иначе Telegram отвергнет всё сообщение', () => {
	let net = stub_network({ police: (method, url) => index(url, 'searchByAuto') >= 0
		? respond(200, '<html><b>502 Bad Gateway</b></html>')
		: respond(200, `<input name="csrf_token" value="${CSRF}">`) });
	throws(() => scheduled_run(config(), memory_store(), { today: TODAY }));
	let text = net.sent[0].text;
	like(text, /&lt;html&gt;&lt;b&gt;502 Bad Gateway/);
	unlike(text, /<html>/);
});

test('сбой не сыплется каждый час: сразу, потом раз в сутки, выздоровление — одной строкой', () => {
	let store = memory_store();
	let broken = { police: () => respond(503, 'down') };

	let net = stub_network(broken);
	throws(() => scheduled_run(config(), store, { today: TODAY }), /503/);
	eq(length(net.sent), 1, 'первый сбой сообщается сразу');

	net = stub_network(broken);
	throws(() => scheduled_run(config(), store, { today: TODAY }), /503/);
	eq(length(net.sent), 0, 'тот же сбой через час — молчим');

	net = stub_network({ police: () => respond(502, 'down') });
	throws(() => scheduled_run(config(), store, { today: TODAY }), /502/);
	eq(length(net.sent), 1, 'другая ошибка — новое сообщение');

	net = stub_network({ police: () => respond(502, 'down') });
	throws(() => scheduled_run(config(), store, { today: '2026-08-30' }), /502/);
	eq(length(net.sent), 1, 'на следующий день напоминаем, что всё ещё лежит');

	net = stub_network({ fines: [] });
	scheduled_run(config(), store, { today: '2026-08-30' });
	eq(length(net.sent), 1);
	like(net.sent[0].text, /снова работает/);

	net = stub_network({ fines: [] });
	scheduled_run(config(), store, { today: '2026-08-30' });
	eq(length(net.sent), 0, 'про выздоровление — один раз');
});

test('Telegram лёг вместе с police.ge — сбой не запоминаем и скажем через час', () => {
	let store = memory_store();
	stub_network({ police: () => respond(503, 'down'), telegram_status: 502 });
	throws(() => scheduled_run(config(), store, { today: TODAY }), /503; в Telegram сообщить не вышло/);
	eq(store.get('failure'), null);

	let net = stub_network({ police: () => respond(503, 'down') });
	throws(() => scheduled_run(config(), store, { today: TODAY }));
	eq(length(net.sent), 1, 'достучались — сообщили');
});

test('ручная проверка показывает оплаченный штраф и больше ничего не добавляет', () => {
	let net = stub_network({ paid: [ NO ] });
	manual_run(config(), memory_store());
	eq(length(net.sent), 1, '«неоплаченных нет» после карточки — лишняя строка');
	like(net.sent[0].text, /✅ Штраф оплачен/);
});

test('ручная проверка присылает сам штраф с кнопкой оплаты', () => {
	let net = stub_network();
	manual_run(config(), memory_store());
	eq(length(net.sent), 1, 'ручная проверка присылает сам штраф, а не сводку');
	like(net.sent[0].text, /AB123CD/);
	ok(net.sent[0].reply_markup?.inline_keyboard, 'и кнопку оплаты вместе с ним');
});

test('ручная проверка показывает штраф даже когда он уже известен', () => {
	let store = memory_store();
	stub_network();
	check(store);

	let net = stub_network();
	manual_run(config(), store);
	eq(length(net.sent), 1, 'плановая промолчала бы, кнопка — нет');
	ok(net.sent[0].reply_markup?.inline_keyboard, 'с кнопкой оплаты');
});

test('ручная проверка без штрафов отвечает и переприклеивает клавиатуру', () => {
	let net = stub_network({ fines: [] });
	eq(manual_run(config(), memory_store()).sent, 1, 'ответ «нет штрафов» тоже сообщение — в сводке его видно');
	eq(length(net.sent), 1, 'пустая проверка тоже должна ответить');
	like(net.sent[0].text, /Неоплаченных штрафов нет/);
	ok(net.sent[0].reply_markup?.keyboard, 'и переприклеить клавиатуру');
});

test('упавшая ручная проверка отвечает ошибкой с клавиатурой', () => {
	let net = stub_network({ police: () => respond(503, 'down') });
	throws(() => manual_run(config(), memory_store()), /503/);
	like(net.sent[0].text, /⚠️ Проверка упала/);
	ok(net.sent[0].reply_markup?.keyboard);
});

test('проверку просят кнопка, команда /check и закреплённая инлайн-кнопка', () => {
	let own = { id: 'chat' };
	ok(wants_check('chat', { message: { chat: own, text: CHECK_BUTTON } }), 'кнопка на клавиатуре');
	ok(wants_check('chat', { message: { chat: own, text: '/check' } }), 'команда');
	ok(wants_check('chat', { message: { chat: own, text: '/check@autofines_bot' } }), 'команда с именем бота');
	ok(wants_check('chat', { callback_query: { id: 'cb1', data: 'check', message: { chat: own } } }), 'инлайн-кнопка');
	ok(wants_check('123456789', { message: { chat: { id: 123456789 }, text: '/check' } }), 'id чата числом');
});

test('чужой чат и посторонний текст проверку не запускают', () => {
	ok(!wants_check('chat', { message: { chat: { id: '999' }, text: '/check' } }), 'чужой чат');
	ok(!wants_check('chat', { message: { chat: { id: 'chat' }, text: 'привет' } }), 'посторонний текст');
	ok(!wants_check('chat', { edited_message: { chat: { id: 'chat' }, text: '/check' } }), 'правка сообщения');
	ok(!wants_check('chat', {}), 'пустой апдейт');
});

test('setup снимает вебхук, вешает команду и закрепляет сообщение', () => {
	let net = stub_network();
	setup(config({ telegram: { token: 'token', chat_id: '123456789', api: 'https://api.telegram.org' } }));
	let methods = map(net.calls, (c) => c.method);
	eq(methods[0], 'deleteWebhook', 'без этого getUpdates не получит нажатий');
	ok(index(methods, 'pinChatMessage') >= 0);
	eq(net.calls[1].payload.scope, { type: 'chat', chat_id: 123456789 }, 'команда — только в своём чате');
	like(net.sent[length(net.sent) - 1].text, /Проверка каждый час/);
});

exit(run());
