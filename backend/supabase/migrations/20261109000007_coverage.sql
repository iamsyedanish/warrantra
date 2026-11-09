-- =============================================================================
-- 0007 Coverage evidence: warranties, return windows, registrations
--   * No mandatory warranty end date — unknown stays unknown.
--   * term_kind and date_certainty are explicit; estimates need user acceptance
--     before they can drive reminders.
--   * Contractual state is separate from derived time status and claim status.
--   * Return deadlines record their anchor and what the deadline means.
--   * No default 30-day return entitlement and no universal statutory rules.
-- =============================================================================

create table public.warranties (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null,
  item_id               uuid not null,
  coverage_type         text not null
                          check (coverage_type in ('manufacturer', 'retailer', 'extended', 'protection_plan',
                                                   'credit_card', 'statutory_note', 'other')),
  provider_name         text check (char_length(provider_name) <= 200),
  term_kind             text not null default 'unknown'
                          check (term_kind in ('fixed_date', 'duration', 'lifetime', 'conditional', 'unknown')),
  date_certainty        text not null default 'unknown'
                          check (date_certainty in ('document_verified', 'user_confirmed', 'estimated', 'unknown')),
  start_anchor          text not null default 'purchase_date'
                          check (start_anchor in ('purchase_date', 'delivery_date', 'custom', 'unknown')),
  start_date            date,
  end_date              date,
  duration_months       integer check (duration_months > 0 and duration_months <= 1200),
  conditional_terms     text check (char_length(conditional_terms) <= 2000),
  -- An estimate becomes alert-eligible only after explicit user acceptance.
  estimate_accepted_at  timestamptz,
  source_kind           text not null default 'user_entry'
                          check (source_kind in ('receipt', 'warranty_document', 'provider_website', 'user_entry',
                                                 'reference_suggestion', 'ai_extraction', 'card_benefit_reference')),
  source_url            text check (char_length(source_url) <= 2048),
  source_attachment_id  uuid,
  source_reference_id   uuid,              -- warranty_reference or card_benefits row used for a suggestion
  source_checked_at     timestamptz,
  confirmed_at          timestamptz,
  contract_state        text not null default 'active'
                          check (contract_state in ('active', 'cancelled', 'voided', 'transferred', 'superseded')),
  policy_number         text check (char_length(policy_number) <= 120),
  terms_url             text check (char_length(terms_url) <= 2048),
  payment_card_id       uuid,
  notes                 text check (char_length(notes) <= 4000),
  version               integer not null default 1,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (id, user_id),
  unique (id, item_id, user_id),
  foreign key (item_id, user_id) references public.items (id, user_id) on delete cascade,
  foreign key (source_attachment_id, user_id) references public.attachments (id, user_id) on delete set null (source_attachment_id),
  foreign key (payment_card_id, user_id) references public.payment_cards (id, user_id) on delete set null (payment_card_id),
  check (end_date is null or start_date is null or end_date >= start_date),
  check (term_kind <> 'fixed_date' or end_date is not null),
  check (term_kind <> 'duration' or duration_months is not null),
  -- "Lifetime" is not a distant fabricated year; unknown has no end date.
  check (term_kind not in ('lifetime', 'unknown') or end_date is null),
  check (term_kind <> 'conditional' or conditional_terms is not null),
  check (end_date is null or date_certainty <> 'unknown'),
  check (date_certainty not in ('document_verified', 'user_confirmed') or confirmed_at is not null),
  check (start_anchor <> 'custom' or start_date is not null)
);
create index warranties_item_idx on public.warranties (item_id);
create index warranties_user_end_idx on public.warranties (user_id, end_date) where contract_state = 'active';
create index warranties_attachment_idx on public.warranties (source_attachment_id) where source_attachment_id is not null;

-- Derive anchored start dates and duration-based end dates. A derived end date
-- is at most `estimated` until the user confirms it.
create or replace function app_private.derive_warranty_dates()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_item public.items;
begin
  select * into v_item from public.items where id = new.item_id and user_id = new.user_id;

  if new.start_anchor = 'purchase_date' then
    new.start_date := v_item.purchase_date;
  elsif new.start_anchor = 'delivery_date' then
    new.start_date := v_item.delivery_date;
  elsif new.start_anchor = 'unknown' then
    new.start_date := null;
  end if;

  if new.term_kind = 'duration' then
    if new.start_date is null then
      new.end_date := null;
      if new.date_certainty <> 'unknown' and new.confirmed_at is null then
        new.date_certainty := 'unknown';
      end if;
    else
      -- Coverage through the day before the anniversary (conservative for alerts).
      new.end_date := app_private.add_months(new.start_date, new.duration_months) - 1;
      if new.date_certainty = 'unknown' then
        new.date_certainty := 'estimated';
      end if;
    end if;
  end if;

  -- Editing the date invalidates a previous acceptance of an estimate.
  if tg_op = 'UPDATE' and new.end_date is distinct from old.end_date
     and new.estimate_accepted_at is not distinct from old.estimate_accepted_at then
    new.estimate_accepted_at := null;
  end if;
  if new.date_certainty <> 'estimated' then
    new.estimate_accepted_at := null;
  end if;
  return new;
