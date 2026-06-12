-- KotaMess Owner — reshape meal_requests for the WhatsApp extraction workflow.
-- Run after 0001_init.sql and 0002_rls.sql.
--
-- Renames legacy columns to the extraction vocabulary, adds the new columns,
-- remaps old request_type values, and reinstalls the value CHECK constraints.
-- Guarded so it is safe whether or not legacy data exists. RLS is untouched
-- (policies key on owner_id, which does not change here).

-- 1. Drop legacy value constraints so renames / backfills don't fight them.
alter table public.meal_requests drop constraint if exists meal_requests_type_check;
alter table public.meal_requests drop constraint if exists meal_requests_meal_check;
alter table public.meal_requests drop constraint if exists meal_requests_status_check;

-- 2. Rename legacy columns to the new names (only if the old name still exists).
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'meal_requests'
               and column_name = 'raw_message') then
    alter table public.meal_requests rename column raw_message to original_message;
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'meal_requests'
               and column_name = 'type') then
    alter table public.meal_requests rename column type to request_type;
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'meal_requests'
               and column_name = 'meal') then
    alter table public.meal_requests rename column meal to meal_type;
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'meal_requests'
               and column_name = 'date_text') then
    alter table public.meal_requests rename column date_text to date_label;
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'meal_requests'
               and column_name = 'note') then
    alter table public.meal_requests rename column note to reason;
  end if;
end $$;

-- 3. Ensure all expected columns exist (covers fresh / partial states too).
alter table public.meal_requests add column if not exists original_message text not null default '';
alter table public.meal_requests add column if not exists request_type text not null default 'unclear';
alter table public.meal_requests add column if not exists meal_type text not null default 'none';
alter table public.meal_requests add column if not exists date_label text;
alter table public.meal_requests add column if not exists request_date date;
alter table public.meal_requests add column if not exists reason text not null default '';
alter table public.meal_requests add column if not exists source text not null default 'paste';

-- 4. Map any legacy request_type values onto the new vocabulary.
update public.meal_requests set request_type = case request_type
    when 'skipMeal'       then 'cancel_meal'
    when 'extraMeal'      then 'add_meal'
    when 'suspend'        then 'pause_mess'
    when 'resume'         then 'resume_mess'
    when 'payment'        then 'payment_note'
    when 'locationChange' then 'generic_note'
    when 'unknown'        then 'unclear'
    else request_type
  end
  where request_type in
    ('skipMeal','extraMeal','suspend','resume','payment','locationChange','unknown');

-- 5. New defaults.
alter table public.meal_requests alter column request_type set default 'unclear';
alter table public.meal_requests alter column meal_type set default 'none';

-- 6. Reinstall value constraints with the extraction vocabulary.
alter table public.meal_requests add constraint meal_requests_request_type_check
  check (request_type in (
    'cancel_meal','add_meal','pause_mess','resume_mess','both_meals_cancel',
    'dues_query','payment_note','generic_note','unclear'));
alter table public.meal_requests add constraint meal_requests_meal_type_check
  check (meal_type in ('lunch','dinner','both','none'));
alter table public.meal_requests add constraint meal_requests_status_check
  check (status in ('pending','approved','rejected'));

-- 7. Helpful index for the Requests screen filters.
create index if not exists meal_requests_owner_status_created_idx
  on public.meal_requests (owner_id, status, created_at desc);
