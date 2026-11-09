-- =============================================================================
-- 0017 Core RPCs and read models
--   * create_purchase: transactional save of group + lines + selected items +
--     coverage + document links (idempotent per user/idempotency_key).
--   * Action Center, item timeline, items overview, coverage suggestions,
--     claim snapshot builder, maintenance completion, invitations, metrics.
-- SECURITY INVOKER functions run under the caller's RLS.
-- =============================================================================

create or replace function app_private.j_text(p jsonb, k text) returns text
language sql immutable as $$ select nullif(p ->> k, '') $$;
create or replace function app_private.j_date(p jsonb, k text) returns date
language sql immutable as $$ select nullif(p ->> k, '')::date $$;
create or replace function app_private.j_num(p jsonb, k text) returns numeric
language sql immutable as $$ select nullif(p ->> k, '')::numeric $$;
create or replace function app_private.j_int(p jsonb, k text) returns integer
language sql immutable as $$ select nullif(p ->> k, '')::integer $$;
create or replace function app_private.j_uuid(p jsonb, k text) returns uuid
language sql immutable as $$ select nullif(p ->> k, '')::uuid $$;
create or replace function app_private.j_ts(p jsonb, k text) returns timestamptz
language sql immutable as $$ select nullif(p ->> k, '')::timestamptz $$;
grant execute on function app_private.j_text(jsonb, text), app_private.j_date(jsonb, text), app_private.j_num(jsonb, text),
  app_private.j_int(jsonb, text), app_private.j_uuid(jsonb, text), app_private.j_ts(jsonb, text) to authenticated, service_role;

-- Insert one warranty from a JSON object (shared by create_purchase and add-coverage paths).
create or replace function app_private.insert_warranty(p_user_id uuid, p_item_id uuid, w jsonb)
returns uuid
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  insert into public.warranties (user_id, item_id, coverage_type, provider_name, term_kind, date_certainty, start_anchor,
                                 start_date, end_date, duration_months, conditional_terms, estimate_accepted_at, source_kind,
                                 source_url, source_attachment_id, source_reference_id, source_checked_at, confirmed_at,
                                 policy_number, terms_url, payment_card_id, notes)
  values (p_user_id, p_item_id,
          coalesce(app_private.j_text(w, 'coverage_type'), 'manufacturer'),
          app_private.j_text(w, 'provider_name'),
          coalesce(app_private.j_text(w, 'term_kind'), 'unknown'),
          coalesce(app_private.j_text(w, 'date_certainty'), 'unknown'),
          coalesce(app_private.j_text(w, 'start_anchor'), 'purchase_date'),
          app_private.j_date(w, 'start_date'),
          app_private.j_date(w, 'end_date'),
          app_private.j_int(w, 'duration_months'),
          app_private.j_text(w, 'conditional_terms'),
          app_private.j_ts(w, 'estimate_accepted_at'),
          coalesce(app_private.j_text(w, 'source_kind'), 'user_entry'),
          app_private.j_text(w, 'source_url'),
          app_private.j_uuid(w, 'source_attachment_id'),
          app_private.j_uuid(w, 'source_reference_id'),
          app_private.j_ts(w, 'source_checked_at'),
          app_private.j_ts(w, 'confirmed_at'),
          app_private.j_text(w, 'policy_number'),
          app_private.j_text(w, 'terms_url'),
          app_private.j_uuid(w, 'payment_card_id'),
          app_private.j_text(w, 'notes'))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function app_private.insert_return_window(p_user_id uuid, p_item_id uuid, r jsonb)
returns uuid
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  insert into public.return_windows (user_id, item_id, retailer_name, terms_state, policy_anchor, anchor_date, window_days,
                                     return_deadline, deadline_basis, date_certainty, estimate_accepted_at, source_kind,
                                     source_url, source_reference_id, source_attachment_id, source_checked_at, confirmed_at,
                                     conditions, restocking_fee_percent, notes)
  values (p_user_id, p_item_id,
          app_private.j_text(r, 'retailer_name'),
          coalesce(app_private.j_text(r, 'terms_state'), 'unknown'),
          coalesce(app_private.j_text(r, 'policy_anchor'), 'unknown'),
          app_private.j_date(r, 'anchor_date'),
          app_private.j_int(r, 'window_days'),
          app_private.j_date(r, 'return_deadline'),
          coalesce(app_private.j_text(r, 'deadline_basis'), 'unknown'),
          coalesce(app_private.j_text(r, 'date_certainty'), 'unknown'),
          app_private.j_ts(r, 'estimate_accepted_at'),
          coalesce(app_private.j_text(r, 'source_kind'), 'user_entry'),
          app_private.j_text(r, 'source_url'),
          app_private.j_uuid(r, 'source_reference_id'),
          app_private.j_uuid(r, 'source_attachment_id'),
          app_private.j_ts(r, 'source_checked_at'),
          app_private.j_ts(r, 'confirmed_at'),
          app_private.j_text(r, 'conditions'),
          app_private.j_num(r, 'restocking_fee_percent'),
          app_private.j_text(r, 'notes'))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function app_private.insert_registration(p_user_id uuid, p_item_id uuid, g jsonb)
