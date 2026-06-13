-- KotaMess Owner — customer lifecycle, meal plans and audit logs.
-- Run after 0001_init.sql … 0005_student_aliases_and_auto_ledger.sql.
--
-- This migration is ADDITIVE and idempotent. It does not rebuild the app:
--   * `students`      IS the app's "customers" table — we extend it with the
--                     lifecycle fields (status / room_or_address / notes /
--                     joined_at) the owner-facing Customers screen needs.
--   * `meal_requests` IS the app's "extracted_requests" table — we add an owner
--                     note + completion timestamp and widen the status set so a
--                     request can move through a fuller lifecycle. The existing
--                     pending/approved/rejected values keep working unchanged
--                     (pending == "needs review", approved == "confirmed").
--   * meal_plans / customer_meal_plans / audit_logs are NEW tables.
--
-- Every owner-scoped table carries owner_id -> owner_profiles.id (== auth uid).
-- RLS for the new tables lives in 0007_rls_plans_audit.sql.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- students  ->  customer lifecycle fields
-- ---------------------------------------------------------------------------
-- `status` is added nullable first so the backfill can derive it from the
-- legacy `active` boolean for pre-existing rows BEFORE we enforce NOT NULL /
-- the default. (Adding it NOT NULL DEFAULT 'active' up front would silently
-- turn inactive customers active.) The app keeps `active` in sync with
-- `status`, so older code that reads the boolean keeps working.
alter table public.students add column if not exists status text;
update public.students
  set status = case when active then 'active' else 'inactive' end
  where status is null;
alter table public.students alter column status set default 'active';
alter table public.students alter column status set not null;

alter table public.students
  add column if not exists room_or_address text not null default '';
alter table public.students
  add column if not exists notes           text not null default '';
alter table public.students
  add column if not exists joined_at       date;

alter table public.students drop constraint if exists students_status_check;
alter table public.students add constraint students_status_check
  check (status in ('active', 'inactive', 'paused'));

create index if not exists students_owner_phone_idx
  on public.students (owner_id, phone);
create index if not exists students_owner_status_idx
  on public.students (owner_id, status);

-- ---------------------------------------------------------------------------
-- meal_requests  ->  owner note + completion + wider status set
-- ---------------------------------------------------------------------------
alter table public.meal_requests
  add column if not exists owner_note   text not null default '';
alter table public.meal_requests
  add column if not exists completed_at timestamptz;

-- Widen the lifecycle. Old values are preserved; the app treats them as:
--   pending == needs_review, approved == confirmed/scheduled.
alter table public.meal_requests drop constraint if exists meal_requests_status_check;
alter table public.meal_requests add constraint meal_requests_status_check
  check (status in ('pending', 'approved', 'rejected', 'completed', 'cancelled'));

create index if not exists meal_requests_owner_date_idx
  on public.meal_requests (owner_id, request_date);

-- ---------------------------------------------------------------------------
-- meal_plans
-- ---------------------------------------------------------------------------
create table if not exists public.meal_plans (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null references public.owner_profiles (id) on delete cascade,
  name              text not null,
  breakfast_enabled boolean not null default false,
  lunch_enabled     boolean not null default false,
  dinner_enabled    boolean not null default false,
  monthly_price     numeric not null default 0,
  breakfast_price   numeric not null default 0,
  lunch_price       numeric not null default 0,
  dinner_price      numeric not null default 0,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists meal_plans_owner_id_idx on public.meal_plans (owner_id);

drop trigger if exists trg_meal_plans_updated_at on public.meal_plans;
create trigger trg_meal_plans_updated_at
  before update on public.meal_plans
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- customer_meal_plans  (a customer's active/assigned plan over a date range)
--
-- NOTE: `customer_id` here points at public.students(id) — students IS the
-- customers table in this codebase. The column is named student_id to stay
-- consistent with meal_requests / ledger_entries / daily_adjustments.
-- ---------------------------------------------------------------------------
create table if not exists public.customer_meal_plans (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references public.owner_profiles (id) on delete cascade,
  student_id   uuid not null references public.students (id) on delete cascade,
  meal_plan_id uuid references public.meal_plans (id) on delete set null,
  start_date   date not null default current_date,
  end_date     date,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);

create index if not exists customer_meal_plans_owner_id_idx
  on public.customer_meal_plans (owner_id);
create index if not exists customer_meal_plans_student_id_idx
  on public.customer_meal_plans (student_id);
-- At most one active plan per customer, per owner.
create unique index if not exists customer_meal_plans_active_uidx
  on public.customer_meal_plans (owner_id, student_id)
  where is_active;

-- ---------------------------------------------------------------------------
-- audit_logs  (append-only trail of important owner actions)
-- ---------------------------------------------------------------------------
create table if not exists public.audit_logs (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.owner_profiles (id) on delete cascade,
  actor_id    uuid references auth.users (id) on delete set null,
  entity_type text not null,
  entity_id   uuid,
  action      text not null,
  old_data    jsonb,
  new_data    jsonb,
  created_at  timestamptz not null default now()
);

create index if not exists audit_logs_owner_created_idx
  on public.audit_logs (owner_id, created_at desc);
create index if not exists audit_logs_owner_entity_idx
  on public.audit_logs (owner_id, entity_type, entity_id);
