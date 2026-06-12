-- KotaMess Owner — initial schema
-- Run order: 0001_init.sql, then 0002_rls.sql
--
-- Every owner-owned table carries an `owner_id` that points at owner_profiles.id
-- (which is the auth user's uid). Row Level Security in 0002 keeps each owner
-- limited to their own rows.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- updated_at helper
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- owner_profiles  (1 row per authenticated owner; id == auth.users.id)
-- ---------------------------------------------------------------------------
create table if not exists public.owner_profiles (
  id             uuid primary key references auth.users (id) on delete cascade,
  email          text,
  owner_name     text not null default '',
  mess_name      text not null default '',
  phone          text not null default '',
  retention_days integer not null default 90,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create trigger trg_owner_profiles_updated_at
  before update on public.owner_profiles
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- students
-- ---------------------------------------------------------------------------
create table if not exists public.students (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references public.owner_profiles (id) on delete cascade,
  name         text not null,
  phone        text not null default '',
  area         text not null default '',
  monthly_plan integer not null default 0,
  balance      integer not null default 0,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists students_owner_id_idx on public.students (owner_id);

create trigger trg_students_updated_at
  before update on public.students
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- imported_messages  (raw WhatsApp lines an owner imported)
-- ---------------------------------------------------------------------------
create table if not exists public.imported_messages (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references public.owner_profiles (id) on delete cascade,
  source       text not null default 'whatsapp_txt',
  sender_name  text not null default '',
  raw_text     text not null,
  message_date text not null default '',
  imported_at  timestamptz not null default now(),
  created_at   timestamptz not null default now()
);

create index if not exists imported_messages_owner_id_idx
  on public.imported_messages (owner_id);

-- ---------------------------------------------------------------------------
-- meal_requests  (parsed, reviewable requests)
-- ---------------------------------------------------------------------------
create table if not exists public.meal_requests (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null references public.owner_profiles (id) on delete cascade,
  student_id          uuid references public.students (id) on delete set null,
  imported_message_id uuid references public.imported_messages (id) on delete set null,
  student_name        text not null default '',
  phone               text not null default '',
  raw_message         text not null default '',
  type                text not null default 'unknown'
    check (type in ('skipMeal','extraMeal','suspend','resume','locationChange','payment','unknown')),
  status              text not null default 'pending'
    check (status in ('pending','approved','rejected')),
  date_text           text not null default 'today',
  meal                text not null default 'both'
    check (meal in ('lunch','dinner','both')),
  note                text not null default '',
  quantity            integer not null default 1,
  amount              integer not null default 0,
  confidence          numeric(4,3) not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists meal_requests_owner_id_idx
  on public.meal_requests (owner_id);
create index if not exists meal_requests_owner_status_idx
  on public.meal_requests (owner_id, status);

create trigger trg_meal_requests_updated_at
  before update on public.meal_requests
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- daily_adjustments  (per-day, per-meal deltas that feed the daily count)
-- ---------------------------------------------------------------------------
create table if not exists public.daily_adjustments (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references public.owner_profiles (id) on delete cascade,
  student_id      uuid references public.students (id) on delete set null,
  meal_request_id uuid references public.meal_requests (id) on delete set null,
  adjustment_date date not null,
  meal            text not null default 'both'
    check (meal in ('lunch','dinner','both')),
  delta           integer not null,
  reason          text not null default '',
  created_at      timestamptz not null default now()
);

create index if not exists daily_adjustments_owner_id_idx
  on public.daily_adjustments (owner_id);
create index if not exists daily_adjustments_owner_date_idx
  on public.daily_adjustments (owner_id, adjustment_date);

-- ---------------------------------------------------------------------------
-- ledger_entries  (payments / charges per student)
-- ---------------------------------------------------------------------------
create table if not exists public.ledger_entries (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references public.owner_profiles (id) on delete cascade,
  student_id      uuid references public.students (id) on delete cascade,
  meal_request_id uuid references public.meal_requests (id) on delete set null,
  entry_type      text not null default 'payment'
    check (entry_type in ('payment','charge','adjustment')),
  amount          integer not null,
  balance_after   integer,
  note            text not null default '',
  entry_date      date not null default current_date,
  created_at      timestamptz not null default now()
);

create index if not exists ledger_entries_owner_id_idx
  on public.ledger_entries (owner_id);
create index if not exists ledger_entries_student_id_idx
  on public.ledger_entries (student_id);
