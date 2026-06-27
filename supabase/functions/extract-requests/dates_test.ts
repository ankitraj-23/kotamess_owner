// Unit tests for relative meal-date resolution.
// Run: deno test supabase/functions/extract-requests/dates_test.ts

import { assertEquals } from "https://deno.land/std@0.168.0/testing/asserts.ts";
import { detectDateLabel, resolveDate, resolveMealDateFromText } from "./dates.ts";
import { parseTimestamp } from "./fingerprint.ts";

// The verification chat is all sent on 27/06/26 8:0x pm.
const ts = parseTimestamp("27/06/26, 8:00 pm");

function mealDate(text: string): string | null {
  return resolveMealDateFromText(text, ts, "2026-06-27").date;
}

Deno.test("verification chat resolves each meal date from the message timestamp", () => {
  assertEquals(mealDate("aaj lunch cancel"), "2026-06-27");
  assertEquals(mealDate("kal dinner extra"), "2026-06-28");
  assertEquals(mealDate("parso 2 lunch extra"), "2026-06-29");
  assertEquals(mealDate("tomorrow 3 dinner extra"), "2026-06-28");
  assertEquals(mealDate("day after tomorrow lunch cancel"), "2026-06-29");
});

Deno.test("detectDateLabel classifies the supported words", () => {
  assertEquals(detectDateLabel("aaj lunch cancel"), "today");
  assertEquals(detectDateLabel("aj lunch cancel"), "today");
  assertEquals(detectDateLabel("kal dinner extra"), "tomorrow");
  assertEquals(detectDateLabel("tomorrow 3 dinner"), "tomorrow");
  assertEquals(detectDateLabel("parso 2 lunch extra"), "day_after_tomorrow");
  assertEquals(detectDateLabel("parson lunch"), "day_after_tomorrow");
  assertEquals(detectDateLabel("day after tomorrow lunch"), "day_after_tomorrow");
  assertEquals(detectDateLabel("dinner extra"), "unspecified");
});

Deno.test("kal is always tomorrow (future), never yesterday", () => {
  assertEquals(mealDate("kal lunch cancel kar dena"), "2026-06-28");
});

Deno.test("short date words don't match inside unrelated words", () => {
  // "nikal" contains "kal", "raj" contains "aj" — neither is a date word.
  assertEquals(detectDateLabel("nikal dena lunch"), "unspecified");
  assertEquals(detectDateLabel("raj dinner extra"), "unspecified");
});

Deno.test("the message timestamp is the base, not the import date", () => {
  // Message sent on 2026-01-10; importing it months later must still use the
  // message day. fallbackToday (the import date) is deliberately far away.
  const jan = parseTimestamp("10/01/26, 9:00 pm");
  assertEquals(
    resolveMealDateFromText("kal dinner extra", jan, "2026-06-27").date,
    "2026-01-11",
  );
});

Deno.test("falls back to the import date when the message has no timestamp", () => {
  assertEquals(
    resolveMealDateFromText("kal dinner extra", null, "2026-06-27").date,
    "2026-06-28",
  );
  // No relative word + no timestamp -> null (existing default behavior).
  assertEquals(
    resolveMealDateFromText("dinner extra", null, "2026-06-27").date,
    null,
  );
});

Deno.test("a weekday resolves to its next occurrence after the base", () => {
  // 2026-06-27 is a Saturday; next Sunday is 2026-06-28.
  assertEquals(resolveDate("Sunday", "2026-06-27"), "2026-06-28");
  // Same weekday as base -> the following week, never the base day itself.
  assertEquals(resolveDate("Saturday", "2026-06-27"), "2026-07-04");
});
