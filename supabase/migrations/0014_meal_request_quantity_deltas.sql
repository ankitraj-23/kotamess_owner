-- KotaMess Owner — quantity-based lunch/dinner deltas on meal_requests.
-- Run after 0013_whatsapp_message_fingerprints.sql.
--
-- Real WhatsApp requests are not just yes/no: "kal do lunch extra dena" = +2
-- lunches, "do dinner cancel kar dena" = -2 dinners. We add two signed integer
-- columns that carry the net change per meal:
--
--   lunch_delta  / dinner_delta
--     +N  -> add N of that meal
--     -N  -> remove / cancel N of that meal
--      0  -> no change for that meal
--
-- Additive only: existing columns and constraints are untouched. We backfill the
-- new columns from each row's request_type + meal_type so the Daily counts keep
-- matching today's behavior (a lunch cancel == lunch_delta -1, an extra dinner ==
-- dinner_delta +1, etc.).

alter table public.meal_requests
  add column if not exists lunch_delta integer not null default 0;
alter table public.meal_requests
  add column if not exists dinner_delta integer not null default 0;

-- Backfill existing rows from the legacy request_type + meal_type so quantity
-- counting starts out identical to the old ±1 behavior. pause_mess is left at
-- 0/0 here — the Daily summary still treats a single-day pause as a whole-day
-- (-1 lunch, -1 dinner) special case, exactly as before.
update public.meal_requests
  set lunch_delta = case
        when request_type = 'add_meal'    and meal_type in ('lunch', 'both') then 1
        when request_type = 'cancel_meal' and meal_type in ('lunch', 'both') then -1
        when request_type = 'both_meals_cancel' then -1
        else 0
      end,
      dinner_delta = case
        when request_type = 'add_meal'    and meal_type in ('dinner', 'both') then 1
        when request_type = 'cancel_meal' and meal_type in ('dinner', 'both') then -1
        when request_type = 'both_meals_cancel' then -1
        else 0
      end
  where lunch_delta = 0 and dinner_delta = 0;
