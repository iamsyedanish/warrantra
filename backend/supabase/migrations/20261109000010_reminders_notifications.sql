-- =============================================================================
-- 0010 Reminder service: canonical server schedule, versioned, deduplicated;
--      delivery attempts tracked separately from outcomes.
--
--   * Logical reminders dedupe by (source record, offset) per schedule version.
--   * Delivery attempts dedupe by (reminder, version, channel, destination).
--   * Editing a deadline supersedes old versions; completed returns/registrations
--     cancel their alerts. Two coverages on one item can alert simultaneously.
--   * Dates are interpreted in the user's IANA timezone at their local alert time.
--     A date-only field is not evidence of a legal midnight cutoff.
--   * provider_accepted != delivered != opened.
-- =============================================================================

create table public.reminders (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references public.profiles (id) on delete cascade,
  item_id              uuid,
  reminder_type        text not null
                         check (reminder_type in ('warranty_expiry', 'return_deadline', 'registration_deadline',
                                                  'claim_follow_up', 'maintenance_due', 'custom', 'monthly_digest')),
  warranty_id          uuid,
  return_window_id     uuid,
  registration_id      uuid,
  claim_id             uuid,
  maintenance_task_id  uuid references public.maintenance_tasks (id) on delete cascade,
  source_id            uuid generated always as (coalesce(warranty_id, return_window_id, registration_id, claim_id, maintenance_task_id)) stored,
  offset_days          integer not null default 0 check (offset_days between 0 and 365),
  target_date          date,
  local_alert_time     time not null default '09:00',
  timezone             text not null,
  due_at               timestamptz not null,
  schedule_version     integer not null default 1 check (schedule_version > 0),
  state                text not null default 'scheduled'
                         check (state in ('scheduled', 'dispatching', 'dispatched', 'cancelled', 'superseded', 'failed')),
  cancel_reason        text,
  title                text not null check (char_length(title) <= 200),
  body                 text not null check (char_length(body) <= 500),
  is_estimate          boolean not null default false,
  dedupe_key           text,
  attempts             integer not null default 0,
  next_attempt_at      timestamptz,
  locked_at            timestamptz,
  dispatched_at        timestamptz,
  last_error           text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  foreign key (warranty_id, item_id, user_id) references public.warranties (id, item_id, user_id) on delete cascade,
  foreign key (return_window_id, item_id, user_id) references public.return_windows (id, item_id, user_id) on delete cascade,
  foreign key (registration_id, item_id, user_id) references public.registrations (id, item_id, user_id) on delete cascade,
  foreign key (claim_id, user_id) references public.claims (id, user_id) on delete cascade,
  foreign key (item_id, user_id) references public.items (id, user_id) on delete cascade,
  -- Exactly one appropriate source reference must match the reminder type.
  check (
    (reminder_type = 'warranty_expiry'       and warranty_id is not null and num_nonnulls(return_window_id, registration_id, claim_id, maintenance_task_id) = 0 and item_id is not null) or
    (reminder_type = 'return_deadline'       and return_window_id is not null and num_nonnulls(warranty_id, registration_id, claim_id, maintenance_task_id) = 0 and item_id is not null) or
    (reminder_type = 'registration_deadline' and registration_id is not null and num_nonnulls(warranty_id, return_window_id, claim_id, maintenance_task_id) = 0 and item_id is not null) or
    (reminder_type = 'claim_follow_up'       and claim_id is not null and num_nonnulls(warranty_id, return_window_id, registration_id, maintenance_task_id) = 0) or
    (reminder_type = 'maintenance_due'       and maintenance_task_id is not null and num_nonnulls(warranty_id, return_window_id, registration_id, claim_id) = 0) or
    (reminder_type in ('custom', 'monthly_digest') and num_nonnulls(warranty_id, return_window_id, registration_id, claim_id, maintenance_task_id) = 0)
  )
);
-- Logical dedupe: one reminder per (source, offset, version) and one live reminder per (source, offset).
create unique index reminders_logical_uniq on public.reminders (reminder_type, source_id, offset_days, schedule_version)
  where source_id is not null;
