// Unit tests for the WhatsApp roster (group join/add) parser.
// Run: deno test supabase/functions/extract-requests/roster_parser_test.ts

import { assertEquals } from "https://deno.land/std@0.168.0/testing/asserts.ts";
import {
  isGroupSystemLine,
  parseRosterEvents,
  rosterNamesFromBody,
  systemBody,
} from "./roster_parser.ts";

Deno.test("parses the brief's sample: join names found, notices ignored", () => {
  const sample = [
    "24/06/2026, 6:39 pm - Messages and calls are end-to-end encrypted. Only people in this chat can read, listen to, or share them. Learn more",
    "24/06/2026, 6:39 pm - You created this group",
    "24/06/2026, 6:40 pm - Vishal joined using a group link.",
    "24/06/2026, 6:41 pm - Rahul Room 204 joined using a group link.",
    "24/06/2026, 6:42 pm - Anyone in this group can invite new members using a group link.",
    "24/06/2026, 8:10 pm - Rahul Room 204: No dinner today",
  ].join("\n");

  // Only the two real join events are returned, verbatim. The encryption
  // notice, "You created this group", the invite-link line and the meal
  // message are all ignored by the roster parser.
  assertEquals(parseRosterEvents(sample), ["Vishal", "Rahul Room 204"]);
});

Deno.test("duplicate join lines are returned per-line (dedupe happens in onboarding)", () => {
  const sample = [
    "24/06/2026, 6:40 pm - Rahul Room 204 joined using a group link.",
    "24/06/2026, 6:41 pm - Rahul Room 204 joined using a group link.",
  ].join("\n");
  // The parser preserves both; onboardRoster dedupes by normalized name so only
  // one customer/alias is ever created.
  assertEquals(parseRosterEvents(sample), ["Rahul Room 204", "Rahul Room 204"]);
});

Deno.test("supports join/add phrasings", () => {
  assertEquals(rosterNamesFromBody("Vishal joined using a group link."), [
    "Vishal",
  ]);
  assertEquals(rosterNamesFromBody("Vishal joined this group"), ["Vishal"]);
  assertEquals(rosterNamesFromBody("Vishal joined"), ["Vishal"]);
  assertEquals(
    rosterNamesFromBody("Rahul Room 204 joined using this group's invite link"),
    ["Rahul Room 204"],
  );
  assertEquals(rosterNamesFromBody("You added Vishal"), ["Vishal"]);
  assertEquals(rosterNamesFromBody("Vishal was added"), ["Vishal"]);
  assertEquals(rosterNamesFromBody("Priya added Vishal"), ["Vishal"]);
  assertEquals(rosterNamesFromBody("You added Vishal, Rahul and Aman"), [
    "Vishal",
    "Rahul",
    "Aman",
  ]);
});

Deno.test("ignores non-roster system notices", () => {
  for (
    const body of [
      "You created this group",
      "Anyone in this group can invite new members using a group link.",
      "Messages and calls are end-to-end encrypted. Only people in this chat can read, listen to, or share them. Learn more",
      "Priya changed the subject to “Mess Group”",
      "Priya left",
      "Priya removed Vishal",
    ]
  ) {
    assertEquals(rosterNamesFromBody(body), [], `should ignore: ${body}`);
  }
});

Deno.test("a real meal message is never treated as a join/system line", () => {
  const line = "24/06/2026, 8:10 pm - Rahul Room 204: No dinner today";
  assertEquals(isGroupSystemLine(line), false);
  assertEquals(parseRosterEvents(line), []);
});

Deno.test("system notices ARE flagged so they don't pollute meal text", () => {
  assertEquals(
    isGroupSystemLine("24/06/2026, 6:39 pm - You created this group"),
    true,
  );
  assertEquals(
    isGroupSystemLine(
      "24/06/2026, 6:40 pm - Vishal joined using a group link.",
    ),
    true,
  );
});

Deno.test("systemBody strips both dash and bracket timestamp formats", () => {
  assertEquals(
    systemBody("24/06/2026, 6:40 pm - Vishal joined using a group link."),
    "Vishal joined using a group link.",
  );
  assertEquals(
    systemBody("[24/06/26, 6:40:00 PM] Vishal joined using a group link."),
    "Vishal joined using a group link.",
  );
  assertEquals(systemBody("no timestamp here"), null);
});
