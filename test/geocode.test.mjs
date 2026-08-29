import { test } from "node:test";
import assert from "node:assert/strict";
import { parsePlace } from "../src/geocode.js";

test("адрес МВД разбирается на город и улицу с номером дома впереди", () => {
  assert.deepEqual(parsePlace("ქ. ბათუმი ანწუხელიძის ქუჩა N83 (წრიული) 2"), {
    city: "ბათუმი",
    street: "83 ანწუხელიძის ქუჩა",
    cleaned: "ქ. ბათუმი ანწუხელიძის ქუჩა N83",
  });
});

test("адрес без номера дома тоже разбирается", () => {
  const { city, street } = parsePlace("ქ. თბილისი რუსთაველის გამზირი");
  assert.equal(city, "თბილისი");
  assert.equal(street, "რუსთაველის გამზირი");
});

test("строка без префикса «ქ.» уходит в свободный поиск целиком", () => {
  const { city, street } = parsePlace("Rustaveli Ave 12");
  assert.equal(city, "");
  assert.equal(street, "Rustaveli Ave 12");
});

test("пустой адрес не ломает разбор", () => {
  assert.deepEqual(parsePlace(null), { city: "", street: "", cleaned: "" });
});
