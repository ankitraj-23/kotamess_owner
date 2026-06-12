-- KotaMess Owner — Row Level Security
-- Run after 0001_init.sql.
--
-- Goal: every owner can read and write ONLY their own rows. owner_profiles is
-- keyed on the auth uid directly; every other table is scoped through owner_id.
--
-- Policies are split per command so the intent is explicit. INSERT/UPDATE use
-- WITH CHECK to stop a user from writing rows owned by someone else.

-- ---------------------------------------------------------------------------
-- owner_profiles
-- ---------------------------------------------------------------------------
alter table public.owner_profiles enable row level security;

drop policy if exists owner_profiles_select on public.owner_profiles;
create policy owner_profiles_select on public.owner_profiles
  for select using (id = auth.uid());

drop policy if exists owner_profiles_insert on public.owner_profiles;
create policy owner_profiles_insert on public.owner_profiles
  for insert with check (id = auth.uid());

drop policy if exists owner_profiles_update on public.owner_profiles;
create policy owner_profiles_update on public.owner_profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists owner_profiles_delete on public.owner_profiles;
create policy owner_profiles_delete on public.owner_profiles
  for delete using (id = auth.uid());

-- ---------------------------------------------------------------------------
-- students
-- ---------------------------------------------------------------------------
alter table public.students enable row level security;

drop policy if exists students_select on public.students;
create policy students_select on public.students
  for select using (owner_id = auth.uid());

drop policy if exists students_insert on public.students;
create policy students_insert on public.students
  for insert with check (owner_id = auth.uid());

drop policy if exists students_update on public.students;
create policy students_update on public.students
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists students_delete on public.students;
create policy students_delete on public.students
  for delete using (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- imported_messages
-- ---------------------------------------------------------------------------
alter table public.imported_messages enable row level security;

drop policy if exists imported_messages_select on public.imported_messages;
create policy imported_messages_select on public.imported_messages
  for select using (owner_id = auth.uid());

drop policy if exists imported_messages_insert on public.imported_messages;
create policy imported_messages_insert on public.imported_messages
  for insert with check (owner_id = auth.uid());

drop policy if exists imported_messages_update on public.imported_messages;
create policy imported_messages_update on public.imported_messages
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists imported_messages_delete on public.imported_messages;
create policy imported_messages_delete on public.imported_messages
  for delete using (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- meal_requests
-- ---------------------------------------------------------------------------
alter table public.meal_requests enable row level security;

drop policy if exists meal_requests_select on public.meal_requests;
create policy meal_requests_select on public.meal_requests
  for select using (owner_id = auth.uid());

drop policy if exists meal_requests_insert on public.meal_requests;
create policy meal_requests_insert on public.meal_requests
  for insert with check (owner_id = auth.uid());

drop policy if exists meal_requests_update on public.meal_requests;
create policy meal_requests_update on public.meal_requests
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists meal_requests_delete on public.meal_requests;
create policy meal_requests_delete on public.meal_requests
  for delete using (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- daily_adjustments
-- ---------------------------------------------------------------------------
alter table public.daily_adjustments enable row level security;

drop policy if exists daily_adjustments_select on public.daily_adjustments;
create policy daily_adjustments_select on public.daily_adjustments
  for select using (owner_id = auth.uid());

drop policy if exists daily_adjustments_insert on public.daily_adjustments;
create policy daily_adjustments_insert on public.daily_adjustments
  for insert with check (owner_id = auth.uid());

drop policy if exists daily_adjustments_update on public.daily_adjustments;
create policy daily_adjustments_update on public.daily_adjustments
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists daily_adjustments_delete on public.daily_adjustments;
create policy daily_adjustments_delete on public.daily_adjustments
  for delete using (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- ledger_entries
-- ---------------------------------------------------------------------------
alter table public.ledger_entries enable row level security;

drop policy if exists ledger_entries_select on public.ledger_entries;
create policy ledger_entries_select on public.ledger_entries
  for select using (owner_id = auth.uid());

drop policy if exists ledger_entries_insert on public.ledger_entries;
create policy ledger_entries_insert on public.ledger_entries
  for insert with check (owner_id = auth.uid());

drop policy if exists ledger_entries_update on public.ledger_entries;
create policy ledger_entries_update on public.ledger_entries
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists ledger_entries_delete on public.ledger_entries;
create policy ledger_entries_delete on public.ledger_entries
  for delete using (owner_id = auth.uid());
