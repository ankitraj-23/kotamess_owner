-- KotaMess Owner — billing / payment foundation for production.
-- Run after 0001_init.sql … 0008_chat_imports_history.sql.
--
-- This migration is additive and idempotent. It:
--   * extends the EXISTING public.ledger_entries table (created in 0001 and
--     reshaped in 0004/0005) — it is NOT recreated and no columns are renamed;
--   * creates public.payments and public.monthly_bills if they are missing;
--   * adds owner-scoped RLS, safe indexes and the monthly-bill uniqueness rule.
--
-- Convention note: owner_id references public.owner_profiles(id), exactly like
-- ledger_entries. owner_profiles.id is itself the auth.users(id) primary key,
-- so owner_id == auth.uid() and the RLS predicate (owner_id = auth.uid()) holds
-- identically to a direct auth.users reference. Audit logging stays in the app
-- layer; audit_logs (added in 0006) is untouched.

-- ===========================================================================
-- 1. ledger_entries — extend in place (do not recreate / rename).
-- ===========================================================================

-- New optional, additive columns. `note` is preserved; `description` is added
-- alongside it for the richer billing vocabulary.
alter table public.ledger_entries
  add column if not exists description text;
alter table public.ledger_entries
  add column if not exists updated_at timestamptz not null default now();

-- Widen entry_type to the union of the existing Ledger-tab vocabulary and the
-- new billing entry types, so existing rows and the Ledger screen keep working.
alter table public.ledger_entries
  drop constraint if exists ledger_entries_entry_type_check;
alter table public.ledger_entries
  add constraint ledger_entries_entry_type_check
  check (entry_type in (
    -- existing Ledger-tab values (0001/0004) — kept for backward compatibility
    'payment', 'due', 'adjustment', 'note', 'charge',
    -- new billing values
    'base_plan', 'meal_cancel_credit', 'extra_meal_charge',
    'manual_adjustment', 'payment_adjustment', 'other'
  ));

-- Keep updated_at fresh via the shared trigger function defined in 0001.
drop trigger if exists trg_ledger_entries_updated_at on public.ledger_entries;
create trigger trg_ledger_entries_updated_at
  before update on public.ledger_entries
  for each row execute function public.set_updated_at();

-- Reporting index for per-student, date-ordered ledger queries.
create index if not exists ledger_entries_owner_student_date_idx
  on public.ledger_entries (owner_id, student_id, entry_date);

-- ===========================================================================
-- 2. payments — one row per received payment, per student.
-- ===========================================================================
create table if not exists public.payments (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references public.owner_profiles (id) on delete cascade,
  student_id   uuid not null references public.students (id) on delete cascade,
  amount       numeric not null,
  payment_date date not null default current_date,
  payment_mode text
    check (payment_mode is null or payment_mode in ('cash', 'upi', 'bank', 'card', 'other')),
  note         text,
  created_at   timestamptz not null default now()
);

create index if not exists payments_owner_student_date_idx
  on public.payments (owner_id, student_id, payment_date);

alter table public.payments enable row level security;

drop policy if exists payments_select on public.payments;
create policy payments_select on public.payments
  for select using (owner_id = auth.uid());

drop policy if exists payments_insert on public.payments;
create policy payments_insert on public.payments
  for insert with check (owner_id = auth.uid());

drop policy if exists payments_update on public.payments;
create policy payments_update on public.payments
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists payments_delete on public.payments;
create policy payments_delete on public.payments
  for delete using (owner_id = auth.uid());

-- ===========================================================================
-- 3. monthly_bills — one generated bill per student per month.
-- ===========================================================================
create table if not exists public.monthly_bills (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null references public.owner_profiles (id) on delete cascade,
  student_id        uuid not null references public.students (id) on delete cascade,
  bill_month        integer not null,
  bill_year         integer not null,
  base_amount       numeric default 0,
  extra_amount      numeric default 0,
  credit_amount     numeric default 0,
  adjustment_amount numeric default 0,
  paid_amount       numeric default 0,
  final_amount      numeric default 0,
  status            text not null default 'unpaid'
    check (status in ('unpaid', 'partially_paid', 'paid', 'overdue')),
  generated_at      timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- One bill per owner + student + month + year.
create unique index if not exists monthly_bills_owner_student_month_year_uidx
  on public.monthly_bills (owner_id, student_id, bill_month, bill_year);

-- Lookup / filtering indexes.
create index if not exists monthly_bills_owner_student_period_idx
  on public.monthly_bills (owner_id, student_id, bill_year, bill_month);
create index if not exists monthly_bills_owner_status_idx
  on public.monthly_bills (owner_id, status);

-- Keep updated_at fresh via the shared trigger function defined in 0001.
drop trigger if exists trg_monthly_bills_updated_at on public.monthly_bills;
create trigger trg_monthly_bills_updated_at
  before update on public.monthly_bills
  for each row execute function public.set_updated_at();

alter table public.monthly_bills enable row level security;

drop policy if exists monthly_bills_select on public.monthly_bills;
create policy monthly_bills_select on public.monthly_bills
  for select using (owner_id = auth.uid());

drop policy if exists monthly_bills_insert on public.monthly_bills;
create policy monthly_bills_insert on public.monthly_bills
  for insert with check (owner_id = auth.uid());

drop policy if exists monthly_bills_update on public.monthly_bills;
create policy monthly_bills_update on public.monthly_bills
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists monthly_bills_delete on public.monthly_bills;
create policy monthly_bills_delete on public.monthly_bills
  for delete using (owner_id = auth.uid());
