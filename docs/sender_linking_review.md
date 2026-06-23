# Ambiguous WhatsApp sender review (Week 6)

## Why
A WhatsApp chat export only includes a **phone number** for senders who are
**not saved** in the owner's (Priya's) phone contacts. For **saved** contacts it
includes Priya's **saved contact name**. So if Priya saved two different
students both as "Rahul", the export only says "Rahul" — the phone identity is
gone. The app must **not guess** in that case.

## What changed
- **Stopped auto-linking duplicate names.** A saved name that matches more than
  one **active** customer is marked `ambiguous` and left **unlinked**.
- **Explicit sender link status** on each request (`meal_requests`, migration
  `0011`): `link_status` ∈ `linked | needs_review | ambiguous |
  unreliable_sender`, plus `sender_raw`, `sender_normalized`, `link_reason`,
  `candidate_student_ids`.
- **Ambiguous sender review flow** in Import Detail ("Review unclear students").
- **Reliability nudge** shown only for duplicate-name ambiguity.
- Linking an ambiguous duplicate name fixes **only that request** — the generic
  name is **never** saved as a global alias.

## Matching order (server: `extract-requests` `resolveSenders`)
0. **Unreliable sender** (empty / `null` / `undefined` / symbol-only /
   emoji-only / < 2 alphanumeric chars) → `unreliable_sender`, never linked,
   never creates a customer.
1. **Phone-shaped sender** (normalised to a 10-digit Indian number):
   - exactly one active customer with that phone → `linked`
   - more than one → `ambiguous` (candidates listed)
   - none → `needs_review` (never creates a customer named after a number)
2. **Saved alias** (`student_aliases`): exactly one active → `linked`;
   more than one → `ambiguous`.
3. **Exact normalized name**: exactly one active customer → `linked`.
4. **More than one active customer** with the same normalized name → `ambiguous`
   (the duplicate "Rahul" case), left unlinked.
5. **No exact active match** → `needs_review`, `student_id` stays null. The
   import **never auto-creates a customer** from a chat sender name (a spelling
   variant like "Ashirvad" vs "Ashirwad" would otherwise duplicate a real
   student). Fuzzy lookalikes (shared name token, or a small edit distance) are
   attached as `candidate_student_ids` **suggestions only**.

Fuzzy/partial similarity is used **only** to surface suggestions in the review
sheet — it never auto-links and never creates a customer. Creating a customer is
an explicit owner action in the resolve sheet.

## What Priya sees
Import Detail shows a **"Review unclear students"** section (only when there is
something to fix) with the explainer: *"WhatsApp export uses your saved contact
name. If two students are saved as the same name, Kotamess cannot safely know
who sent the message."* Each unclear request shows the sender exactly as
exported, the message, request type/meal/date, the reason (e.g. "2 active
customers saved as 'Rahul'"), and the likely candidate students (name, room,
phone, status). **Resolve** opens a sheet to **Link** to a chosen student or
**Leave unlinked / Not sure**. For ambiguous duplicate names it also shows the
tip: *"rename duplicate WhatsApp contacts with a unique hint, like Rahul 204…"*.

## Manual acceptance cases
| # | Setup | Sender | Expected |
|---|-------|--------|----------|
| 1 | Active: "Rahul Room 204", "Rahul Room 317" | `Rahul` | `link_status = ambiguous`, no auto-link, both shown as candidates, review prompts a choice; picking one fixes that request only; **no** alias "Rahul" saved. |
| 2 | Active: "Aman", phone 9876543210 | `+91 98765 43210` | auto-linked to Aman (`link_status = linked`, phone wins). |
| 3 | Active: "Ashirwad Paswan" | `Ashirvad Paswan: Lunch cancel tomorrow` | **not** auto-linked, **no** new customer auto-created, `link_status = needs_review`; "Ashirwad Paswan" appears as a fuzzy suggestion (edit distance 1) in `candidate_student_ids`; Priya links it manually in the review flow. |
| 4 | — | `null` (or empty / emoji-only) | `link_status = unreliable_sender`, unlinked, needs manual review, never creates a customer. |

## Checks run
- `deno check supabase/functions/extract-requests/index.ts` → passes.
- `flutter analyze` → no issues.
- `flutter test` → passes.
- No `service_role` key in `lib/` or the Edge Function (anon key + user JWT only).
