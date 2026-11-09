-- =============================================================================
-- 0019 Completeness fixes found in the post-build audit
--   * Time status uses the USER's calendar date (IANA timezone), not server UTC.
--   * Workspace sharing follows the owner's current plan (existing shares are
--     preserved on downgrade; new shares pause).
--   * Registration suggestions from curated brand data.
--   * Annual summary (no "money saved" claims).
--   * Recovery of uploads whose client never called /complete.
-- =============================================================================

create or replace function app_private.user_today(p_user_id uuid)
returns date
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (now() at time zone coalesce((select timezone from public.profiles where id = p_user_id), 'UTC'))::date;
$$;
grant execute on function app_private.user_today(uuid) to authenticated, service_role;

create or replace view public.coverage_status
with (security_invoker = true) as
select
  w.id as warranty_id,
  w.item_id,
  w.user_id,
  w.coverage_type,
  w.provider_name,
  w.term_kind,
  w.date_certainty,
  w.contract_state,
  w.start_date,
  w.end_date,
  w.estimate_accepted_at is not null as estimate_accepted,
  case
    when w.contract_state <> 'active' then 'not_in_force'
    when w.term_kind = 'lifetime' then 'lifetime_terms'
    when w.term_kind = 'conditional' and w.end_date is null then 'conditional_terms'
    when w.end_date is null then 'unknown_end_date'
    when w.start_date is not null and w.start_date > t.today then 'not_started'
    when w.end_date < t.today then 'contract_term_ended'
    when w.end_date <= t.today + 30 then 'ending_soon'
    else 'in_term'
  end as time_status,
  case when w.end_date is not null then w.end_date - t.today end as days_remaining,
  case
    when w.end_date is not null and w.end_date < t.today
      then 'The contractual term recorded here has ended. This does not determine any statutory rights you may have.'
    when w.date_certainty = 'estimated' then 'Estimated date — confirm your actual terms.'
    when w.date_certainty = 'unknown' then 'End date unknown.'
    else null
  end as disclosure
from public.warranties w
cross join lateral (select app_private.user_today(w.user_id) as today) t;

create or replace view public.items_overview
with (security_invoker = true) as
select
  i.*,
  c.slug as category_slug,
  (select min(w.end_date) from public.warranties w
    where w.item_id = i.id and w.contract_state = 'active' and w.end_date >= t.today) as nearest_coverage_end,
  (select count(*) from public.warranties w where w.item_id = i.id and w.contract_state = 'active') as coverage_count,
  (select bool_or(w.date_certainty in ('estimated', 'unknown')) from public.warranties w
    where w.item_id = i.id and w.contract_state = 'active') as has_unconfirmed_coverage,
  (select min(r.return_deadline) from public.return_windows r
    where r.item_id = i.id and r.return_state = 'not_started' and not r.dismissed and r.return_deadline >= t.today) as next_return_deadline,
  (select min(g.deadline) from public.registrations g
    where g.item_id = i.id and g.status in ('not_started', 'link_opened')) as next_registration_deadline,
  exists (select 1 from public.registrations g
           where g.item_id = i.id and g.status in ('not_started', 'link_opened')
             and g.requirement_state in ('terms_stated_required', 'extra_benefit')) as registration_pending,
  (select count(*) from public.item_attachments ia where ia.item_id = i.id) as document_count,
  exists (select 1 from public.item_attachments ia where ia.item_id = i.id and ia.role = 'receipt') as has_receipt
from public.items i
left join public.categories c on c.id = i.category_id
cross join lateral (select app_private.user_today(i.user_id) as today) t;

-- ---------------------------------------------------------------------------
-- New shares require the workspace OWNER's plan to include workspaces.
-- ---------------------------------------------------------------------------
create or replace function app_private.guard_workspace_items()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid;
begin
  if tg_op = 'INSERT' then
    if new.shared_by <> new.user_id then
      raise exception 'only_item_owner_can_share' using errcode = '42501';
    end if;
    if app_private.workspace_role(new.workspace_id, new.user_id) is null then
      raise exception 'item_owner_not_workspace_member' using errcode = '42501';
    end if;
    select owner_id into v_owner from public.workspaces where id = new.workspace_id;
    if not (app_private.plan_limits_for(v_owner)).workspaces_enabled then
      raise exception 'plan_feature_unavailable:workspaces' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Registration suggestions (curated brand URLs; never proof of completion).
