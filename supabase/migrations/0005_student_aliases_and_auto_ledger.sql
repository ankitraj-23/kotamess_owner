-- KotaMess Owner — student aliases + semi-automatic ledger support.
-- Run after 0001_init.sql … 0004_dashboard_ledger.sql.
--
-- Adds:
--   1. student_aliases — alternate names (from WhatsApp / manual correction)
--      that map onto a canonical students row, so short names like "Amit" can
--      be linked to "Amit Sharma" and auto-link on future imports.
--   2. A unique guard so an approved meal_request can produce at most ONE
--      auto-created ledger entry (idempotent re-approval).
--
-- RLS is NOT weakened: student_aliases gets its own per-owner policies, and the
-- existing ledger_entries policies are untouched.

-- ---------------------------------------------------------------------------
-- 1. student_aliases
-- ---------------------------------------------------------------------------
create table if not exists public.student_aliases (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references public.owner_profiles (id) on delete cascade,
  student_id       uuid not null references public.students (id) on delete cascade,
  alias            text not null,
  normalized_alias text not null,
  created_at       timestamptz not null default now()
);

-- One canonical target per normalized alias, per owner. Lets us upsert aliases
-- and guarantees an alias never points at two students for the same owner.
create unique index if not exists student_aliases_owner_norm_uidx
  on public.student_aliases (owner_id, normalized_alias);

create index if not exists student_aliases_owner_id_idx
  on public.student_aliases (owner_id);
create index if not exists student_aliases_student_id_idx
  on public.student_aliases (student_id);

alter table public.student_aliases enable row level security;

drop policy if exists student_aliases_select on public.student_aliases;
create policy student_aliases_select on public.student_aliases
  for select using (owner_id = auth.uid());

drop policy if exists student_aliases_insert on public.student_aliases;
create policy student_aliases_insert on public.student_aliases
  for insert with check (owner_id = auth.uid());

drop policy if exists student_aliases_update on public.student_aliases;
create policy student_aliases_update on public.student_aliases
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists student_aliases_delete on public.student_aliases;
create policy student_aliases_delete on public.student_aliases
  for delete using (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 2. ledger_entries: idempotent auto-ledger per approved request.
--    The meal_request_id column already exists (see 0001_init.sql); we only add
--    a partial unique index so re-approving a request cannot create duplicates.
-- ---------------------------------------------------------------------------
create unique index if not exists ledger_entries_owner_request_uidx
  on public.ledger_entries (owner_id, meal_request_id)
  where meal_request_id is not null;
