-- =============================================================================
-- 0011 Usage ledger, AI budget controls, scan jobs, upload reservations
--   * Reservations are atomic (per-user advisory lock) so concurrent requests
--     cannot exceed quota.
--   * The same idempotency key never consumes a second allowance; failures release.
--   * Global provider budget, per-account cost ceiling, rate limit, kill switch.
-- =============================================================================

create table public.usage_ledger (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  feature           text not null check (feature in ('ai_action', 'storage_bytes')),
  quantity          bigint not null check (quantity > 0),
  state             text not null default 'reserved' check (state in ('reserved', 'settled', 'released')),
  idempotency_key   text not null check (char_length(idempotency_key) between 8 and 200),
  quota_period      text not null,              -- 'YYYY-MM' (UTC), 'lifetime', or 'balance' for storage
  plan_code         text not null,
  plan_version      integer not null,
  source_type       text check (source_type in ('scan_job', 'attachment', 'claim_draft')),
  source_id         uuid,
  release_reason    text,
  reserved_at       timestamptz not null default now(),
  settled_at        timestamptz,
  released_at       timestamptz,
  expires_at        timestamptz not null default now() + interval '30 minutes',
  unique (user_id, feature, idempotency_key)
);
create index usage_ledger_user_period_idx on public.usage_ledger (user_id, feature, quota_period) where state in ('reserved', 'settled');
create index usage_ledger_expiring_idx on public.usage_ledger (expires_at) where state = 'reserved';

-- Per provider call cost record (append-only); feeds budgets and margin analytics.
create table public.usage_events (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid,                         -- no FK: cost history survives deletion
  scan_job_id     uuid,
  feature         text not null check (feature in ('receipt_extraction', 'product_label_extraction', 'claim_draft')),
  provider        text not null,
  model           text not null,
  prompt_version  text not null,
  schema_version  text,
  input_tokens    integer not null default 0,
  output_tokens   integer not null default 0,
  cost_usd        numeric(12, 6) not null default 0 check (cost_usd >= 0),
  outcome         text not null check (outcome in ('success', 'provider_error', 'invalid_output', 'refused', 'timeout')),
  latency_ms      integer,
  created_at      timestamptz not null default now()
);
create index usage_events_month_idx on public.usage_events (created_at);
create index usage_events_user_month_idx on public.usage_events (user_id, created_at);

create table public.scan_jobs (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references public.profiles (id) on delete cascade,
  idempotency_key       text not null check (char_length(idempotency_key) between 8 and 128),
  feature               text not null check (feature in ('receipt_extraction', 'product_label_extraction', 'claim_draft')),
  input_kind            text not null check (input_kind in ('attachment', 'ocr_text', 'claim')),
  input_attachment_id   uuid,
  input_claim_id        uuid,
  input_page_count      integer check (input_page_count > 0),
  input_chars           integer check (input_chars >= 0),
  state                 text not null default 'queued'
                          check (state in ('queued', 'processing', 'succeeded', 'failed', 'cancelled', 'confirmed', 'discarded')),
  provider              text,
  model                 text,
  model_version         text,
  prompt_version        text,
  schema_version        text,
  usage_reservation_id  uuid references public.usage_ledger (id) on delete set null,
  attempts              integer not null default 0,
  max_attempts          integer not null default 2,
  input_tokens          integer,
  output_tokens         integer,
  actual_cost_usd       numeric(12, 6),
  quota_period          text,
  error_code            text,
  -- Original extraction candidate kept separately from confirmed data, for a limited time.
  candidate             jsonb,
  candidate_expires_at  timestamptz,
  validation_warnings   jsonb not null default '[]'::jsonb,
  confirmed_purchase_group_id uuid,
  correction_count      integer,
  started_at            timestamptz,
  completed_at          timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (user_id, idempotency_key),
  unique (id, user_id),
  foreign key (input_attachment_id, user_id) references public.attachments (id, user_id) on delete set null (input_attachment_id),
  foreign key (input_claim_id, user_id) references public.claims (id, user_id) on delete set null (input_claim_id)
);
create index scan_jobs_user_idx on public.scan_jobs (user_id, created_at desc);
create index scan_jobs_queue_idx on public.scan_jobs (created_at) where state = 'queued';
create index scan_jobs_candidate_expiry_idx on public.scan_jobs (candidate_expires_at) where candidate is not null;
create trigger scan_jobs_updated_at before update on public.scan_jobs
  for each row execute function app_private.set_updated_at();

