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

// Реквизиты платёжной страницы — ровно те, что подставляет police.ge в payment().
const PAY_PAGE = "https://mpi.gc.ge/page1/";
const PAGE_ID = "0B849B8B559D32AE7E2F136C180F5983";
const MERCHANT_ID = "5ACF0AC08EA8263A576BDC08B6E25DED";
const BACK_OK = "https://police.ge/protocol/success.php";
const BACK_FAIL = "https://police.ge/protocol/fail.php?id=";

/** Платёжная ссылка на протокол — ровно та, что собирает police.ge в функции payment(). */
export function paymentUrl(protocolNo, plate) {
  const protocol = encodeURIComponent(protocolNo);
  return (
    `${PAY_PAGE}?lang_code=ka` +
    `&page_id=${PAGE_ID}` +
    `&merch_id=${MERCHANT_ID}` +
    `&back_url_s=${BACK_OK}` +
    `&back_url_f=${BACK_FAIL}${protocol}` +
    `&o.protocolId=${protocol}` +
    `&o.vehicleNumber=${encodeURIComponent(plate)}` +
    "&o.resourceAlias=1"
  );
}

// Открытая часть API платёжного шлюза Банка Грузии. Версия и portal-идентификатор
// взяты из mpi.gc.ge/page1/settings.js — оттуда же их берёт сама страница оплаты.
const PAY_API = "https://mpi.gc.ge/open/api/v4/66EF9A2E6D429D8F0C767574F9353E8B";

/** POST к шлюзу. Возвращает разобранный JSON или null: по мусору судить нельзя. */
async function payApi(path, body) {
  const response = await fetch(`${PAY_API}${path}`, {
    method: "POST",
    headers: {
      "User-Agent": USER_AGENT,
      "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
      "X-Requested-With": "XMLHttpRequest",
      Referer: PAY_PAGE,
      Origin: "https://mpi.gc.ge",
    },
    body,
  });
  return response.json().catch(() => null);
}

/**
 * Оплачен ли протокол на самом деле.
 *
 * МВД проводит оплату с задержкой: оплаченный штраф ещё несколько дней висит в
 * выдаче searchByAuto, и по ней оплату не отличить. Отличает платёжный шлюз —
 * на оплаченный протокол он не открывает форму карты, а сразу отдаёт готовый
 * результат со статусом FAILED. Страница оплаты в этом случае молча уходит на
 * back_url_f, то есть на police.ge/protocol/index.php: это и видно в браузере.
 * Повторяем ровно те два запроса, которые страница делает при загрузке.
 *
 * @returns {Promise<boolean|null>} null — шлюз ответил непонятно, судить нельзя
 */
export async function isPaid(protocolNo, plate) {
  try {
    const { token } = (await payApi("/token")) ?? {};
    if (!token) return null;

    const start = await payApi(
      `/payment/${encodeURIComponent(token)}/start`,
      new URLSearchParams({
        merchantId: MERCHANT_ID,
        "state.redirect": "post_params",
        "state.in_progress": "no",
        back_url_s: BACK_OK,
        back_url_f: `${BACK_FAIL}${protocolNo}`,
        returnUrl: PAY_PAGE,
        lang: "ka",
        "3ds2.supported": "true",
        "params.protocolId": protocolNo,
        "params.vehicleNumber": plate,
        "params.resourceAlias": "1",
      }),
    );

    // Готовый результат на старте, до всякой карты, — заказ отклонили не глядя.
    // CPA_REJECTED ставит биллинг полиции: он и есть тот, кто знает про долг,
    // поэтому его отказ читаем как «платить нечего». Отказ с другим кодом мог
    // прийти по своей причине — оплаченным штраф по нему не считаем.
    if (start?.result?.extendedCode === "CPA_REJECTED") return true;
    // «input» — шлюз просит карту, значит платить есть за что.
    return start?.state ? false : null;
  } catch {
    return null;
  }
}
