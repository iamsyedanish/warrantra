-- =============================================================================
-- 0015 Profitability & cohort monitoring; partner distribution (P2)
--
-- Trace: gross subscription revenue -> net of store fees/refunds/RevenueCat ->
-- variable costs (AI, infrastructure, support) -> CAC by new-paying cohort ->
-- allocated overhead + founder comp + free-user subsidy -> after-tax profit per
-- active paid account-month, compared to the $6 target, with margin alerts.
-- All rows are service_role only (admin finance views).
-- =============================================================================

create table public.profit_model_settings (
  id                        uuid primary key default gen_random_uuid(),
  version                   integer not null unique check (version > 0),
  effective_from            date not null,
  target_after_tax_usd      numeric(10, 2) not null default 6.00,
  tax_rate                  numeric(6, 4) not null default 0.20 check (tax_rate between 0 and 1),
  refund_reserve_rate       numeric(6, 4) not null default 0.03 check (refund_reserve_rate between 0 and 1),
  revenuecat_rate           numeric(6, 4) not null default 0.01 check (revenuecat_rate between 0 and 1),
  default_platform_fee_rate numeric(6, 4) not null default 0.15 check (default_platform_fee_rate between 0 and 1),
  cac_recovery_months       integer not null default 12 check (cac_recovery_months > 0),
  free_account_monthly_cost numeric(10, 4) not null default 0.02,
  paid_variable_cost_floor  numeric(10, 4) not null default 0.45,  -- used when measured variable cost is unavailable
  cac_payback_alert_months  integer not null default 12,
  refund_rate_alert         numeric(6, 4) not null default 0.08,
  ai_cost_p95_alert_usd     numeric(10, 4) not null default 0.10,
  notes                     text,
  created_at                timestamptz not null default now()
);
insert into public.profit_model_settings (version, effective_from, notes)
values (1, date '2026-11-01', 'Illustrative planning case from the v4 spec; every input is an assumption to be replaced by measured data.');

create table public.operating_costs (
  id             uuid primary key default gen_random_uuid(),
  month          date not null check (extract(day from month) = 1),
  category       text not null check (category in ('fixed_overhead', 'founder_compensation', 'infrastructure', 'object_storage',
                                                   'database', 'ai_provider', 'support', 'legal_privacy', 'development_amortization',
                                                   'payroll_oncost', 'financing', 'other')),
  amount_usd     numeric(12, 2) not null check (amount_usd >= 0),
  -- Variable costs are allocated to paid users; fixed costs to F. Acquisition
  -- spend must NOT be entered here (it lives in acquisition_spend) to avoid
  -- double counting CAC.
  cost_class     text not null check (cost_class in ('fixed', 'variable_paid', 'variable_free')),
  source         text not null default 'estimate' check (source in ('invoice', 'estimate', 'measured')),
  notes          text,
  created_by     uuid,
  created_at     timestamptz not null default now()
);
create index operating_costs_month_idx on public.operating_costs (month);

create table public.acquisition_spend (
  id          uuid primary key default gen_random_uuid(),
  month       date not null check (extract(day from month) = 1),
  channel     text not null check (channel in ('paid_social', 'paid_search', 'creator', 'referral', 'partner', 'discount',
                                               'app_store_ads', 'other')),
  amount_usd  numeric(12, 2) not null check (amount_usd >= 0),
  includes    text,              -- e.g. creator payments, discounts, attribution tooling
  notes       text,
  created_by  uuid,
  created_at  timestamptz not null default now()
);
create index acquisition_spend_month_idx on public.acquisition_spend (month, channel);

-- First conversion to paid, per user (cohort membership). No FK: finance history.
create table public.customer_acquisitions (
  user_id         uuid primary key,
  first_paid_at   timestamptz not null,
  cohort_month    date not null,
  channel         text not null default 'organic',
  partner_id      uuid,
  first_product   text,
  billing_period  text,
  created_at      timestamptz not null default now()
);
create index customer_acquisitions_cohort_idx on public.customer_acquisitions (cohort_month, channel);

create table public.profitability_snapshots (
  id                          uuid primary key default gen_random_uuid(),
  month                       date not null unique check (extract(day from month) = 1),
  settings_version            integer not null,
  active_paying               integer not null,
  free_accounts               integer not null,
  new_paying                  integer not null,
  gross_revenue_usd           numeric(14, 2) not null,     -- recognised monthly-equivalent revenue
  refunds_usd                 numeric(14, 2) not null,
  platform_fees_usd           numeric(14, 2) not null,
  revenuecat_fees_usd         numeric(14, 2) not null,
  net_receipts_usd            numeric(14, 2) not null,
  ai_cost_usd                 numeric(14, 4) not null,
  variable_paid_cost_usd      numeric(14, 2) not null,
  free_subsidy_usd            numeric(14, 2) not null,
  fixed_cost_usd              numeric(14, 2) not null,
  acquisition_spend_usd       numeric(14, 2) not null,
  cac_per_new_payer_usd       numeric(14, 2),
  cac_allocation_per_paid_usd numeric(14, 4) not null,
  pretax_per_paid_usd         numeric(14, 4),
  after_tax_per_paid_usd      numeric(14, 4),
  target_after_tax_usd        numeric(10, 2) not null,
  meets_target                boolean,
  ai_cost_p50_usd             numeric(12, 6),
  ai_cost_p95_usd             numeric(12, 6),
  support_minutes             integer not null default 0,
  refund_rate                 numeric(8, 4),
  details                     jsonb not null default '{}'::jsonb,
  computed_at                 timestamptz not null default now()
);

