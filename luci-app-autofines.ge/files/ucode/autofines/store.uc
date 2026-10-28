'use strict';

// Состояние бота: что уже отправлено, кэш геокодера, последний сбой. Один
// JSON-файл с теми же ключами, что были в Workers KV. Пишется только
// изменившееся, атомарно через переименование — флешу роутера лишние записи
// ни к чему, а оборванная запись не должна портить файл.

import * as fs from 'fs';

function open(path) {
	let data = {};
	let text = fs.readfile(path);

	if (length(text)) {
		data = null;
		try {
			data = json(text);
		}
		catch (e) {
		}
		// Битый файл не должен навсегда остановить проверки: откладываем его
		// в сторону и начинаем с чистого листа.
		if (type(data) != 'object') {
			fs.rename(path, `${path}.broken`);
			data = {};
		}
	}

	let saved = sprintf('%J', data);

	return {
		// Копия, как у KV: правка полученного объекта не меняет хранилище.
		get: (key) => exists(data, key) ? json(sprintf('%J', data[key])) : null,
		put: (key, value) => {
			data[key] = value;
		},
		// true — файл переписан, false — менять было нечего.
		flush: () => {
			let next = sprintf('%J', data);
			if (next == saved)
				return false;
			let tmp = `${path}.tmp`;
			if (fs.writefile(tmp, next) == null || !fs.rename(tmp, path))
				die(`не удалось записать ${path}: ${fs.error()}`);
			saved = next;
			return true;
		},
	};
}

export { open };
