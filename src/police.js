/**
 * Клиент публичной формы police.ge/protocol («Search by vehicle number plate»).
 * Ищет по одному госномеру, без капчи; нужен только csrf_token со страницы формы
 * и cookie той же сессии.
 */

const FORM_URL = "https://police.ge/protocol/index.php?lang=en";
const SEARCH_URL = "https://police.ge/protocol/index.php?url=protocols/searchByAuto";
const CSRF_RE = /name="csrf_token"\s+value="([0-9a-f]{16,})"/;

const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

export class PoliceGeError extends Error {}

/** Склеивает Set-Cookie ответа в значение для заголовка Cookie. */
function collectCookies(response) {
  const raw =
    typeof response.headers.getSetCookie === "function"
      ? response.headers.getSetCookie()
      : [response.headers.get("set-cookie")].filter(Boolean);
  return raw
    .map((cookie) => cookie.split(";")[0].trim())
    .filter(Boolean)
    .join("; ");
}

/**
 * Все неоплаченные протоколы по госномеру. Пагинация вычерпывается целиком.
 * @param {string} plate латиницей, слитно, без кода страны — например A354OC797
 */
export async function fetchPlate(plate, { pageCap = 20 } = {}) {
  const formResponse = await fetch(FORM_URL, {
    headers: { "User-Agent": USER_AGENT, "Accept-Language": "en-US,en;q=0.9" },
  });
  if (!formResponse.ok) {
    throw new PoliceGeError(`страница формы police.ge вернула ${formResponse.status}`);
  }

  const cookies = collectCookies(formResponse);
  const csrf = CSRF_RE.exec(await formResponse.text())?.[1];
  if (!csrf) throw new PoliceGeError("на странице формы police.ge не нашёлся csrf_token");

  const found = [];
  const seen = new Set();

  for (let page = 0; page < pageCap; page++) {
    const body = new URLSearchParams({
      firstResult: String(found.length),
      protocolAuto: plate,
      csrf_token: csrf,
    });

    const response = await fetch(SEARCH_URL, {
      method: "POST",
      headers: {
        "User-Agent": USER_AGENT,
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "X-Requested-With": "XMLHttpRequest",
        Referer: FORM_URL,
        Origin: "https://police.ge",
        ...(cookies ? { Cookie: cookies } : {}),
      },
      body,
    });
    if (!response.ok) {
      throw new PoliceGeError(`поиск по номеру вернул ${response.status}`);
    }

    const text = await response.text();
    let payload;
    try {
      payload = JSON.parse(text);
    } catch {
      throw new PoliceGeError(`police.ge вернул не JSON: ${text.slice(0, 200)}`);
    }
    if (!payload.success) {
      throw new PoliceGeError(`police.ge ответил ошибкой: ${payload.message ?? "без текста"}`);
    }

    const batch = payload.data?.results ?? [];
    const fresh = batch.filter((item) => item.protocolNo && !seen.has(item.protocolNo));
    if (fresh.length === 0) break;
    for (const item of fresh) {
      seen.add(item.protocolNo);
      found.push(item);
    }
  }

  return found;
}

/** Ссылка на оплату — ровно та, что собирает police.ge в своей функции payment(). */
export function paymentUrl(protocolNo, plate) {
  const protocol = encodeURIComponent(protocolNo);
  return (
    "https://mpi.gc.ge/page1/?lang_code=ka" +
    "&page_id=0B849B8B559D32AE7E2F136C180F5983" +
    "&merch_id=5ACF0AC08EA8263A576BDC08B6E25DED" +
    "&back_url_s=https://police.ge/protocol/success.php" +
    `&back_url_f=https://police.ge/protocol/fail.php?id=${protocol}` +
    `&o.protocolId=${protocol}` +
    `&o.vehicleNumber=${encodeURIComponent(plate)}` +
    "&o.resourceAlias=1"
  );
}
