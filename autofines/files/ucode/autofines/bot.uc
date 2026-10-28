'use strict';

// Проверка штрафов и реакция на кнопку в Telegram. Состояние (какие протоколы
// уже отправлены) лежит в store под ключом "state".

import { fetch_plate, is_paid, payment_url } from 'autofines.police';
import { diff_fines, render_event } from 'autofines.notify';
import { geocode_cached } from 'autofines.geocode';
import { call, send_message } from 'autofines.telegram';
import { clip, escape_html } from 'autofines.text';

// Подпись кнопки на постоянной клавиатуре бота.
const CHECK_BUTTON = '🔄 Проверить штрафы';

// Клавиатура отваливается, если её не подтверждать: Telegram показывает её
// ровно до тех пор, пока бот присылает сообщения с этой разметкой. Поэтому
// прикладываем её к последнему сообщению каждой ручной проверки.
const KEYBOARD = {
	keyboard: [ [ { text: CHECK_BUTTON } ] ],
	resize_keyboard: true,
	is_persistent: true,
};

// Грузия круглый год живёт по UTC+4, сезон не переводит.
const TBILISI_OFFSET = 4 * 3600;

function tbilisi_date(now) {
	let t = gmtime((now ?? time()) + TBILISI_OFFSET);
	return sprintf('%04d-%02d-%02d', t.year, t.mon, t.mday);
}

// Какие из найденных протоколов на самом деле оплачены. Шлюз спрашиваем только
// про те, что ещё не помечены оплаченными: обратно из оплаченных штраф не выходит.
// Неуверенный ответ шлюза (null) считаем «не оплачен» — лучше лишняя тревога,
// чем пропущенный штраф.
function find_paid(fines, plate, known) {
	let paid = {};
	for (let fine in fines) {
		let protocol_no = fine.protocolNo;
		if (!protocol_no)
			continue;
		if (known[protocol_no]?.paid || is_paid(protocol_no, plate))
			paid[protocol_no] = true;
	}
	return paid;
}

// Один проход проверки. Возвращает короткий отчёт для лога.
// overrides: notify_always — прислать всё, что висит; today — дата для тестов.
function run_check(cfg, store, overrides) {
	overrides ??= {};
	if (!length(cfg.plates))
		die('не задан госномер: list plate в /etc/config/autofines');
	if (!cfg.telegram?.token || !cfg.telegram?.chat_id)
		die('не заданы bot_token и chat_id в /etc/config/autofines');

	let notify_always = overrides.notify_always ?? cfg.notify_always;
	let today = overrides.today ?? tbilisi_date();

	let state = store.get('state') ?? {};
	let report = { today: today, plates: {}, sent: 0 };
	let total_unpaid = 0;

	for (let plate in cfg.plates) {
		let fines = fetch_plate(plate);
		let paid = find_paid(fines, plate, state[plate] ?? {});
		let unpaid = length(fines) - length(paid);
		total_unpaid += unpaid;

		let diff = diff_fines({
			fines: fines,
			paid: paid,
			known: state[plate] ?? {},
			today: today,
			remind_days: cfg.remind_days,
			notify_always: notify_always,
		});

		for (let event in diff.events) {
			// Оплачивать нечего ни у оплаченного, ни у пропавшего из базы.
			let settled = event.type == 'gone' || event.type == 'paid';
			let pay_url = settled ? null : payment_url(event.protocolNo, plate);
			let coords = event.fine?.protocolPlace ? geocode_cached(store, event.fine.protocolPlace) : null;
			send_message(cfg.telegram, render_event(event, plate, coords), pay_url);
			report.sent++;
		}

		if (length(diff.known))
			state[plate] = diff.known;
		else
			delete state[plate];

		report.plates[plate] = {
			found: length(fines),
			unpaid: unpaid,
			events: map(diff.events, (event) => event.type),
		};
	}

	if (cfg.notify_empty && total_unpaid == 0) {
		send_message(cfg.telegram, '✅ Проверка прошла: неоплаченных штрафов нет.');
		report.sent++;
	}

	store.put('state', state);
	return report;
}

// Текст ошибки для <code>: в нём бывает HTML ответа сервера, а неэкранированный
// тег Telegram отвергает вместе со всем сообщением.
function failure_text(title, message) {
	return `⚠️ ${title}:\n<code>${escape_html(message)}</code>`;
}

