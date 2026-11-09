-- =============================================================================
-- 0014 Operations: durable job queue (outbox), audit events, worker health,
--      support tickets, retention schedule, privacy-conscious analytics.
-- =============================================================================

create table public.jobs (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null check (kind in ('scan_process', 'export_build', 'account_deletion', 'billing_process',
                                              'billing_reconcile', 'email_ingest', 'storage_backup', 'claim_pack',
                                              'monthly_digest', 'profitability_snapshot', 'retention_purge',
                                              'upload_verify', 'maintenance')),
  payload       jsonb not null default '{}'::jsonb,
  user_id       uuid,
  state         text not null default 'queued' check (state in ('queued', 'running', 'succeeded', 'failed', 'dead', 'cancelled')),
  priority      integer not null default 100,
  run_at        timestamptz not null default now(),
  attempts      integer not null default 0,
  max_attempts  integer not null default 5,
  dedupe_key    text,
  locked_by     text,
  locked_at     timestamptz,
  last_error    text,
  result        jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  completed_at  timestamptz
);
create unique index jobs_dedupe_uniq on public.jobs (kind, dedupe_key) where dedupe_key is not null and state in ('queued', 'running');
create index jobs_ready_idx on public.jobs (priority, run_at) where state = 'queued';
create index jobs_failed_idx on public.jobs (updated_at desc) where state in ('failed', 'dead');
create trigger jobs_updated_at before update on public.jobs
  for each row execute function app_private.set_updated_at();

create or replace function public.enqueue_job(p_kind text, p_payload jsonb, p_user_id uuid default null,
                                              p_dedupe_key text default null, p_run_at timestamptz default now(),
                                              p_priority integer default 100, p_max_attempts integer default 5)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  insert into public.jobs (kind, payload, user_id, dedupe_key, run_at, priority, max_attempts)
  values (p_kind, coalesce(p_payload, '{}'::jsonb), p_user_id, p_dedupe_key, p_run_at, p_priority, p_max_attempts)
  on conflict (kind, dedupe_key) where dedupe_key is not null and state in ('queued', 'running') do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.jobs
     where kind = p_kind and dedupe_key = p_dedupe_key and state in ('queued', 'running');
  end if;
  return v_id;
end;
$$;

create or replace function public.worker_claim_jobs(p_kinds text[], p_worker text, p_batch integer default 10,
                                                    p_lock_timeout interval default interval '15 minutes')
returns setof public.jobs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.jobs set state = 'queued', locked_by = null, locked_at = null, last_error = 'lock_timeout'
   where state = 'running' and locked_at < now() - p_lock_timeout;

  return query
  with ready as (
    select j.id from public.jobs j
     where j.state = 'queued' and j.run_at <= now() and j.kind = any (p_kinds)
     order by j.priority, j.run_at
     limit p_batch
     for update skip locked
  )
  update public.jobs j
     set state = 'running', locked_by = p_worker, locked_at = now(), attempts = j.attempts + 1
    from ready
   where j.id = ready.id
  returning j.*;
end;
$$;

