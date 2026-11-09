-- =============================================================================
-- 0002 Accounts & identity, devices, admin roles, system settings, plan limits
-- =============================================================================

-- -----------------------------------------------------------------------------
-- profiles
-- -----------------------------------------------------------------------------
create table public.profiles (
  id                        uuid primary key references auth.users (id) on delete cascade,
  email                     text,
  display_name              text check (char_length(display_name) <= 120),
  avatar_url                text check (char_length(avatar_url) <= 2048),
  default_currency          public.currency_code not null default 'USD',
  country_code              public.country_code not null default 'US',
  timezone                  text not null default 'America/New_York',
  alert_local_time          time not null default '09:00',
  notification_preferences  jsonb not null default jsonb_build_object(
                              'warranty',     jsonb_build_object('enabled', true, 'offsets_days', jsonb_build_array(30, 7, 1)),
                              'return',       jsonb_build_object('enabled', true, 'offsets_days', jsonb_build_array(7, 3, 1)),
                              'registration', jsonb_build_object('enabled', true, 'offsets_days', jsonb_build_array(7, 1)),
                              'claim_follow_up', jsonb_build_object('enabled', true, 'offsets_days', jsonb_build_array(0)),
                              'maintenance',  jsonb_build_object('enabled', true, 'offsets_days', jsonb_build_array(3, 0)),
                              'monthly_digest', jsonb_build_object('enabled', false)
                            ),
  onboarding_completed      boolean not null default false,
  -- Explicit permission for sharing receipt content with a third-party AI provider.
  ai_processing_consent_at  timestamptz,
  ai_consent_version        text,
  analytics_consent         boolean not null default false,
  -- Attribution captured at signup (channel only; no ad identifiers).
  acquisition_channel       text check (acquisition_channel in
                              ('organic','paid_social','paid_search','creator','referral','partner','app_store_search','other')),
  referral_code             text check (char_length(referral_code) <= 64),
  account_state             text not null default 'active'
                              check (account_state in ('active', 'deletion_pending', 'deleting')),
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

create or replace function app_private.validate_profile()
returns trigger
language plpgsql
as $$
begin
  if not app_private.is_valid_timezone(new.timezone) then
    raise exception 'invalid_timezone' using errcode = '22023';
  end if;
  if jsonb_typeof(new.notification_preferences) <> 'object' then
    raise exception 'invalid_notification_preferences' using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger profiles_validate before insert or update on public.profiles
  for each row execute function app_private.validate_profile();
create trigger profiles_updated_at before update on public.profiles
  for each row execute function app_private.set_updated_at();

-- Create the profile row when Supabase Auth creates a user.
create or replace function app_private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app_private.handle_new_auth_user();

-- Keep the convenience email mirror current.
create or replace function app_private.handle_auth_user_email_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.email is distinct from old.email then
    update public.profiles set email = new.email where id = new.id;
  end if;
  return new;
end;
$$;

create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row execute function app_private.handle_auth_user_email_change();

alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
-- Column-level grant: clients may not change account_state/email/consent timestamps directly.
grant update (display_name, avatar_url, default_currency, country_code, timezone, alert_local_time,
              notification_preferences, onboarding_completed, analytics_consent)
  on public.profiles to authenticated;
grant all on public.profiles to service_role;

create policy profiles_select_own on public.profiles
  for select to authenticated using (id = auth.uid());
create policy profiles_update_own on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- -----------------------------------------------------------------------------
-- No email-only account merging.
-- A new provider identity may only attach to an EXISTING user if that user
-- explicitly created a short-lived link intent while signed in.
-- -----------------------------------------------------------------------------
create table public.identity_link_intents (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  provider    text not null check (provider in ('google', 'apple', 'email')),
  expires_at  timestamptz not null default now() + interval '10 minutes',
  consumed_at timestamptz,
  created_at  timestamptz not null default now()
);
create index identity_link_intents_user_idx on public.identity_link_intents (user_id, provider) where consumed_at is null;

alter table public.identity_link_intents enable row level security;
revoke all on public.identity_link_intents from anon, authenticated;
grant all on public.identity_link_intents to service_role;

create or replace function app_private.guard_identity_linking()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_intent_id uuid;
begin
  -- First identity for a brand-new user: normal sign-up.
  if not exists (select 1 from auth.identities i where i.user_id = new.user_id) then
    return new;
  end if;

  select id into v_intent_id
    from public.identity_link_intents
   where user_id = new.user_id
     and provider = new.provider
     and consumed_at is null
     and expires_at > now()
   order by created_at desc
   limit 1
   for update;

  if v_intent_id is null then
    raise exception 'identity_link_requires_explicit_intent'
      using errcode = '42501',
            hint = 'Sign in with the original method and link this provider from Settings.';
  end if;

  update public.identity_link_intents set consumed_at = now() where id = v_intent_id;
  return new;
end;
$$;

create trigger guard_identity_linking
  before insert on auth.identities
  for each row execute function app_private.guard_identity_linking();

-- -----------------------------------------------------------------------------
-- devices (push installations)
-- -----------------------------------------------------------------------------
create table public.devices (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  installation_id   text not null check (char_length(installation_id) between 8 and 128),
  platform          text not null check (platform in ('ios', 'android', 'web')),
  push_provider     text not null default 'fcm' check (push_provider in ('fcm', 'none')),
  push_token        text check (char_length(push_token) <= 4096),
  permission_state  text not null default 'unknown'
                      check (permission_state in ('unknown', 'granted', 'denied', 'provisional')),
  token_state       text not null default 'active' check (token_state in ('active', 'stale', 'revoked')),
  app_version       text check (char_length(app_version) <= 32),
  locale            text check (char_length(locale) <= 35),
  timezone          text,
  last_seen_at      timestamptz not null default now(),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (user_id, installation_id)
);
create unique index devices_active_token_uniq on public.devices (push_token)
  where push_token is not null and token_state = 'active';
create index devices_user_active_idx on public.devices (user_id) where token_state = 'active';

create trigger devices_updated_at before update on public.devices
  for each row execute function app_private.set_updated_at();

alter table public.devices enable row level security;
revoke all on public.devices from anon, authenticated;
grant select, delete on public.devices to authenticated;
grant all on public.devices to service_role;
create policy devices_select_own on public.devices for select to authenticated using (user_id = auth.uid());
create policy devices_delete_own on public.devices for delete to authenticated using (user_id = auth.uid());

-- Register/refresh a device. A push token can belong to only one active account:
-- switching accounts on the same phone moves the token and revokes the old row.
create or replace function public.register_device(
  p_installation_id text,
  p_platform text,
  p_push_token text,
  p_permission_state text,
  p_app_version text default null,
  p_locale text default null,
  p_timezone text default null
)
returns public.devices
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_row public.devices;
begin
  if p_timezone is not null and not app_private.is_valid_timezone(p_timezone) then
    raise exception 'invalid_timezone' using errcode = '22023';
  end if;

  if p_push_token is not null then
    update public.devices
       set token_state = 'revoked', push_token = null
     where push_token = p_push_token
       and token_state = 'active'
       and not (user_id = v_uid and installation_id = p_installation_id);
  end if;

  insert into public.devices as d (user_id, installation_id, platform, push_token, permission_state,
                                   app_version, locale, timezone, token_state, last_seen_at)
  values (v_uid, p_installation_id, p_platform, p_push_token, coalesce(p_permission_state, 'unknown'),
          p_app_version, p_locale, p_timezone, 'active', now())
  on conflict (user_id, installation_id) do update
     set platform = excluded.platform,
         push_token = excluded.push_token,
         permission_state = excluded.permission_state,
         app_version = excluded.app_version,
         locale = excluded.locale,
         timezone = excluded.timezone,
         token_state = 'active',
         last_seen_at = now()
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function public.register_device(text, text, text, text, text, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- Admin users (restricted admin access). Only service_role can read/write.
-- -----------------------------------------------------------------------------
create table public.admin_users (
  user_id       uuid primary key references auth.users (id) on delete cascade,
  role          text not null check (role in ('support', 'operator', 'finance', 'superadmin')),
  mfa_required  boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  revoked_at    timestamptz
);
alter table public.admin_users enable row level security;
revoke all on public.admin_users from anon, authenticated;
grant all on public.admin_users to service_role;

-- -----------------------------------------------------------------------------
-- System settings (kill switches, budgets). service_role only.
-- -----------------------------------------------------------------------------
create table public.system_settings (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);
alter table public.system_settings enable row level security;
revoke all on public.system_settings from anon, authenticated;
grant all on public.system_settings to service_role;

insert into public.system_settings (key, value, description) values
  ('ai_kill_switch',                    'false'::jsonb, 'When true, all AI extraction/drafting is refused; manual entry is unaffected.'),
  ('ai_global_monthly_budget_usd',      '250'::jsonb,   'Hard ceiling on provider spend per calendar month (UTC).'),
  ('ai_account_monthly_cost_ceiling_usd','1.00'::jsonb, 'Per-account provider spend ceiling per month, independent of action count.'),
  ('ai_max_attempts',                   '2'::jsonb,     'Bounded provider retries per scan job.'),
  ('ai_rate_limit_per_hour',            '10'::jsonb,    'Per-user AI reservations per rolling hour.'),
  ('uploads_enabled',                   'true'::jsonb,  'Global upload switch.'),
  ('billing_environment',               '"PRODUCTION"'::jsonb, 'Only entitlements from this RevenueCat environment grant access.'),
  ('email_ingest_daily_limit',          '30'::jsonb,    'Inbound forwarded emails accepted per address per day.'),
  ('signed_url_ttl_seconds',            '300'::jsonb,   'Lifetime of signed download URLs (bearer credentials).');

create or replace function app_private.setting(p_key text)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select value from public.system_settings where key = p_key;
$$;
grant execute on function app_private.setting(text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Versioned plan limits
-- -----------------------------------------------------------------------------
create table public.plan_limits (
  id                          uuid primary key default gen_random_uuid(),
  plan_code                   text not null check (plan_code in ('free', 'pro', 'business_pilot')),
  version                     integer not null check (version > 0),
  effective_from              timestamptz not null default now(),
  effective_to                timestamptz,
  max_items                   integer not null check (max_items >= 0),
  storage_bytes               bigint not null check (storage_bytes >= 0),
  ai_actions_per_month        integer not null default 0 check (ai_actions_per_month >= 0),
  ai_lifetime_trial_actions   integer not null default 0 check (ai_lifetime_trial_actions >= 0),
  max_file_bytes              bigint not null default 10485760,
  max_pdf_pages_stored        integer not null default 10,
  max_ai_pages_per_action     integer not null default 2,
  max_ai_input_chars          integer not null default 20000,
  claim_pack_level            text not null default 'basic' check (claim_pack_level in ('basic', 'assembled')),
  ai_claim_draft              boolean not null default false,
  workspaces_enabled          boolean not null default false,
  max_workspace_members       integer not null default 0,
  business_portfolio_enabled  boolean not null default false,
  email_forwarding_enabled    boolean not null default false,
  notes                       text,
  created_at                  timestamptz not null default now(),
  unique (plan_code, version),
  check (effective_to is null or effective_to > effective_from)
);
alter table public.plan_limits enable row level security;
revoke all on public.plan_limits from anon, authenticated;
grant select on public.plan_limits to authenticated;
grant all on public.plan_limits to service_role;
create policy plan_limits_read on public.plan_limits for select to authenticated using (true);

insert into public.plan_limits (plan_code, version, max_items, storage_bytes, ai_actions_per_month,
  ai_lifetime_trial_actions, claim_pack_level, ai_claim_draft, workspaces_enabled, max_workspace_members,
  business_portfolio_enabled, email_forwarding_enabled, notes)
values
  ('free', 1, 10, 104857600, 0, 3, 'basic', false, false, 0, false, false,
   'Proposed operating control; needs usability/cost tests.'),
  ('pro', 1, 500, 1073741824, 20, 0, 'assembled', true, true, 6, false, true,
   'Test $169.99/yr or $19.99/mo; stress-test $199.99/yr. Prices unvalidated.'),
  ('business_pilot', 1, 2000, 5368709120, 60, 0, 'assembled', true, true, 25, true, true,
   'Pilot only for paying landlords/property operators; own unit economics required.');
