'use strict';

// Настройки из /etc/config/autofines.

import { cursor } from 'uci';

function flag(value) {
	return index([ '1', 'true', 'yes', 'on' ], lc(trim(`${value ?? ''}`))) >= 0;
}

// В UCI госномера — list plate, но строка через пробел или запятую тоже сойдёт.
function parse_plates(raw) {
	let list = type(raw) == 'array' ? raw : split(`${raw ?? ''}`, /[,\s]+/);
	return filter(map(list, (plate) => uc(trim(`${plate}`))), (plate) => length(plate) > 0);
}

function number(value, fallback) {
	let parsed = int(value ?? fallback);
	return parsed >= 0 ? parsed : fallback;
}

function load() {
	let main = cursor().get_all('autofines', 'main') ?? {};
	let interval = number(main.interval, 60);

	return {
		enabled: flag(main.enabled),
		plates: parse_plates(main.plate),
		// Минуты между проверками.
		interval: interval > 0 ? interval : 60,
		// Напоминать, когда до конца срока оплаты осталось столько дней; 0 — не напоминать.
		remind_days: number(main.remind_days, 7),
		notify_always: flag(main.notify_always),
		notify_empty: flag(main.notify_empty),
		state_file: main.state_file ?? '/etc/autofines/state.json',
		telegram: {
			token: main.bot_token,
			chat_id: main.chat_id,
			api: main.api ?? 'https://api.telegram.org',
		},
	};
}

export { load, flag, parse_plates };
