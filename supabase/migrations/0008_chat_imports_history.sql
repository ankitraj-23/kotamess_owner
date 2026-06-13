-- KotaMess Owner — production import history for the WhatsApp chat workflow.
-- Run after 0001_init.sql … 0007_rls_plans_audit.sql.
--
-- This migration is ADDITIVE and idempotent. It does not rebuild the app and
-- does not touch any UI / AI code:
--   * chat_imports      NEW — one row per upload/import run (a batch of chat
--                       text the owner pastes/uploads), with progress + outcome
--                       counters and a lifecycle status.
--   * chat_messages     NEW — the individual parsed messages belonging to an
--                       import. Distinct from the legacy imported_messages
--                       table; these are scoped to a chat_imports run.
--   * request_duplicates NEW — records that a `meal_requests` row was detected
--                       as a (possible) duplicate of another request.
--   * meal_requests     EXTENDED — link each extracted request back to the
--                       import / source message it came from, plus a
--                       duplicate_status flag. `meal_requests` IS the app's
--                       "extracted_requests" table; no new copy is created.
--
-- owner_id -> owner_profiles.id (== auth uid), matching every other table here.
-- RLS for the new tables is defined at the bottom of this file (same model as
-- 0002_rls.sql / 0007_rls_plans_audit.sql).

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- chat_imports  (one row per upload/import run)
-- ---------------------------------------------------------------------------
create table if not exists public.chat_imports (
  id                   uuid primary key default gen_random_uuid(),
  owner_id             uuid not null references public.owner_profiles (id) on delete cascade,
  source               text not null default 'text_upload',
  file_name            text,
  imported_text_hash   text,
  import_start_date    date,
  import_end_date      date,
  total_messages       integer default 0,
  processed_messages   integer default 0,
  skipped_old_messages integer default 0,
  extracted_count      integer default 0,
  duplicate_count      integer default 0,
  rejected_count       integer default 0,
  status               text not null default 'uploaded',
  error_message        text,
  created_at           timestamptz default now(),
  updated_at           timestamptz default now()
);

alter table public.chat_imports drop constraint if exists chat_imports_status_check;
alter table public.chat_imports add constraint chat_imports_status_check
  check (status in ('uploaded', 'processing', 'completed', 'failed'));

create index if not exists chat_imports_owner_created_idx
  on public.chat_imports (owner_id, created_at);
create index if not exists chat_imports_owner_text_hash_idx
  on public.chat_imports (owner_id, imported_text_hash);

drop trigger if exists trg_chat_imports_updated_at on public.chat_imports;
create trigger trg_chat_imports_updated_at
  before update on public.chat_imports
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- chat_messages  (parsed messages belonging to one import run)
-- ---------------------------------------------------------------------------
create table if not exists public.chat_messages (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null references public.owner_profiles (id) on delete cascade,
  import_id           uuid not null references public.chat_imports (id) on delete cascade,
  sender_name         text,
  sender_phone        text,
  message_text        text not null,
  message_timestamp   timestamptz,
  message_hash        text,
  is_customer_message boolean default true,
  is_processed        boolean default false,
  created_at          timestamptz default now()
);

create index if not exists chat_messages_owner_import_idx
  on public.chat_messages (owner_id, import_id);
create index if not exists chat_messages_owner_hash_idx
  on public.chat_messages (owner_id, message_hash);

-- ---------------------------------------------------------------------------
-- request_duplicates  (a meal_requests row flagged as a possible duplicate)
-- ---------------------------------------------------------------------------
create table if not exists public.request_duplicates (
  id                       uuid primary key default gen_random_uuid(),
  owner_id                 uuid not null references public.owner_profiles (id) on delete cascade,
  request_id               uuid not null references public.meal_requests (id) on delete cascade,
  duplicate_of_request_id  uuid references public.meal_requests (id) on delete cascade,
  reason                   text,
  similarity_score         numeric,
  created_at               timestamptz default now()
);

create index if not exists request_duplicates_owner_request_idx
  on public.request_duplicates (owner_id, request_id);

-- ---------------------------------------------------------------------------
-- meal_requests  ->  link back to import / source message + duplicate flag
--
-- Added AFTER chat_imports / chat_messages exist so the FKs resolve. ON DELETE
-- SET NULL: deleting an import keeps the extracted request, just unlinks it.
-- ---------------------------------------------------------------------------
alter table public.meal_requests
  add column if not exists import_id        uuid references public.chat_imports (id) on delete set null;
alter table public.meal_requests
  add column if not exists message_id       uuid references public.chat_messages (id) on delete set null;
alter table public.meal_requests
  add column if not exists duplicate_status text default 'unique';

alter table public.meal_requests drop constraint if exists meal_requests_duplicate_status_check;
alter table public.meal_requests add constraint meal_requests_duplicate_status_check
  check (duplicate_status in ('unique', 'possible_duplicate', 'duplicate'));

create index if not exists meal_requests_owner_import_idx
  on public.meal_requests (owner_id, import_id);
-- Requested explicitly; complements meal_requests_owner_status_created_idx (0003).
create index if not exists meal_requests_owner_status_idx
  on public.meal_requests (owner_id, status);

-- ===========================================================================
-- Row Level Security  (signed-in user only ever touches their own rows)
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- chat_imports
-- ---------------------------------------------------------------------------
alter table public.chat_imports enable row level security;

drop policy if exists chat_imports_select on public.chat_imports;
create policy chat_imports_select on public.chat_imports
  for select using (owner_id = auth.uid());

drop policy if exists chat_imports_insert on public.chat_imports;
create policy chat_imports_insert on public.chat_imports
  for insert with check (owner_id = auth.uid());

drop policy if exists chat_imports_update on public.chat_imports;
create policy chat_imports_update on public.chat_imports
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists chat_imports_delete on public.chat_imports;
create policy chat_imports_delete on public.chat_imports
  for delete using (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- chat_messages
-- ---------------------------------------------------------------------------
alter table public.chat_messages enable row level security;

drop policy if exists chat_messages_select on public.chat_messages;
create policy chat_messages_select on public.chat_messages
  for select using (owner_id = auth.uid());

drop policy if exists chat_messages_insert on public.chat_messages;
create policy chat_messages_insert on public.chat_messages
  for insert with check (owner_id = auth.uid());

drop policy if exists chat_messages_update on public.chat_messages;
create policy chat_messages_update on public.chat_messages
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists chat_messages_delete on public.chat_messages;
create policy chat_messages_delete on public.chat_messages
  for delete using (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- request_duplicates
-- ---------------------------------------------------------------------------
alter table public.request_duplicates enable row level security;

drop policy if exists request_duplicates_select on public.request_duplicates;
create policy request_duplicates_select on public.request_duplicates
  for select using (owner_id = auth.uid());

drop policy if exists request_duplicates_insert on public.request_duplicates;
create policy request_duplicates_insert on public.request_duplicates
  for insert with check (owner_id = auth.uid());

drop policy if exists request_duplicates_update on public.request_duplicates;
create policy request_duplicates_update on public.request_duplicates
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists request_duplicates_delete on public.request_duplicates;
create policy request_duplicates_delete on public.request_duplicates
  for delete using (owner_id = auth.uid());
