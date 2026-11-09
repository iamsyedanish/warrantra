-- =============================================================================
-- 0004 Billing & entitlements (server-authoritative)
--   * billing_events: immutable, unique provider event id (replay-safe webhooks)
--   * entitlements: validity window, renewal intent and state stored separately
--   * revenue_transactions: gross/fee/refund facts for profitability monitoring
-- No client may write any of these tables.
-- =============================================================================

create table public.billing_events (
  id                  uuid primary key default gen_random_uuid(),
  provider            text not null default 'revenuecat' check (provider in ('revenuecat')),
  provider_event_id   text not null,
  event_type          text not null,
  environment         text not null check (environment in ('PRODUCTION', 'SANDBOX')),
  app_user_id         text,
  original_app_user_id text,
  user_id             uuid,                    -- resolved Warrantra user (no FK: event outlives account)
  product_id          text,
  store               text,
  entitlement_ids     text[] not null default '{}',
  event_timestamp     timestamptz,
  payload             jsonb not null,
  received_at         timestamptz not null default now(),
  processing_state    text not null default 'received'
                        check (processing_state in ('received', 'processing', 'processed', 'ignored', 'failed')),
  processing_note     text,
  attempts            integer not null default 0,
  processed_at        timestamptz,
  unique (provider, provider_event_id)
);
create index billing_events_user_idx on public.billing_events (user_id, event_timestamp desc);
create index billing_events_pending_idx on public.billing_events (received_at) where processing_state in ('received', 'failed');

-- Immutability: the recorded event itself can never change; only processing columns may.
create or replace function app_private.billing_events_immutable()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'billing_events_are_immutable' using errcode = '42501';
  end if;
  if new.provider is distinct from old.provider
     or new.provider_event_id is distinct from old.provider_event_id
     or new.event_type is distinct from old.event_type
     or new.environment is distinct from old.environment
     or new.payload is distinct from old.payload
     or new.event_timestamp is distinct from old.event_timestamp
     or new.received_at is distinct from old.received_at then
    raise exception 'billing_events_are_immutable' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger billing_events_immutable before update or delete on public.billing_events
  for each row execute function app_private.billing_events_immutable();

create table public.entitlements (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references public.profiles (id) on delete cascade,
  entitlement_key         text not null check (entitlement_key in ('pro', 'business_pilot')),
  environment             text not null check (environment in ('PRODUCTION', 'SANDBOX')),
  state                   text not null
                            check (state in ('active', 'grace_period', 'billing_retry', 'expired', 'refunded', 'revoked', 'paused', 'transferred')),
  renewal_intent          text not null default 'unknown' check (renewal_intent in ('will_renew', 'will_not_renew', 'unknown')),
  valid_from              timestamptz,
  valid_until             timestamptz,           -- paid access ends here (cancellation does not end it early)
  grace_until             timestamptz,
  product_id              text,
  store                   text check (store in ('app_store', 'play_store', 'stripe', 'promotional', 'amazon', 'mac_app_store', 'unknown')),
  period_type             text check (period_type in ('normal', 'trial', 'intro', 'promotional', 'prepaid')),
  billing_period          text check (billing_period in ('monthly', 'annual', 'other')),
  original_transaction_id text,
  last_event_id           uuid references public.billing_events (id) on delete set null,
  last_event_at           timestamptz,
  last_reconciled_at      timestamptz,
  reconciliation_source   text check (reconciliation_source in ('provider_api', 'event', 'admin')),
  version                 integer not null default 1,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  unique (user_id, entitlement_key, environment)
);
create index entitlements_expiry_idx on public.entitlements (valid_until) where state in ('active', 'grace_period', 'billing_retry');
create trigger entitlements_updated_at before update on public.entitlements
  for each row execute function app_private.set_updated_at();
create trigger entitlements_version before update on public.entitlements
  for each row execute function app_private.bump_version();

create table public.revenue_transactions (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid,                       -- no FK: finance history survives account deletion
  billing_event_id      uuid not null references public.billing_events (id) on delete restrict,
  transaction_id        text not null,
  kind                  text not null check (kind in ('purchase', 'renewal', 'refund')),
  store                 text,
  product_id            text,
  billing_period        text check (billing_period in ('monthly', 'annual', 'other')),
  environment           text not null check (environment in ('PRODUCTION', 'SANDBOX')),
  gross_usd             numeric(12, 2) not null,   -- negative for refunds
  platform_fee_rate     numeric(6, 4) check (platform_fee_rate between 0 and 1),
  tax_rate              numeric(6, 4) check (tax_rate between 0 and 1),
  occurred_at           timestamptz not null,
  country_code          text,
  created_at            timestamptz not null default now(),
  unique (transaction_id, kind)
);
create index revenue_transactions_month_idx on public.revenue_transactions (occurred_at) where environment = 'PRODUCTION';

alter table public.billing_events enable row level security;
alter table public.entitlements enable row level security;
alter table public.revenue_transactions enable row level security;
revoke all on public.billing_events, public.entitlements, public.revenue_transactions from anon, authenticated;
grant select on public.entitlements to authenticated;
grant all on public.billing_events, public.entitlements, public.revenue_transactions to service_role;

-- Clients can read their own entitlement rows; no INSERT/UPDATE/DELETE policy exists
-- (default deny) so a client can never grant itself premium access.
create policy entitlements_select_own on public.entitlements
  for select to authenticated using (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Effective plan resolution (single source of truth for every quota check)
-- -----------------------------------------------------------------------------
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
     and e.environment = v_env
     and e.state in ('active', 'grace_period', 'billing_retry')
     and (e.valid_until is null and e.store = 'promotional'
          or greatest(e.valid_until, coalesce(e.grace_until, e.valid_until)) > now())
   order by case e.entitlement_key when 'business_pilot' then 0 else 1 end
   limit 1;

  return coalesce(v_key, 'free');
end;
$$;

create or replace function app_private.plan_limits_for(p_user_id uuid)
returns public.plan_limits
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan text := app_private.effective_plan_code(p_user_id);
  v_row public.plan_limits;
begin
  select * into v_row
    from public.plan_limits
   where plan_code = v_plan
     and effective_from <= now()
     and (effective_to is null or effective_to > now())
   order by version desc
   limit 1;
  if v_row.id is null then
    raise exception 'plan_limits_missing:%', v_plan;
  end if;
  return v_row;
end;
$$;

grant execute on function app_private.effective_plan_code(uuid) to authenticated, service_role;
grant execute on function app_private.plan_limits_for(uuid) to authenticated, service_role;

-- Client-facing view of the caller's own entitlement summary.
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
     and e.environment = coalesce(app_private.setting('billing_environment') #>> '{}', 'PRODUCTION')
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
grant execute on function public.get_my_entitlement() to authenticated;
