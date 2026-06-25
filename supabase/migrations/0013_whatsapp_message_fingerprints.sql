-- KotaMess Owner — WhatsApp import idempotency via message fingerprints.
-- Run after 0008_chat_imports_history.sql … 0012_*.sql.
--
-- PROBLEM: re-importing the SAME WhatsApp .txt export recreated requests the
-- owner had already accepted/rejected, because duplicate detection keyed off
-- request status / recent meal_requests only. A re-export also re-formats
-- whitespace and am/pm spacing, so a raw text compare can't catch it.
--
-- FIX: an owner-scoped registry of every imported message's normalized
-- fingerprint. The Edge Function fingerprints each parsed message
-- (owner + normalized sender + normalized timestamp + normalized text), skips
-- the ones already in this table BEFORE extraction, and records the genuinely
-- new ones. Idempotency is therefore independent of request status.
--
-- This migration is ADDITIVE and idempotent. It does NOT touch any UI / AI code
-- and requires NO app update — only `supabase db push` + redeploy of the
-- extract-requests function.
--
-- owner_id -> owner_profiles.id (== auth uid), matching every other table here.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- whatsapp_message_fingerprints  (one row per distinct imported message)
-- ---------------------------------------------------------------------------
-- The primary key (owner_id, message_fingerprint) is BOTH the dedup identity
-- and the concurrency guard: two imports racing on the same message can only
-- insert the row once. message_fingerprint is a hex SHA-256 (see below).
-- chat_message_id is an optional back-link to the source row (set null if that
-- message row is later deleted) — handy for debugging, never required for dedup.
create table if not exists public.whatsapp_message_fingerprints (
  owner_id            uuid not null references public.owner_profiles (id) on delete cascade,
  message_fingerprint text not null,
  chat_message_id     uuid references public.chat_messages (id) on delete set null,
  created_at          timestamptz not null default now(),
  primary key (owner_id, message_fingerprint)
);

create index if not exists whatsapp_message_fingerprints_owner_idx
  on public.whatsapp_message_fingerprints (owner_id);

-- ===========================================================================
-- Row Level Security  (same model as 0008_chat_imports_history.sql)
-- ===========================================================================
alter table public.whatsapp_message_fingerprints enable row level security;

drop policy if exists whatsapp_message_fingerprints_select on public.whatsapp_message_fingerprints;
create policy whatsapp_message_fingerprints_select on public.whatsapp_message_fingerprints
  for select using (owner_id = auth.uid());

drop policy if exists whatsapp_message_fingerprints_insert on public.whatsapp_message_fingerprints;
create policy whatsapp_message_fingerprints_insert on public.whatsapp_message_fingerprints
  for insert with check (owner_id = auth.uid());

drop policy if exists whatsapp_message_fingerprints_update on public.whatsapp_message_fingerprints;
create policy whatsapp_message_fingerprints_update on public.whatsapp_message_fingerprints
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists whatsapp_message_fingerprints_delete on public.whatsapp_message_fingerprints;
create policy whatsapp_message_fingerprints_delete on public.whatsapp_message_fingerprints
  for delete using (owner_id = auth.uid());

-- ===========================================================================
-- Backfill from existing chat_messages
-- ===========================================================================
-- So messages imported BEFORE this migration are already "known" and a first
-- re-import after deploying won't re-offer them.
--
-- The fingerprint MUST match supabase/functions/extract-requests/fingerprint.ts
-- byte-for-byte. Canonical string (parts joined with U+0001):
--   owner_id  |  norm(sender_name)  |  epoch-seconds(message_timestamp)  |  norm(message_text)
-- where norm(x) lower-cases, turns the narrow no-break space (U+202F) and the
-- non-breaking space (U+00A0) into a normal space, collapses whitespace runs and
-- trims. message_timestamp was stored from the SAME parseTimestamp(), so its
-- whole-second epoch equals the function's Math.floor(getTime()/1000).
insert into public.whatsapp_message_fingerprints (owner_id, message_fingerprint, chat_message_id, created_at)
select distinct on (owner_id, message_fingerprint)
  owner_id, message_fingerprint, id as chat_message_id, created_at
from (
  select
    cm.owner_id,
    cm.id,
    cm.created_at,
    encode(
      extensions.digest(
        convert_to(
        cm.owner_id::text
          || E'\u0001'
          || trim(regexp_replace(lower(translate(coalesce(cm.sender_name, ''), E'\u202F\u00A0', '  ')), '\s+', ' ', 'g'))
          || E'\u0001'
          || coalesce(floor(extract(epoch from cm.message_timestamp))::bigint::text, '')
          || E'\u0001'
          || trim(regexp_replace(lower(translate(coalesce(cm.message_text, ''), E'\u202F\u00A0', '  ')), '\s+', ' ', 'g')),
          'UTF8'
        ),
        'sha256'
      ),
      'hex'
    ) as message_fingerprint
  from public.chat_messages cm
) f
order by owner_id, message_fingerprint, created_at
on conflict (owner_id, message_fingerprint) do nothing;