create unique index reminders_live_uniq on public.reminders (reminder_type, source_id, offset_days)
  where source_id is not null and state in ('scheduled', 'dispatching');
create unique index reminders_dedupe_key_uniq on public.reminders (user_id, dedupe_key) where dedupe_key is not null;
create index reminders_due_idx on public.reminders (due_at) where state = 'scheduled';
create index reminders_user_due_idx on public.reminders (user_id, due_at, state);
create index reminders_item_idx on public.reminders (item_id) where item_id is not null;
create index reminders_source_idx on public.reminders (source_id) where source_id is not null;
create trigger reminders_updated_at before update on public.reminders
  for each row execute function app_private.set_updated_at();

create table public.notification_deliveries (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references public.profiles (id) on delete cascade,
  reminder_id           uuid not null references public.reminders (id) on delete cascade,
  schedule_version      integer not null,
  channel               text not null check (channel in ('push', 'in_app', 'email')),
  destination           text not null,                 -- device id for push, 'in_app', or email hash
  device_id             uuid references public.devices (id) on delete set null,
  provider              text,
  state                 text not null default 'queued'
                          check (state in ('queued', 'provider_accepted', 'failed', 'opened', 'suppressed')),
  attempt_count         integer not null default 0,
  provider_message_id   text,
  provider_response     jsonb,                          -- sanitised: status + error code only
  error_code            text,
  queued_at             timestamptz not null default now(),
  accepted_at           timestamptz,
  failed_at             timestamptz,
  opened_at             timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (reminder_id, schedule_version, channel, destination)
);
create index notification_deliveries_user_idx on public.notification_deliveries (user_id, created_at desc);
create index notification_deliveries_failed_idx on public.notification_deliveries (failed_at) where state = 'failed';
create trigger notification_deliveries_updated_at before update on public.notification_deliveries
  for each row execute function app_private.set_updated_at();