returns uuid
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  insert into public.registrations (user_id, item_id, requirement_state, benefit_description, provider_name, registration_url,
                                    deadline, deadline_certainty, status, source_kind, source_url, source_checked_at, notes)
  values (p_user_id, p_item_id,
          coalesce(app_private.j_text(g, 'requirement_state'), 'unknown'),
          app_private.j_text(g, 'benefit_description'),
          app_private.j_text(g, 'provider_name'),
          app_private.j_text(g, 'registration_url'),
          app_private.j_date(g, 'deadline'),
          coalesce(app_private.j_text(g, 'deadline_certainty'),
                   case when app_private.j_date(g, 'deadline') is not null then 'user_confirmed' else 'unknown' end),
          coalesce(app_private.j_text(g, 'status'), 'not_started'),
          coalesce(app_private.j_text(g, 'source_kind'), 'user_entry'),
          app_private.j_text(g, 'source_url'),
          app_private.j_ts(g, 'source_checked_at'),
          app_private.j_text(g, 'notes'))
  returning id into v_id;
  return v_id;
end;
$$;
grant execute on function app_private.insert_warranty(uuid, uuid, jsonb), app_private.insert_return_window(uuid, uuid, jsonb),
  app_private.insert_registration(uuid, uuid, jsonb) to authenticated, service_role;

create or replace function public.create_purchase(p jsonb)
returns jsonb
language plpgsql
security definer   -- ownership of every referenced row is enforced by composite FKs (parent_id, user_id)
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_group_id uuid;
  v_existing uuid;
  v_line jsonb;
  v_item jsonb;
  v_line_id uuid;
  v_item_id uuid;
  v_w jsonb;
  v_att uuid;
  v_item_ids uuid[] := '{}';
  v_line_ids uuid[] := '{}';
  v_currency text := coalesce(app_private.j_text(p, 'currency'), 'USD');
  v_sum_tax numeric := 0;
  v_sum_ship numeric := 0;
  v_sum_disc numeric := 0;
  v_any_alloc boolean := false;
