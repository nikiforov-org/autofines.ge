'use strict';

// Отправка в Telegram. Ссылку на оплату кладём кнопкой, с откатом в текст.
// tg — { token, chat_id, api }; api — адрес Bot API, обычно https://api.telegram.org.

import { request, ok, json_or_null } from 'autofines.http';
import { clip } from 'autofines.text';

function endpoint(tg, method) {
	return `${tg.api}/bot${tg.token}/${method}`;
}

function post(tg, method, payload, timeout) {
	return request('POST', endpoint(tg, method), {
		headers: { 'Content-Type': 'application/json' },
		body: sprintf('%J', payload ?? {}),
		timeout: timeout,
	});
}

// Любой метод Bot API. Бросает при ошибке, чтобы падение не осталось незамеченным.
function call(tg, method, payload, timeout) {
	let res = post(tg, method, payload, timeout);
	let data = json_or_null(res.body) ?? {};
	if (!ok(res) || data.ok === false)
		die(`Telegram ${method}: ${res.status} ${clip(sprintf('%J', data), 200)}`);
	return data.result;
}

function send_message(tg, text, pay_url, keyboard) {
	let base = {
		chat_id: tg.chat_id,
		text: text,
		parse_mode: 'HTML',
		disable_web_page_preview: true,
	};

	if (keyboard)
		base.reply_markup = keyboard;

	let attempts = pay_url
		? [
			{ ...base, reply_markup: { inline_keyboard: [ [ { text: '💳 Оплатить', url: pay_url } ] ] } },
			// Telegram придирчив к ссылкам в кнопках: не принял — уводим её в текст.
			{ ...base, text: `${text}\n\n<a href="${pay_url}">💳 Оплатить</a>` },
		]
		: [ base ];

	let last_error = '';
	for (let payload in attempts) {
		let res = post(tg, 'sendMessage', payload);
		if (ok(res))
			return;
		last_error = `${res.status} ${clip(res.body, 300)}`;
	}
	die(`Telegram отклонил сообщение: ${last_error}`);
}

export { call, send_message };
