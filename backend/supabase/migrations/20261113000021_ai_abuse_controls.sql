-- =============================================================================
-- 0021 AI abuse controls
--   * AI requires a verified email (slows free-trial account farming).
--   * Daily cap on total free-tier AI spend (bounds the cost of farmed accounts).
--   * Automatic, time-limited AI suspension after repeated abuse signals
--     (non-receipts, refusals, moderation hits, off-topic drafts); admins can lift it.
--   * Identical inputs reuse an earlier result instead of a new paid call.
-- Manual entry and existing records are never affected by any of these.
-- =============================================================================

alter table public.profiles
  add column ai_suspended_until timestamptz,
  add column ai_suspension_reason text check (char_length(ai_suspension_reason) <= 200);
-- (profiles UPDATE grants are column-level, so clients cannot clear these.)

alter table public.scan_jobs add column input_sha256 text check (input_sha256 ~ '^[0-9a-f]{64}$');
alter table public.scan_jobs add column reused_from_job_id uuid references public.scan_jobs (id) on delete set null;
create index scan_jobs_input_hash_idx on public.scan_jobs (user_id, feature, input_sha256)
  where input_sha256 is not null and state in ('succeeded', 'confirmed');

alter table public.usage_events add column plan_code text;
create index usage_events_plan_day_idx on public.usage_events (plan_code, created_at);

alter table public.scan_jobs drop constraint scan_jobs_state_check;
alter table public.scan_jobs add constraint scan_jobs_state_check
  check (state in ('queued', 'processing', 'succeeded', 'failed', 'cancelled', 'confirmed', 'discarded', 'rejected'));

insert into public.system_settings (key, value, description) values
  ('ai_require_verified_email',      'true'::jsonb, 'AI actions require a confirmed email address.'),
  ('ai_free_tier_daily_budget_usd',  '5'::jsonb,    'Total provider spend allowed per UTC day across all FREE-plan users.'),
  ('ai_abuse_signal_threshold_24h',  '5'::jsonb,    'Abuse signals in 24h (non-receipts, refusals, moderation hits) that trigger an AI suspension.'),
  ('ai_suspension_days',             '7'::jsonb,    'Length of an automatic AI suspension.')
on conflict (key) do nothing;

create or replace function public.reserve_ai_action(p_idempotency_key text, p_source_type text, p_source_id uuid)
returns public.usage_ledger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_profile public.profiles;
  v_limits public.plan_limits;
  v_existing public.usage_ledger;
  v_row public.usage_ledger;
  v_period text;
  v_allowance integer;
  v_used bigint;
  v_rate integer;
