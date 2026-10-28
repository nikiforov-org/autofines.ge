'use strict';

import * as fs from 'fs';
import { test, eq, ok, run } from 'harness';
import { open } from 'autofines.store';
import { clip, escape_html } from 'autofines.text';
import { uri_encode, form } from 'autofines.http';

const DIR = `/tmp/autofines-test-${time()}`;
fs.mkdir(DIR);

let n = 0;
function fresh_path() {
	return `${DIR}/state-${++n}.json`;
}

test('состояние переживает перезапуск', () => {
	let path = fresh_path();
	let store = open(path);
	store.put('state', { AB123CD: { X: { firstSeen: '2026-08-29' } } });
	ok(store.flush(), 'новое состояние пишется');
	eq(open(path).get('state'), { AB123CD: { X: { firstSeen: '2026-08-29' } } });
});

test('без изменений на флеш не пишем', () => {
	let path = fresh_path();
	let store = open(path);
	store.put('state', {});
	store.flush();
	let before = fs.stat(path).mtime;
	store.put('state', {});
	ok(!store.flush(), 'то же самое — без записи');
	eq(fs.stat(path).mtime, before);
});

test('полученный объект — копия: правка без put хранилище не меняет', () => {
	let store = open(fresh_path());
	store.put('state', { a: 1 });
	let state = store.get('state');
	state.a = 2;
	eq(store.get('state'), { a: 1 });
});

test('битый файл откладывается в сторону, проверки идут с чистого листа', () => {
	let path = fresh_path();
	fs.writefile(path, '{"state": {обрыв');
	let store = open(path);
	eq(store.get('state'), null);
	ok(fs.stat(`${path}.broken`), 'битый файл сохранён для разбора');
	store.put('state', {});
	ok(store.flush());
	eq(open(path).get('state'), {});
});

test('нет файла — пустое состояние', () => {
	eq(open(fresh_path()).get('state'), null);
});

test('обрезка текста не рвёт UTF-8 посреди символа', () => {
	eq(clip('Проверка', 3), 'Про');
	eq(clip('ქართული', 2), 'ქა');
	eq(clip('🚨 штраф', 1), '🚨');
	eq(clip('коротко', 500), 'коротко');
	eq(clip(null, 5), '');
});

test('HTML экранируется для parse_mode HTML', () => {
	eq(escape_html('<b>x</b> & y'), '&lt;b&gt;x&lt;/b&gt; &amp; y');
	eq(escape_html(50), '50');
	eq(escape_html(null), '');
});

test('кодирование адресов как в JS: encodeURIComponent и URLSearchParams', () => {
	eq(uri_encode("a b/c?d=e&f'g(h)*!~.-_"), "a%20b%2Fc%3Fd%3De%26f'g(h)*!~.-_");
	eq(uri_encode('ქ'), '%E1%83%A5');
	eq(form({ q: 'a b', 'x.y': '1&2', n: 0 }), 'q=a+b&x.y=1%262&n=0');
});

exit(run());
