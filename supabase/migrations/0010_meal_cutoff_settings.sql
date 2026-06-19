-- KotaMess Owner — configurable meal times and request cutoff foundation.
-- Run after 0001_init.sql … 0009_billing_foundation.sql.
--
-- This migration is additive and idempotent. It:
--   * extends the EXISTING public.owner_profiles table with the owner's meal
--     times and a single request-cutoff window (no new settings table — the
--     owner profile is already the per-owner settings row);
--   * extends the EXISTING public.meal_requests table with the fields the
--     extract-requests Edge Function will later use to flag late requests.
--
-- No columns are renamed or dropped, and no RLS policy is touched. Both tables
-- already enable RLS keyed on owner_id / id (see 0002_rls.sql), which is
-- unchanged here, so existing owner-scoped access continues to hold.

-- ===========================================================================
-- 1. owner_profiles — meal times + request cutoff window.
-- ===========================================================================

-- Owner's daily meal serving times. Defaults match the app's assumptions:
-- breakfast 08:00, lunch 13:00, dinner 20:00.
alter table public.owner_profiles
  add column if not exists breakfast_time time not null default '08:00';
alter table public.owner_profiles
  add column if not exists lunch_time time not null default '13:00';
alter table public.owner_profiles
  add column if not exists dinner_time time not null default '20:00';

-- How many minutes before a meal a student must send a change/cancel/add
-- request. Anything later is flagged for owner review. Default 60 (= 1 hour);
-- do NOT hardcode 1 hour elsewhere — read this column.
alter table public.owner_profiles
  add column if not exists request_cutoff_minutes integer not null default 60;

-- Keep the cutoff in a sane range (0 minutes .. 6 hours).
alter table public.owner_profiles
  drop constraint if exists owner_profiles_request_cutoff_minutes_check;
alter table public.owner_profiles
  add constraint owner_profiles_request_cutoff_minutes_check
  check (request_cutoff_minutes between 0 and 360);

-- ===========================================================================
-- 2. meal_requests — late-request flagging fields (set later by the
--    extract-requests Edge Function; left null/false until then).
-- ===========================================================================

-- True when the message arrived after cutoff_at and needs owner review.
alter table public.meal_requests
  add column if not exists is_late_request boolean not null default false;

-- The computed deadline (meal time minus request_cutoff_minutes) for the meal
-- this request targets.
alter table public.meal_requests
  add column if not exists cutoff_at timestamptz;

-- When the student's message was actually received (from the chat timestamp).
alter table public.meal_requests
  add column if not exists message_received_at timestamptz;

-- Optional human-readable explanation of why a request was flagged late.
alter table public.meal_requests
  add column if not exists late_reason text;
