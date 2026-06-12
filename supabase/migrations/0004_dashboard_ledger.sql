-- KotaMess Owner — dashboard, daily count and ledger support.
-- Run after 0001_init.sql, 0002_rls.sql and 0003_meal_requests_extraction.sql.
--
-- Adds the owner-level base meal counts that the Daily screen uses as its
-- starting point, and reshapes ledger_entries so the Ledger screen can record
-- simple owner-typed entries (payment / due / adjustment / note) per student
-- name without requiring a linked students row. RLS is untouched: every policy
-- keys on owner_id / id, which do not change here.

-- ---------------------------------------------------------------------------
-- owner_profiles: base lunch / dinner counts for the daily preparation total.
-- ---------------------------------------------------------------------------
alter table public.owner_profiles
  add column if not exists default_lunch_count integer not null default 0;
alter table public.owner_profiles
  add column if not exists default_dinner_count integer not null default 0;

-- ---------------------------------------------------------------------------
-- ledger_entries: allow the owner to type a student name and use the wider
-- entry vocabulary the Ledger screen exposes.
-- ---------------------------------------------------------------------------
alter table public.ledger_entries
  add column if not exists student_name text not null default '';

-- Amount may legitimately be 0 (e.g. a note), so relax any NOT NULL default to 0.
alter table public.ledger_entries alter column amount set default 0;

-- Reinstall the entry_type CHECK with the new vocabulary. 'charge' is kept so
-- any pre-existing rows remain valid.
alter table public.ledger_entries drop constraint if exists ledger_entries_entry_type_check;
alter table public.ledger_entries add constraint ledger_entries_entry_type_check
  check (entry_type in ('payment','due','adjustment','note','charge'));

create index if not exists ledger_entries_owner_created_idx
  on public.ledger_entries (owner_id, created_at desc);
