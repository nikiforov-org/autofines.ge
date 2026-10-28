'use strict';
'require dom';
'require form';
'require fs';
'require poll';
'require rpc';
'require ui';
'require uci';
'require view';

// «Службы → Штрафы МВД»: настройки autofines и состояние службы. Сводку бот
// пишет сам в /var/run/autofines/status.json — это память роутера. rpcd сверяет
// права по настоящему пути, а /var на OpenWrt — ссылка на /tmp, поэтому в ACL
// прописаны оба.
//
// E() вставляет строку как HTML, если передать её одну, и как текст — если
// внутри массива. В сводке бывают ответы чужих серверов, поэтому всё, что
// пришло снаружи, идёт только массивом.

const STATUS_FILE = '/var/run/autofines/status.json';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

function loadState() {
	return Promise.all([
		L.resolveDefault(callServiceList('autofines'), {}),
		L.resolveDefault(fs.read(STATUS_FILE), '')
	]).then(([ services, text ]) => {
		let status = null;
		try {
			status = text ? JSON.parse(text) : null;
		}
		catch (e) {}

		return {
			running: Object.values(services?.autofines?.instances ?? {}).some((instance) => instance.running),
			status: status
		};
	});
}

function when(epoch) {
	return new Date(epoch * 1000).toLocaleString('ru-RU', { dateStyle: 'short', timeStyle: 'short' });
}

// Что поправить в настройках при частых ошибках.
function hint(error) {
	if (/\b401\b/.test(error))
		return _('Telegram не принял токен бота — проверьте его.');
	if (/chat not found/i.test(error))
		return _('Telegram не знает такого чата: проверьте ID и напишите боту хоть одно сообщение.');
	if (/\b409\b/.test(error))
		return _('Этим токеном Telegram опрашивает кто-то ещё.');
	if (/police\.ge/.test(error))
		return _('police.ge не ответил, бот повторит при следующей проверке.');
	return null;
}

function failure(error) {
	const tip = hint(error);
	return E('span', {}, [
		E('span', { 'style': 'color:#c00' }, [ _('ошибка: %s').format(error) ]),
		tip ? E('br') : '',
		tip ? E('small', {}, [ tip ]) : ''
	]);
}

function row(label, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, [ label ]),
		E('td', { 'class': 'td left' }, [ value ])
	]);
}

function renderStatus(node, state) {
	const status = state.status ?? {};
	const enabled = uci.get('autofines', 'main', 'enabled') == '1';

	let service = _('работает');
	if (!state.running)
		service = enabled
			? E('span', { 'style': 'color:#c00' }, [ _('не запущена: нужны токен бота и ID чата, подробности — logread -e autofines') ])
			: _('выключена');

	let telegram = '—';
	if (state.running)
		telegram = !status.telegram ? _('подключается…')
			: status.telegram.ok ? _('на связи')
			: failure(status.telegram.error);

	let check = _('ещё не было');
	if (status.check?.ok)
		check = '%s%s — %s'.format(when(status.check.time),
			status.check.manual ? _(' (по кнопке)') : '', status.check.summary);
	else if (status.check)
		check = E('span', {}, [ '%s — '.format(when(status.check.time)), failure(status.check.error) ]);

	dom.content(node, E('table', { 'class': 'table' }, [
		row(_('Служба'), service),
		row(_('Telegram'), telegram),
		row(_('Последняя проверка'), check),
		row(_('Следующая проверка'), state.running && status.next ? when(status.next) : '—')
	]));
}

// Пустые токен и ID при включённой службе — ошибка: без них бот не запустится.
function credential(pattern, message) {
	return function(section_id, value) {
		if (!value)
			return this.section.formvalue(section_id, 'enabled') == '1' ? _('Без этого бот не запустится') : true;
		return pattern.test(value) || message;
	};
}

function setupChat() {
	return fs.exec('/usr/bin/autofines', [ 'setup' ]).then((res) => {
		if (res.code == 0)
			ui.addNotification(null, E('p', [ _('В чат отправлены клавиатура и закреплённое сообщение с кнопкой проверки.') ]), 'info');
		else
			ui.addNotification(null, E('p', [ _('Не получилось: %s').format((res.stderr || res.stdout || '').trim()) ]), 'danger');
	}).catch((e) => ui.addNotification(null, E('p', [ e.message ]), 'danger'));
}