alter table public.reminders enable row level security;
alter table public.notification_deliveries enable row level security;
revoke all on public.reminders, public.notification_deliveries from anon, authenticated;
grant select on public.reminders, public.notification_deliveries to authenticated;
grant all on public.reminders, public.notification_deliveries to service_role;
create policy reminders_select_own on public.reminders for select to authenticated using (user_id = auth.uid());
create policy notification_deliveries_select_own on public.notification_deliveries for select to authenticated using (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Scheduling engine
-- -----------------------------------------------------------------------------
create or replace function app_private.pref_offsets(p_prefs jsonb, p_key text, p_default int[])
returns int[]
language sql
immutable
as $$
  select case
           when p_prefs -> p_key ? 'offsets_days' and jsonb_typeof(p_prefs -> p_key -> 'offsets_days') = 'array'
             then (select coalesce(array_agg(distinct v::int order by v::int desc), '{}')
                     from jsonb_array_elements_text(p_prefs -> p_key -> 'offsets_days') v
                    where v ~ '^\d{1,3}$' and v::int between 0 and 365)
           else p_default
         end;
$$;

create or replace function app_private.pref_enabled(p_prefs jsonb, p_key text)
returns boolean
language sql
immutable
as $$
  select coalesce((p_prefs -> p_key ->> 'enabled')::boolean, true);
$$;

create or replace function app_private.format_day(p_date date)
returns text
language sql
immutable
as $$
  select trim(to_char(p_date, 'FMMonth FMDD, YYYY'));
$$;

create or replace function app_private.relative_phrase(p_days integer)
returns text
language sql
immutable
as $$
  select case
           when p_days <= 0 then 'today'
           when p_days = 1 then 'tomorrow'
           else 'in ' || p_days || ' days'
         end;
$$;

-- Core: (re)build the reminders for one source record. Idempotent — an unchanged
-- schedule causes no writes; a changed one supersedes the old version.
create or replace function app_private.sync_source_reminders(p_type text, p_source_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_item_id uuid;
  v_target date;
  v_eligible boolean := false;
  v_is_estimate boolean := false;
  v_item_name text;
  v_detail text;
  v_pref_key text;
  v_default int[];
  v_prefs jsonb;
  v_tz text;
  v_alert time;
  v_offsets int[];
  v_today date;
  v_new jsonb := '[]'::jsonb;
  v_existing jsonb;
  v_version integer;
  v_off integer;
  v_due timestamptz;
  v_days integer;
  v_title text;
  v_body text;
  v_rec record;
  v_cancel_reason text := 'source_no_longer_eligible';
begin
  if p_type = 'warranty_expiry' then
    select w.user_id, w.item_id, w.end_date,
           w.contract_state = 'active'
             and w.end_date is not null
             and w.term_kind in ('fixed_date', 'duration')
             and (w.date_certainty in ('document_verified', 'user_confirmed') or w.estimate_accepted_at is not null)
             and i.lifecycle_state = 'owned',
           w.date_certainty = 'estimated',
           i.name,
           coalesce(nullif(w.provider_name, ''), replace(w.coverage_type, '_', ' ')) || ' coverage'
      into v_user_id, v_item_id, v_target, v_eligible, v_is_estimate, v_item_name, v_detail
      from public.warranties w join public.items i on i.id = w.item_id
     where w.id = p_source_id;
    v_pref_key := 'warranty'; v_default := array[30, 7, 1];
  elsif p_type = 'return_deadline' then
    select r.user_id, r.item_id, r.return_deadline,
           r.return_deadline is not null and r.return_state = 'not_started' and not r.dismissed
             and (r.date_certainty in ('document_verified', 'user_confirmed') or r.estimate_accepted_at is not null)
             and i.lifecycle_state = 'owned',
           r.date_certainty = 'estimated',
           i.name,
           case r.deadline_basis
             when 'request_by' then 'Return request deadline'
             when 'postmark_by' then 'Return must be postmarked by'
             when 'merchant_receipt_by' then 'Return must reach the merchant by'
             else 'Return deadline' end
      into v_user_id, v_item_id, v_target, v_eligible, v_is_estimate, v_item_name, v_detail
      from public.return_windows r join public.items i on i.id = r.item_id
     where r.id = p_source_id;
    if v_user_id is not null and not v_eligible then
      v_cancel_reason := 'return_completed_or_ineligible';
    end if;
    v_pref_key := 'return'; v_default := array[7, 3, 1];
  elsif p_type = 'registration_deadline' then
    select g.user_id, g.item_id, g.deadline,
           g.deadline is not null and g.status in ('not_started', 'link_opened') and i.lifecycle_state = 'owned',
           g.deadline_certainty = 'estimated',
           i.name,
           coalesce(nullif(g.provider_name, ''), 'Product') || ' registration'
      into v_user_id, v_item_id, v_target, v_eligible, v_is_estimate, v_item_name, v_detail
      from public.registrations g join public.items i on i.id = g.item_id
     where g.id = p_source_id;
    if v_user_id is not null and not v_eligible then
      v_cancel_reason := 'registration_completed_or_ineligible';
    end if;
    v_pref_key := 'registration'; v_default := array[7, 1];
  elsif p_type = 'claim_follow_up' then
    select c.user_id, c.item_id, c.follow_up_on,
           c.follow_up_on is not null and c.status in ('submitted_by_user', 'in_review', 'info_requested'),
           false, c.item_label, coalesce(nullif(c.provider_name, ''), 'your') || ' claim'
      into v_user_id, v_item_id, v_target, v_eligible, v_is_estimate, v_item_name, v_detail
      from public.claims c
     where c.id = p_source_id;
    v_pref_key := 'claim_follow_up'; v_default := array[0];
    v_item_id := null;  -- claim reminders do not hard-link to the item
  elsif p_type = 'maintenance_due' then
    select t.owner_id, null::uuid, t.next_due_on,
           t.next_due_on is not null and t.state = 'active' and t.reminder_enabled,
           false, t.title, t.title
      into v_user_id, v_item_id, v_target, v_eligible, v_is_estimate, v_item_name, v_detail
      from public.maintenance_tasks t
     where t.id = p_source_id;
    v_pref_key := 'maintenance'; v_default := array[3, 0];
  else
    raise exception 'unknown_reminder_type:%', p_type;
  end if;

  -- Source deleted: FK cascades remove its reminders.
  if v_user_id is null then
    return;
  end if;

  select p.notification_preferences, p.timezone, p.alert_local_time
    into v_prefs, v_tz, v_alert
    from public.profiles p where p.id = v_user_id;

  if v_eligible and not app_private.pref_enabled(v_prefs, v_pref_key) then
    v_eligible := false;
    v_cancel_reason := 'disabled_in_preferences';
  end if;

  if v_eligible then
    v_today := (now() at time zone v_tz)::date;
    v_offsets := app_private.pref_offsets(v_prefs, v_pref_key, v_default);

    if v_target >= v_today then
      foreach v_off in array v_offsets loop
        v_due := app_private.local_to_instant(v_target - v_off, v_alert, v_tz);
        if v_due > now() then
          v_new := v_new || jsonb_build_object('offset', v_off, 'due_at', v_due);
        end if;
      end loop;
      -- Every configured offset is already past but the deadline is not: send one
      -- catch-up alert now, unless something was already dispatched for this source.
      if jsonb_array_length(v_new) = 0
         and not exists (select 1 from public.reminders r where r.reminder_type = p_type and r.source_id = p_source_id
                           and r.state = 'dispatched') then
        v_new := jsonb_build_array(jsonb_build_object('offset', greatest(v_target - v_today, 0), 'due_at', now()));
      end if;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('offset', r.offset_days, 'due_at', r.due_at) order by r.offset_days desc), '[]'::jsonb)
    into v_existing
    from public.reminders r
   where r.reminder_type = p_type and r.source_id = p_source_id and r.state in ('scheduled', 'dispatching');

  -- Normalise ordering for comparison.
  select coalesce(jsonb_agg(e order by (e ->> 'offset')::int desc), '[]'::jsonb) into v_new
    from jsonb_array_elements(v_new) e;

  if v_new = v_existing then
    return;  -- unchanged: idempotent, no version churn
  end if;

  select coalesce(max(schedule_version), 0) + 1 into v_version
    from public.reminders where reminder_type = p_type and source_id = p_source_id;

  update public.reminders
     set state = case when jsonb_array_length(v_new) = 0 then 'cancelled' else 'superseded' end,
         cancel_reason = case when jsonb_array_length(v_new) = 0 then v_cancel_reason else 'schedule_changed' end
   where reminder_type = p_type and source_id = p_source_id and state in ('scheduled', 'dispatching');

  for v_rec in select (e ->> 'offset')::int as off, (e ->> 'due_at')::timestamptz as due from jsonb_array_elements(v_new) e loop
    v_days := v_rec.off;
    v_title := case p_type
      when 'return_deadline' then 'Your return window ends ' || app_private.relative_phrase(v_days)
      when 'warranty_expiry' then 'Coverage ends ' || app_private.relative_phrase(v_days)
      when 'registration_deadline' then 'Registration for your ' || v_item_name || ' is due ' || app_private.relative_phrase(v_days)
      when 'claim_follow_up' then 'Time to follow up on your claim'
      when 'maintenance_due' then v_item_name || ' is due ' || app_private.relative_phrase(v_days)
    end;
    v_body := case p_type
      when 'return_deadline' then v_detail || ' for your ' || v_item_name || ': ' || app_private.format_day(v_target) || '.'
      when 'warranty_expiry' then 'Your ' || v_item_name || ' ' || v_detail || ' term recorded in Warrantra ends ' || app_private.format_day(v_target) || '.'
      when 'registration_deadline' then v_detail || ' deadline: ' || app_private.format_day(v_target) || '.'
      when 'claim_follow_up' then 'Check the status of ' || v_detail || ' for ' || v_item_name || '.'
      when 'maintenance_due' then 'Scheduled for ' || app_private.format_day(v_target) || '.'
    end;
    if v_is_estimate then
      v_body := v_body || ' (Estimated date — confirm your terms.)';
    end if;

    insert into public.reminders (user_id, item_id, reminder_type, warranty_id, return_window_id, registration_id,
                                  claim_id, maintenance_task_id, offset_days, target_date, local_alert_time, timezone,
                                  due_at, schedule_version, title, body, is_estimate)
    values (v_user_id, v_item_id, p_type,
            case when p_type = 'warranty_expiry' then p_source_id end,
            case when p_type = 'return_deadline' then p_source_id end,
            case when p_type = 'registration_deadline' then p_source_id end,
            case when p_type = 'claim_follow_up' then p_source_id end,
            case when p_type = 'maintenance_due' then p_source_id end,
            v_rec.off, v_target, v_alert, v_tz, v_rec.due, v_version, left(v_title, 200), left(v_body, 500), v_is_estimate);
  end loop;
