// KotaMess Owner — deterministic WhatsApp message fingerprinting.
//
// Pure, side-effect-free helpers shared by the extract-requests Edge Function
// (kept in their own module, like roster_parser.ts, so they can be unit tested
// directly without importing serve()).
//
// PURPOSE: make re-importing the SAME WhatsApp .txt export idempotent. A
// re-export of a chat re-formats whitespace and the am/pm spacing, so a raw
// string compare is not enough. We compute an owner-scoped fingerprint from the
// NORMALIZED (sender, timestamp, text) so the same logical message maps to the
// same fingerprint across re-exports — regardless of:
//   * Unicode narrow no-break space  U+202F  (WhatsApp uses this before am/pm)
//   * non-breaking space             U+00A0
//   * repeated / leading / trailing spaces
//   * inconsistent am/pm spacing      ("8:47 am" vs "8:47 am")
//   * equivalent timestamp formatting (12h/24h, 2- vs 4-digit year, separators)
//
// IMPORTANT: the canonical string + hash below MUST stay byte-for-byte identical
// to the SQL backfill in migration 0013_whatsapp_message_fingerprints.sql, so a
// fingerprint computed here matches one backfilled from an existing
// chat_messages row. If you change normalization, change the migration too.

// Collapse the whitespace variants WhatsApp re-exports introduce into a single
// canonical form: narrow no-break space + nbsp -> normal space, lower-case,
// collapse runs of whitespace, trim. Idempotent (applying twice == once).
export function normalizeForFingerprint(value: string): string {
  return (value ?? "")
    .replace(/[  ]/g, " ")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
}

// Parse a WhatsApp header date/time into a Date (UTC), tolerant of formats.
// Indian exports are day-first: 12/06/26 or 12/06/2026, with 12h or 24h time.
// Returns null when there is no usable timestamp. `\s*` before am/pm matches the
// narrow no-break space WhatsApp uses, so "8:47 am" and "8:47 am" parse to
// the same instant.
export function parseTimestamp(dateText: string): Date | null {
  if (!dateText || dateText.trim() === "") return null;
  const cleaned = dateText.replace(/[‎‏]/g, "").trim();

  const dm = cleaned.match(/(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{2,4})/);
  if (!dm) return null;
  let day = parseInt(dm[1], 10);
  let month = parseInt(dm[2], 10);
  let year = parseInt(dm[3], 10);
  if (year < 100) year += 2000;
  // If clearly month-first (day field > 12 but month field <= 12 is the common
  // case already handled); swap only when the first field can't be a month.
  if (month > 12 && day <= 12) {
    const t = month;
    month = day;
    day = t;
  }
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;

  let hour = 0;
  let minute = 0;
  let second = 0;
  const tm = cleaned.match(/(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([ap])\.?m?\.?/i);
  if (tm) {
    hour = parseInt(tm[1], 10) % 12;
    minute = parseInt(tm[2], 10);
    second = tm[3] ? parseInt(tm[3], 10) : 0;
    if (/p/i.test(tm[4])) hour += 12;
  } else {
    const t24 = cleaned.match(/(\d{1,2}):(\d{2})(?::(\d{2}))?/);
    if (t24) {
      hour = parseInt(t24[1], 10);
      minute = parseInt(t24[2], 10);
      second = t24[3] ? parseInt(t24[3], 10) : 0;
    }
  }
  const ms = Date.UTC(year, month - 1, day, hour, minute, second);
  if (isNaN(ms)) return null;
  return new Date(ms);
}

// Normalize a parsed timestamp to its integer epoch-seconds key (or "" when the
// message has no usable timestamp). Whole seconds only — parseTimestamp never
// produces sub-second precision, which keeps this equal to the SQL backfill's
// floor(extract(epoch from message_timestamp)).
function timestampKey(ts: Date | null): string {
  return ts ? String(Math.floor(ts.getTime() / 1000)) : "";
}

async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const buf = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// Owner-scoped, deterministic fingerprint of one parsed WhatsApp message.
//
// `sender` must already be the cleaned sender (the same value stored in
// chat_messages.sender_name) so this matches the SQL backfill, which normalizes
// that stored column. `dateText` is the raw WhatsApp header date/time string.
//
// The canonical string joins the normalized parts with U+0001 (a control char
// that never appears in chat text, so the fields can't run together), then we
// SHA-256 it. owner_id is part of the canonical string AND the table key, so the
// same message from two different owners yields different fingerprints/rows.
export async function messageFingerprint(
  ownerId: string,
  sender: string,
  dateText: string,
  text: string,
): Promise<string> {
  const canonical = [
    ownerId,
    normalizeForFingerprint(sender),
    timestampKey(parseTimestamp(dateText)),
    normalizeForFingerprint(text),
  ].join("");
  return await sha256Hex(canonical);
}
