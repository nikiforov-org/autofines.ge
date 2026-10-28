#!/usr/bin/ucode
'use strict';

// autofines — штрафы МВД Грузии по госномеру с уведомлениями в Telegram.
// Живёт на роутере: сайт МВД отвечает только грузинским адресам.

import * as fs from 'fs';
import * as log from 'log';
import { load } from 'autofines.config';
import { open } from 'autofines.store';
import { call } from 'autofines.telegram';
import { manual_run, scheduled_run, wants_check, setup } from 'autofines.bot';
import { fetch_plate, is_paid, payment_url } from 'autofines.police';
import { render_event } from 'autofines.notify';

const USAGE = `Использование:
  autofines daemon            служба: проверка раз в interval минут и кнопка в Telegram
  autofines dry-run [НОМЕР…]  живой запрос к police.ge без Telegram и без записи состояния
  autofines setup             команда /check, клавиатура и закреплённое сообщение в чате
`;

// Столько Telegram держит getUpdates, если нажатий нет.
const POLL_SECONDS = 50;
// После загрузки роутера дать подняться WAN и NTP: без них проверка упадёт
// или запишет в состояние неверную дату.
const STARTUP_GRACE = 120;
// Пауза после сбоя опроса, чтобы без сети не крутиться вхолостую.
const RETRY_PAUSE_MS = 15000;

// Сводка для страницы в LuCI: последняя и следующая проверка, связь с Telegram.
// /var/run — это память роутера, так что флеш от неё не изнашивается.
const STATUS_FILE = '/var/run/autofines/status.json';

let status = {};

function publish(changes) {
	status = { ...status, ...changes };
	let tmp = `${STATUS_FILE}.tmp`;
	if (fs.writefile(tmp, sprintf('%J', status)) != null)
		fs.rename(tmp, STATUS_FILE);
}

function summary(report) {
	let parts = [];
	for (let plate, result in report.plates)
		push(parts, `${plate}: найдено ${result.found}, не оплачено ${result.unpaid}` +
			(length(result.events) ? `, события: ${join(' ', result.events)}` : ''));
	return join('; ', parts) + `; сообщений: ${report.sent}`;
}

function flush(store) {
	try {
		store.flush();
	}
	catch (e) {
		log.ERR('%s', e.message);
	}
}

// Проверка с записью итога в лог и в сводку; падение не роняет цикл службы.
function attempt(title, manual, run) {
	let entry = { time: time(), manual: manual };
	try {
		entry.summary = summary(run());
		entry.ok = true;
		log.INFO('%s', `${title}: ${entry.summary}`);
	}
	catch (e) {
		entry.error = e.message;
		entry.ok = false;
		log.ERR('%s', `${title} упала: ${e.message}`);
	}
	return entry;
}

function daemon() {
	log.ulog_open(log.ULOG_SYSLOG, log.LOG_DAEMON, 'autofines');

	let cfg = load();
	let store = open(cfg.state_file);
	let started = time();
	let last_check = null;
	let offset = null;
	let webhook_cleared = false;

	log.INFO('%s', `запущен: ${join(', ', cfg.plates)}, проверка раз в ${cfg.interval} мин`);
	publish({ started: started, next: started + STARTUP_GRACE, check: null, telegram: null });

	while (true) {
		let now = time();
		// Часы могли уйти назад, пока не было NTP, — тогда тоже проверяем.
		if (now - started >= STARTUP_GRACE &&
		    (last_check == null || now - last_check >= cfg.interval * 60 || now < last_check)) {
			last_check = now;
			publish({
				check: attempt('проверка', false, () => scheduled_run(cfg, store)),
				next: now + cfg.interval * 60,
			});
			flush(store);
		}

		try {
			if (!webhook_cleared) {
				// Нажатия бот забирает опросом, а при живом вебхуке Telegram их не отдаёт.
				call(cfg.telegram, 'deleteWebhook', {});
				webhook_cleared = true;
			}

			let poll = { timeout: POLL_SECONDS, allowed_updates: [ 'message', 'callback_query' ] };
			if (offset != null)
				poll.offset = offset;
			let updates = call(cfg.telegram, 'getUpdates', poll, (POLL_SECONDS + 20) * 1000);
			if (!status.telegram?.ok)
				publish({ telegram: { ok: true, time: time() } });

			// Пока роутер был недоступен, кнопку могли нажать несколько раз:
			// на всю пачку хватит одной проверки.
			let asked = false;
			for (let update in updates ?? []) {
				offset = update.update_id + 1;
				if (!wants_check(cfg.telegram.chat_id, update))
					continue;
				asked = true;
				if (update.callback_query) {
					try {
						call(cfg.telegram, 'answerCallbackQuery', {
							callback_query_id: update.callback_query.id,
							text: 'Проверяю…',
						});
					}
					catch (e) {
					}
				}
			}

			if (asked) {
				publish({ check: attempt('ручная проверка', true, () => manual_run(cfg, store)) });
				flush(store);
			}
		}
		catch (e) {
			log.WARN('%s', e.message);
			if (status.telegram?.error != e.message)
				publish({ telegram: { ok: false, error: e.message, time: time() } });
			// Вебхук мог появиться снова — например, его поставил старый воркер.
			webhook_cleared = false;
			sleep(RETRY_PAUSE_MS);
		}
	}
}

function dry_run(plates) {
	if (!length(plates))
		plates = load().plates;
	if (!length(plates))
		die('укажите госномер: autofines dry-run AB123CD');

	for (let plate in plates) {
		let fines = fetch_plate(plate);
		print(`\n${plate}: протоколов — ${length(fines)}\n`);
		for (let fine in fines) {
			// Выдача МВД одинакова для оплаченных и неоплаченных — спрашиваем шлюз.
			let paid = is_paid(fine.protocolNo, plate);
			let text = render_event({ type: paid ? 'paid' : 'new', protocolNo: fine.protocolNo, fine: fine }, plate);
			print('\n', replace(text, /<[^>]+>/g, ''), '\n');
			if (paid === null)
				print('⚠️ шлюз ответил непонятно — считаем неоплаченным\n');
			if (!paid)
				print('💳 ', payment_url(fine.protocolNo, plate), '\n');
		}
	}
}

let command = ARGV[0];
let failure;

try {
	if (command == 'daemon')
		daemon();
	else if (command == 'dry-run')
		dry_run(map(slice(ARGV, 1), (plate) => uc(plate)));
	else if (command == 'setup')
		print(`Готово: команда /check, клавиатура и закреплённое сообщение (id ${setup(load())}).\n`);
	else
		failure = command == null || command == 'help' ? 0 : USAGE;
}
catch (e) {
	failure = `autofines: ${e.message}\n`;
}

if (failure === 0)
	print(USAGE);
else if (failure != null) {
	warn(failure);
	exit(1);
}