end;
$$;
create trigger warranties_derive_dates before insert or update on public.warranties
  for each row execute function app_private.derive_warranty_dates();
create trigger warranties_updated_at before update on public.warranties
  for each row execute function app_private.set_updated_at();
create trigger warranties_version before update on public.warranties
  for each row execute function app_private.bump_version();

-- -----------------------------------------------------------------------------
-- Return windows (item-level; supports partial returns)
-- -----------------------------------------------------------------------------
create table public.return_windows (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null,
  item_id                uuid not null,
  retailer_name          text check (char_length(retailer_name) <= 200),
  terms_state            text not null default 'unknown' check (terms_state in ('known', 'suggested', 'unknown')),
  policy_anchor          text not null default 'unknown'
                           check (policy_anchor in ('purchase_date', 'delivery_date', 'custom', 'unknown')),
  anchor_date            date,
  window_days            integer check (window_days >= 0 and window_days <= 730),
  return_deadline        date,
  deadline_basis         text not null default 'unknown'
                           check (deadline_basis in ('request_by', 'postmark_by', 'merchant_receipt_by', 'unknown')),
  date_certainty         text not null default 'unknown'
                           check (date_certainty in ('document_verified', 'user_confirmed', 'estimated', 'unknown')),
  estimate_accepted_at   timestamptz,
  source_kind            text not null default 'user_entry'
                           check (source_kind in ('receipt', 'retailer_website', 'user_entry', 'reference_suggestion', 'ai_extraction')),
  source_url             text check (char_length(source_url) <= 2048),
  source_reference_id    uuid references public.return_policy_reference (id) on delete set null,
  source_attachment_id   uuid,
  source_checked_at      timestamptz,
  confirmed_at           timestamptz,
  conditions             text check (char_length(conditions) <= 2000),
  restocking_fee_percent numeric(5, 2) check (restocking_fee_percent between 0 and 100),
  -- Return progress tracked separately.
  return_state           text not null default 'not_started'
                           check (return_state in ('not_started', 'initiated', 'shipped', 'received_by_merchant',
                                                   'refunded', 'rejected', 'cancelled')),
  return_quantity        integer check (return_quantity > 0),
  rma_number             text check (char_length(rma_number) <= 120),
  tracking_reference     text check (char_length(tracking_reference) <= 200),
  initiated_at           timestamptz,
  shipped_at             timestamptz,
  merchant_received_at   timestamptz,
  refunded_at            timestamptz,
  refund_amount          public.money_amount,
  refund_currency        public.currency_code,
  dismissed              boolean not null default false,
  notes                  text check (char_length(notes) <= 4000),
  version                integer not null default 1,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (id, user_id),
  unique (id, item_id, user_id),
  foreign key (item_id, user_id) references public.items (id, user_id) on delete cascade,
  foreign key (source_attachment_id, user_id) references public.attachments (id, user_id) on delete set null (source_attachment_id),
  check (return_deadline is null or anchor_date is null or return_deadline >= anchor_date),
  check (return_deadline is null or date_certainty <> 'unknown'),
  check (date_certainty not in ('document_verified', 'user_confirmed') or confirmed_at is not null),
  check (policy_anchor <> 'custom' or anchor_date is not null),
  check (refund_amount is null or refund_currency is not null),
  check (return_state <> 'refunded' or refunded_at is not null)
);
create index return_windows_item_idx on public.return_windows (item_id);
create index return_windows_user_deadline_idx on public.return_windows (user_id, return_deadline)
  where return_state = 'not_started' and dismissed = false;