// Плановая проверка. Писем о падении у роутера нет, поэтому об ошибке бот
// сообщает сам, в тот же чат. Но проверка идёт каждый час, и лежащий police.ge
// не должен присылать одно и то же круглые сутки: сбой сообщается сразу, потом
// не чаще раза в день, пока не пройдёт, а выздоровление — одной строкой.
function scheduled_run(cfg, store, overrides) {
	let report, failure;
	try {
		report = run_check(cfg, store, overrides);
	}
	catch (e) {
		failure = clip(e.message, 500);
	}

	let today = overrides?.today ?? tbilisi_date();
	let reported = store.get('failure');

	if (failure) {
		if (reported?.text != failure || reported?.date != today) {
			// Не дошло — не запоминаем: через час попробуем сказать ещё раз.
			try {
				send_message(cfg.telegram, failure_text('Проверка штрафов упала', failure));
				store.put('failure', { text: failure, date: today });
			}
			catch (e) {
				die(`${failure}; в Telegram сообщить не вышло: ${e.message}`);
			}
		}
		die(failure);
	}

	if (reported) {
		try {
			send_message(cfg.telegram, '✅ Проверка штрафов снова работает.');
			store.put('failure', null);
		}
		catch (e) {
		}
	}
	return report;
}

// Ручная проверка. В отличие от плановой присылает все висящие штрафы, а не
// только новые: кнопку жмут именно чтобы увидеть, что сейчас в системе и что
// можно оплатить.
function manual_run(cfg, store) {
	let report;
	try {
		report = run_check(cfg, store, { notify_always: true });
	}
	catch (e) {
		let message = clip(e.message, 500);
		try {
			send_message(cfg.telegram, failure_text('Проверка упала', message), null, KEYBOARD);
		}
		catch (e2) {
			die(`${message}; в Telegram сообщить не вышло: ${e2.message}`);
		}
		die(message);
	}

	// Отвечаем сами, только если проверка промолчала: после карточек штрафов
	// «неоплаченных нет» — лишняя строка. Заодно это единственное сообщение,
	// к которому можно приложить клавиатуру: у карточек занято кнопкой оплаты.
	if (report.sent == 0) {
		send_message(cfg.telegram, '✅ Неоплаченных штрафов нет.', null, KEYBOARD);
		report.sent++;
	}
	return report;
}

// Просит ли апдейт Telegram проверку. Отвечаем только своему чату: бот виден
// всем, кто найдёт его в поиске.
function wants_check(chat_id, update) {
	let callback = update?.callback_query;
	let message = callback?.message ?? update?.message ?? {};
	let text = trim(`${callback?.data ?? update?.message?.text ?? ''}`);
	let own = `${message.chat?.id ?? ''}` == `${chat_id}`;
	let asked = text == 'check' || text == CHECK_BUTTON || text == '/check' || substr(text, 0, 7) == '/check@';
	return own && asked;
}

function every(minutes) {
	return minutes == 60 ? 'каждый час' : `каждые ${minutes} мин`;
}

// Разовая настройка чата: команда /check, постоянная клавиатура и закреплённое
// сообщение с инлайн-кнопкой. Возвращает id закреплённого сообщения.
function setup(cfg) {
	let tg = cfg.telegram;
	if (!tg?.token || !tg?.chat_id)
		die('не заданы bot_token и chat_id в /etc/config/autofines');

	// Нажатия бот забирает сам, опросом getUpdates, а при живом вебхуке
	// Telegram их не отдаёт.
	call(tg, 'deleteWebhook', {});

	// Команду видит только владелец: для всех остальных меню бота пустое.
	call(tg, 'setMyCommands', {
		commands: [ { command: 'check', description: 'Проверить штрафы сейчас' } ],
		scope: { type: 'chat', chat_id: int(tg.chat_id) },
	});
	try {
		call(tg, 'setMyCommands', { commands: [], scope: { type: 'default' } });
	}
	catch (e) {
	}
	try {
		call(tg, 'setMyDescription', { description: 'Личный бот. Посторонним не отвечает.' });
	}
	catch (e) {
	}

	// Клавиатура: живёт, пока Telegram её не свернёт.
	call(tg, 'sendMessage', { chat_id: tg.chat_id, text: 'Кнопка проверки готова.', reply_markup: KEYBOARD });

	// Закреплённое сообщение с инлайн-кнопкой: висит вверху чата всегда.
	let pinned = call(tg, 'sendMessage', {
		chat_id: tg.chat_id,
		text: `<b>Штрафы МВД Грузии</b>\nПроверка ${every(cfg.interval)}.`,
		parse_mode: 'HTML',
		reply_markup: { inline_keyboard: [ [ { text: CHECK_BUTTON, callback_data: 'check' } ] ] },
	});
	try {
		call(tg, 'pinChatMessage', { chat_id: tg.chat_id, message_id: pinned.message_id, disable_notification: true });
	}
	catch (e) {
	}

	return pinned.message_id;
}

export { CHECK_BUTTON, KEYBOARD, tbilisi_date, run_check, scheduled_run, manual_run, wants_check, setup };
