/**
 * Превращение адреса из базы МВД в координаты.
 *
 * МВД пишет адрес как «ქ. <город> <улица> N<дом> (<тип камеры>) <номер камеры>».
 * Поиск по такой строке не находит ничего: мешает хвост про камеру, префикс «ქ.»
 * и порядок, в котором город идёт перед улицей. Структурный запрос к Nominatim
 * (city + street + страна) точку находит, поэтому разбираем строку на части.
 */

const NOMINATIM = "https://nominatim.openstreetmap.org/search";
const USER_AGENT = "autofines.ge (personal traffic-fine notifier)";

/** @returns {{city: string, street: string, cleaned: string}} */
export function parsePlace(place) {
  const cleaned = String(place ?? "")
    .replace(/\s*\([^)]*\)\s*\d*\s*$/, "") // «(წრიული) 2» — тип и номер камеры
    .replace(/\s+/g, " ")
    .trim();

  const parts = /^ქ\.\s*(\S+)\s+(.+)$/.exec(cleaned);
  if (!parts) return { city: "", street: cleaned, cleaned };

  // Nominatim ждёт номер дома перед названием улицы: «N83 ანწუხელიძის ქუჩა» → «83 ...»
  const house = /\bN\s*(\d+)\b/i.exec(parts[2])?.[1];
  const street = parts[2].replace(/\bN\s*\d+\b/i, "").replace(/\s+/g, " ").trim();

  return { city: parts[1], street: house ? `${house} ${street}` : street, cleaned };
}

/** Координаты адреса или null. Ошибки геокодера не должны ронять уведомление. */
export async function geocode(place) {
  const { city, street, cleaned } = parsePlace(place);
  if (!cleaned) return null;

  const params = new URLSearchParams({
    format: "json",
    limit: "20",
    addressdetails: "1",
    countrycodes: "ge",
  });
  if (city && street) {
    params.set("city", city);
    params.set("street", street);
  } else {
    params.set("q", `${cleaned}, Georgia`);
  }

  try {
    const response = await fetch(`${NOMINATIM}?${params}`, {
      headers: { "User-Agent": USER_AGENT, "Accept-Language": "ka,en" },
    });
    if (!response.ok) return null;
    const hits = await response.json();
    if (!hits.length) return null;
    return centreOfStreet(hits);
  } catch {
    return null;
  }
}

/**
 * OSM режет улицу на сегменты (у ანწუხელიძის ქუჩა их 21 на 2.3 км) и при равной
 * релевантности отдаёт их в произвольном порядке — из-за этого пин прыгал от
 * запуска к запуску. Берём центр всех сегментов одной улицы: точка становится
 * устойчивой и лежит посередине, а не на случайном краю.
 *
 * Номера домов в Батуми в OSM почти не размечены, поэтому точность здесь
 * уличная: `precision: "street"` честно говорит, что дом не найден.
 */
function centreOfStreet(hits) {
  const road = hits[0].address?.road;
  const segments = road ? hits.filter((h) => h.address?.road === road) : [hits[0]];
  const mean = (values) => values.reduce((a, b) => a + b, 0) / values.length;

  return {
    lat: Number(mean(segments.map((h) => Number(h.lat))).toFixed(6)),
    lon: Number(mean(segments.map((h) => Number(h.lon))).toFixed(6)),
    name: hits[0].display_name ?? "",
    precision: hits[0].address?.house_number ? "house" : "street",
    segments: segments.length,
  };
}

/**
 * То же, но с кэшем в KV: адреса камер повторяются, а Nominatim просит
 * не ходить к нему чаще раза в секунду.
 */
export async function geocodeCached(kv, place) {
  const { cleaned } = parsePlace(place);
  if (!cleaned) return null;

  const key = `geo:${cleaned}`;
  const cached = await kv.get(key, "json");
  if (cached) return cached.lat === null ? null : cached;

  const found = await geocode(place);
  await kv.put(key, JSON.stringify(found ?? { lat: null }));
  return found;
}