create or replace function app_private.derive_return_deadline()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_item public.items;
begin
  select * into v_item from public.items where id = new.item_id and user_id = new.user_id;

  if new.policy_anchor = 'purchase_date' then
    new.anchor_date := v_item.purchase_date;
  elsif new.policy_anchor = 'delivery_date' then
    -- Correct date anchor: an undelivered order has no computable deadline yet.
    new.anchor_date := v_item.delivery_date;
  elsif new.policy_anchor = 'unknown' then
    new.anchor_date := null;
  end if;

  if new.window_days is not null and new.policy_anchor in ('purchase_date', 'delivery_date', 'custom') then
    if new.anchor_date is null then
      new.return_deadline := null;
      if new.confirmed_at is null then new.date_certainty := 'unknown'; end if;
    else
      new.return_deadline := new.anchor_date + new.window_days;
      if new.date_certainty = 'unknown' then new.date_certainty := 'estimated'; end if;
    end if;
  end if;

  if new.terms_state = 'unknown' and new.window_days is null and new.return_deadline is null then
    new.date_certainty := 'unknown';
  end if;

  if tg_op = 'UPDATE' and new.return_deadline is distinct from old.return_deadline
     and new.estimate_accepted_at is not distinct from old.estimate_accepted_at then
    new.estimate_accepted_at := null;
  end if;
  if new.date_certainty <> 'estimated' then
    new.estimate_accepted_at := null;
  end if;

  -- Progress timestamps.
  if tg_op = 'INSERT' or new.return_state is distinct from old.return_state then
    case new.return_state
      when 'initiated' then new.initiated_at := coalesce(new.initiated_at, now());
      when 'shipped' then new.shipped_at := coalesce(new.shipped_at, now());
      when 'received_by_merchant' then new.merchant_received_at := coalesce(new.merchant_received_at, now());
      when 'refunded' then new.refunded_at := coalesce(new.refunded_at, now());
      else null;
    end case;
  end if;

  if new.return_quantity is not null and new.return_quantity > v_item.quantity then
    raise exception 'return_quantity_exceeds_item_quantity' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger return_windows_derive before insert or update on public.return_windows
  for each row execute function app_private.derive_return_deadline();
create trigger return_windows_updated_at before update on public.return_windows
  for each row execute function app_private.set_updated_at();
create trigger return_windows_version before update on public.return_windows
  for each row execute function app_private.bump_version();

-- A completed return marks ONLY its own item as returned (partial-return safety:
-- other items on the same receipt are untouched). Returning fewer than the item's
-- quantity leaves the item owned.
create or replace function app_private.apply_return_completion()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_qty integer;
begin
  if new.return_state = 'refunded' and (tg_op = 'INSERT' or old.return_state is distinct from 'refunded') then
    select quantity into v_qty from public.items where id = new.item_id and user_id = new.user_id;
    if new.return_quantity is null or new.return_quantity >= v_qty then
      update public.items set lifecycle_state = 'returned'
       where id = new.item_id and user_id = new.user_id and lifecycle_state = 'owned';
    end if;
  end if;
  return new;
end;
$$;
create trigger return_windows_apply_completion after insert or update of return_state on public.return_windows
  for each row execute function app_private.apply_return_completion();

-- -----------------------------------------------------------------------------
-- Registrations — explicit requirement state; opening a link is not completion.
-- -----------------------------------------------------------------------------
create table public.registrations (
  id                          uuid primary key default gen_random_uuid(),
  user_id                     uuid not null,
  item_id                     uuid not null,
  requirement_state           text not null default 'unknown'
                                check (requirement_state in ('unknown', 'optional', 'extra_benefit', 'terms_stated_required')),
  benefit_description         text check (char_length(benefit_description) <= 1000),
  provider_name               text check (char_length(provider_name) <= 200),
  registration_url            text check (char_length(registration_url) <= 2048),
  deadline                    date,
  deadline_certainty          text not null default 'unknown'
                                check (deadline_certainty in ('document_verified', 'user_confirmed', 'estimated', 'unknown')),
  status                      text not null default 'not_started'
                                check (status in ('not_started', 'link_opened', 'user_reported_complete',
                                                  'confirmed_with_evidence', 'not_applicable', 'dismissed')),
  link_opened_at              timestamptz,
  completed_at                timestamptz,
  confirmation_attachment_id  uuid,
  confirmation_reference      text check (char_length(confirmation_reference) <= 200),
  source_kind                 text not null default 'user_entry'
                                check (source_kind in ('warranty_document', 'provider_website', 'user_entry', 'reference_suggestion', 'ai_extraction')),
  source_url                  text check (char_length(source_url) <= 2048),
  source_checked_at           timestamptz,
  notes                       text check (char_length(notes) <= 4000),
  version                     integer not null default 1,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  unique (id, user_id),
  unique (id, item_id, user_id),
  foreign key (item_id, user_id) references public.items (id, user_id) on delete cascade,
  foreign key (confirmation_attachment_id, user_id) references public.attachments (id, user_id)
    on delete set null (confirmation_attachment_id),
  check (status not in ('user_reported_complete', 'confirmed_with_evidence') or completed_at is not null),
  check (status <> 'confirmed_with_evidence' or confirmation_attachment_id is not null or confirmation_reference is not null),
  check (deadline is null or deadline_certainty <> 'unknown')
);
create index registrations_item_idx on public.registrations (item_id);
create index registrations_user_deadline_idx on public.registrations (user_id, deadline)
  where status in ('not_started', 'link_opened');

