// Unit tests for the lunch/dinner quantity parser.
// Run: deno test supabase/functions/extract-requests/quantity_test.ts

import { assertEquals } from "https://deno.land/std@0.168.0/testing/asserts.ts";
import { clampDelta, deltasFor, detectQuantity } from "./quantity.ts";

// Mirror of normalize() in index.ts so test inputs match what the parser sees.
function normalize(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

Deno.test("detectQuantity reads a number word before a meal word", () => {
  assertEquals(detectQuantity(normalize("kal do lunch extra dena")), 2);
  assertEquals(detectQuantity(normalize("do dinner cancel kar dena")), 2);
  assertEquals(detectQuantity(normalize("do lunch kam kar dena")), 2);
});

Deno.test("detectQuantity reads a bare digit", () => {
  assertEquals(detectQuantity(normalize("aaj 3 dinner extra")), 3);
  assertEquals(detectQuantity(normalize("kal 2 lunch kam kar dena")), 2);
});

Deno.test("detectQuantity ignores a trailing 'kar do' (do = 'do it', not 2)", () => {
  assertEquals(detectQuantity(normalize("dinner cancel kar do")), 1);
  assertEquals(detectQuantity(normalize("lunch cancel kar do")), 1);
});

Deno.test("detectQuantity defaults to 1 with no number", () => {
  assertEquals(detectQuantity(normalize("lunch cancel")), 1);
  assertEquals(detectQuantity(normalize("lunch dinner cancel")), 1);
});

Deno.test("deltasFor maps the brief's worked examples", () => {
  // "kal do lunch extra dena" -> add_meal, lunch, qty 2
  assertEquals(deltasFor("add_meal", "lunch", 2), { lunch: 2, dinner: 0 });
  // "aaj 3 dinner extra" -> add_meal, dinner, qty 3
  assertEquals(deltasFor("add_meal", "dinner", 3), { lunch: 0, dinner: 3 });
  // "kal 2 lunch kam kar dena" -> cancel_meal, lunch, qty 2
  assertEquals(deltasFor("cancel_meal", "lunch", 2), { lunch: -2, dinner: 0 });
  // "do dinner cancel kar dena" -> cancel_meal, dinner, qty 2
  assertEquals(deltasFor("cancel_meal", "dinner", 2), { lunch: 0, dinner: -2 });
  // "lunch cancel" -> -1 lunch
  assertEquals(deltasFor("cancel_meal", "lunch", 1), { lunch: -1, dinner: 0 });
  // "dinner cancel" -> -1 dinner
  assertEquals(deltasFor("cancel_meal", "dinner", 1), { lunch: 0, dinner: -1 });
  // "lunch dinner cancel" -> -1 / -1
  assertEquals(deltasFor("cancel_meal", "both", 1), { lunch: -1, dinner: -1 });
});

Deno.test("deltasFor: both_meals_cancel removes both meals", () => {
  assertEquals(deltasFor("both_meals_cancel", "both", 1), { lunch: -1, dinner: -1 });
  assertEquals(deltasFor("both_meals_cancel", "none", 2), { lunch: -2, dinner: -2 });
});

Deno.test("deltasFor: non-meal types never carry a delta", () => {
  assertEquals(deltasFor("pause_mess", "both", 3), { lunch: 0, dinner: 0 });
  assertEquals(deltasFor("payment_note", "none", 2), { lunch: 0, dinner: 0 });
  assertEquals(deltasFor("unclear", "lunch", 5), { lunch: 0, dinner: 0 });
});

Deno.test("clampDelta keeps integers within the sane cap", () => {
  assertEquals(clampDelta(2), 2);
  assertEquals(clampDelta(-1), -1);
  assertEquals(clampDelta(0), 0);
  assertEquals(clampDelta(999), 20);
  assertEquals(clampDelta(-999), -20);
  assertEquals(clampDelta(Number.NaN), 0);
  assertEquals(clampDelta(2.9), 2);
});
