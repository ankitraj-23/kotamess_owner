// KotaMess Owner — relative meal-date resolution for Hindi/Hinglish date words.
//
// Mess requests are operational and future-looking: "aaj lunch cancel",
// "kal dinner extra", "parso 2 lunch extra". The meal date must be resolved
// against the WhatsApp MESSAGE timestamp (when the student sent it), never the
// import time — re-importing an old chat next week must still place each request
// on its original day.
//
// Kept in its own module (like quantity.ts) so the rules are unit-testable
// without importing the Edge Function entrypoint.

import { NUM_WORDS } from "./quantity.ts";

// Date-focused normalize: lowercase, strip punctuation/symbols to spaces, and
// collapse runs of whitespace. Matches the meaningful part of index.ts's
// normalize() for the words we care about.
function normalizeForDates(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

const WEEKDAYS = [
  "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
];

// Classify a message into a relative date label. Day-after-tomorrow is checked
// first because "day after tomorrow" contains "tomorrow". Word boundaries keep
// short tokens like "aj"/"kal" from matching inside unrelated words. Returns
// "today" | "tomorrow" | "day_after_tomorrow" | a capitalized weekday |
// "unspecified".
export function detectDateLabel(text: string): string {
  const lower = normalizeForDates(text);
  if (/\b(parso|parson|day after tomorrow)\b/.test(lower)) {
    return "day_after_tomorrow";
  }
  if (/\b(aaj|aj|today)\b/.test(lower)) return "today";
  if (/\b(kal|tomorrow|tmrw)\b/.test(lower)) return "tomorrow";
  for (const d of WEEKDAYS) {
    if (new RegExp(`\\b${d}\\b`).test(lower)) {
      return d.charAt(0).toUpperCase() + d.slice(1);
    }
  }
  return "unspecified";
}

// Resolve a date label to an ISO yyyy-mm-dd, relative to [base] (also ISO).
// today -> base, tomorrow -> base+1, day_after_tomorrow -> base+2, a weekday ->
// its next occurrence after base. Returns null for "unspecified"/unknown so the
// caller can fall back to its existing default behavior.
export function resolveDate(label: string, base: string): string | null {
  const d = new Date(base + "T00:00:00Z");
  if (isNaN(d.getTime())) return null;
  const lbl = label.toLowerCase();
  if (lbl === "today") return base;
  if (lbl === "tomorrow") {
    d.setUTCDate(d.getUTCDate() + 1);
    return d.toISOString().slice(0, 10);
  }
  if (lbl === "day_after_tomorrow") {
    d.setUTCDate(d.getUTCDate() + 2);
    return d.toISOString().slice(0, 10);
  }
  const idx = WEEKDAYS.indexOf(lbl);
  if (idx !== -1) {
    let diff = (idx - d.getUTCDay() + 7) % 7;
    if (diff === 0) diff = 7; // next occurrence, not the same weekday
    d.setUTCDate(d.getUTCDate() + diff);
    return d.toISOString().slice(0, 10);
  }
  return null;
}

// Centralized meal-date resolution. Base date is the message's wall-clock day
// (parseTimestamp encodes the parsed local date/time as UTC, so .toISOString()
// yields the same calendar day), falling back to [fallbackToday] (the import
// date) only when the message carried no usable timestamp. Returns the detected
// label plus the resolved ISO date (null when no relative word was found).
export function resolveMealDateFromText(
  messageText: string,
  messageTimestamp: Date | null,
  fallbackToday: string,
): { label: string; date: string | null } {
  const label = detectDateLabel(messageText);
  const base = messageTimestamp
    ? messageTimestamp.toISOString().slice(0, 10)
    : fallbackToday;
  return { label, date: resolveDate(label, base) };
}

// ---------------------------------------------------------------------------
// Date-range pause / cancellation support
// ---------------------------------------------------------------------------
// Some requests pause food for a SPAN of days: "kal se ek hafte tak khana mat
// dena" (from tomorrow, for a week). We detect a narrow set of durations and
// turn them into an inclusive [start, end] range. Intentionally simple — no
// general NLP. Hindi/Hinglish numbers reuse the quantity parser's NUM_WORDS.

// Number alternatives accepted before "din" / "hafte" / "week" / "days".
// "a" covers "for a week".
const DURATION_NUM_ALT =
  "\\d{1,2}|a|ek|do|teen|char|chaar|paanch|panch|chhe|che|saat|one|two|three|four|five|six|seven";

function durationNumber(tok: string): number | null {
  if (tok === "a") return 1;
  if (/^\d{1,2}$/.test(tok)) {
    const n = parseInt(tok, 10);
    return n > 0 ? n : null;
  }
  if (tok in NUM_WORDS) return NUM_WORDS[tok];
  const extra: Record<string, number> = { chhe: 6, che: 6, six: 6, saat: 7, seven: 7 };
  return tok in extra ? extra[tok] : null;
}

function clampDuration(n: number): number {
  return Math.max(1, Math.min(60, Math.trunc(n)));
}

// Inclusive duration in DAYS, or null when no supported duration is present.
//   "ek hafte tak" / "1 hafte" / "one week" / "for a week" -> 7
//   "2 din tak" / "do din tak" / "for 2 days"             -> 2
//   "teen din tak"                                        -> 3
export function detectDurationDays(text: string): number | null {
  const lower = normalizeForDates(text);
  // Weeks first (a week is also "7 days"): optional count + hafta/week.
  const week = lower.match(
    new RegExp(`(?:(${DURATION_NUM_ALT})\\s+)?(hafte|hafta|hafton|week|weeks)\\b`),
  );
  if (week) {
    const n = week[1] ? (durationNumber(week[1]) ?? 1) : 1;
    return clampDuration(n * 7);
  }
  // "<n> din" (Hinglish) or "<n> day(s)" (English).
  const din = lower.match(new RegExp(`(${DURATION_NUM_ALT})\\s+din\\b`));
  if (din) {
    const n = durationNumber(din[1]);
    if (n) return clampDuration(n);
  }
  const days = lower.match(new RegExp(`(${DURATION_NUM_ALT})\\s+days?\\b`));
  if (days) {
    const n = durationNumber(days[1]);
    if (n) return clampDuration(n);
  }
  return null;
}

function addDays(iso: string, days: number): string {
  const d = new Date(iso + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

// Centralized range resolution. Start date is the relative day in the text
// (aaj/kal/parso/… via resolveMealDateFromText), resolved against the message
// timestamp. End date = start + (durationDays - 1), inclusive — or null for a
// single-day request (no duration, or duration of 1). durationDays is returned
// too so the caller can treat a date-range pause as a per-day change (each day
// is -1, not the duration number).
export function resolveMealDateRangeFromText(
  messageText: string,
  messageTimestamp: Date | null,
  fallbackToday: string,
): {
  label: string;
  startDate: string | null;
  endDate: string | null;
  durationDays: number | null;
} {
  const { label, date: startDate } = resolveMealDateFromText(
    messageText,
    messageTimestamp,
    fallbackToday,
  );
  const durationDays = detectDurationDays(messageText);
  let endDate: string | null = null;
  if (startDate && durationDays && durationDays > 1) {
    endDate = addDays(startDate, durationDays - 1);
  }
  return { label, startDate, endDate, durationDays };
}
