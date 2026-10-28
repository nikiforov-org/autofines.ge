'use strict';

// Превращение адреса из базы МВД в координаты.
//
// МВД пишет адрес как «ქ. <город> <улица> N<дом> (<тип камеры>) <номер камеры>».
// Поиск по такой строке не находит ничего: мешает хвост про камеру, префикс «ქ.»
// и порядок, в котором город идёт перед улицей. Структурный запрос к Nominatim
// (city + street + страна) точку находит, поэтому разбираем строку на части.

import { request, ok, form, json_or_null } from 'autofines.http';

const NOMINATIM = 'https://nominatim.openstreetmap.org/search';
const USER_AGENT = 'autofines.ge (personal traffic-fine notifier)';

// «N83» отдельным словом. \b в регулярках ucode нет, поэтому границы расписаны явно.
const HOUSE_RE = /(^|[^A-Za-z0-9_])N\s*(\d+)([^A-Za-z0-9_]|$)/i;

// { city, street, cleaned }
function parse_place(place) {
	let cleaned = trim(replace(replace(`${place ?? ''}`,
		/\s*\([^)]*\)\s*\d*\s*$/, ''), // «(წრიული) 2» — тип и номер камеры
		/\s+/g, ' '));

	let parts = match(cleaned, /^ქ\.\s*(\S+)\s+(.+)$/);
	if (!parts)
		return { city: '', street: cleaned, cleaned: cleaned };

	// Nominatim ждёт номер дома перед названием улицы: «N83 ანწუხელიძის ქუჩა» → «83 ...»
	let house = match(parts[2], HOUSE_RE)?.[2];
	let street = trim(replace(replace(parts[2], HOUSE_RE, '$1$3'), /\s+/g, ' '));

	return { city: parts[1], street: house ? `${house} ${street}` : street, cleaned: cleaned };
}

function mean(values) {
	let sum = 0.0;
	for (let value in values)
		sum += value;
	return sum / length(values);
}

// OSM режет улицу на сегменты (у ანწუხელიძის ქუჩა их 21 на 2.3 км) и при равной
// релевантности отдаёт их в произвольном порядке — из-за этого пин прыгал от
// запуска к запуску. Берём центр всех сегментов одной улицы: точка становится
// устойчивой и лежит посередине, а не на случайном краю.
//
// Номера домов в Батуми в OSM почти не размечены, поэтому точность здесь
// уличная: precision: "street" честно говорит, что дом не найден.
function centre_of_street(hits) {
	let road = hits[0].address?.road;
	let segments = road ? filter(hits, (hit) => hit.address?.road == road) : [ hits[0] ];

	return {
		lat: +sprintf('%.6f', mean(map(segments, (hit) => +hit.lat))),
		lon: +sprintf('%.6f', mean(map(segments, (hit) => +hit.lon))),
		name: hits[0].display_name ?? '',
		precision: hits[0].address?.house_number ? 'house' : 'street',
		segments: length(segments),
	};
}

// Координаты адреса или null. Ошибки геокодера не должны ронять уведомление.
function geocode(place) {
	let parsed = parse_place(place);
	if (!parsed.cleaned)
		return null;

	let params = { format: 'json', limit: '20', addressdetails: '1', countrycodes: 'ge' };
	if (parsed.city && parsed.street) {
		params.city = parsed.city;
		params.street = parsed.street;
	}
	else {
		params.q = `${parsed.cleaned}, Georgia`;
	}

	try {
		let res = request('GET', `${NOMINATIM}?${form(params)}`, {
			headers: { 'User-Agent': USER_AGENT, 'Accept-Language': 'ka,en' },
		});
		if (!ok(res))
			return null;
		let hits = json_or_null(res.body);
		if (type(hits) != 'array' || !length(hits))
			return null;
		return centre_of_street(hits);
	}
	catch (e) {
		return null;
	}
}

// То же, но с кэшем в состоянии: адреса камер повторяются, а Nominatim просит
// не ходить к нему чаще раза в секунду.
function geocode_cached(store, place) {
	let cleaned = parse_place(place).cleaned;
	if (!cleaned)
		return null;

	let key = `geo:${cleaned}`;
	let cached = store.get(key);
	if (cached)
		return cached.lat === null ? null : cached;

	let found = geocode(place);
	store.put(key, found ?? { lat: null });
	return found;
}

export { parse_place, geocode, geocode_cached };
