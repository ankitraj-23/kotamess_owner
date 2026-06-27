-- KotaMess Owner — date-range meal pause/cancellation requests.
-- Run after 0014_meal_request_quantity_deltas.sql.
--
-- Real requests can pause food for a span of days, e.g. "mera kal se ek hafte
-- tak khana mat dena" = from tomorrow, for one week, both meals off each day.
-- We model this with one logical row carrying a start + end date:
--
--   request_date      = start date (UNCHANGED; never renamed)
--   request_end_date  = end date, inclusive (NEW; null = single-day request)
--
-- Semantics:
--   * request_end_date null  -> treat the request as a single day (request_date)
--   * valid range            -> request_date <= request_end_date
--   * the per-day lunch_delta / dinner_delta apply to EVERY day in [start, end]
--
-- Additive only: the column is nullable with no default, so every existing row
-- stays a valid single-day request (request_end_date null) and nothing breaks.

alter table public.meal_requests
  add column if not exists request_end_date date;

-- Guard the range so a stray edit can't store end-before-start. Permissive when
-- either endpoint is null (single-day / undated rows), so it never rejects
-- existing data.
alter table public.meal_requests
  drop constraint if exists meal_requests_date_range_check;
alter table public.meal_requests
  add constraint meal_requests_date_range_check
  check (
    request_end_date is null
    or request_date is null
    or request_end_date >= request_date
  );
