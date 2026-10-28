'use strict';

// HTTP поверх uclient — того же клиента, что у uclient-fetch, TLS через
// ustream-ssl. Запросы синхронные: каждый крутит uloop, пока не придёт конец
// ответа или ошибка. Тело POST uclient всегда шлёт чанками (Transfer-Encoding:
// chunked) — police.ge, платёжный шлюз и Telegram это принимают.

import * as uclient from 'uclient';
import * as uloop from 'uloop';

const CA_FILE = '/etc/ssl/certs/ca-certificates.crt';

// enum uclient_error_code из uclient.h, по порядку.
const ERRORS = [
	'неизвестная ошибка', 'не удалось подключиться', 'таймаут',
	'недействительный сертификат', 'сертификат выдан другому сайту', 'нет TLS',
];

uloop.init();
// uloop_init() — и этот, и тот, что uclient зовёт сам перед первым запросом, —
// вешает на SIGTERM и SIGINT обработчик, который лишь прерывает текущий цикл:
// бот принимал это за обрыв запроса и жил дальше, пока procd через 5 секунд не
// добивал его SIGKILL, и «Сохранить и применить» в LuCI ждало. Сброс в SIG_DFL
// не помогает — libubox тогда ставит свой заново, а чужой обработчик не трогает.
// Состояние пишется атомарно, так что выходить по сигналу сразу безопасно.
signal('SIGTERM', () => exit(0));
signal('SIGINT', () => exit(0));

function host_of(url) {
	return match(url, /^[a-z]+:\/\/([^\/:?#]+)/)?.[1] ?? url;
}

function network(method, url, opts) {
	let res = { status: 0, headers: {}, body: '' };
	let failure;
	let cl = uclient.new(url, null, {
		header_done: function() {
			res.status = this.status().status;
			res.headers = this.get_headers();
		},
		data_read: function() {
			let chunk;
			while (length(chunk = this.read()))
				res.body += chunk;
		},
		data_eof: function() {
			uloop.end();
		},
		error: function(cb, code) {
			failure = ERRORS[code] ?? `ошибка ${code}`;
			uloop.end();
		},
	});
	if (!cl)
		die(`${host_of(url)}: неверный адрес`);

	cl.ssl_init({ ca_files: [ CA_FILE ], verify: true });
	cl.set_timeout(opts.timeout ?? 30000);
	if (!cl.connect()) {
		cl.free();
		die(`${host_of(url)}: не удалось подключиться`);
	}
	if (!cl.request(method, { headers: opts.headers ?? {}, post_data: opts.body })) {
		cl.free();
		die(`${host_of(url)}: запрос не ушёл`);
	}
	uloop.run();
	cl.free();

	if (failure)
		die(`${host_of(url)}: ${failure}`);
	// Без статуса ответа не бывает: сервер закрыл соединение раньше заголовков.
	if (!res.status)
		die(`${host_of(url)}: соединение оборвалось`);
	return res;
}

let transport = network;

// Ответ { status, headers, body }; заголовки — в нижнем регистре. Сбой сети —
// исключение с понятным текстом, по статусу судит вызывающий.
function request(method, url, opts) {
	return transport(method, url, opts ?? {});
}

// Тесты подменяют сеть заглушкой; без аргумента возвращается настоящая.
function stub(fn) {
	transport = fn ?? network;
}

function ok(res) {
	return res.status >= 200 && res.status <= 299;
}

// encodeURIComponent: всё, кроме A–Z a–z 0–9 - _ . ! ~ * ' ( ), — в %XX по байтам UTF-8.
function uri_encode(value) {
	return replace(`${value}`, /[^A-Za-z0-9_.!~*'()-]/g, (c) => sprintf('%%%02X', ord(c)));
}

function form_encode(value) {
	return replace(`${value}`, /[^A-Za-z0-9*_.-]/g, (c) => c == ' ' ? '+' : sprintf('%%%02X', ord(c)));
}

// application/x-www-form-urlencoded, как у URLSearchParams: пробел — «+».
function form(params) {
	let parts = [];
	for (let key, value in params)
		push(parts, form_encode(key) + '=' + form_encode(value));
	return join('&', parts);
}

// Разобранный JSON или null: по мусору судить нельзя.
function json_or_null(text) {
	try {
		return json(text);
	}
	catch (e) {
		return null;
	}
}

export { request, stub, ok, uri_encode, form, json_or_null };
