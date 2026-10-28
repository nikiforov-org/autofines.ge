'use strict';

const HTML = { '&': '&amp;', '<': '&lt;', '>': '&gt;' };

// Первые count символов строки. substr режет байты и рвёт UTF-8 посреди
// символа, а такой текст Telegram не примет.
function clip(text, count) {
	text = `${text ?? ''}`;
	let chars = 0;
	for (let i = 0; i < length(text); i++) {
		// 10xxxxxx — продолжение символа, всё остальное начинает новый.
		if ((ord(text, i) & 0xC0) != 0x80 && chars++ == count)
			return substr(text, 0, i);
	}
	return text;
}

function escape_html(value) {
	return replace(`${value ?? ''}`, /[&<>]/g, (c) => HTML[c]);
}

export { clip, escape_html };
