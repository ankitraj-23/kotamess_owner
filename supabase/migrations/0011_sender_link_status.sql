-- KotaMess Owner — ambiguous WhatsApp sender identity (Week 6 fix).
-- Run after 0001_init.sql … 0010_meal_cutoff_settings.sql.
--
-- Background: a WhatsApp export only gives a phone number for senders who are
-- NOT saved in the owner's phone contacts. For SAVED contacts it gives the
-- owner's saved contact NAME. So if the owner saved two different students as
-- "Rahul", the export only says "Rahul" and the phone identity is lost. In that
-- case the app must NOT guess — it records the sender as ambiguous and asks the
-- owner to resolve it manually.
--
-- This migration is ADDITIVE and idempotent. It only adds nullable columns to
-- the EXISTING meal_requests table (which is the app's extracted_requests
-- table). No columns are renamed/dropped and no RLS policy is touched — the
-- existing owner_id-keyed policies (0002_rls.sql) continue to hold.

-- The sender exactly as exported (saved contact name, or a raw phone number for
-- unsaved contacts). Distinct from student_name, which may be edited/canonical.
alter table public.meal_requests
  add column if not exists sender_raw text;

-- Deterministic normalized form of sender_raw (lowercased, punctuation/emoji
-- stripped, honorifics dropped) — the key used for matching.
alter table public.meal_requests
  add column if not exists sender_normalized text;

-- How the sender was resolved to a customer:
--   linked            — auto-linked to exactly one active customer (phone /
--                       alias / unique name), or a brand-new customer created.
--   needs_review      — no confident match (e.g. phone matched nobody, or only
--                       an inactive customer matches). Owner should confirm.
--   ambiguous         — the saved name matches >1 active customer (the duplicate
--                       "Rahul" case). Left UNLINKED on purpose; owner must pick.
--   unreliable_sender — sender is empty / "null" / symbol- or emoji-only / has
--                       too little usable text to ever auto-link.
-- Nullable so pre-existing rows (which predate this column) stay valid; the app
-- falls back to "student_id is null" for those.
alter table public.meal_requests
  add column if not exists link_status text;

alter table public.meal_requests
  drop constraint if exists meal_requests_link_status_check;
alter table public.meal_requests
  add constraint meal_requests_link_status_check
  check (link_status is null or link_status in
    ('linked', 'needs_review', 'ambiguous', 'unreliable_sender'));

-- Human-readable explanation of the link_status decision, e.g.
-- "2 customers named “Rahul” — left unlinked; choose the right one in review."
alter table public.meal_requests
  add column if not exists link_reason text;

-- Candidate customers the owner can choose from when the sender is ambiguous or
-- needs review: a JSON array of students.id values. NULL/[] when not applicable.
alter table public.meal_requests
  add column if not exists candidate_student_ids jsonb;

-- Speeds up the "unclear senders for this import" review query.
create index if not exists meal_requests_owner_import_link_status_idx
  on public.meal_requests (owner_id, import_id, link_status);