begin
  -- Idempotent replay returns the original result without duplicating anything.
  select id into v_existing from public.purchase_groups
   where user_id = v_uid and idempotency_key = app_private.j_text(p, 'idempotency_key');
  if v_existing is not null then
    return jsonb_build_object(
      'purchase_group_id', v_existing,
      'created', false,
      'item_ids', (select coalesce(jsonb_agg(id order by created_at), '[]'::jsonb) from public.items where purchase_group_id = v_existing),
      'line_ids', (select coalesce(jsonb_agg(id order by line_index), '[]'::jsonb) from public.receipt_lines where purchase_group_id = v_existing));
  end if;

  if jsonb_typeof(p -> 'lines') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then
    raise exception 'purchase_requires_at_least_one_line' using errcode = '22023';
  end if;

  insert into public.purchase_groups (user_id, retailer, order_number, purchase_date, delivery_date, currency, subtotal, tax,
                                      shipping, discount, total_paid, source, payment_card_id, scan_job_id, notes, idempotency_key)
  values (v_uid, app_private.j_text(p, 'retailer'), app_private.j_text(p, 'order_number'), app_private.j_date(p, 'purchase_date'),
          app_private.j_date(p, 'delivery_date'), v_currency, app_private.j_num(p, 'subtotal'), app_private.j_num(p, 'tax'),
          app_private.j_num(p, 'shipping'), app_private.j_num(p, 'discount'), app_private.j_num(p, 'total_paid'),
          coalesce(app_private.j_text(p, 'source'), 'manual'), app_private.j_uuid(p, 'payment_card_id'),
          app_private.j_uuid(p, 'scan_job_id'), app_private.j_text(p, 'notes'), app_private.j_text(p, 'idempotency_key'))
  returning id into v_group_id;

  -- Original documents are stored once and linked, never duplicated.
  for v_att in select (x #>> '{}')::uuid from jsonb_array_elements(coalesce(p -> 'attachment_ids', '[]'::jsonb)) x loop
    insert into public.purchase_attachments (purchase_group_id, attachment_id, user_id) values (v_group_id, v_att, v_uid);
  end loop;

  for v_line in select * from jsonb_array_elements(p -> 'lines') loop
    v_item_id := null;
    v_item := v_line -> 'item';

    if v_item is not null and jsonb_typeof(v_item) = 'object' then
      insert into public.items (user_id, purchase_group_id, name, brand, brand_id, model_number, serial_number, sku, order_number,
                                category_id, retailer_name, purchase_date, delivery_date, purchase_price, price_is_estimated,
                                currency, quantity, condition_at_purchase, payment_card_id, notes, source)
      values (v_uid, v_group_id,
              coalesce(app_private.j_text(v_item, 'name'), app_private.j_text(v_line, 'confirmed_name'), app_private.j_text(v_line, 'original_description')),
              app_private.j_text(v_item, 'brand'), app_private.j_uuid(v_item, 'brand_id'),
              app_private.j_text(v_item, 'model_number'), app_private.j_text(v_item, 'serial_number'),
              coalesce(app_private.j_text(v_item, 'sku'), app_private.j_text(v_line, 'sku')),
              app_private.j_text(p, 'order_number'), app_private.j_uuid(v_item, 'category_id'),
              app_private.j_text(p, 'retailer'), app_private.j_date(p, 'purchase_date'), app_private.j_date(p, 'delivery_date'),
              app_private.j_num(v_item, 'purchase_price'), coalesce((v_item ->> 'price_is_estimated')::boolean, false),
              v_currency, coalesce(app_private.j_int(v_item, 'quantity'), 1),
              coalesce(app_private.j_text(v_item, 'condition_at_purchase'), 'unknown'),
              app_private.j_uuid(p, 'payment_card_id'), app_private.j_text(v_item, 'notes'),
              coalesce(app_private.j_text(p, 'source'), 'manual'))
      returning id into v_item_id;
      v_item_ids := v_item_ids || v_item_id;

      for v_att in select (x #>> '{}')::uuid from jsonb_array_elements(coalesce(p -> 'attachment_ids', '[]'::jsonb)) x loop
        insert into public.item_attachments (item_id, attachment_id, user_id, role) values (v_item_id, v_att, v_uid, 'receipt')
        on conflict do nothing;
      end loop;
      for v_att in select (x #>> '{}')::uuid from jsonb_array_elements(coalesce(v_item -> 'attachment_ids', '[]'::jsonb)) x loop
        insert into public.item_attachments (item_id, attachment_id, user_id, role) values (v_item_id, v_att, v_uid, 'document')
        on conflict do nothing;
      end loop;

      for v_w in select * from jsonb_array_elements(coalesce(v_item -> 'warranties', '[]'::jsonb)) loop
        perform app_private.insert_warranty(v_uid, v_item_id, v_w);
      end loop;
      if jsonb_typeof(v_item -> 'return_window') = 'object' then
        perform app_private.insert_return_window(v_uid, v_item_id, v_item -> 'return_window');
      end if;
      if jsonb_typeof(v_item -> 'registration') = 'object' then
        perform app_private.insert_registration(v_uid, v_item_id, v_item -> 'registration');
      end if;
    end if;

    insert into public.receipt_lines (user_id, purchase_group_id, item_id, line_index, original_description, confirmed_name, sku,
                                      quantity, unit_amount, line_amount, allocated_tax, allocated_discount, allocated_shipping,
                                      allocation_is_estimated, confirmation_state)
    values (v_uid, v_group_id, v_item_id, app_private.j_int(v_line, 'line_index'),
            app_private.j_text(v_line, 'original_description'), app_private.j_text(v_line, 'confirmed_name'),
            app_private.j_text(v_line, 'sku'), coalesce(app_private.j_num(v_line, 'quantity'), 1),
            app_private.j_num(v_line, 'unit_amount'), app_private.j_num(v_line, 'line_amount'),
            app_private.j_num(v_line, 'allocated_tax'), app_private.j_num(v_line, 'allocated_discount'),
            app_private.j_num(v_line, 'allocated_shipping'),
            coalesce((v_line ->> 'allocation_is_estimated')::boolean, false),
            coalesce(app_private.j_text(v_line, 'confirmation_state'), 'user_confirmed'))
    returning id into v_line_id;
    v_line_ids := v_line_ids || v_line_id;

    if app_private.j_num(v_line, 'allocated_tax') is not null or app_private.j_num(v_line, 'allocated_shipping') is not null
       or app_private.j_num(v_line, 'allocated_discount') is not null then
      v_any_alloc := true;
    end if;
    v_sum_tax := v_sum_tax + coalesce(app_private.j_num(v_line, 'allocated_tax'), 0);
    v_sum_ship := v_sum_ship + coalesce(app_private.j_num(v_line, 'allocated_shipping'), 0);
    v_sum_disc := v_sum_disc + coalesce(app_private.j_num(v_line, 'allocated_discount'), 0);
  end loop;

  -- Allocations can never exceed the group-level amounts (no duplicated totals).
  if v_any_alloc then
    if v_sum_tax > coalesce(app_private.j_num(p, 'tax'), 0)
       or v_sum_ship > coalesce(app_private.j_num(p, 'shipping'), 0)
       or v_sum_disc > coalesce(app_private.j_num(p, 'discount'), 0) then
      raise exception 'allocations_exceed_group_amounts' using errcode = '22023';
    end if;
  end if;

  if app_private.j_uuid(p, 'scan_job_id') is not null then
    update public.scan_jobs set state = 'confirmed', confirmed_purchase_group_id = v_group_id,
                                correction_count = app_private.j_int(p, 'correction_count')
     where id = app_private.j_uuid(p, 'scan_job_id') and user_id = v_uid and state = 'succeeded';
  end if;
  if app_private.j_uuid(p, 'capture_draft_id') is not null then
    update public.capture_drafts set state = 'confirmed', purchase_group_id = v_group_id
     where id = app_private.j_uuid(p, 'capture_draft_id') and user_id = v_uid;
  end if;

  return jsonb_build_object('purchase_group_id', v_group_id, 'created', true,
                            'item_ids', to_jsonb(v_item_ids), 'line_ids', to_jsonb(v_line_ids));
end;
$$;
grant execute on function public.create_purchase(jsonb) to authenticated;

-- Promote an untracked receipt line to a tracked item later (partial selection).
create or replace function public.track_receipt_line(p_line_id uuid, p_item jsonb)
returns uuid
language plpgsql
security definer   -- ownership of every referenced row is enforced by composite FKs (parent_id, user_id)
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_line public.receipt_lines;
  v_group public.purchase_groups;
  v_item_id uuid;
  v_att uuid;
begin
  select * into v_line from public.receipt_lines where id = p_line_id and user_id = v_uid for update;
  if v_line.id is null then raise exception 'line_not_found' using errcode = 'P0002'; end if;
  if v_line.item_id is not null then return v_line.item_id; end if;
  select * into v_group from public.purchase_groups where id = v_line.purchase_group_id;

  insert into public.items (user_id, purchase_group_id, name, brand, model_number, serial_number, sku, order_number, category_id,
                            retailer_name, purchase_date, delivery_date, purchase_price, price_is_estimated, currency, quantity,
                            condition_at_purchase, payment_card_id, source)
  values (v_uid, v_group.id,
          coalesce(app_private.j_text(p_item, 'name'), v_line.confirmed_name, v_line.original_description, 'Item'),
          app_private.j_text(p_item, 'brand'), app_private.j_text(p_item, 'model_number'), app_private.j_text(p_item, 'serial_number'),
          coalesce(app_private.j_text(p_item, 'sku'), v_line.sku), v_group.order_number, app_private.j_uuid(p_item, 'category_id'),
          v_group.retailer, v_group.purchase_date, v_group.delivery_date,
          coalesce(app_private.j_num(p_item, 'purchase_price'),
                   v_line.line_amount + coalesce(v_line.allocated_tax, 0) + coalesce(v_line.allocated_shipping, 0)
                     - coalesce(v_line.allocated_discount, 0)),
          v_line.allocation_is_estimated, v_group.currency, coalesce(app_private.j_int(p_item, 'quantity'), 1),
          coalesce(app_private.j_text(p_item, 'condition_at_purchase'), 'unknown'), v_group.payment_card_id, v_group.source)
  returning id into v_item_id;

  update public.receipt_lines set item_id = v_item_id, confirmation_state = 'user_confirmed' where id = v_line.id;
  for v_att in select attachment_id from public.purchase_attachments where purchase_group_id = v_group.id loop
    insert into public.item_attachments (item_id, attachment_id, user_id, role) values (v_item_id, v_att, v_uid, 'receipt')
    on conflict do nothing;
  end loop;
  return v_item_id;
end;
$$;
grant execute on function public.track_receipt_line(uuid, jsonb) to authenticated;

-- -----------------------------------------------------------------------------
-- Read models
-- -----------------------------------------------------------------------------
create or replace view public.items_overview
with (security_invoker = true) as
select
  i.*,
  c.slug as category_slug,
  (select min(w.end_date) from public.warranties w
    where w.item_id = i.id and w.contract_state = 'active' and w.end_date >= current_date) as nearest_coverage_end,
  (select count(*) from public.warranties w where w.item_id = i.id and w.contract_state = 'active') as coverage_count,
  (select bool_or(w.date_certainty in ('estimated', 'unknown')) from public.warranties w
    where w.item_id = i.id and w.contract_state = 'active') as has_unconfirmed_coverage,
  (select min(r.return_deadline) from public.return_windows r
    where r.item_id = i.id and r.return_state = 'not_started' and not r.dismissed and r.return_deadline >= current_date) as next_return_deadline,
  (select min(g.deadline) from public.registrations g
    where g.item_id = i.id and g.status in ('not_started', 'link_opened')) as next_registration_deadline,
  exists (select 1 from public.registrations g
           where g.item_id = i.id and g.status in ('not_started', 'link_opened')
             and g.requirement_state in ('terms_stated_required', 'extra_benefit')) as registration_pending,
  (select count(*) from public.item_attachments ia where ia.item_id = i.id) as document_count,
  exists (select 1 from public.item_attachments ia where ia.item_id = i.id and ia.role = 'receipt') as has_receipt
from public.items i
left join public.categories c on c.id = i.category_id;
revoke all on public.items_overview from anon;
grant select on public.items_overview to authenticated, service_role;

create or replace function public.get_action_center(p_horizon_days integer default 60)
returns table (
  kind text,
  priority integer,
  item_id uuid,
  item_name text,
  source_id uuid,
  due_date date,
  days_left integer,
  title text,
  certainty text,
  detail text
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  with me as (select p.timezone from public.profiles p where p.id = auth.uid()),
  today as (select (now() at time zone coalesce((select timezone from me), 'UTC'))::date as d),
  actions as (
    select 'return_deadline'::text as kind,
           case when r.return_deadline < (select d from today) then 0 else 1 end as priority,
           i.id as item_id, i.name as item_name, r.id as source_id, r.return_deadline as due_date,
           r.date_certainty as certainty,
           case r.deadline_basis when 'postmark_by' then 'Must be postmarked by this date'
                                 when 'merchant_receipt_by' then 'Must reach the merchant by this date'
                                 when 'request_by' then 'Request the return by this date'
                                 else 'What this deadline means is unknown' end as detail
      from public.return_windows r join public.items i on i.id = r.item_id
     where r.user_id = auth.uid() and r.return_state = 'not_started' and not r.dismissed
       and r.return_deadline is not null and i.lifecycle_state = 'owned'
       and r.return_deadline <= (select d from today) + p_horizon_days
       and r.return_deadline >= (select d from today) - 7
    union all
    select 'registration_deadline', case when g.deadline < (select d from today) then 0 else 2 end,
           i.id, i.name, g.id, g.deadline, g.deadline_certainty,
           case g.requirement_state when 'terms_stated_required' then 'Terms state registration is required'
                                    when 'extra_benefit' then 'Registration may add a benefit'
                                    when 'optional' then 'Registration is optional'
                                    else 'Whether registration is required is unknown' end
      from public.registrations g join public.items i on i.id = g.item_id
     where g.user_id = auth.uid() and g.status in ('not_started', 'link_opened') and g.deadline is not null
       and i.lifecycle_state = 'owned'
       and g.deadline <= (select d from today) + p_horizon_days
    union all
    select 'coverage_ending', case when w.end_date < (select d from today) then 0 else 3 end,
           i.id, i.name, w.id, w.end_date, w.date_certainty,
           coalesce(nullif(w.provider_name, ''), replace(w.coverage_type, '_', ' ')) ||
             case when w.date_certainty = 'estimated' then ' (estimated date)' else '' end
      from public.warranties w join public.items i on i.id = w.item_id
     where w.user_id = auth.uid() and w.contract_state = 'active' and w.end_date is not null
       and i.lifecycle_state = 'owned'
       and w.end_date between (select d from today) - 7 and (select d from today) + p_horizon_days
    union all
    select 'claim_follow_up', case when c.follow_up_on < (select d from today) then 0 else 4 end,
           c.item_id, c.item_label, c.id, c.follow_up_on, 'user_confirmed', coalesce(c.provider_name, 'Claim')
      from public.claims c
     where c.user_id = auth.uid() and c.status in ('submitted_by_user', 'in_review', 'info_requested')
       and c.follow_up_on is not null and c.follow_up_on <= (select d from today) + p_horizon_days
    union all
    select 'maintenance_due', case when t.next_due_on < (select d from today) then 0 else 5 end,
           t.item_id, t.title, t.id, t.next_due_on, 'user_confirmed',
           case t.requirement_basis when 'warranty_terms_stated' then 'Warranty terms mention this task'
                                    when 'manufacturer_recommended' then 'Manufacturer recommendation'
                                    else 'Your schedule' end
      from public.maintenance_tasks t
     where t.owner_id = auth.uid() and t.state = 'active' and t.next_due_on is not null
       and t.next_due_on <= (select d from today) + least(p_horizon_days, 30)
    union all
    -- Missing information (quiet, lowest priority).
    select 'missing_end_date_confirmation', 6, i.id, i.name, w.id, null::date, w.date_certainty,
           'Confirm the estimated coverage date to receive alerts'
      from public.warranties w join public.items i on i.id = w.item_id
     where w.user_id = auth.uid() and w.contract_state = 'active' and w.date_certainty = 'estimated'
       and w.estimate_accepted_at is null and i.lifecycle_state = 'owned'
       and (w.end_date is null or w.end_date >= (select d from today))
    union all
    select 'missing_receipt', 7, i.id, i.name, i.id, null::date, null::text, 'No proof of purchase attached'
      from public.items i
     where i.user_id = auth.uid() and i.lifecycle_state = 'owned' and not i.archived
       and not exists (select 1 from public.item_attachments ia where ia.item_id = i.id and ia.role = 'receipt')
       and i.created_at > now() - interval '120 days'
  )
  select a.kind, a.priority, a.item_id, a.item_name, a.source_id, a.due_date,
         case when a.due_date is not null then a.due_date - (select d from today) end as days_left,
         case a.kind
           when 'return_deadline' then 'Return window ' || case when a.due_date < (select d from today) then 'passed' else 'ends ' || app_private.relative_phrase(a.due_date - (select d from today)) end
           when 'registration_deadline' then 'Registration due ' || app_private.relative_phrase(a.due_date - (select d from today))
           when 'coverage_ending' then case when a.due_date < (select d from today) then 'Coverage term ended' else 'Coverage ends ' || app_private.relative_phrase(a.due_date - (select d from today)) end
           when 'claim_follow_up' then 'Follow up on claim'
           when 'maintenance_due' then 'Maintenance due ' || app_private.relative_phrase(a.due_date - (select d from today))
           when 'missing_end_date_confirmation' then 'Confirm coverage date'
           when 'missing_receipt' then 'Add a receipt'
         end as title,
         a.certainty, a.detail
    from actions a
   order by a.priority, a.due_date nulls last, a.item_name;
$$;
grant execute on function public.get_action_center(integer) to authenticated;
grant execute on function app_private.relative_phrase(integer), app_private.format_day(date) to authenticated, service_role;

create or replace function public.get_item_timeline(p_item_id uuid)
returns table (event_date date, event_kind text, label text, source_id uuid, certainty text)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select * from (
    select i.purchase_date, 'purchased', 'Purchased' || coalesce(' at ' || i.retailer_name, ''), i.id, null::text
      from public.items i where i.id = p_item_id and i.purchase_date is not null
    union all
    select i.delivery_date, 'delivered', 'Delivered', i.id, null from public.items i where i.id = p_item_id and i.delivery_date is not null
    union all
    select a.created_at::date, 'document_added', initcap(replace(a.file_type, '_', ' ')) || ' added', a.id, null
      from public.item_attachments ia join public.attachments a on a.id = ia.attachment_id
     where ia.item_id = p_item_id and a.deletion_state = 'active'
    union all
    select g.completed_at::date, 'registered',
           case g.status when 'confirmed_with_evidence' then 'Registration confirmed' else 'Registration reported complete' end, g.id, null
      from public.registrations g where g.item_id = p_item_id and g.completed_at is not null
    union all
    select g.deadline, 'registration_deadline', 'Registration deadline', g.id, g.deadline_certainty
      from public.registrations g where g.item_id = p_item_id and g.deadline is not null
    union all
    select r.return_deadline, 'return_deadline', 'Return deadline', r.id, r.date_certainty
      from public.return_windows r where r.item_id = p_item_id and r.return_deadline is not null
    union all
    select r.refunded_at::date, 'refunded', 'Return refunded', r.id, null from public.return_windows r where r.item_id = p_item_id and r.refunded_at is not null
    union all
    select w.start_date, 'coverage_start', coalesce(w.provider_name, initcap(replace(w.coverage_type, '_', ' '))) || ' coverage starts', w.id, w.date_certainty
      from public.warranties w where w.item_id = p_item_id and w.start_date is not null
    union all
    select w.end_date, 'coverage_end', coalesce(w.provider_name, initcap(replace(w.coverage_type, '_', ' '))) || ' coverage ends', w.id, w.date_certainty
      from public.warranties w where w.item_id = p_item_id and w.end_date is not null
    union all
    select c.created_at::date, 'claim_created', 'Claim started', c.id, null from public.claims c where c.item_id = p_item_id
    union all
    select h.created_at::date, 'claim_status', 'Claim ' || replace(h.to_status, '_', ' '), h.claim_id, null
      from public.claim_status_history h join public.claims c on c.id = h.claim_id
     where c.item_id = p_item_id and h.from_status is not null
    union all
    select s.service_date, 'service', initcap(replace(s.service_type, '_', ' ')) || coalesce(' — ' || s.provider_name, ''), s.id, null
      from public.service_records s where s.item_id = p_item_id
  ) t (event_date, event_kind, label, source_id, certainty)
  where app_private.can_read_item(p_item_id)
  order by event_date, event_kind;
$$;
grant execute on function public.get_item_timeline(uuid) to authenticated;

-- What would deleting this document affect? (Explicit deletion explains all links.)
create or replace function public.get_attachment_impact(p_attachment_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'attachment_id', p_attachment_id,
    'items', (select coalesce(jsonb_agg(jsonb_build_object('item_id', i.id, 'name', i.name, 'role', ia.role)), '[]'::jsonb)
                from public.item_attachments ia join public.items i on i.id = ia.item_id
               where ia.attachment_id = p_attachment_id and ia.user_id = auth.uid()),
    'purchases', (select coalesce(jsonb_agg(jsonb_build_object('purchase_group_id', pa.purchase_group_id, 'retailer', g.retailer)), '[]'::jsonb)
                    from public.purchase_attachments pa join public.purchase_groups g on g.id = pa.purchase_group_id
                   where pa.attachment_id = p_attachment_id and pa.user_id = auth.uid()),
    'claims', (select coalesce(jsonb_agg(jsonb_build_object('claim_id', c.id, 'item_label', c.item_label, 'status', c.status)), '[]'::jsonb)
                 from public.claim_attachments ca join public.claims c on c.id = ca.claim_id
                where ca.attachment_id = p_attachment_id and ca.user_id = auth.uid()),
    'warranty_sources', (select count(*) from public.warranties w where w.source_attachment_id = p_attachment_id and w.user_id = auth.uid()),
    'registration_confirmations', (select count(*) from public.registrations g where g.confirmation_attachment_id = p_attachment_id and g.user_id = auth.uid()),
    'service_records', (select count(*) from public.service_record_attachments s where s.attachment_id = p_attachment_id and s.user_id = auth.uid())
  )
  where exists (select 1 from public.attachments a where a.id = p_attachment_id and a.user_id = auth.uid());
$$;
grant execute on function public.get_attachment_impact(uuid) to authenticated;

-- Suggestions only: labelled, sourced, and never applied without user acceptance.
create or replace function public.suggest_coverage(p_item_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public, pg_temp
as $$
declare
  v_item public.items;
  v_country text;
begin
  select * into v_item from public.items where id = p_item_id and user_id = auth.uid();
  if v_item.id is null then raise exception 'item_not_found' using errcode = 'P0002'; end if;
  select country_code into v_country from public.profiles where id = auth.uid();

  return jsonb_build_object(
    'disclaimer', 'Suggested terms based on available reference information. Confirm your actual warranty and return terms.',
    'warranties', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'source_reference_id', wr.id, 'coverage_type', 'manufacturer', 'provider_name', b.name,
               'term_kind', wr.term_kind, 'duration_months', wr.standard_duration_months,
               'conditions_summary', wr.conditions_summary, 'source_url', wr.source_url,
               'last_verified_at', wr.last_verified_at, 'date_certainty', 'estimated',
               'source_kind', 'reference_suggestion')), '[]'::jsonb)
        from public.warranty_reference wr join public.brands b on b.id = wr.brand_id
       where wr.review_status = 'published' and wr.country_code = v_country
         and (wr.effective_to is null or wr.effective_to >= coalesce(v_item.purchase_date, current_date))
         and (b.id = v_item.brand_id or b.normalized_name = lower(btrim(coalesce(v_item.brand, '')))) ),
    'card_benefits', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'source_reference_id', cb.id, 'coverage_type', 'credit_card', 'provider_name', cb.issuer || ' ' || cb.card_name,
               'extension_months', cb.extension_months, 'max_original_warranty_months', cb.max_original_warranty_months,
               'maximum_coverage_amount', cb.maximum_coverage_amount, 'exclusions', cb.exclusions,
               'enrollment_required', cb.enrollment_required, 'source_url', cb.source_url, 'last_verified_at', cb.last_verified_at,
               'note', 'This card may include additional warranty protection. Review the card''s official terms before relying on this coverage.')), '[]'::jsonb)
        from public.payment_cards pc join public.card_benefits cb on cb.id = pc.card_benefit_id
       where pc.id = v_item.payment_card_id and pc.user_id = auth.uid() and cb.review_status = 'published'
         and (cb.effective_from is null or cb.effective_from <= coalesce(v_item.purchase_date, current_date))
         and (cb.effective_to is null or cb.effective_to >= coalesce(v_item.purchase_date, current_date)) ),
    'return_policies', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'source_reference_id', rp.id, 'retailer_name', rp.retailer_name, 'window_days', rp.window_days,
               'policy_anchor', rp.policy_anchor, 'deadline_basis', rp.deadline_basis,
               'conditions_summary', rp.conditions_summary, 'source_url', rp.source_url, 'last_verified_at', rp.last_verified_at,
               'terms_state', 'suggested', 'source_kind', 'reference_suggestion')), '[]'::jsonb)
        from public.return_policy_reference rp
       where rp.review_status = 'published' and rp.country_code = v_country
         and rp.normalized_retailer = lower(btrim(coalesce(v_item.retailer_name, '')))
         and (rp.effective_to is null or rp.effective_to >= coalesce(v_item.purchase_date, current_date)) )
  );
