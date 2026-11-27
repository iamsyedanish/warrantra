-- Reminders: never send the same reminder twice.
--
-- sync_source_reminders rebuilds a source's schedule whenever the deadline, the
-- preferences or the alert time change. It used to re-add an offset that had
-- already been sent (e.g. "return window ends tomorrow" sent at 16:58, alert time
-- moved to 17:00, sent again at 17:00), and it superseded rows the worker was in
-- the middle of sending. Now:
--   * an offset already sent for the same deadline is not scheduled again;
--   * rows in 'dispatching' are left for the worker to finish;
--   * "sent" means dispatched, or any push the provider accepted (covers a row
--     that was sent and then superseded before this fix).

create or replace function app_private.reminder_already_sent(p_type text, p_source_id uuid, p_offset integer, p_target date)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.reminders r
     where r.reminder_type = p_type and r.source_id = p_source_id
       and r.target_date is not distinct from p_target
       and (p_offset is null or r.offset_days = p_offset)
       and (r.state in ('dispatched', 'dispatching')
            or exists (select 1 from public.notification_deliveries d
                        where d.reminder_id = r.id and d.channel = 'push' and d.state in ('provider_accepted', 'opened'))));
$$;
revoke all on function app_private.reminder_already_sent(text, uuid, integer, date) from public;

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
        if v_due > now() and not app_private.reminder_already_sent(p_type, p_source_id, v_off, v_target) then
          v_new := v_new || jsonb_build_object('offset', v_off, 'due_at', v_due);
        end if;
      end loop;
      -- Every configured offset is already past but the deadline is not: send one
      -- catch-up alert now, unless something was already dispatched for this source.
      if jsonb_array_length(v_new) = 0
         and not app_private.reminder_already_sent(p_type, p_source_id, null, v_target) then
        v_new := jsonb_build_array(jsonb_build_object('offset', greatest(v_target - v_today, 0), 'due_at', now()));
      end if;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('offset', r.offset_days, 'due_at', r.due_at) order by r.offset_days desc), '[]'::jsonb)
    into v_existing
    from public.reminders r
   where r.reminder_type = p_type and r.source_id = p_source_id and r.state = 'scheduled';

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
   where reminder_type = p_type and source_id = p_source_id and state = 'scheduled';

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