end;
$$;

-- Trigger wrappers
create or replace function app_private.trg_sync_warranty_reminders()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app_private.sync_source_reminders('warranty_expiry', new.id);
  return null;
end; $$;
create or replace function app_private.trg_sync_return_reminders()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app_private.sync_source_reminders('return_deadline', new.id);
  return null;
end; $$;
create or replace function app_private.trg_sync_registration_reminders()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app_private.sync_source_reminders('registration_deadline', new.id);
  return null;
end; $$;
create or replace function app_private.trg_sync_claim_reminders()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app_private.sync_source_reminders('claim_follow_up', new.id);
  return null;
end; $$;
create or replace function app_private.trg_sync_maintenance_reminders()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app_private.sync_source_reminders('maintenance_due', new.id);
  return null;
end; $$;

create trigger warranties_sync_reminders after insert or update on public.warranties
  for each row execute function app_private.trg_sync_warranty_reminders();
create trigger return_windows_sync_reminders after insert or update on public.return_windows
  for each row execute function app_private.trg_sync_return_reminders();
create trigger registrations_sync_reminders after insert or update on public.registrations
  for each row execute function app_private.trg_sync_registration_reminders();
create trigger claims_sync_reminders after insert or update of follow_up_on, status on public.claims
  for each row execute function app_private.trg_sync_claim_reminders();
