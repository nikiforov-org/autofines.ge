'use strict';

// Клиент публичной формы police.ge/protocol («Search by vehicle number plate»).
// Ищет по одному госномеру, без капчи; нужен только csrf_token со страницы формы
// и cookie той же сессии.

import { request, ok, form, uri_encode, json_or_null } from 'autofines.http';
import { clip } from 'autofines.text';

const FORM_URL = 'https://police.ge/protocol/index.php?lang=en';
const SEARCH_URL = 'https://police.ge/protocol/index.php?url=protocols/searchByAuto';
const CSRF_RE = /name="csrf_token"\s+value="([0-9a-f]{16,})"/;

const USER_AGENT =
	'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
	'(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

// Cookie сессии из ответа формы. uclient оставляет от одноимённых заголовков
// последний, но police.ge и ставит один — PHPSESSID.
function session_cookie(headers) {
	return trim(split(headers['set-cookie'] ?? '', ';')[0]);
}

// Все неоплаченные протоколы по госномеру. Пагинация вычерпывается целиком.
// plate — латиницей, слитно, без кода страны: AB123CD.
function fetch_plate(plate, page_cap) {
	let page_form = request('GET', FORM_URL, {
		headers: { 'User-Agent': USER_AGENT, 'Accept-Language': 'en-US,en;q=0.9' },
	});
	if (!ok(page_form))
		die(`страница формы police.ge вернула ${page_form.status}`);

	let cookie = session_cookie(page_form.headers);
	let csrf = match(page_form.body, CSRF_RE)?.[1];
	if (!csrf)
		die('на странице формы police.ge не нашёлся csrf_token');

	let found = [], seen = {};

	for (let page = 0; page < (page_cap ?? 20); page++) {
		let headers = {
			'User-Agent': USER_AGENT,
			'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
			'X-Requested-With': 'XMLHttpRequest',
			'Referer': FORM_URL,
			'Origin': 'https://police.ge',
		};
		if (cookie)
			headers.Cookie = cookie;

		let res = request('POST', SEARCH_URL, {
			headers: headers,
			body: form({ firstResult: length(found), protocolAuto: plate, csrf_token: csrf }),
		});
		if (!ok(res))
			die(`поиск по номеру вернул ${res.status}`);

		let payload = json_or_null(res.body);
		if (type(payload) != 'object')
			die(`police.ge вернул не JSON: ${clip(res.body, 200)}`);
		if (!payload.success)
			die(`police.ge ответил ошибкой: ${payload.message ?? 'без текста'}`);

		let fresh = filter(payload.data?.results ?? [], (item) => item?.protocolNo && !seen[item.protocolNo]);
		if (!length(fresh))
			break;
		for (let item in fresh) {
			seen[item.protocolNo] = true;
			push(found, item);
		}
	}

	return found;
}

// Реквизиты платёжной страницы — ровно те, что подставляет police.ge в payment().
const PAY_PAGE = 'https://mpi.gc.ge/page1/';
const PAGE_ID = '0B849B8B559D32AE7E2F136C180F5983';
const MERCHANT_ID = '5ACF0AC08EA8263A576BDC08B6E25DED';
const BACK_OK = 'https://police.ge/protocol/success.php';
const BACK_FAIL = 'https://police.ge/protocol/fail.php?id=';

// Платёжная ссылка на протокол — ровно та, что собирает police.ge в функции payment().
function payment_url(protocol_no, plate) {
	let protocol = uri_encode(protocol_no);
	return PAY_PAGE + '?lang_code=ka' +
		'&page_id=' + PAGE_ID +
		'&merch_id=' + MERCHANT_ID +
		'&back_url_s=' + BACK_OK +
		'&back_url_f=' + BACK_FAIL + protocol +
		'&o.protocolId=' + protocol +
		'&o.vehicleNumber=' + uri_encode(plate) +
		'&o.resourceAlias=1';
}

// Открытая часть API платёжного шлюза Банка Грузии. Версия и portal-идентификатор
// взяты из mpi.gc.ge/page1/settings.js — оттуда же их берёт сама страница оплаты.
const PAY_API = 'https://mpi.gc.ge/open/api/v4/66EF9A2E6D429D8F0C767574F9353E8B';

// POST к шлюзу. Разобранный JSON или null: по мусору судить нельзя.
function pay_api(path, body) {
	let res = request('POST', PAY_API + path, {
		headers: {
			'User-Agent': USER_AGENT,
			'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
			'X-Requested-With': 'XMLHttpRequest',
			'Referer': PAY_PAGE,
			'Origin': 'https://mpi.gc.ge',
		},
		body: body,
	});
	return json_or_null(res.body);
}

// Оплачен ли протокол на самом деле: true, false или null — шлюз ответил
// непонятно, судить нельзя.
//
// МВД проводит оплату с задержкой: оплаченный штраф ещё несколько дней висит в
// выдаче searchByAuto, и по ней оплату не отличить. Отличает платёжный шлюз —
// на оплаченный протокол он не открывает форму карты, а сразу отдаёт готовый
// результат со статусом FAILED. Страница оплаты в этом случае молча уходит на
// back_url_f, то есть на police.ge/protocol/index.php: это и видно в браузере.
// Повторяем ровно те два запроса, которые страница делает при загрузке.
function is_paid(protocol_no, plate) {
	try {
		let token = pay_api('/token')?.token;
		if (!token)
			return null;

		let start = pay_api(`/payment/${uri_encode(token)}/start`, form({
			'merchantId': MERCHANT_ID,
			'state.redirect': 'post_params',
			'state.in_progress': 'no',
			'back_url_s': BACK_OK,
			'back_url_f': BACK_FAIL + protocol_no,
			'returnUrl': PAY_PAGE,
			'lang': 'ka',
			'3ds2.supported': 'true',
			'params.protocolId': protocol_no,
			'params.vehicleNumber': plate,
			'params.resourceAlias': '1',
		}));

		// Готовый результат на старте, до всякой карты, — заказ отклонили не глядя.
		// CPA_REJECTED ставит биллинг полиции: он и есть тот, кто знает про долг,
		// поэтому его отказ читаем как «платить нечего». Отказ с другим кодом мог
		// прийти по своей причине — оплаченным штраф по нему не считаем.
		if (start?.result?.extendedCode == 'CPA_REJECTED')
			return true;
		// «input» — шлюз просит карту, значит платить есть за что.
		return start?.state ? false : null;
	}
	catch (e) {
		return null;
	}
}

export { fetch_plate, payment_url, is_paid };