alter table public.purchase_groups add constraint purchase_groups_scan_job_fk
  foreign key (scan_job_id, user_id) references public.scan_jobs (id, user_id) on delete set null (scan_job_id);
alter table public.claims add constraint claims_ai_draft_job_fk
  foreign key (ai_draft_job_id) references public.scan_jobs (id) on delete set null;

alter table public.usage_ledger enable row level security;
alter table public.usage_events enable row level security;
alter table public.scan_jobs enable row level security;
revoke all on public.usage_ledger, public.usage_events, public.scan_jobs from anon, authenticated;
grant select on public.usage_ledger, public.scan_jobs to authenticated;
grant all on public.usage_ledger, public.usage_events, public.scan_jobs to service_role;
create policy usage_ledger_select_own on public.usage_ledger for select to authenticated using (user_id = auth.uid());
create policy scan_jobs_select_own on public.scan_jobs for select to authenticated using (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Storage usage
-- -----------------------------------------------------------------------------
create or replace function app_private.storage_used_bytes(p_user_id uuid)
returns bigint
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  -- Each document counts once, however many items/claims link to it.
  select coalesce((select sum(coalesce(a.actual_byte_size, a.declared_byte_size))
                     from public.attachments a
                    where a.user_id = p_user_id and a.deletion_state = 'active'
                      and a.processing_state in ('ready', 'quarantined', 'verifying')), 0)
       + coalesce((select sum(l.quantity) from public.usage_ledger l
                    where l.user_id = p_user_id and l.feature = 'storage_bytes' and l.state = 'reserved'), 0);
$$;

-- -----------------------------------------------------------------------------
-- Upload lifecycle step 1-3: authorize account/plan -> reserve bytes -> pending record.
-- Called by the API with the USER's JWT (auth.uid() is the caller).
-- -----------------------------------------------------------------------------
create or replace function public.begin_attachment_upload(
  p_idempotency_key text,
  p_file_type text,
  p_filename text,
  p_declared_mime text,
  p_declared_size bigint
)
returns public.attachments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_limits public.plan_limits;
  v_existing public.attachments;
  v_row public.attachments;
  v_res_id uuid;
  v_id uuid := gen_random_uuid();
  v_safe_name text;
begin
  if coalesce((app_private.setting('uploads_enabled'))::boolean, true) = false then
    raise exception 'uploads_disabled' using errcode = 'P0001';
  end if;
  if (select account_state from public.profiles where id = v_uid) <> 'active' then
    raise exception 'account_not_active' using errcode = '42501';
  end if;
  if p_declared_mime not in ('image/jpeg', 'image/png', 'image/heic', 'image/heif', 'application/pdf') then
    raise exception 'unsupported_file_type' using errcode = '22023';
  end if;

  perform app_private.lock_user(v_uid, 'storage');

  -- Idempotent retry returns the same pending record.
  select * into v_existing from public.attachments where user_id = v_uid and idempotency_key = p_idempotency_key;
  if v_existing.id is not null then
    return v_existing;
  end if;

  v_limits := app_private.plan_limits_for(v_uid);
  if p_declared_size is null or p_declared_size <= 0 or p_declared_size > v_limits.max_file_bytes then
    raise exception 'file_too_large:%', v_limits.max_file_bytes using errcode = 'P0001';
  end if;
  if app_private.storage_used_bytes(v_uid) + p_declared_size > v_limits.storage_bytes then
    raise exception 'quota_exceeded:storage_bytes:%', v_limits.storage_bytes using errcode = 'P0001';
  end if;

  insert into public.usage_ledger (user_id, feature, quantity, idempotency_key, quota_period, plan_code, plan_version,
                                   source_type, source_id, expires_at)
  values (v_uid, 'storage_bytes', p_declared_size, 'upload:' || p_idempotency_key, 'balance', v_limits.plan_code,
          v_limits.version, 'attachment', v_id, now() + interval '2 hours')
  returning id into v_res_id;

  v_safe_name := coalesce(nullif(regexp_replace(coalesce(p_filename, ''), '[^A-Za-z0-9._-]+', '_', 'g'), ''), 'file');
  v_safe_name := left(v_safe_name, 100);

  insert into public.attachments (id, user_id, storage_path, file_type, original_filename, declared_mime_type,
                                  declared_byte_size, processing_state, idempotency_key, usage_reservation_id,
                                  upload_expires_at, source)
  values (v_id, v_uid, v_uid::text || '/' || v_id::text || '/' || v_safe_name, coalesce(p_file_type, 'other'),
          left(p_filename, 255), p_declared_mime, p_declared_size, 'pending_upload', p_idempotency_key, v_res_id,
          now() + interval '1 hour', 'upload')
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function public.begin_attachment_upload(text, text, text, text, bigint) to authenticated;

-- Upload lifecycle steps 5-7 (server-only, after the API has inspected the stored object).
create or replace function public.worker_complete_attachment_upload(
  p_attachment_id uuid,
  p_verified_mime text,
  p_actual_size bigint,
  p_page_count integer,
  p_checksum text,
  p_outcome text,               -- 'ready' | 'quarantined' | 'failed'
  p_reason text default null
)
returns public.attachments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_att public.attachments;
  v_limits public.plan_limits;
  v_used bigint;
begin
  select * into v_att from public.attachments where id = p_attachment_id for update;
  if v_att.id is null then
    raise exception 'attachment_not_found' using errcode = 'P0002';
  end if;
  if v_att.processing_state not in ('pending_upload', 'verifying') then
    return v_att;  -- idempotent
  end if;

  perform app_private.lock_user(v_att.user_id, 'storage');
  v_limits := app_private.plan_limits_for(v_att.user_id);

  if p_outcome = 'ready' then
    if p_actual_size > v_limits.max_file_bytes then
      p_outcome := 'failed'; p_reason := 'file_too_large';
    elsif p_page_count is not null and p_verified_mime = 'application/pdf' and p_page_count > v_limits.max_pdf_pages_stored then
      p_outcome := 'failed'; p_reason := 'too_many_pdf_pages';
    else
      -- Actual bytes larger than reserved must still fit within the plan.
      v_used := app_private.storage_used_bytes(v_att.user_id) - v_att.declared_byte_size;
      if v_used + p_actual_size > v_limits.storage_bytes and p_actual_size > v_att.declared_byte_size then
        p_outcome := 'failed'; p_reason := 'quota_exceeded';
      end if;
    end if;
  end if;

  update public.attachments
     set processing_state = p_outcome,
         verified_mime_type = case when p_outcome in ('ready', 'quarantined') then p_verified_mime end,
         actual_byte_size = p_actual_size,
         page_count = p_page_count,
         checksum_sha256 = p_checksum,
         quarantine_reason = case when p_outcome <> 'ready' then left(p_reason, 200) end,
         verified_at = now(),
         upload_expires_at = null
   where id = p_attachment_id
  returning * into v_att;

  -- Release the byte reservation: ready/quarantined bytes are now counted on the attachment itself.
  update public.usage_ledger
     set state = case when p_outcome = 'ready' then 'settled' else 'released' end,
         settled_at = case when p_outcome = 'ready' then now() end,
         released_at = case when p_outcome <> 'ready' then now() end,
         release_reason = case when p_outcome <> 'ready' then p_reason end
   where id = v_att.usage_reservation_id and state = 'reserved';

  return v_att;
end;
$$;
revoke all on function public.worker_complete_attachment_upload(uuid, text, bigint, integer, text, text, text) from public, anon, authenticated;
grant execute on function public.worker_complete_attachment_upload(uuid, text, bigint, integer, text, text, text) to service_role;

-- -----------------------------------------------------------------------------
-- AI reservations
-- -----------------------------------------------------------------------------
create or replace function app_private.ai_month_spend_usd(p_user_id uuid default null)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(cost_usd), 0)
    from public.usage_events
   where created_at >= date_trunc('month', now() at time zone 'UTC') at time zone 'UTC'
     and (p_user_id is null or user_id = p_user_id);
