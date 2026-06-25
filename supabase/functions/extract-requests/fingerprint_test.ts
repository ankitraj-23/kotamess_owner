// Unit tests for WhatsApp message fingerprinting (import idempotency).
// Run: deno test supabase/functions/extract-requests/fingerprint_test.ts
//
// The KNOWN-ANSWER vectors below were computed independently (Python) using the
// SAME normalization the SQL backfill in
// 0013_whatsapp_message_fingerprints.sql performs. Asserting the TypeScript
// fingerprint equals them proves the function and the migration agree
// byte-for-byte, so a backfilled fingerprint matches a freshly computed one.

import { assertEquals, assertNotEquals } from "https://deno.land/std@0.168.0/testing/asserts.ts";
import { messageFingerprint, normalizeForFingerprint } from "./fingerprint.ts";

const OWNER_A = "11111111-1111-1111-1111-111111111111";
const OWNER_B = "22222222-2222-2222-2222-222222222222";

// Narrow no-break space (U+202F) is what WhatsApp puts before am/pm.
const NNBSP = " ";
const NBSP = " ";

Deno.test("known-answer vector matches the SQL backfill normalization", async () => {
  const fp = await messageFingerprint(
    OWNER_A,
    "Kiran A142",
    "25/06/2026, 8:47 am",
    "Aaj dinner mat bhejna",
  );
  assertEquals(fp, "b489908fc9dc341f39628e8f28fdcecf0b4c16cb1c68bdf405566ec08995c5a2");
});

Deno.test("same message imported twice -> identical fingerprint (re-import skips it)", async () => {
  const a = await messageFingerprint(OWNER_A, "Kiran A142", "25/06/2026, 8:47 am", "Aaj dinner mat bhejna");
  const b = await messageFingerprint(OWNER_A, "Kiran A142", "25/06/2026, 8:47 am", "Aaj dinner mat bhejna");
  assertEquals(a, b);
});

Deno.test("narrow no-break space and normal space am/pm normalize the same", async () => {
  // Re-exports differ only by the space before "am": U+202F vs a normal space.
  const narrow = await messageFingerprint(OWNER_A, "Kiran A142", `25/06/2026, 8:47${NNBSP}am`, "Aaj dinner mat bhejna");
  const normal = await messageFingerprint(OWNER_A, "Kiran A142", "25/06/2026, 8:47 am", "Aaj dinner mat bhejna");
  assertEquals(narrow, normal);
});

Deno.test("whitespace quirks in text normalize the same (nbsp, repeated, trailing)", async () => {
  const base = await messageFingerprint(OWNER_A, "Kiran A142", "25/06/2026, 8:47 am", "Aaj dinner mat bhejna");
  const messy = await messageFingerprint(
    OWNER_A,
    "Kiran A142",
    "25/06/2026, 8:47 am",
    `  Aaj${NBSP}dinner   mat  bhejna  `,
  );
  assertEquals(messy, base);
});

Deno.test("equivalent timestamp formatting (2- vs 4-digit year, 12h vs 24h) matches", async () => {
  const a = await messageFingerprint(OWNER_A, "Kiran A142", "25/06/2026, 8:47 am", "Aaj dinner mat bhejna");
  const twoDigit = await messageFingerprint(OWNER_A, "Kiran A142", "25/06/26, 8:47 am", "Aaj dinner mat bhejna");
  const h24 = await messageFingerprint(OWNER_A, "Kiran A142", "25/06/2026, 08:47", "Aaj dinner mat bhejna");
  assertEquals(twoDigit, a);
  assertEquals(h24, a);
});

Deno.test("same sender/text but a different timestamp -> different message", async () => {
  const t847 = await messageFingerprint(OWNER_A, "Kiran A142", "25/06/2026, 8:47 am", "Aaj dinner mat bhejna");
  const t848 = await messageFingerprint(OWNER_A, "Kiran A142", "25/06/2026, 8:48 am", "Aaj dinner mat bhejna");
  assertNotEquals(t847, t848);
});

Deno.test("same timestamp/text but a different owner -> different fingerprint (allowed)", async () => {
  const a = await messageFingerprint(OWNER_A, "Kiran A142", "25/06/2026, 8:47 am", "Aaj dinner mat bhejna");
  const b = await messageFingerprint(OWNER_B, "Kiran A142", "25/06/2026, 8:47 am", "Aaj dinner mat bhejna");
  assertNotEquals(a, b);
  assertEquals(b, "994f6d24149f3ef80ea660f69bfa3b43c9906e9f0629fafb351e7ff530a73474");
});

Deno.test("a message with no parseable timestamp uses an empty timestamp key", async () => {
  const fp = await messageFingerprint(OWNER_A, "Kiran A142", "", "Aaj dinner mat bhejna");
  assertEquals(fp, "7033e355780a0a12343580e5ee46886de417235e47a3c36f471a2eed7ff0ab99");
});

Deno.test("normalizeForFingerprint collapses unicode spaces, repeats, and trims", () => {
  assertEquals(normalizeForFingerprint(`  Aaj${NNBSP}dinner${NBSP}mat   bhejna  `), "aaj dinner mat bhejna");
  assertEquals(normalizeForFingerprint(""), "");
});