create table public.cohort_metrics (
  cohort_month          date not null,
  channel               text not null,
  as_of_month           date not null,
  new_paying            integer not null,
  acquisition_spend_usd numeric(14, 2) not null,
  cac_usd               numeric(14, 2),
  retained_30d          integer,
  retained_90d          integer,
  retained_365d         integer,
  renewed_count         integer,
  cumulative_net_usd    numeric(14, 2) not null default 0,
  payback_months        numeric(8, 2),
  computed_at           timestamptz not null default now(),
  primary key (cohort_month, channel, as_of_month)
);

create table public.margin_alerts (
  id               uuid primary key default gen_random_uuid(),
  month            date not null,
  alert_type       text not null check (alert_type in ('below_target', 'negative_margin', 'cac_payback_exceeded',
                                                       'ai_cost_p95_high', 'refund_rate_high', 'ai_budget_near_limit',
                                                       'missing_cost_inputs')),
  severity         text not null check (severity in ('info', 'warning', 'critical')),
  metric_value     numeric,
  threshold        numeric,
  message          text not null,
  acknowledged_at  timestamptz,
  acknowledged_by  uuid,
  created_at       timestamptz not null default now(),
  unique (month, alert_type)
);

-- Partner distribution (P2): pilot demand before integrations; no data sharing
-- without explicit, revocable, versioned user consent.
create table public.partners (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null,
  kind                  text not null check (kind in ('retailer', 'property_manager', 'insurer', 'creator', 'affiliate', 'other')),
  status                text not null default 'pilot' check (status in ('prospect', 'pilot', 'active', 'ended')),
  contact_email         text,
  data_sharing_allowed  boolean not null default false,
  revenue_share_rate    numeric(6, 4) check (revenue_share_rate between 0 and 1),
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create trigger partners_updated_at before update on public.partners
  for each row execute function app_private.set_updated_at();

create table public.partner_referral_codes (
  code        text primary key check (code ~ '^[A-Z0-9_-]{4,32}$'),
  partner_id  uuid not null references public.partners (id) on delete cascade,
  campaign    text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.partner_consents (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references public.profiles (id) on delete cascade,
  partner_id            uuid not null references public.partners (id) on delete cascade,
  scope                 text not null check (scope in ('share_contact', 'share_purchase_summary', 'receive_offers')),
  consent_text_version  text not null,
  granted_at            timestamptz not null default now(),
  revoked_at            timestamptz
);
create unique index partner_consents_active_uniq on public.partner_consents (user_id, partner_id, scope) where revoked_at is null;

alter table public.profit_model_settings enable row level security;
alter table public.operating_costs enable row level security;
alter table public.acquisition_spend enable row level security;
alter table public.customer_acquisitions enable row level security;
alter table public.profitability_snapshots enable row level security;
alter table public.cohort_metrics enable row level security;
alter table public.margin_alerts enable row level security;
alter table public.partners enable row level security;
alter table public.partner_referral_codes enable row level security;
alter table public.partner_consents enable row level security;

revoke all on public.profit_model_settings, public.operating_costs, public.acquisition_spend, public.customer_acquisitions,
              public.profitability_snapshots, public.cohort_metrics, public.margin_alerts, public.partners,
              public.partner_referral_codes, public.partner_consents from anon, authenticated;
grant all on public.profit_model_settings, public.operating_costs, public.acquisition_spend, public.customer_acquisitions,
             public.profitability_snapshots, public.cohort_metrics, public.margin_alerts, public.partners,
             public.partner_referral_codes, public.partner_consents to service_role;
grant select on public.partner_consents to authenticated;
grant select (id, name, kind, status) on public.partners to authenticated;
create policy partner_consents_select_own on public.partner_consents for select to authenticated using (user_id = auth.uid());
create policy partners_read_active on public.partners for select to authenticated using (status in ('pilot', 'active'));

create or replace function public.grant_partner_consent(p_partner_id uuid, p_scope text, p_consent_text_version text)
returns public.partner_consents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_row public.partner_consents;
begin
  if not exists (select 1 from public.partners where id = p_partner_id and status in ('pilot', 'active')) then
    raise exception 'partner_not_found' using errcode = 'P0002';
  end if;
  insert into public.partner_consents (user_id, partner_id, scope, consent_text_version)
  values (v_uid, p_partner_id, p_scope, p_consent_text_version)
  on conflict (user_id, partner_id, scope) where revoked_at is null do update set consent_text_version = excluded.consent_text_version
  returning * into v_row;
  return v_row;
end;
$$;
create or replace function public.revoke_partner_consent(p_consent_id uuid)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.partner_consents set revoked_at = now() where id = p_consent_id and user_id = auth.uid() and revoked_at is null;
$$;
grant execute on function public.grant_partner_consent(uuid, text, text) to authenticated;
grant execute on function public.revoke_partner_consent(uuid) to authenticated;