end;
$$;
grant execute on function public.suggest_coverage(uuid) to authenticated;

-- Facts for the user to review before a claim snapshot is saved.
create or replace function public.build_claim_facts(p_item_id uuid, p_warranty_id uuid default null)
returns jsonb
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'product', jsonb_build_object('name', i.name, 'brand', i.brand, 'model_number', i.model_number,
                                  'serial_number', i.serial_number, 'sku', i.sku, 'condition_at_purchase', i.condition_at_purchase),
    'purchase', jsonb_build_object('retailer', i.retailer_name, 'order_number', i.order_number, 'purchase_date', i.purchase_date,
                                   'delivery_date', i.delivery_date, 'price', i.purchase_price, 'price_is_estimated', i.price_is_estimated,
                                   'currency', i.currency),
    'coverage', (select jsonb_build_object('coverage_type', w.coverage_type, 'provider_name', w.provider_name, 'term_kind', w.term_kind,
                                          'start_date', w.start_date, 'end_date', w.end_date, 'date_certainty', w.date_certainty,
                                          'policy_number', w.policy_number, 'terms_url', w.terms_url,
                                          'conditional_terms', w.conditional_terms)
                   from public.warranties w where w.id = p_warranty_id and w.item_id = i.id),
    'documents', (select coalesce(jsonb_agg(jsonb_build_object('attachment_id', a.id, 'file_type', a.file_type,
                                                              'filename', a.original_filename, 'role', ia.role)), '[]'::jsonb)
                    from public.item_attachments ia join public.attachments a on a.id = ia.attachment_id
                   where ia.item_id = i.id and a.processing_state = 'ready' and a.deletion_state = 'active')
  )
  from public.items i where i.id = p_item_id and i.user_id = auth.uid();
