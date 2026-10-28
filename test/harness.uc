'use strict';

// Мини-раннер для тестов на ucode: test() копит случаи, run() их гоняет.
// Плюс заготовки: протокол из жизни, хранилище в памяти и подмена сети.

import * as http from 'autofines.http';

let cases = [];

function test(name, fn) {
	push(cases, { name: name, fn: fn });
}

// Объекты сравниваются без учёта порядка ключей — как deepEqual.
function canon(value) {
	if (type(value) == 'object') {
		let out = {};
		for (let key in sort(keys(value)))
			out[key] = canon(value[key]);
		return out;
	}
	if (type(value) == 'array')
		return map(value, canon);
	return value;
}

function eq(actual, expected, message) {
	let got = sprintf('%J', canon(actual)), want = sprintf('%J', canon(expected));
	if (got != want)
		die(`${message ?? 'не совпало'}\n      ждали:    ${want}\n      получили: ${got}`);
}

function ok(value, message) {
	if (!value)
		die(message ?? 'ждали истину');
}

function like(text, pattern, message) {
	if (!match(`${text}`, pattern))
		die(`${message ?? 'текст не подошёл под шаблон'}:\n      ${text}`);
}

function unlike(text, pattern, message) {
	if (match(`${text}`, pattern))
		die(`${message ?? 'в тексте лишнее'}:\n      ${text}`);
}

function throws(fn, pattern, message) {
	let error;
	try {
		fn();
	}
	catch (e) {
		error = e.message;
	}
	if (error == null)
		die(message ?? 'ждали исключение');
	if (pattern && !match(error, pattern))
		die(`${message ?? 'не то исключение'}:\n      ${error}`);
	return error;
}

function run() {
	let failed = 0;
	for (let c in cases) {
		let error;
		try {
			c.fn();
		}
		catch (e) {
			error = e.message;
		}
		http.stub();
		if (error == null)
			print(`✔ ${c.name}\n`);
		else {
			failed++;
			print(`✖ ${c.name}\n      ${error}\n`);
		}
	}
	print(`# тестов: ${length(cases)}, упало: ${failed}\n`);
	return failed ? 1 : 0;
}

// Протокол из жизни (госномер заменён на вымышленный): камера в Батуми, 19.08.2026.
const FINE = {
	protocolAuto: 'AB123CD',
	violationDate: '2026-08-19',
	protocolPlace: 'ქ. ბათუმი ანწუხელიძის ქუჩა N83 (წრიული) 2',
	protocolLaw: '125-1-0',
	protocolLawDescription: 'ასკ 125-ე მუხლის პირველი ნაწილი',
	protocolAmount: 50,
	lastDate: '2026-10-18',
	remainingDays: 50,
	protocolDate: '2026-08-19',
	protocolNo: 'კვ000474970',
};

function copy(value) {
	return json(sprintf('%J', value));
}

// Хранилище в памяти — тот же интерфейс, что у store.open().
function memory_store(initial) {
	let data = copy(initial ?? {});
	return {
		get: (key) => exists(data, key) ? copy(data[key]) : null,
		put: (key, value) => {
			data[key] = copy(value);
		},
		flush: () => false,
		dump: () => data,
	};
}

function url_decode(text) {
	return replace(replace(text, /\+/g, ' '), /%([0-9A-Fa-f][0-9A-Fa-f])/g, (all, code) => chr(hex(code)));
}

// Тело application/x-www-form-urlencoded в объект.
function form_decode(body) {
	let out = {};
	for (let pair in split(body ?? '', '&')) {
		let at = index(pair, '=');
		if (at < 0)
			continue;
		out[url_decode(substr(pair, 0, at))] = url_decode(substr(pair, at + 1));
	}
	return out;
}

const CSRF = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

function respond(status, body, headers) {
	return { status: status, headers: headers ?? {}, body: body };
}