begin
  if coalesce((app_private.setting('ai_kill_switch'))::boolean, false) then
    raise exception 'ai_disabled' using errcode = 'P0001';
  end if;
  select * into v_profile from public.profiles where id = v_uid;
  if v_profile.ai_processing_consent_at is null then
    raise exception 'ai_consent_required' using errcode = '42501';
  end if;
  if v_profile.account_state <> 'active' then
    raise exception 'account_not_active' using errcode = '42501';
  end if;
  if v_profile.ai_suspended_until is not null and v_profile.ai_suspended_until > now() then
    raise exception 'ai_suspended' using errcode = '42501';
  end if;
  if coalesce((app_private.setting('ai_require_verified_email'))::boolean, true)
     and not exists (select 1 from auth.users u where u.id = v_uid and u.email_confirmed_at is not null) then
    raise exception 'ai_email_verification_required' using errcode = '42501';
  end if;

  perform app_private.lock_user(v_uid, 'ai');

  -- Retrying the same action never consumes a second allowance.
  select * into v_existing from public.usage_ledger
   where user_id = v_uid and feature = 'ai_action' and idempotency_key = p_idempotency_key
   for update;
  if v_existing.id is not null and v_existing.state in ('reserved', 'settled') then
    if v_existing.state = 'reserved' then
      update public.usage_ledger set expires_at = now() + interval '30 minutes' where id = v_existing.id
      returning * into v_existing;
    end if;
    return v_existing;
  end if;

  if app_private.ai_month_spend_usd(null) >= coalesce((app_private.setting('ai_global_monthly_budget_usd') #>> '{}')::numeric, 0) then
    raise exception 'ai_global_budget_exhausted' using errcode = 'P0001';
  end if;
  if app_private.ai_month_spend_usd(v_uid) >= coalesce((app_private.setting('ai_account_monthly_cost_ceiling_usd') #>> '{}')::numeric, 0) then
    raise exception 'ai_account_cost_ceiling_reached' using errcode = 'P0001';
  end if;

  v_rate := coalesce((app_private.setting('ai_rate_limit_per_hour') #>> '{}')::int, 10);
  if (select count(*) from public.usage_ledger where user_id = v_uid and feature = 'ai_action'
        and reserved_at > now() - interval '1 hour') >= v_rate then
    raise exception 'ai_rate_limited' using errcode = 'P0001';
  end if;

  v_limits := app_private.plan_limits_for(v_uid);
  if v_limits.plan_code = 'free'
     and (select coalesce(sum(cost_usd), 0) from public.usage_events
           where plan_code = 'free' and created_at >= date_trunc('day', now() at time zone 'UTC') at time zone 'UTC')
         >= coalesce((app_private.setting('ai_free_tier_daily_budget_usd') #>> '{}')::numeric, 0) then
    raise exception 'ai_free_tier_busy' using errcode = 'P0001';
  end if;

  if v_limits.ai_actions_per_month > 0 then
    v_period := to_char(now() at time zone 'UTC', 'YYYY-MM');
    v_allowance := v_limits.ai_actions_per_month;
  else
    v_period := 'lifetime';
    v_allowance := v_limits.ai_lifetime_trial_actions;
  end if;

  select coalesce(sum(quantity), 0) into v_used from public.usage_ledger
   where user_id = v_uid and feature = 'ai_action' and quota_period = v_period and state in ('reserved', 'settled');
  if v_used + 1 > v_allowance then
    raise exception 'quota_exceeded:ai_actions:%', v_allowance using errcode = 'P0001';
  end if;

  if v_existing.id is not null then
    update public.usage_ledger
       set state = 'reserved', quota_period = v_period, plan_code = v_limits.plan_code, plan_version = v_limits.version,
           reserved_at = now(), released_at = null, release_reason = null, expires_at = now() + interval '30 minutes'
     where id = v_existing.id
    returning * into v_row;
  else
    insert into public.usage_ledger (user_id, feature, quantity, idempotency_key, quota_period, plan_code, plan_version,
                                     source_type, source_id)
    values (v_uid, 'ai_action', 1, p_idempotency_key, v_period, v_limits.plan_code, v_limits.version, p_source_type, p_source_id)
    returning * into v_row;
  end if;
  return v_row;
end;
$$;
grant execute on function public.reserve_ai_action(text, text, uuid) to authenticated;

-- Count recent abuse signals and suspend AI when the threshold is reached (service_role).
create or replace function public.worker_ai_abuse_check(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signals integer;
  v_threshold integer := coalesce((app_private.setting('ai_abuse_signal_threshold_24h') #>> '{}')::int, 5);
  v_days integer := coalesce((app_private.setting('ai_suspension_days') #>> '{}')::int, 7);
  v_until timestamptz;
begin
  select count(*) into v_signals from public.scan_jobs
   where user_id = p_user_id and created_at > now() - interval '24 hours'
     and error_code in ('not_a_receipt', 'not_a_product_label', 'refused', 'moderation_flagged', 'off_topic_draft');
  if v_signals >= v_threshold then
    v_until := now() + make_interval(days => v_days);
    update public.profiles
       set ai_suspended_until = v_until,
           ai_suspension_reason = format('automatic: %s abuse signals in 24h', v_signals)
     where id = p_user_id and (ai_suspended_until is null or ai_suspended_until < v_until);
    insert into public.audit_events (actor_type, action, target_type, target_id, metadata)
    values ('system', 'ai.suspended', 'user', p_user_id::text, jsonb_build_object('signals', v_signals, 'until', v_until));
    return jsonb_build_object('suspended', true, 'signals', v_signals, 'until', v_until);
  end if;
  return jsonb_build_object('suspended', false, 'signals', v_signals);
end;
$$;
revoke all on function public.worker_ai_abuse_check(uuid) from public, anon, authenticated;
grant execute on function public.worker_ai_abuse_check(uuid) to service_role;