$$;

create or replace function public.reserve_ai_action(p_idempotency_key text, p_source_type text, p_source_id uuid)
returns public.usage_ledger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
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
  if (select ai_processing_consent_at from public.profiles where id = v_uid) is null then
    raise exception 'ai_consent_required' using errcode = '42501';
  end if;
  if (select account_state from public.profiles where id = v_uid) <> 'active' then
    raise exception 'account_not_active' using errcode = '42501';
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
    -- A previously released (failed) attempt is re-reserved in place.
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

create or replace function public.worker_settle_usage(p_reservation_id uuid)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.usage_ledger set state = 'settled', settled_at = now()
   where id = p_reservation_id and state = 'reserved';
$$;

create or replace function public.worker_release_usage(p_reservation_id uuid, p_reason text)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.usage_ledger set state = 'released', released_at = now(), release_reason = left(p_reason, 200)
   where id = p_reservation_id and state = 'reserved';
$$;

-- Release abandoned reservations and expire abandoned uploads.
create or replace function public.worker_cleanup_reservations()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_released integer;
  v_uploads integer;
  v_candidates integer;
begin
  update public.attachments
     set processing_state = 'failed', quarantine_reason = 'upload_abandoned'
   where processing_state = 'pending_upload' and upload_expires_at < now();
  get diagnostics v_uploads = row_count;

  update public.usage_ledger
     set state = 'released', released_at = now(), release_reason = 'reservation_expired'
   where state = 'reserved' and expires_at < now();
  get diagnostics v_released = row_count;

  -- Limited retention for original extraction candidates.
  update public.scan_jobs set candidate = null
   where candidate is not null and candidate_expires_at < now();
  get diagnostics v_candidates = row_count;

  return jsonb_build_object('released_reservations', v_released, 'abandoned_uploads', v_uploads,
                            'expired_candidates', v_candidates);
