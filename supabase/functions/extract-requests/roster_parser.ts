// KotaMess Owner — WhatsApp roster (group join/add) parsing.
//
// Pure, side-effect-free helpers shared by the extract-requests Edge Function.
// Kept in their own module (no `serve()` import) so they can be unit tested
// directly. The DB onboarding (create/match customers) lives in index.ts.
//
// A WhatsApp join/add line carries no sender colon, so it is NEVER a chat
// message. We pull the system "body" (the text after the timestamp prefix) and
// match it against the known join/add phrasings to recover the new member's
// exact display name — preserved verbatim for use as the customer's name + a
// WhatsApp alias so future meal requests link exactly.

// Strip the WhatsApp timestamp prefix and return the system-message body, or
// null when the line has no recognizable header (so it can't be a system line).
// Handles both "12/06/26, 8:32 pm - <body>" and "[12/06/26, 8:32:11 PM] <body>".
export function systemBody(line: string): string | null {
  const cleaned = line.replace(/[‎‏]/g, "").trim();
  let m = cleaned.match(/^\[.{6,28}?\]\s*(.+)$/);
  if (m) return m[1].trim();
  m = cleaned.match(/^.{6,28}?\s-\s(.+)$/);
  if (m) return m[1].trim();
  return null;
}

// Split an "added" name list ("A, B and C") into individual names.
function splitAddedNames(raw: string): string[] {
  return raw
    .split(/\s*,\s*|\s+and\s+/i)
    .map((s) => s.trim())
    .filter((s) => s !== "");
}

// Extract the joined/added member name(s) from a system body, or [] when the
// body is not a join/add event. Conservative: only the documented WhatsApp
// phrasings are matched, so ordinary notices ("You created this group",
// "Anyone in this group can invite…", the encryption notice) yield nothing.
export function rosterNamesFromBody(body: string): string[] {
  const b = body.replace(/\s+/g, " ").trim();
  if (b === "") return [];

  // "<Name> joined using a group link." / "…using this group's invite link"
  let m = b.match(/^(.+?)\s+joined\s+using\s+.*link\.?$/i);
  if (m) return [m[1].trim()];

  // "<Name> joined this group" / "<Name> joined the group" / "<Name> joined"
  m = b.match(/^(.+?)\s+joined(?:\s+(?:this|the)\s+group)?\.?$/i);
  if (m) return [m[1].trim()];

  // "<Name> was added"
  m = b.match(/^(.+?)\s+was added\.?$/i);
  if (m) return [m[1].trim()];

  // "You added <Name>[, <Name> and <Name>]"
  m = b.match(/^You added (.+?)\.?$/i);
  if (m) return splitAddedNames(m[1]);

  // "<Adder> added <Name>[, <Name> and <Name>]" — the added people are the new
  // members; the adder (group 1) is the owner/admin and is ignored.
  m = b.match(/^(?:.+?) added (.+?)\.?$/i);
  if (m) return splitAddedNames(m[1]);

  return [];
}

// True when a line is a group system/notification line (join/add event OR a
// non-roster notice). Used by parseWhatsApp to drop these lines so they never
// pollute meal-request text. Only lines with a real timestamp header but no
// chat-message sender colon are considered.
export function isGroupSystemLine(line: string): boolean {
  const body = systemBody(line);
  if (body === null) return false;
  // A real chat message ("<Sender>: <text>") is not a system line.
  if (/^[^:]{1,60}?:\s+\S/.test(body)) return false;
  if (rosterNamesFromBody(body).length > 0) return true;
  return /\b(created this group|added|removed|left|changed the subject|changed this group|changed their phone number|are end-to-end encrypted|can invite new members|security code|pinned a message|deleted this message|turned (on|off))/i
    .test(body);
}

// Parse every join/add event in the export into a list of raw display names
// (verbatim, order preserved; deduped later in onboardRoster).
export function parseRosterEvents(raw: string): string[] {
  const lines = raw.replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n");
  const names: string[] = [];
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (line === "") continue;
    const body = systemBody(line);
    if (body === null) continue;
    if (/^[^:]{1,60}?:\s+\S/.test(body)) continue; // a chat message, not a system line
    for (const name of rosterNamesFromBody(body)) names.push(name);
  }
  return names;
}
