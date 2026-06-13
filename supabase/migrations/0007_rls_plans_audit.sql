-- KotaMess Owner — Row Level Security for the 0006 tables.
-- Run after 0006_customers_plans_audit.sql.
--
-- Same model as 0002_rls.sql: a signed-in user can only ever touch rows whose
-- owner_id equals their auth uid. INSERT/UPDATE use WITH CHECK so a user can
-- never write a row owned by someone else. No service_role is ever used by the
-- client; these policies are the sole authority for cross-owner isolation.
--
-- audit_logs is intentionally APPEND-ONLY from the client: select + insert
-- only, no update/delete, so the trail cannot be rewritten from the app.

-- ---------------------------------------------------------------------------
-- meal_plans
-- ---------------------------------------------------------------------------
alter table public.meal_plans enable row level security;

drop policy if exists meal_plans_select on public.meal_plans;
create policy meal_plans_select on public.meal_plans
  for select using (owner_id = auth.uid());

drop policy if exists meal_plans_insert on public.meal_plans;
create policy meal_plans_insert on public.meal_plans
  for insert with check (owner_id = auth.uid());

drop policy if exists meal_plans_update on public.meal_plans;
create policy meal_plans_update on public.meal_plans
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists meal_plans_delete on public.meal_plans;
create policy meal_plans_delete on public.meal_plans
  for delete using (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- customer_meal_plans
-- ---------------------------------------------------------------------------
alter table public.customer_meal_plans enable row level security;

drop policy if exists customer_meal_plans_select on public.customer_meal_plans;
create policy customer_meal_plans_select on public.customer_meal_plans
  for select using (owner_id = auth.uid());

drop policy if exists customer_meal_plans_insert on public.customer_meal_plans;
create policy customer_meal_plans_insert on public.customer_meal_plans
  for insert with check (owner_id = auth.uid());

drop policy if exists customer_meal_plans_update on public.customer_meal_plans;
create policy customer_meal_plans_update on public.customer_meal_plans
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists customer_meal_plans_delete on public.customer_meal_plans;
create policy customer_meal_plans_delete on public.customer_meal_plans
  for delete using (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- audit_logs  (append-only: select + insert, no update/delete policy)
-- ---------------------------------------------------------------------------
alter table public.audit_logs enable row level security;

drop policy if exists audit_logs_select on public.audit_logs;
create policy audit_logs_select on public.audit_logs
  for select using (owner_id = auth.uid());

drop policy if exists audit_logs_insert on public.audit_logs;
create policy audit_logs_insert on public.audit_logs
  for insert with check (owner_id = auth.uid());
