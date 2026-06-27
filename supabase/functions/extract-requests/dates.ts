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