create or replace function app_private.registration_progress()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'link_opened' and new.link_opened_at is null then
    new.link_opened_at := now();
  end if;
  if new.status in ('user_reported_complete', 'confirmed_with_evidence') and new.completed_at is null then
    new.completed_at := now();
  end if;
  if new.status in ('not_started', 'link_opened') then
    new.completed_at := null;
  end if;
  return new;
end;
$$;
create trigger registrations_progress before insert or update on public.registrations
  for each row execute function app_private.registration_progress();
create trigger registrations_updated_at before update on public.registrations
  for each row execute function app_private.set_updated_at();
create trigger registrations_version before update on public.registrations
  for each row execute function app_private.bump_version();

-- Item date edits re-derive anchored coverage and return deadlines.
create or replace function app_private.rederive_item_dependents()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.purchase_date is distinct from old.purchase_date or new.delivery_date is distinct from old.delivery_date then
    -- No-op updates fire the BEFORE triggers that recompute anchored dates.
    update public.warranties set start_anchor = start_anchor
     where item_id = new.id and user_id = new.user_id and start_anchor in ('purchase_date', 'delivery_date');
    update public.return_windows set policy_anchor = policy_anchor
     where item_id = new.id and user_id = new.user_id and policy_anchor in ('purchase_date', 'delivery_date');
  end if;
  return new;
end;
$$;
create trigger items_rederive_dependents after update of purchase_date, delivery_date on public.items
  for each row execute function app_private.rederive_item_dependents();

-- -----------------------------------------------------------------------------
-- Derived time status (never stored; separate from contract and claim status)
-- -----------------------------------------------------------------------------
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
    when w.start_date is not null and w.start_date > current_date then 'not_started'
    when w.end_date < current_date then 'contract_term_ended'
    when w.end_date <= current_date + 30 then 'ending_soon'
    else 'in_term'
  end as time_status,
  case when w.end_date is not null then w.end_date - current_date end as days_remaining,
  -- Explicit labelling: an ended contractual term is not a finding about statutory rights.
  case
    when w.end_date is not null and w.end_date < current_date
      then 'The contractual term recorded here has ended. This does not determine any statutory rights you may have.'
    when w.date_certainty = 'estimated' then 'Estimated date — confirm your actual terms.'
    when w.date_certainty = 'unknown' then 'End date unknown.'
    else null
  end as disclosure
from public.warranties w;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.warranties enable row level security;
alter table public.return_windows enable row level security;
alter table public.registrations enable row level security;

revoke all on public.warranties, public.return_windows, public.registrations from anon, authenticated;
grant select, insert, update, delete on public.warranties, public.return_windows, public.registrations to authenticated;
grant all on public.warranties, public.return_windows, public.registrations to service_role;
revoke all on public.coverage_status from anon;
grant select on public.coverage_status to authenticated, service_role;

create policy warranties_select_own on public.warranties for select to authenticated using (user_id = auth.uid());
create policy warranties_insert_own on public.warranties for insert to authenticated with check (user_id = auth.uid());
create policy warranties_update_own on public.warranties for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy warranties_delete_own on public.warranties for delete to authenticated using (user_id = auth.uid());

create policy return_windows_select_own on public.return_windows for select to authenticated using (user_id = auth.uid());
create policy return_windows_insert_own on public.return_windows for insert to authenticated with check (user_id = auth.uid());
create policy return_windows_update_own on public.return_windows for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy return_windows_delete_own on public.return_windows for delete to authenticated using (user_id = auth.uid());

create policy registrations_select_own on public.registrations for select to authenticated using (user_id = auth.uid());
create policy registrations_insert_own on public.registrations for insert to authenticated with check (user_id = auth.uid());
create policy registrations_update_own on public.registrations for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy registrations_delete_own on public.registrations for delete to authenticated using (user_id = auth.uid());