$$;
grant execute on function public.build_claim_facts(uuid, uuid) to authenticated;

create or replace function public.complete_maintenance_task(p_task_id uuid, p_service_date date, p_notes text default null,
                                                            p_provider text default null, p_cost numeric default null,
                                                            p_currency text default null)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_task public.maintenance_tasks;
  v_record_id uuid;
  v_next date;
begin
  select * into v_task from public.maintenance_tasks where id = p_task_id for update;
  if v_task.id is null then raise exception 'task_not_found' using errcode = 'P0002'; end if;

  if v_task.item_id is not null then
    insert into public.service_records (item_id, workspace_id, created_by, service_date, service_type, provider_name,
                                        description, cost_amount, cost_currency, maintenance_task_id)
    values (v_task.item_id, v_task.workspace_id, auth.uid(), p_service_date, 'maintenance', p_provider,
            coalesce(p_notes, v_task.title), p_cost, p_currency, v_task.id)
    returning id into v_record_id;
  end if;

  v_next := case v_task.recurrence_unit
              when 'day' then p_service_date + v_task.recurrence_interval
              when 'week' then p_service_date + v_task.recurrence_interval * 7
              when 'month' then app_private.add_months(p_service_date, v_task.recurrence_interval)
              when 'year' then app_private.add_months(p_service_date, v_task.recurrence_interval * 12)
              else null end;

  update public.maintenance_tasks
     set last_completed_on = p_service_date, next_due_on = v_next,
         state = case when v_next is null then 'archived' else state end
   where id = v_task.id;

  return jsonb_build_object('service_record_id', v_record_id, 'next_due_on', v_next);