-- ---------------------------------------------------------------------------
create or replace function public.suggest_registration(p_item_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'provider_name', b.name,
           'registration_url', b.registration_url,
           'requirement_state', 'unknown',
           'source_kind', 'reference_suggestion',
           'last_verified_at', b.last_verified_at,
           'note', 'Registration may be optional or offer an extra benefit. Check the manufacturer terms; opening the page does not register the product.')), '[]'::jsonb)
    from public.items i
    join public.brands b on b.id = i.brand_id or b.normalized_name = lower(btrim(coalesce(i.brand, '')))
   where i.id = p_item_id and i.user_id = auth.uid() and b.registration_url is not null;
$$;
grant execute on function public.suggest_registration(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Annual summary — counts only; recovered money comes from user-reported outcomes.
-- ---------------------------------------------------------------------------
create or replace function public.get_annual_summary(p_year integer)
returns jsonb
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  with bounds as (select make_date(p_year, 1, 1) as d0, make_date(p_year + 1, 1, 1) as d1),
  yr_items as (
    select i.* from public.items i, bounds b
     where i.user_id = auth.uid() and coalesce(i.purchase_date, i.created_at::date) >= b.d0
       and coalesce(i.purchase_date, i.created_at::date) < b.d1
  )
  select jsonb_build_object(
    'year', p_year,
    'purchases_tracked', (select count(*) from yr_items),
    'purchase_value_tracked', (select coalesce(jsonb_object_agg(currency, total), '{}'::jsonb)
                                 from (select currency, sum(purchase_price) total from yr_items
                                        where purchase_price is not null group by currency) x),
    'returns_completed_before_deadline', (
      select count(*) from public.return_windows r, bounds b
       where r.user_id = auth.uid() and r.initiated_at >= b.d0 and r.initiated_at < b.d1
         and r.return_deadline is not null and r.initiated_at::date <= r.return_deadline),
    'registrations_completed', (
      select count(*) from public.registrations g, bounds b
       where g.user_id = auth.uid() and g.completed_at >= b.d0 and g.completed_at < b.d1),
    'claims_started', (
      select count(*) from public.claims c, bounds b where c.user_id = auth.uid() and c.created_at >= b.d0 and c.created_at < b.d1),
    'outcomes', (
      select coalesce(jsonb_object_agg(outcome_type, n), '{}'::jsonb)
        from (select outcome_type, count(*) n from public.outcomes o, bounds b
               where o.user_id = auth.uid() and o.outcome_date >= b.d0 and o.outcome_date < b.d1 group by outcome_type) x),
    'refunds_reported', (
      select coalesce(jsonb_object_agg(currency, total), '{}'::jsonb)
        from (select currency, sum(amount) total from public.outcomes o, bounds b
               where o.user_id = auth.uid() and o.outcome_type = 'refund_received' and o.amount is not null
                 and o.outcome_date >= b.d0 and o.outcome_date < b.d1 group by currency) x),
    'receipts_stored', (
      select count(*) from public.attachments a, bounds b
       where a.user_id = auth.uid() and a.file_type = 'receipt' and a.deletion_state = 'active'
         and a.processing_state = 'ready' and a.created_at >= b.d0 and a.created_at < b.d1),
    'note', 'Purchase value is what you tracked, not money saved. Refunds are the amounts you reported.'
  );
$$;
grant execute on function public.get_annual_summary(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Upload recovery: pending uploads older than a few minutes are queued for
-- server-side verification; abandoned objects are listed for storage removal.
-- ---------------------------------------------------------------------------
create or replace function public.worker_pending_uploads(p_older_than interval default interval '10 minutes', p_limit integer default 200)
returns table (id uuid, storage_path text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select a.id, a.storage_path from public.attachments a
   where a.processing_state = 'pending_upload' and a.created_at < now() - p_older_than
   order by a.created_at limit p_limit;
$$;

create or replace function public.worker_abandoned_uploads(p_limit integer default 200)
returns table (id uuid, storage_path text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select a.id, a.storage_path from public.attachments a
   where a.processing_state = 'failed' and a.quarantine_reason = 'upload_abandoned'
   order by a.updated_at limit p_limit;
$$;

revoke all on function public.worker_pending_uploads(interval, integer) from public, anon, authenticated;
revoke all on function public.worker_abandoned_uploads(integer) from public, anon, authenticated;
grant execute on function public.worker_pending_uploads(interval, integer) to service_role;
grant execute on function public.worker_abandoned_uploads(integer) to service_role;