return view.extend({
	load() {
		return Promise.all([ loadState(), uci.load('autofines') ]);
	},

	render([ state ]) {
		const m = new form.Map('autofines');
		const s = m.section(form.NamedSection, 'main', 'autofines');
		s.tab('general', _('Основное'));
		s.tab('notify', _('Уведомления'));
		s.tab('advanced', _('Дополнительно'));

		let o = s.taboption('general', form.Flag, 'enabled', _('Включить'));
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'bot_token', _('Токен бота'),
			_('Выдаёт <a href="https://t.me/BotFather" target="_blank" rel="noreferrer">@BotFather</a>, вид — 123456789:AAE…'));
		o.password = true;
		o.validate = credential(/^\d+:[\w-]{30,}$/, _('Токен выглядит как 123456789:AAE…, без пробелов'));

		o = s.taboption('general', form.Value, 'chat_id', _('ID чата'),
			_('Куда слать уведомления. Посторонним чатам бот не отвечает.'));
		o.validate = credential(/^-?\d+$/, _('ID чата — целое число'));

		o = s.taboption('general', form.DynamicList, 'plate', _('Госномера'),
			_('Латиница слитно, без пробелов и кода страны: AB123CD.'));
		o.validate = (section_id, value) => !value || /^[A-Za-z0-9]+$/.test(value) || _('Только латинские буквы и цифры, слитно');

		o = s.taboption('general', form.Value, 'interval', _('Проверять police.ge'),
			_('Раз во столько минут. Каждая проверка — запрос к police.ge и, на каждый неоплаченный штраф, платёжная сессия на mpi.gc.ge: так бот узнаёт об оплате.'));
		o.value('15', _('каждые 15 минут'));
		o.value('30', _('каждые 30 минут'));
		o.value('60', _('каждый час'));
		o.value('180', _('каждые 3 часа'));
		o.value('360', _('каждые 6 часов'));
		o.value('720', _('каждые 12 часов'));
		o.value('1440', _('раз в сутки'));
		o.default = '60';
		o.datatype = 'range(5,10080)';

		o = s.taboption('general', form.Button, '_setup', _('Кнопка в Telegram'),
			_('Присылает в чат клавиатуру с кнопкой «🔄 Проверить штрафы», закрепляет сообщение с ней и вешает команду /check. Сначала сохраните и примените токен и ID чата.'));
		o.inputtitle = _('Настроить чат');
		o.inputstyle = 'action';
		o.onclick = setupChat;

		o = s.taboption('notify', form.Value, 'remind_days', _('Напоминать о сроке оплаты'),
			_('За столько дней до конца срока, не чаще раза в сутки. 0 — не напоминать.'));
		o.datatype = 'uinteger';
		o.placeholder = '7';

		o = s.taboption('notify', form.Flag, 'notify_always', _('Все штрафы при каждой проверке'),
			_('Обычно приходят только новые штрафы и напоминания о сроке.'));

		o = s.taboption('notify', form.Flag, 'notify_empty', _('Сообщать, что штрафов нет'),
			_('После каждой проверки — то есть с выбранным интервалом.'));

		o = s.taboption('advanced', form.Value, 'api', _('Адрес Bot API'),
			_('Для своего сервера Bot API. Обычно не нужен.'));
		o.placeholder = 'https://api.telegram.org';
		o.validate = (section_id, value) => !value || /^https?:\/\/\S+$/.test(value) || _('Адрес вида https://api.telegram.org');

		const status = E('div');
		renderStatus(status, state);
		poll.add(() => loadState().then((next) => renderStatus(status, next)), 10);

		return m.render().then((map) => E([], [
			E('h2', [ _('Штрафы МВД Грузии') ]),
			E('div', { 'class': 'cbi-map-descr' }, [ _('Бот проверяет штрафы по госномеру на police.ge и присылает новые в Telegram с кнопкой оплаты.') ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', [ _('Состояние') ]), status ]),
			map
		]));
	}
});