// Подменяет сеть: police.ge, шлюз и Nominatim отвечают заготовками, сообщения
// в Telegram копятся в sent. opts: fines, paid (оплаченные протоколы),
// gateway (свой ответ шлюза), telegram_status, police (свой ответ police.ge).
function stub_network(opts) {
	opts ??= {};
	let fines = opts.fines ?? [ FINE ];
	let paid = opts.paid ?? [];
	let sent = [], calls = [], requests = [];

	http.stub((method, url, req) => {
		push(requests, url);

		if (index(url, 'police.ge/') >= 0 && opts.police)
			return opts.police(method, url, req);

		if (index(url, 'protocols/searchByAuto') >= 0) {
			let body = form_decode(req.body);
			eq(body.csrf_token, CSRF, 'csrf должен уехать на сервер');
			ok(index(req.headers.Cookie ?? '', 'PHPSESSID=zzz') >= 0, 'cookie сессии должна уехать');
			let results = int(body.firstResult) == 0 ? fines : [];
			return respond(200, sprintf('%J', { success: true, data: { count: length(results), results: results } }));
		}

		if (index(url, 'police.ge/protocol/index.php') >= 0)
			return respond(200, `<input type="hidden" name="csrf_token" value="${CSRF}">`,
				{ 'set-cookie': 'PHPSESSID=zzz; path=/; HttpOnly' });

		// Платёжный шлюз: на оплаченный протокол он отдаёт готовый результат вместо
		// формы карты — по этому и отличаем оплату, которую МВД ещё не провело.
		if (index(url, 'mpi.gc.ge/open/api') >= 0) {
			if (opts.gateway)
				return opts.gateway(url, req);
			if (match(url, /\/token$/))
				return respond(200, '{"token":"TKN"}');
			let protocol_no = form_decode(req.body)['params.protocolId'];
			return respond(200, sprintf('%J', index(paid, protocol_no) >= 0
				? { state: 'result', result: { status: 'FAILED', extendedCode: 'CPA_REJECTED' } }
				: { state: 'input' }));
		}

		if (index(url, 'nominatim.openstreetmap.org') >= 0) {
			// Nominatim отдаёт улицу кусками — бот должен усреднить их в одну точку.
			return respond(200, sprintf('%J', [
				{ lat: '41.6100000', lon: '41.6000000', display_name: 'გიორგი ანწუხელიძის ქუჩა, ბათუმი',
				  address: { road: 'გიორგი ანწუხელიძის ქუჩა' } },
				{ lat: '41.6200000', lon: '41.6100000', display_name: 'გიორგი ანწუხელიძის ქუჩა, ბათუმი',
				  address: { road: 'გიორგი ანწუხელიძის ქუჩა' } },
				{ lat: '41.9999999', lon: '41.9999999', display_name: 'სხვა ქუჩა',
				  address: { road: 'სხვა ქუჩა' } },
			]));
		}

		if (index(url, 'api.telegram.org') >= 0) {
			let method_name = match(url, /\/([A-Za-z]+)$/)[1];
			if (method_name != 'sendMessage') {
				push(calls, { method: method_name, payload: json(req.body) });
				return respond(200, '{"ok":true,"result":true}');
			}
			push(sent, json(req.body));
			let status = opts.telegram_status ?? 200;
			return respond(status, sprintf('%J', { ok: status == 200, result: { message_id: 42 } }));
		}

		die(`неожиданный запрос: ${url}`);
	});

	return { sent: sent, calls: calls, requests: requests };
}

// Настройки как из UCI: один номер, напоминание за 7 дней.
function config(extra) {
	return {
		plates: [ 'AB123CD' ],
		interval: 60,
		remind_days: 7,
		notify_always: false,
		notify_empty: false,
		telegram: { token: 'token', chat_id: 'chat', api: 'https://api.telegram.org' },
		...(extra ?? {}),
	};
}

export {
	test, eq, ok, like, unlike, throws, run,
	FINE, CSRF, copy, memory_store, form_decode, respond, stub_network, config
};
