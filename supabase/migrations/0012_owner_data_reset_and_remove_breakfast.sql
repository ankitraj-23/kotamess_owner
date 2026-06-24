-- KotaMess Owner — owner-scoped data reset + breakfast removal.
-- Run after 0001_init.sql … 0011_sender_link_status.sql.
--
-- This migration is additive/idempotent and touches NO existing applied
-- migration. It does two independent things:
--
--   1. Adds reset_current_owner_data(): a SECURITY DEFINER RPC that wipes all
--      app data belonging to the CURRENT authenticated owner (auth.uid()) so
--      the account becomes fresh — without deleting the auth user, the email,
--      the password, or the owner_profiles identity row.
--   2. Drops the now-unused breakfast columns (this app only serves lunch and
--      dinner). Uses `drop column if exists` so it is safe to re-run.

-- ===========================================================================
-- 1. Owner-scoped "reset all my data" RPC
-- ===========================================================================
--
-- Safety design:
--   * SECURITY DEFINER so it can delete across the owner's tables atomically in
--     one round-trip, but it derives the owner from auth.uid() INTERNALLY and
--     filters every statement by it — a caller can never target another owner.
--   * No service_role is involved; the Flutter app calls this with the user's
--     own JWT. `authenticated` is the only role granted execute.
--   * Deletes run child -> parent in foreign-key-safe order so no statement
--     trips an FK even though most child FKs already cascade from owner_profiles.
--   * owner_profiles is PRESERVED (never deleted): we only reset operational
--     values to clean defaults, so the same email keeps working immediately.
--   * auth.users is NEVER touched.
create or replace function public.reset_current_owner_data()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  -- Refuse to run without an authenticated session.
  if uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  -- Delete in child -> parent order, every statement scoped to this owner only.
  delete from public.request_duplicates  where owner_id = uid;
  delete from public.chat_messages       where owner_id = uid;
  delete from public.monthly_bills       where owner_id = uid;
  delete from public.payments            where owner_id = uid;
  delete from public.customer_meal_plans where owner_id = uid;
  delete from public.ledger_entries      where owner_id = uid;
  delete from public.daily_adjustments   where owner_id = uid;
  delete from public.meal_requests       where owner_id = uid;
  delete from public.student_aliases     where owner_id = uid;
  delete from public.meal_plans          where owner_id = uid;
  delete from public.chat_imports        where owner_id = uid;
  delete from public.imported_messages   where owner_id = uid;
  delete from public.students            where owner_id = uid;
  delete from public.audit_logs          where owner_id = uid;

  -- Preserve the owner's identity (id / email / owner_name / mess_name / phone)
  -- so the account stays usable; reset only operational values to clean
  -- defaults. Deleting zero rows above is fine — this is safe on an empty
  -- account too.
  update public.owner_profiles
     set retention_days         = 90,
         request_cutoff_minutes = 60,
         lunch_time             = '13:00',
         dinner_time            = '20:00',
         default_lunch_count    = 0,
         default_dinner_count   = 0
   where id = uid;
end;
$$;

-- Only signed-in users may call it (and only ever on their own data).
revoke all on function public.reset_current_owner_data() from public;
grant execute on function public.reset_current_owner_data() to authenticated;

-- ===========================================================================
-- 2. Remove breakfast (app serves lunch + dinner only)
-- ===========================================================================
-- Safe + idempotent. Dropping a column also drops its column-level defaults;
-- there are no CHECK constraints or code paths referencing these columns after
-- this release.
alter table public.owner_profiles drop column if exists breakfast_time;
alter table public.meal_plans     drop column if exists breakfast_enabled;
alter table public.meal_plans     drop column if exists breakfast_price;
