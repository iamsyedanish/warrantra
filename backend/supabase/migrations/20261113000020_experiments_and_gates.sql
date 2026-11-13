-- =============================================================================
-- 0020 Price experiments, launch-gate alerts, acquisition spending cap
--   * Honest paid price experiment (spec §8/§10): each user is assigned one
--     variant deterministically and permanently, so results per variant are
--     comparable. Prices are unvalidated hypotheses.
--   * New margin alert types for the acquisition spending cap and the
--     first-year cohort forecast.
-- =============================================================================

create table public.price_experiments (
  id          uuid primary key default gen_random_uuid(),
  key         text not null unique check (key ~ '^[a-z0-9_-]{3,40}$'),
  status      text not null default 'draft' check (status in ('draft', 'running', 'stopped')),
  -- [{code, label, annual_price_usd, monthly_price_usd, revenuecat_offering, weight}]
  variants    jsonb not null check (jsonb_typeof(variants) = 'array' and jsonb_array_length(variants) between 1 and 6),
  notes       text,
  started_at  timestamptz,
  stopped_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index price_experiments_one_running on public.price_experiments ((true)) where status = 'running';
create trigger price_experiments_updated_at before update on public.price_experiments
  for each row execute function app_private.set_updated_at();

create table public.experiment_assignments (
  user_id        uuid not null references public.profiles (id) on delete cascade,
  experiment_id  uuid not null references public.price_experiments (id) on delete cascade,
  variant_code   text not null,
  assigned_at    timestamptz not null default now(),
  primary key (user_id, experiment_id)
);
create index experiment_assignments_experiment_idx on public.experiment_assignments (experiment_id, variant_code);

alter table public.price_experiments enable row level security;
alter table public.experiment_assignments enable row level security;
revoke all on public.price_experiments, public.experiment_assignments from anon, authenticated;
grant select on public.experiment_assignments to authenticated;
grant all on public.price_experiments, public.experiment_assignments to service_role;
create policy experiment_assignments_select_own on public.experiment_assignments for select to authenticated using (user_id = auth.uid());

-- Seed the spec's experiment as a draft (start it from the admin API).
insert into public.price_experiments (key, status, variants, notes) values (
  'pro_price_v1', 'draft',
  '[{"code":"A","label":"Pro $169.99/yr or $19.99/mo","annual_price_usd":169.99,"monthly_price_usd":19.99,"revenuecat_offering":"pro_169","weight":1},
    {"code":"B","label":"Pro $199.99/yr (stress test)","annual_price_usd":199.99,"monthly_price_usd":19.99,"revenuecat_offering":"pro_199","weight":1}]'::jsonb,
  'Spec v4 §8 price test. Prices are unvalidated; only offer them if customers demonstrate sufficient value.'
);

-- Deterministic, sticky assignment for the caller in the running experiment.
create or replace function public.get_price_offer()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_exp public.price_experiments;
  v_code text;
  v_total integer;
  v_pick integer;
  v_acc integer := 0;
  v_variant jsonb;
begin
  select * into v_exp from public.price_experiments where status = 'running' limit 1;
  if v_exp.id is null then
    return jsonb_build_object('experiment', null, 'variant', null);
  end if;

  select variant_code into v_code from public.experiment_assignments where user_id = v_uid and experiment_id = v_exp.id;
  if v_code is null then
    select coalesce(sum(greatest((v ->> 'weight')::int, 0)), 0) into v_total from jsonb_array_elements(v_exp.variants) v;
    if v_total = 0 then
      return jsonb_build_object('experiment', v_exp.key, 'variant', null);
    end if;
    v_pick := abs(hashtextextended(v_uid::text || ':' || v_exp.key, 0) % v_total);
    for v_variant in select v from jsonb_array_elements(v_exp.variants) v loop
      v_acc := v_acc + greatest((v_variant ->> 'weight')::int, 0);
      if v_pick < v_acc then
        v_code := v_variant ->> 'code';
        exit;
      end if;
    end loop;
    insert into public.experiment_assignments (user_id, experiment_id, variant_code)
    values (v_uid, v_exp.id, v_code)
    on conflict (user_id, experiment_id) do nothing;
    select variant_code into v_code from public.experiment_assignments where user_id = v_uid and experiment_id = v_exp.id;
  end if;

  select v into v_variant from jsonb_array_elements(v_exp.variants) v where v ->> 'code' = v_code;
  return jsonb_build_object('experiment', v_exp.key, 'variant', v_variant - 'weight',
    'note', 'Prices shown are a test. You will see the same offer each time.');
end;
$$;
grant execute on function public.get_price_offer() to authenticated;

