-- =============================================================================
-- 0009 Claim readiness, claim packs and the outcome ledger
--   * A claim stores a user-reviewed snapshot so it stays understandable even if
--     the item is later deleted (item_id becomes NULL, history remains useful).
--   * Warrantra never submits claims; the user submits through the provider.
--   * Outcomes are user-confirmed, one per case — no "money saved" inflation.
-- =============================================================================

create table public.claims (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references public.profiles (id) on delete cascade,
  item_id              uuid,
  warranty_id          uuid,
  return_window_id     uuid,
  claim_kind           text not null default 'warranty_repair'
                         check (claim_kind in ('warranty_repair', 'warranty_replacement', 'return_refund',
                                               'protection_plan', 'credit_card_benefit', 'other')),
  item_label           text not null check (char_length(btrim(item_label)) between 1 and 200),
  provider_name        text check (char_length(provider_name) <= 200),
  provider_contact     jsonb not null default '{}'::jsonb,   -- {email, phone, url, address}
  claim_number         text check (char_length(claim_number) <= 120),
  status               text not null default 'draft'
                         check (status in ('draft', 'ready_to_submit', 'submitted_by_user', 'in_review', 'info_requested',
                                           'approved', 'denied', 'resolved', 'withdrawn')),
  issue_description    text not null check (char_length(btrim(issue_description)) between 1 and 5000),
  issue_started_on     date,
  -- User-reviewed facts copied at review time (product, coverage, purchase).
  snapshot             jsonb not null default '{}'::jsonb,
  snapshot_reviewed_at timestamptz,
  submitted_at         timestamptz,                -- user-reported submission
  follow_up_on         date,
  resolved_at          timestamptz,
  resolution_notes     text check (char_length(resolution_notes) <= 4000),
  ai_draft_text        text check (char_length(ai_draft_text) <= 8000),
  ai_draft_job_id      uuid,
  ai_draft_reviewed_at timestamptz,
  version              integer not null default 1,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (id, user_id),
  foreign key (item_id, user_id) references public.items (id, user_id) on delete set null (item_id),
  foreign key (warranty_id, user_id) references public.warranties (id, user_id) on delete set null (warranty_id),
  foreign key (return_window_id, user_id) references public.return_windows (id, user_id) on delete set null (return_window_id),
  check (issue_started_on is null or issue_started_on <= current_date + 1),
  check (status not in ('ready_to_submit', 'submitted_by_user', 'in_review', 'info_requested', 'approved', 'denied', 'resolved')
         or snapshot_reviewed_at is not null)
);
create index claims_item_idx on public.claims (item_id) where item_id is not null;
create index claims_warranty_idx on public.claims (warranty_id) where warranty_id is not null;
create index claims_return_idx on public.claims (return_window_id) where return_window_id is not null;
create index claims_user_status_idx on public.claims (user_id, status);

-- Same-item consistency: the chosen warranty/return must belong to the claim's item.
create or replace function app_private.guard_claim_consistency()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.warranty_id is not null and new.item_id is not null
     and not exists (select 1 from public.warranties w where w.id = new.warranty_id and w.item_id = new.item_id and w.user_id = new.user_id) then
    raise exception 'warranty_not_on_claim_item' using errcode = '23514';
  end if;
  if new.return_window_id is not null and new.item_id is not null
     and not exists (select 1 from public.return_windows r where r.id = new.return_window_id and r.item_id = new.item_id and r.user_id = new.user_id) then
    raise exception 'return_window_not_on_claim_item' using errcode = '23514';
  end if;
  if (new.warranty_id is not null or new.return_window_id is not null) and new.item_id is null and tg_op = 'INSERT' then
    raise exception 'coverage_requires_item' using errcode = '23514';
  end if;
  if new.status = 'submitted_by_user' and new.submitted_at is null then
    new.submitted_at := now();
  end if;
  if new.status in ('approved', 'denied', 'resolved', 'withdrawn') and new.resolved_at is null then
    new.resolved_at := now();
  end if;
  return new;
end;
$$;
create trigger claims_guard before insert or update on public.claims
  for each row execute function app_private.guard_claim_consistency();
create trigger claims_updated_at before update on public.claims
  for each row execute function app_private.set_updated_at();
create trigger claims_version before update on public.claims
  for each row execute function app_private.bump_version();

create table public.claim_status_history (
  id          uuid primary key default gen_random_uuid(),
  claim_id    uuid not null,
  user_id     uuid not null,
  from_status text,
  to_status   text not null,
  note        text check (char_length(note) <= 1000),
  created_at  timestamptz not null default now(),
  foreign key (claim_id, user_id) references public.claims (id, user_id) on delete cascade
);
create index claim_status_history_claim_idx on public.claim_status_history (claim_id, created_at);

create or replace function app_private.record_claim_status()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.claim_status_history (claim_id, user_id, from_status, to_status)
    values (new.id, new.user_id, case when tg_op = 'UPDATE' then old.status end, new.status);
  end if;
  return new;
end;
$$;
create trigger claims_status_history after insert or update of status on public.claims
  for each row execute function app_private.record_claim_status();

create table public.claim_attachments (
  claim_id         uuid not null,
  attachment_id    uuid not null,
  user_id          uuid not null,
  include_in_pack  boolean not null default true,
  caption          text check (char_length(caption) <= 300),
  sort_order       integer not null default 0,
  created_at       timestamptz not null default now(),
  primary key (claim_id, attachment_id),
  foreign key (claim_id, user_id) references public.claims (id, user_id) on delete cascade,
  foreign key (attachment_id, user_id) references public.attachments (id, user_id) on delete cascade
);
create index claim_attachments_attachment_idx on public.claim_attachments (attachment_id);
create index claim_attachments_user_idx on public.claim_attachments (user_id);