end;
$$;
grant execute on function public.complete_maintenance_task(uuid, date, text, text, numeric, text) to authenticated;

-- Explicit identity linking intent (see guard_identity_linking).
create or replace function public.request_identity_link(p_provider text)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_exp timestamptz;
begin
  if p_provider not in ('google', 'apple', 'email') then
    raise exception 'unsupported_provider' using errcode = '22023';
  end if;
  insert into public.identity_link_intents (user_id, provider) values (v_uid, p_provider) returning expires_at into v_exp;
  return v_exp;
end;
$$;
grant execute on function public.request_identity_link(text) to authenticated;

-- Workspace invitation acceptance: the caller's verified email must match.
create or replace function public.accept_workspace_invitation(p_token_hash text)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_inv public.workspace_invitations;
  v_email text;
begin
  select * into v_inv from public.workspace_invitations where token_hash = p_token_hash for update;
  if v_inv.id is null or v_inv.revoked_at is not null or v_inv.accepted_at is not null or v_inv.expires_at < now() then
    raise exception 'invitation_invalid' using errcode = 'P0002';
  end if;
  select lower(email) into v_email from auth.users where id = v_uid and email_confirmed_at is not null;
  if v_email is null or v_email <> v_inv.email_normalized then
    raise exception 'invitation_email_mismatch' using errcode = '42501';
  end if;

  insert into public.workspace_members (workspace_id, user_id, role, state, invited_by)
  values (v_inv.workspace_id, v_uid, v_inv.role, 'active', v_inv.invited_by)
  on conflict (workspace_id, user_id) do update set role = excluded.role, state = 'active', revoked_at = null, joined_at = now();

  update public.workspace_invitations set accepted_at = now(), accepted_by = v_uid where id = v_inv.id;
  return v_inv.workspace_id;
