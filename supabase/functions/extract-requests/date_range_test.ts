// Unit tests for date-range pause/cancellation resolution.
// Run: deno test supabase/functions/extract-requests/date_range_test.ts

import { assertEquals } from "https://deno.land/std@0.168.0/testing/asserts.ts";
import { detectDurationDays, resolveMealDateRangeFromText } from "./dates.ts";
import { deltasFor } from "./quantity.ts";
import { parseTimestamp } from "./fingerprint.ts";

// All example messages are sent on 27/06/26 8:00 pm.
const ts = parseTimestamp("27/06/26, 8:00 pm");

function range(text: string) {
  return resolveMealDateRangeFromText(text, ts, "2026-06-27");
}

Deno.test("durations parse to inclusive day counts", () => {
  assertEquals(detectDurationDays("kal se ek hafte tak khana mat dena"), 7);
  assertEquals(detectDurationDays("1 hafte tak band"), 7);
  assertEquals(detectDurationDays("one week"), 7);
  assertEquals(detectDurationDays("for a week"), 7);
  assertEquals(detectDurationDays("aaj se 2 din khana band"), 2);
  assertEquals(detectDurationDays("do din tak"), 2);
  assertEquals(detectDurationDays("parso se 3 din lunch mat dena"), 3);
  assertEquals(detectDurationDays("teen din tak"), 3);
  assertEquals(detectDurationDays("for 2 days"), 2);
  assertEquals(detectDurationDays("aaj lunch cancel"), null); // no duration
});

Deno.test("kal se ek hafte tak khana mat dena -> 7-day range, both meals", () => {
  const r = range("mera kal se ek hafte tak khana mat dena");
  assertEquals(r.startDate, "2026-06-28");
  assertEquals(r.endDate, "2026-07-04");
  // Whole-food cancel with no specific meal = both meals, -1 each per day.
  assertEquals(deltasFor("both_meals_cancel", "both", 1), { lunch: -1, dinner: -1 });
});

Deno.test("aaj se 2 din khana band -> 2-day range, both meals", () => {
  const r = range("aaj se 2 din khana band");
  assertEquals(r.startDate, "2026-06-27");
  assertEquals(r.endDate, "2026-06-28");
  assertEquals(deltasFor("both_meals_cancel", "both", 1), { lunch: -1, dinner: -1 });
});

Deno.test("parso se 3 din lunch mat dena -> 3-day range, lunch only", () => {
  const r = range("parso se 3 din lunch mat dena");
  assertEquals(r.startDate, "2026-06-29");
  assertEquals(r.endDate, "2026-07-01");
  // Only lunch named -> lunch -1, dinner 0 (per day). Duration is NOT quantity.
  assertEquals(deltasFor("cancel_meal", "lunch", 1), { lunch: -1, dinner: 0 });
});

Deno.test("single-day requests have no end date (endDate null)", () => {
  assertEquals(range("aaj lunch cancel").endDate, null);
  assertEquals(range("kal dinner extra").endDate, null);
  // A duration of 1 ("1 din") is still single-day.
  assertEquals(range("aaj se 1 din khana band").endDate, null);
});

Deno.test("a duration with no start word yields no range", () => {
  // No relative start word -> start unknown -> no range to anchor.
  assertEquals(range("ek hafte tak khana mat dena").startDate, null);
  assertEquals(range("ek hafte tak khana mat dena").endDate, null);
});

Deno.test("range is based on the message timestamp, not the import date", () => {
  const jan = parseTimestamp("10/01/26, 9:00 pm");
  const r = resolveMealDateRangeFromText(
    "kal se ek hafte tak khana mat dena",
    jan,
    "2026-06-27",
  );
  assertEquals(r.startDate, "2026-01-11");
  assertEquals(r.endDate, "2026-01-17");
});