end;
$$;

revoke all on function public.worker_settle_usage(uuid) from public, anon, authenticated;
revoke all on function public.worker_release_usage(uuid, text) from public, anon, authenticated;
revoke all on function public.worker_cleanup_reservations() from public, anon, authenticated;
grant execute on function public.worker_settle_usage(uuid) to service_role;
grant execute on function public.worker_release_usage(uuid, text) to service_role;
grant execute on function public.worker_cleanup_reservations() to service_role;
grant execute on function app_private.storage_used_bytes(uuid) to authenticated, service_role;
grant execute on function app_private.ai_month_spend_usd(uuid) to service_role;

create or replace function public.get_my_usage()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_limits public.plan_limits := app_private.plan_limits_for(v_uid);
  v_period text := case when v_limits.ai_actions_per_month > 0 then to_char(now() at time zone 'UTC', 'YYYY-MM') else 'lifetime' end;
begin
  return jsonb_build_object(
    'plan_code', v_limits.plan_code,
    'items', jsonb_build_object('used', (select count(*) from public.items where user_id = v_uid), 'limit', v_limits.max_items),
    'storage_bytes', jsonb_build_object('used', app_private.storage_used_bytes(v_uid), 'limit', v_limits.storage_bytes),
    'ai_actions', jsonb_build_object(
      'period', v_period,
      'used', (select coalesce(sum(quantity), 0) from public.usage_ledger where user_id = v_uid and feature = 'ai_action'
                 and quota_period = v_period and state in ('reserved', 'settled')),
      'limit', case when v_limits.ai_actions_per_month > 0 then v_limits.ai_actions_per_month else v_limits.ai_lifetime_trial_actions end),
    'additions_paused', (select count(*) from public.items where user_id = v_uid) >= v_limits.max_items
  );
end;
$$;
grant execute on function public.get_my_usage() to authenticated;