-- Results per variant (admin, service_role only). Denominator = assigned users.
create or replace function public.price_experiment_report(p_experiment_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with a as (
    select ea.variant_code, ea.user_id, ea.assigned_at from public.experiment_assignments ea where ea.experiment_id = p_experiment_id
  ), buyers as (
    select a.variant_code, ca.user_id from a join public.customer_acquisitions ca on ca.user_id = a.user_id and ca.first_paid_at >= a.assigned_at
  ), money as (
    select a.variant_code,
           coalesce(sum(rt.gross_usd) filter (where rt.kind <> 'refund'), 0) as gross,
           coalesce(-sum(rt.gross_usd) filter (where rt.kind = 'refund'), 0) as refunds,
           count(distinct rt.user_id) filter (where rt.kind = 'refund') as refunders
      from a join public.revenue_transactions rt on rt.user_id = a.user_id and rt.environment = 'PRODUCTION' and rt.occurred_at >= a.assigned_at
     group by a.variant_code
  ), views as (
    select a.variant_code, count(distinct ae.user_id) as viewers
      from a join public.analytics_events ae on ae.user_id = a.user_id and ae.event_name = 'paywall_viewed' and ae.occurred_at >= a.assigned_at
     group by a.variant_code
  )
  select jsonb_build_object(
    'experiment', (select jsonb_build_object('key', key, 'status', status, 'started_at', started_at, 'stopped_at', stopped_at, 'variants', variants)
                     from public.price_experiments where id = p_experiment_id),
    'by_variant', coalesce((
      select jsonb_agg(jsonb_build_object(
               'variant', v.variant_code,
               'assigned', v.assigned,
               'paywall_viewers_with_consent', coalesce(vw.viewers, 0),
               'paying_customers', coalesce(b.n, 0),
               'conversion_rate', case when v.assigned > 0 then round(coalesce(b.n, 0)::numeric / v.assigned, 4) end,
               'gross_usd', coalesce(m.gross, 0),
               'refunds_usd', coalesce(m.refunds, 0),
               'refund_customer_rate', case when coalesce(b.n, 0) > 0 then round(coalesce(m.refunders, 0)::numeric / b.n, 4) end,
               'gross_per_assigned_user_usd', case when v.assigned > 0 then round(coalesce(m.gross, 0) / v.assigned, 2) end)
             order by v.variant_code)
        from (select variant_code, count(*) assigned from a group by variant_code) v
        left join (select variant_code, count(distinct user_id) n from buyers group by variant_code) b using (variant_code)
        left join money m using (variant_code)
        left join views vw using (variant_code)), '[]'::jsonb),
    'notes', jsonb_build_array(
      'Denominator is users assigned to each variant (assigned when the paywall offer was first requested).',
      'Paywall viewers only include users who consented to analytics.',
      'Compare renewals and refunds over time, not first purchases alone, before choosing a price.')
  );
$$;
revoke all on function public.price_experiment_report(uuid) from public, anon, authenticated;
grant execute on function public.price_experiment_report(uuid) to service_role;

-- New alert types.
alter table public.margin_alerts drop constraint margin_alerts_alert_type_check;
alter table public.margin_alerts add constraint margin_alerts_alert_type_check
  check (alert_type in ('below_target', 'negative_margin', 'cac_payback_exceeded', 'ai_cost_p95_high', 'refund_rate_high',
                        'ai_budget_near_limit', 'missing_cost_inputs', 'acquisition_cap_exceeded', 'cohort_forecast_below_target'));

insert into public.system_settings (key, value, description) values
  ('acquisition_monthly_cap_usd', '500'::jsonb, 'Spending cap for the acquisition experiment (spec Phase D). Spend above it raises a critical alert.')
on conflict (key) do nothing;

-- Backup copies of files the user deleted are kept for the published retention
-- period counted from when the original disappeared, then purged.
alter table public.backup_objects add column source_missing_since timestamptz;

create or replace function public.worker_mark_missing_backup_sources(p_limit integer default 2000)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_n integer;
begin
  update public.backup_objects b set source_missing_since = now()
   where b.ctid in (
     select b2.ctid from public.backup_objects b2
      where b2.purged_at is null and b2.source_missing_since is null
        and not exists (select 1 from public.attachments a
                         where a.bucket = b2.bucket and a.storage_path = b2.storage_path and a.deletion_state = 'active')
      limit p_limit);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function public.worker_expired_backup_objects(p_retention_days integer, p_limit integer default 500)
returns table (bucket text, storage_path text, backup_key text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select b.bucket, b.storage_path, b.backup_key
    from public.backup_objects b
   where b.purged_at is null
     and b.source_missing_since < now() - make_interval(days => p_retention_days)
   limit p_limit;
$$;
revoke all on function public.worker_mark_missing_backup_sources(integer) from public, anon, authenticated;
revoke all on function public.worker_expired_backup_objects(integer, integer) from public, anon, authenticated;
grant execute on function public.worker_mark_missing_backup_sources(integer) to service_role;
grant execute on function public.worker_expired_backup_objects(integer, integer) to service_role;
