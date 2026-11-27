-- Item timeline: same-day events now keep the order they happened in (a claim
-- started, sent and denied on one day no longer shows "denied" first), and
-- claim steps use plain words instead of raw status names.
create or replace function public.get_item_timeline(p_item_id uuid)
returns table (event_date date, event_kind text, label text, source_id uuid, certainty text)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select t.event_date, t.event_kind, t.label, t.source_id, t.certainty from (
    select i.purchase_date, 'purchased', 'Purchased' || coalesce(' at ' || i.retailer_name, ''), i.id, null::text, i.purchase_date::timestamptz
      from public.items i where i.id = p_item_id and i.purchase_date is not null
    union all
    select i.delivery_date, 'delivered', 'Delivered', i.id, null, i.delivery_date::timestamptz from public.items i where i.id = p_item_id and i.delivery_date is not null
    union all
    select a.created_at::date, 'document_added', initcap(replace(a.file_type, '_', ' ')) || ' added', a.id, null, a.created_at
      from public.item_attachments ia join public.attachments a on a.id = ia.attachment_id
     where ia.item_id = p_item_id and a.deletion_state = 'active'
    union all
    select g.completed_at::date, 'registered',
           case g.status when 'confirmed_with_evidence' then 'Registration confirmed' else 'Registration reported complete' end, g.id, null, g.completed_at
      from public.registrations g where g.item_id = p_item_id and g.completed_at is not null
    union all
    select g.deadline, 'registration_deadline', 'Registration deadline', g.id, g.deadline_certainty, g.deadline::timestamptz + interval '23 hours'
      from public.registrations g where g.item_id = p_item_id and g.deadline is not null
    union all
    select r.return_deadline, 'return_deadline', 'Return deadline', r.id, r.date_certainty, r.return_deadline::timestamptz + interval '23 hours'
      from public.return_windows r where r.item_id = p_item_id and r.return_deadline is not null
    union all
    select r.refunded_at::date, 'refunded', 'Return refunded', r.id, null, r.refunded_at from public.return_windows r where r.item_id = p_item_id and r.refunded_at is not null
    union all
    select w.start_date, 'coverage_start', coalesce(w.provider_name, initcap(replace(w.coverage_type, '_', ' '))) || ' coverage starts', w.id, w.date_certainty, w.start_date::timestamptz
      from public.warranties w where w.item_id = p_item_id and w.start_date is not null
    union all
    select w.end_date, 'coverage_end', coalesce(w.provider_name, initcap(replace(w.coverage_type, '_', ' '))) || ' coverage ends', w.id, w.date_certainty, w.end_date::timestamptz + interval '23 hours'
      from public.warranties w where w.item_id = p_item_id and w.end_date is not null
    union all
    select c.created_at::date, 'claim_created', 'Claim started', c.id, null, c.created_at from public.claims c where c.item_id = p_item_id
    union all
    select h.created_at::date, 'claim_status',
           case h.to_status
             when 'ready_to_submit' then 'Claim pack ready'
             when 'submitted_by_user' then 'Claim sent'
             when 'in_review' then 'Claim in review'
             when 'info_requested' then 'Provider asked for more info'
             else 'Claim ' || replace(h.to_status, '_', ' ')
           end, h.claim_id, null, h.created_at
      from public.claim_status_history h join public.claims c on c.id = h.claim_id
     where c.item_id = p_item_id and h.from_status is not null
    union all
    select s.service_date, 'service', initcap(replace(s.service_type, '_', ' ')) || coalesce(' — ' || s.provider_name, ''), s.id, null, s.service_date::timestamptz
      from public.service_records s where s.item_id = p_item_id
  ) t (event_date, event_kind, label, source_id, certainty, event_at)
  where app_private.can_read_item(p_item_id)
  order by t.event_date, t.event_at, t.event_kind;
$$;
grant execute on function public.get_item_timeline(uuid) to authenticated;