create table public.claim_packs (
  id                uuid primary key default gen_random_uuid(),
  claim_id          uuid not null,
  user_id           uuid not null,
  format            text not null check (format in ('text', 'pdf')),
  pack_level        text not null check (pack_level in ('basic', 'assembled')),
  template_version  text not null,
  bucket            text not null default 'claim-packs',
  storage_path      text,
  content_sha256    text,
  byte_size         bigint,
  generated_at      timestamptz not null default now(),
  foreign key (claim_id, user_id) references public.claims (id, user_id) on delete cascade,
  unique (bucket, storage_path)
);
create index claim_packs_claim_idx on public.claim_packs (claim_id, generated_at desc);

create table public.outcomes (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references public.profiles (id) on delete cascade,
  claim_id                uuid,
  return_window_id        uuid,
  outcome_type            text not null
                            check (outcome_type in ('refund_received', 'repair_completed', 'replacement_received', 'denied', 'withdrawn')),
  amount                  public.money_amount,
  currency                public.currency_code,
  outcome_date            date not null default current_date,
  evidence_level          text not null default 'user_reported'
                            check (evidence_level in ('user_reported', 'document_attached', 'provider_confirmation')),
  evidence_attachment_id  uuid,
  warrantra_helped        text check (warrantra_helped in ('yes_significantly', 'yes_somewhat', 'no', 'unsure')),
  user_comment            text check (char_length(user_comment) <= 2000),
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  foreign key (claim_id, user_id) references public.claims (id, user_id) on delete cascade,
  foreign key (return_window_id, user_id) references public.return_windows (id, user_id) on delete set null (return_window_id),
  foreign key (evidence_attachment_id, user_id) references public.attachments (id, user_id) on delete set null (evidence_attachment_id),
  -- Exactly one case reference at creation (enforced by trigger); the return
  -- reference may later become NULL if its item is deleted, keeping history.
  check (num_nonnulls(claim_id, return_window_id) <= 1),
  check (amount is null or currency is not null),
  check (evidence_level <> 'document_attached' or evidence_attachment_id is not null)
);
-- One outcome per case: never count the same case twice.
create unique index outcomes_claim_uniq on public.outcomes (claim_id) where claim_id is not null;
create unique index outcomes_return_uniq on public.outcomes (return_window_id) where return_window_id is not null and claim_id is null;
create index outcomes_user_idx on public.outcomes (user_id, outcome_date desc);
create trigger outcomes_updated_at before update on public.outcomes
  for each row execute function app_private.set_updated_at();

create or replace function app_private.guard_outcome_reference()
returns trigger
language plpgsql
as $$
begin
  if num_nonnulls(new.claim_id, new.return_window_id) <> 1 then
    raise exception 'outcome_requires_exactly_one_case' using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger outcomes_guard_reference before insert on public.outcomes
  for each row execute function app_private.guard_outcome_reference();

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.claims enable row level security;
alter table public.claim_status_history enable row level security;
alter table public.claim_attachments enable row level security;
alter table public.claim_packs enable row level security;
alter table public.outcomes enable row level security;

revoke all on public.claims, public.claim_status_history, public.claim_attachments, public.claim_packs, public.outcomes
  from anon, authenticated;
grant select, delete on public.claims to authenticated;
grant insert (user_id, item_id, warranty_id, return_window_id, claim_kind, item_label, provider_name, provider_contact,
              claim_number, status, issue_description, issue_started_on, snapshot, snapshot_reviewed_at, follow_up_on)
  on public.claims to authenticated;
-- AI draft columns are server-written only (column-level UPDATE grant).
grant update (item_id, warranty_id, return_window_id, claim_kind, item_label, provider_name, provider_contact,
              claim_number, status, issue_description, issue_started_on, snapshot, snapshot_reviewed_at,
              submitted_at, follow_up_on, resolved_at, resolution_notes, ai_draft_reviewed_at)
  on public.claims to authenticated;
grant select, insert, update, delete on public.claim_attachments, public.outcomes to authenticated;
grant select on public.claim_status_history, public.claim_packs to authenticated;
grant all on public.claims, public.claim_status_history, public.claim_attachments, public.claim_packs, public.outcomes
  to service_role;

create policy claims_select_own on public.claims for select to authenticated using (user_id = auth.uid());
create policy claims_insert_own on public.claims for insert to authenticated with check (user_id = auth.uid());
create policy claims_update_own on public.claims for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy claims_delete_own on public.claims for delete to authenticated using (user_id = auth.uid());

create policy claim_status_history_select_own on public.claim_status_history for select to authenticated using (user_id = auth.uid());

create policy claim_attachments_select_own on public.claim_attachments for select to authenticated using (user_id = auth.uid());
create policy claim_attachments_insert_own on public.claim_attachments for insert to authenticated with check (user_id = auth.uid());
create policy claim_attachments_update_own on public.claim_attachments for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy claim_attachments_delete_own on public.claim_attachments for delete to authenticated using (user_id = auth.uid());

create policy claim_packs_select_own on public.claim_packs for select to authenticated using (user_id = auth.uid());

create policy outcomes_select_own on public.outcomes for select to authenticated using (user_id = auth.uid());
create policy outcomes_insert_own on public.outcomes for insert to authenticated with check (user_id = auth.uid());
create policy outcomes_update_own on public.outcomes for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy outcomes_delete_own on public.outcomes for delete to authenticated using (user_id = auth.uid());

-- Service records may cite the claim they relate to.
alter table public.service_records add constraint service_records_claim_fk
  foreign key (claim_id) references public.claims (id) on delete set null;