end;
$$;
grant execute on function public.accept_workspace_invitation(text) to authenticated;

-- -----------------------------------------------------------------------------
-- Product/business metrics with explicit denominators (service_role / admin API)
-- -----------------------------------------------------------------------------
create or replace function public.admin_product_metrics(p_from date, p_to date)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with signups as (
    select p.id, p.created_at from public.profiles p where p.created_at >= p_from and p.created_at < p_to + 1
  ), activated as (
    select s.id from signups s
     where exists (select 1 from public.items i
                    join public.item_attachments ia on ia.item_id = i.id
                   where i.user_id = s.id and i.created_at < s.created_at + interval '7 days')
  ), new_paying as (
    select ca.user_id from public.customer_acquisitions ca where ca.first_paid_at >= p_from and ca.first_paid_at < p_to + 1
  ), ai as (
    select cost_usd from public.usage_events where created_at >= p_from and created_at < p_to + 1 and outcome = 'success'
  ), scans as (
    select * from public.scan_jobs where created_at >= p_from and created_at < p_to + 1 and feature = 'receipt_extraction'
  ), claims_period as (
    select * from public.claims where created_at >= p_from and created_at < p_to + 1
  )
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'activation', jsonb_build_object(
      'definition', 'Signed up in period and saved an item with an attached document within 7 days',
      'numerator', (select count(*) from activated), 'denominator', (select count(*) from signups)),
    'conversion', jsonb_build_object(
      'definition', 'First-time paying customers in period / signups in period (cross-cohort approximation)',
      'numerator', (select count(*) from new_paying), 'denominator', (select count(*) from signups)),
    'renewal', jsonb_build_object(
      'definition', 'Renewal transactions in period / (renewals + expirations without renewal) in period',
      'numerator', (select count(*) from public.revenue_transactions where kind = 'renewal' and environment = 'PRODUCTION'
                      and occurred_at >= p_from and occurred_at < p_to + 1),
      'denominator', (select count(*) from public.revenue_transactions where kind = 'renewal' and environment = 'PRODUCTION'
                        and occurred_at >= p_from and occurred_at < p_to + 1)
                   + (select count(*) from public.billing_events where event_type = 'EXPIRATION' and environment = 'PRODUCTION'
                        and event_timestamp >= p_from and event_timestamp < p_to + 1)),
    'ai_cost', jsonb_build_object(
      'actions', (select count(*) from ai),
      'total_usd', (select coalesce(sum(cost_usd), 0) from ai),
      'p50_usd', (select percentile_cont(0.5) within group (order by cost_usd) from ai),
      'p95_usd', (select percentile_cont(0.95) within group (order by cost_usd) from ai)),
    'extraction', jsonb_build_object(
      'definition', 'Correction rate = confirmed scans with >=1 user correction / confirmed scans',
      'jobs', (select count(*) from scans),
      'failed', (select count(*) from scans where state = 'failed'),
      'confirmed', (select count(*) from scans where state = 'confirmed'),
      'confirmed_with_corrections', (select count(*) from scans where state = 'confirmed' and coalesce(correction_count, 0) > 0)),
    'outcomes', jsonb_build_object(
      'definition', 'User-confirmed outcomes recorded in period; denominator = claims created in period',
      'by_type', (select coalesce(jsonb_object_agg(outcome_type, n), '{}'::jsonb)
                    from (select outcome_type, count(*) n from public.outcomes
                           where created_at >= p_from and created_at < p_to + 1 group by outcome_type) x),
      'recovered_amount_usd_reported', (select coalesce(sum(amount), 0) from public.outcomes
                                          where created_at >= p_from and created_at < p_to + 1
                                            and outcome_type = 'refund_received' and currency = 'USD'),
      'claims_created', (select count(*) from claims_period),
      'note', 'Recovered amounts are user-reported refunds, not "money saved"; purchase values are never counted.')
  );
$$;
revoke all on function public.admin_product_metrics(date, date) from public, anon, authenticated;
grant execute on function public.admin_product_metrics(date, date) to service_role;