create trigger maintenance_tasks_sync_reminders after insert or update on public.maintenance_tasks
  for each row execute function app_private.trg_sync_maintenance_reminders();

-- Re-sync every source for a user (timezone/alert-time/preference changes, travel).
create or replace function app_private.resync_user_reminders(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  for v_id in select id from public.warranties where user_id = p_user_id loop
    perform app_private.sync_source_reminders('warranty_expiry', v_id);
  end loop;
  for v_id in select id from public.return_windows where user_id = p_user_id loop
    perform app_private.sync_source_reminders('return_deadline', v_id);
  end loop;
  for v_id in select id from public.registrations where user_id = p_user_id loop
    perform app_private.sync_source_reminders('registration_deadline', v_id);
  end loop;
  for v_id in select id from public.claims where user_id = p_user_id loop
    perform app_private.sync_source_reminders('claim_follow_up', v_id);
  end loop;
  for v_id in select id from public.maintenance_tasks where owner_id = p_user_id loop
    perform app_private.sync_source_reminders('maintenance_due', v_id);
  end loop;
end;
$$;

create or replace function app_private.trg_profile_resync()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.timezone is distinct from old.timezone
     or new.alert_local_time is distinct from old.alert_local_time
     or new.notification_preferences is distinct from old.notification_preferences then
    perform app_private.resync_user_reminders(new.id);
  end if;
  return null;
end; $$;
create trigger profiles_resync_reminders after update on public.profiles
  for each row execute function app_private.trg_profile_resync();

-- Item lifecycle/name changes affect eligibility and copy.
create or replace function app_private.trg_item_resync()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if new.lifecycle_state is distinct from old.lifecycle_state or new.name is distinct from old.name then
    for v_id in select id from public.warranties where item_id = new.id loop
      perform app_private.sync_source_reminders('warranty_expiry', v_id); end loop;
    for v_id in select id from public.return_windows where item_id = new.id loop
      perform app_private.sync_source_reminders('return_deadline', v_id); end loop;
    for v_id in select id from public.registrations where item_id = new.id loop
      perform app_private.sync_source_reminders('registration_deadline', v_id); end loop;
  end if;
  return null;
end; $$;
create trigger items_resync_reminders after update of lifecycle_state, name on public.items
  for each row execute function app_private.trg_item_resync();

-- -----------------------------------------------------------------------------
-- Custom reminders (client RPC; optional item)
-- -----------------------------------------------------------------------------
create or replace function public.create_custom_reminder(p_title text, p_body text, p_date date, p_item_id uuid default null,
                                                         p_local_time time default null)
returns public.reminders
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_profile public.profiles;
  v_row public.reminders;
  v_due timestamptz;
begin
  select * into v_profile from public.profiles where id = v_uid;
  if p_item_id is not null and not exists (select 1 from public.items where id = p_item_id and user_id = v_uid) then
    raise exception 'item_not_found' using errcode = 'P0002';
  end if;
  if p_title is null or char_length(btrim(p_title)) = 0 then
    raise exception 'title_required' using errcode = '22023';
  end if;
  v_due := app_private.local_to_instant(p_date, coalesce(p_local_time, v_profile.alert_local_time), v_profile.timezone);
  if v_due <= now() then
    raise exception 'reminder_in_past' using errcode = '22023';
  end if;
  insert into public.reminders (user_id, item_id, reminder_type, offset_days, target_date, local_alert_time, timezone,
                                due_at, title, body)
  values (v_uid, p_item_id, 'custom', 0, p_date, coalesce(p_local_time, v_profile.alert_local_time), v_profile.timezone,
          v_due, left(p_title, 200), left(coalesce(p_body, ''), 500))
  returning * into v_row;
  return v_row;
end;
$$;
grant execute on function public.create_custom_reminder(text, text, date, uuid, time) to authenticated;

create or replace function public.cancel_custom_reminder(p_reminder_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
begin
  update public.reminders set state = 'cancelled', cancel_reason = 'user_cancelled'
   where id = p_reminder_id and user_id = v_uid and reminder_type = 'custom' and state = 'scheduled';
  if not found then
    raise exception 'reminder_not_found' using errcode = 'P0002';
  end if;
end;
$$;
grant execute on function public.cancel_custom_reminder(uuid) to authenticated;

-- Opened-tracking from the device (does not imply anything about other deliveries).
create or replace function public.mark_notification_opened(p_delivery_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
begin
  update public.notification_deliveries set state = 'opened', opened_at = coalesce(opened_at, now())
   where id = p_delivery_id and user_id = v_uid and state in ('provider_accepted', 'opened');
end;
$$;
grant execute on function public.mark_notification_opened(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Worker RPCs (service_role only)
-- -----------------------------------------------------------------------------
create or replace function public.worker_claim_due_reminders(p_batch integer default 100, p_lock_timeout interval default interval '5 minutes')
returns setof public.reminders
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Recover reminders stuck in dispatching after a worker crash.
  update public.reminders set state = 'scheduled', locked_at = null
   where state = 'dispatching' and locked_at < now() - p_lock_timeout;

  return query
  with due as (
    select r.id from public.reminders r
     where r.state = 'scheduled'
       and r.due_at <= now()
       and (r.next_attempt_at is null or r.next_attempt_at <= now())
     order by r.due_at
     limit p_batch
     for update skip locked
  )
  update public.reminders r
     set state = 'dispatching', locked_at = now(), attempts = r.attempts + 1
    from due
   where r.id = due.id
  returning r.*;
end;
$$;

create or replace function public.worker_finish_reminder(p_reminder_id uuid, p_schedule_version integer, p_outcome text,
                                                         p_error text default null, p_retry_after interval default null,
                                                         p_max_attempts integer default 5)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_outcome = 'dispatched' then
    update public.reminders set state = 'dispatched', dispatched_at = now(), locked_at = null, last_error = null
     where id = p_reminder_id and schedule_version = p_schedule_version and state = 'dispatching';
  elsif p_outcome = 'retry' then
    update public.reminders
       set state = case when attempts >= p_max_attempts then 'failed' else 'scheduled' end,
           next_attempt_at = now() + coalesce(p_retry_after, interval '2 minutes') * power(2, greatest(attempts - 1, 0)),
           locked_at = null,
           last_error = left(p_error, 500)
     where id = p_reminder_id and schedule_version = p_schedule_version and state = 'dispatching';
  elsif p_outcome = 'failed' then
    update public.reminders set state = 'failed', locked_at = null, last_error = left(p_error, 500)
     where id = p_reminder_id and schedule_version = p_schedule_version and state = 'dispatching';
  else
    raise exception 'invalid_outcome:%', p_outcome;
  end if;
end;
$$;

create or replace function public.reminder_health()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'overdue_not_dispatched', (select count(*) from public.reminders where state in ('scheduled', 'dispatching') and due_at < now() - interval '5 minutes'),
    'dispatched_24h', (select count(*) from public.reminders where state = 'dispatched' and dispatched_at > now() - interval '24 hours'),
    'within_5_min_24h_pct', (select round(100.0 * count(*) filter (where dispatched_at - due_at <= interval '5 minutes') / nullif(count(*), 0), 2)
                               from public.reminders where state = 'dispatched' and dispatched_at > now() - interval '24 hours'),
    'p95_handoff_lag_seconds_24h', (select percentile_cont(0.95) within group (order by extract(epoch from dispatched_at - due_at))
                                      from public.reminders where state = 'dispatched' and dispatched_at > now() - interval '24 hours'),
    'failed_reminders_24h', (select count(*) from public.reminders where state = 'failed' and updated_at > now() - interval '24 hours'),
    'failed_deliveries_24h', (select count(*) from public.notification_deliveries where state = 'failed' and failed_at > now() - interval '24 hours'),
    'provider_accepted_24h', (select count(*) from public.notification_deliveries where state in ('provider_accepted', 'opened') and accepted_at > now() - interval '24 hours'),
    'opened_24h', (select count(*) from public.notification_deliveries where state = 'opened' and opened_at > now() - interval '24 hours'),
    'stale_devices', (select count(*) from public.devices where token_state = 'stale'),
    'target', '99% of eligible due events handed to the provider within 5 minutes (internal target, not an SLA)'
  );
$$;

revoke all on function public.worker_claim_due_reminders(integer, interval) from public, anon, authenticated;
revoke all on function public.worker_finish_reminder(uuid, integer, text, text, interval, integer) from public, anon, authenticated;
revoke all on function public.reminder_health() from public, anon, authenticated;
grant execute on function public.worker_claim_due_reminders(integer, interval) to service_role;
grant execute on function public.worker_finish_reminder(uuid, integer, text, text, interval, integer) to service_role;
grant execute on function public.reminder_health() to service_role;