create or replace function public.worker_finish_job(p_job_id uuid, p_success boolean, p_error text default null,
                                                    p_result jsonb default null, p_retry_in interval default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_success then
    update public.jobs set state = 'succeeded', completed_at = now(), locked_by = null, locked_at = null,
                           result = p_result, last_error = null
     where id = p_job_id;
  else
    update public.jobs
       set state = case when attempts >= max_attempts then 'dead' else 'queued' end,
           run_at = now() + coalesce(p_retry_in, interval '1 minute' * power(2, least(attempts, 10))),
           locked_by = null, locked_at = null,
           last_error = left(p_error, 1000)
     where id = p_job_id;
  end if;
end;
$$;

revoke all on function public.enqueue_job(text, jsonb, uuid, text, timestamptz, integer, integer) from public, anon, authenticated;
revoke all on function public.worker_claim_jobs(text[], text, integer, interval) from public, anon, authenticated;
revoke all on function public.worker_finish_job(uuid, boolean, text, jsonb, interval) from public, anon, authenticated;
grant execute on function public.enqueue_job(text, jsonb, uuid, text, timestamptz, integer, integer) to service_role;
grant execute on function public.worker_claim_jobs(text[], text, integer, interval) to service_role;
grant execute on function public.worker_finish_job(uuid, boolean, text, jsonb, interval) to service_role;

create table public.worker_heartbeats (
  worker_name   text primary key,
  last_beat_at  timestamptz not null default now(),
  info          jsonb not null default '{}'::jsonb
);

-- Append-only audit trail. Metadata must already be redacted by the caller.
create table public.audit_events (
  id           bigint generated always as identity primary key,
  actor_type   text not null check (actor_type in ('user', 'admin', 'system', 'worker', 'webhook')),
  actor_id     uuid,
  action       text not null,
  target_type  text,
  target_id    text,
  metadata     jsonb not null default '{}'::jsonb,
  ip_hash      text,
  created_at   timestamptz not null default now()
);
create index audit_events_target_idx on public.audit_events (target_type, target_id, created_at desc);
create index audit_events_actor_idx on public.audit_events (actor_id, created_at desc);

create or replace function app_private.audit_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'audit_events_are_append_only' using errcode = '42501';
end;
$$;
create trigger audit_events_append_only before update or delete on public.audit_events
  for each row execute function app_private.audit_append_only();

-- Support
create table public.support_tickets (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references public.profiles (id) on delete set null,
  contact_email   text check (char_length(contact_email) <= 320),
  subject         text not null check (char_length(btrim(subject)) between 1 and 200),
  category        text not null default 'general'
                    check (category in ('general', 'billing', 'privacy', 'deletion', 'bug', 'reminders', 'claims', 'data_export')),
  status          text not null default 'open' check (status in ('open', 'pending_user', 'resolved', 'closed')),
  priority        text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  assigned_to     uuid,
  support_minutes integer not null default 0 check (support_minutes >= 0),
  retention_until date,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index support_tickets_user_idx on public.support_tickets (user_id, created_at desc);
create index support_tickets_open_idx on public.support_tickets (status, created_at) where status in ('open', 'pending_user');
create trigger support_tickets_updated_at before update on public.support_tickets
  for each row execute function app_private.set_updated_at();

create table public.support_messages (
  id           uuid primary key default gen_random_uuid(),
  ticket_id    uuid not null references public.support_tickets (id) on delete cascade,
  author_type  text not null check (author_type in ('user', 'staff', 'system')),
  author_id    uuid,
  body         text not null check (char_length(body) between 1 and 10000),
  internal     boolean not null default false,
  created_at   timestamptz not null default now()
);
create index support_messages_ticket_idx on public.support_messages (ticket_id, created_at);

-- Published retention schedule.
create table public.retention_policies (
  data_class      text primary key,
  retention_days  integer check (retention_days > 0),
  description     text not null,
  published_at    timestamptz not null default now()
);
insert into public.retention_policies (data_class, retention_days, description) values
  ('failed_scan_candidates', 30,  'Raw extraction candidates for failed or unconfirmed scans.'),
  ('confirmed_scan_candidates', 30, 'Original extraction candidates retained beside confirmed data for correction analysis.'),
  ('application_logs', 30, 'Operational logs (redacted; no receipt contents, serials or signed links).'),
  ('audit_events', 730, 'Security and administrative audit trail.'),
  ('notification_deliveries', 180, 'Push/in-app delivery attempts and provider responses.'),
  ('support_records', 730, 'Support tickets and messages after closure.'),
  ('inbound_email_records', 90, 'Metadata about forwarded emails (no message bodies retained).'),
  ('analytics_events', 395, 'Allow-listed product analytics events.'),
  ('database_backups', 30, 'Provider-managed database backups (tombstones replayed on restore).'),
  ('storage_backups', 35, 'Separate backups of original files; purged after account deletion.'),
  ('export_bundles', 7, 'Generated export files and their expiring links.'),
  ('claim_packs', 365, 'Generated claim packages, while the account exists.');

-- Analytics: allow-listed events and properties only. No receipt text, serial
-- numbers, purchase details or document contents.
create table public.analytics_event_types (
  event_name      text primary key,
  allowed_props   text[] not null default '{}',
  description     text
);
insert into public.analytics_event_types (event_name, allowed_props, description) values
  ('onboarding_completed', '{}', null),
  ('item_created', '{source}', null),
  ('item_created_manual', '{}', null),
  ('item_created_receipt_scan', '{line_count}', null),
  ('receipt_scan_started', '{input_kind}', null),
  ('receipt_scan_success', '{line_count,correction_count}', null),
  ('receipt_scan_failed', '{error_code}', null),
  ('warranty_added', '{coverage_type,term_kind,date_certainty}', null),
  ('return_deadline_added', '{policy_anchor,terms_state}', null),
  ('registration_added', '{requirement_state}', null),
  ('notification_permission_granted', '{platform}', null),
  ('notification_permission_denied', '{platform}', null),
  ('notification_opened', '{reminder_type}', null),
  ('paywall_viewed', '{placement,offer}', null),
  ('subscription_started', '{offer,billing_period}', null),
  ('subscription_restored', '{}', null),
  ('claim_started', '{claim_kind}', null),
  ('claim_pack_exported', '{format,pack_level}', null),
  ('outcome_recorded', '{outcome_type,evidence_level}', null),
  ('proof_retrieved', '{file_type}', null),
  ('export_requested', '{}', null),
  ('household_created', '{}', null),
  ('portfolio_location_created', '{}', null);

create table public.analytics_events (
  id           bigint generated always as identity primary key,
  user_id      uuid,                 -- for denominators; removed on account deletion
  event_name   text not null references public.analytics_event_types (event_name),
  properties   jsonb not null default '{}'::jsonb,
  platform     text check (platform in ('ios', 'android', 'web', 'server')),
  app_version  text,
  occurred_at  timestamptz not null,
  received_at  timestamptz not null default now()
);
create index analytics_events_name_time_idx on public.analytics_events (event_name, occurred_at);
create index analytics_events_user_idx on public.analytics_events (user_id) where user_id is not null;

-- Strip any property not explicitly allowed for the event, and any non-scalar value.
create or replace function app_private.sanitize_analytics()
returns trigger
language plpgsql
as $$
declare
  v_allowed text[];
begin
  select allowed_props into v_allowed from public.analytics_event_types where event_name = new.event_name;
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into new.properties
    from jsonb_each(coalesce(new.properties, '{}'::jsonb)) as e(k, v)
   where k = any (v_allowed)
     and jsonb_typeof(v) in ('string', 'number', 'boolean')
     and (jsonb_typeof(v) <> 'string' or char_length(v #>> '{}') <= 64);
  if new.occurred_at > now() + interval '1 day' or new.occurred_at < now() - interval '30 days' then
    new.occurred_at := now();
  end if;
  return new;
end;
$$;
create trigger analytics_events_sanitize before insert on public.analytics_events
  for each row execute function app_private.sanitize_analytics();

alter table public.jobs enable row level security;
alter table public.worker_heartbeats enable row level security;
alter table public.audit_events enable row level security;
alter table public.support_tickets enable row level security;
alter table public.support_messages enable row level security;
alter table public.retention_policies enable row level security;
alter table public.analytics_event_types enable row level security;
alter table public.analytics_events enable row level security;

revoke all on public.jobs, public.worker_heartbeats, public.audit_events, public.support_tickets, public.support_messages,
              public.retention_policies, public.analytics_event_types, public.analytics_events from anon, authenticated;
grant select on public.support_tickets, public.support_messages, public.retention_policies, public.analytics_event_types to authenticated;
grant all on public.jobs, public.worker_heartbeats, public.audit_events, public.support_tickets, public.support_messages,
             public.retention_policies, public.analytics_event_types, public.analytics_events to service_role;
grant usage on all sequences in schema public to service_role;

create policy support_tickets_select_own on public.support_tickets for select to authenticated using (user_id = auth.uid());
create policy support_messages_select_own on public.support_messages for select to authenticated
  using (not internal and exists (select 1 from public.support_tickets t where t.id = ticket_id and t.user_id = auth.uid()));
create policy retention_policies_read on public.retention_policies for select to authenticated using (true);
create policy analytics_event_types_read on public.analytics_event_types for select to authenticated using (true);
