/**
 * Живая проверка без Telegram и без деплоя: дёргает police.ge и печатает,
 * что вернулось. Запуск: node scripts/live.mjs A354OC797
 */
import { fetchPlate, isPaid, paymentUrl } from "../src/police.js";
import { renderEvent } from "../src/notify.js";

const plates = process.argv.slice(2).map((p) => p.toUpperCase());
if (plates.length === 0) {
  console.error("укажите госномер: node scripts/live.mjs A354OC797");
  process.exit(1);
}

for (const plate of plates) {
  const fines = await fetchPlate(plate);
  console.log(`\n${plate}: протоколов — ${fines.length}`);
  for (const fine of fines) {
    // Выдача МВД одинакова для оплаченных и неоплаченных — спрашиваем шлюз.
    const paid = await isPaid(fine.protocolNo, plate);
    const type = paid ? "paid" : "new";
    const text = renderEvent({ type, protocolNo: fine.protocolNo, fine }, plate);
    console.log("\n" + text.replace(/<[^>]+>/g, ""));
    if (paid === null) console.log("⚠️ шлюз ответил непонятно — считаем неоплаченным");
    if (!paid) console.log("💳 " + paymentUrl(fine.protocolNo, plate));
  }
}
