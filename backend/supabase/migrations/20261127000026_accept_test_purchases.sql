-- Licence-tester (test) purchases can unlock Pro in production.
--
-- Google flags purchases by licence testers as test purchases; we store them as
-- SANDBOX and production only counted PRODUCTION entitlements, so a tester's
-- purchase went through in Play but never turned Pro on. Only accounts added as
-- licence testers in Play Console can make test purchases.
--
-- A separate switch (not billing_environment) so revenue and acquisition
-- tracking, which read billing_environment, keep counting real purchases only.

insert into public.system_settings (key, value, description) values
  ('billing_accept_test_purchases', 'true'::jsonb,
   'When true, Google Play licence-tester (SANDBOX) purchases also grant Pro. Revenue tracking still counts real purchases only.')
on conflict (key) do nothing;

create or replace function app_private.accepts_test_purchases()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((app_private.setting('billing_accept_test_purchases') #>> '{}')::boolean, false);
$$;
revoke all on function app_private.accepts_test_purchases() from public;

create or replace function app_private.effective_plan_code(p_user_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_env text := coalesce(app_private.setting('billing_environment') #>> '{}', 'PRODUCTION');
  v_key text;
begin
  select e.entitlement_key into v_key
    from public.entitlements e
   where e.user_id = p_user_id
     and (e.environment = v_env or (e.environment = 'SANDBOX' and app_private.accepts_test_purchases()))
     and e.state in ('active', 'grace_period', 'billing_retry')
     and (e.valid_until is null and e.store = 'promotional'
          or greatest(e.valid_until, coalesce(e.grace_until, e.valid_until)) > now())
   order by case e.entitlement_key when 'business_pilot' then 0 else 1 end
   limit 1;

  return coalesce(v_key, 'free');
end;
$$;

create or replace function public.get_my_entitlement()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_limits public.plan_limits := app_private.plan_limits_for(v_uid);
  v_ent jsonb;
begin
  select to_jsonb(e) - 'original_transaction_id' - 'last_event_id' into v_ent
    from public.entitlements e
   where e.user_id = v_uid
     and (e.environment = coalesce(app_private.setting('billing_environment') #>> '{}', 'PRODUCTION')
          or (e.environment = 'SANDBOX' and app_private.accepts_test_purchases()))
   order by e.updated_at desc
   limit 1;

  return jsonb_build_object(
    'plan_code', v_limits.plan_code,
    'plan_version', v_limits.version,
    'limits', to_jsonb(v_limits) - 'id' - 'created_at' - 'notes',
    'entitlement', v_ent
  );
end;
$$;
