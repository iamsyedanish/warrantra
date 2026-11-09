-- =============================================================================
-- 0012 Capture drafts (share-to-app, upload, email) and email forwarding
--   * Share-to-app: a user-shared receipt becomes a draft — no blanket access.
--   * Email forwarding: unique rotatable address, authenticated ingestion,
--     file screening, quotas and duplicate detection.
-- Nothing becomes a purchase until the user reviews and confirms the draft.
-- =============================================================================

create table public.capture_drafts (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references public.profiles (id) on delete cascade,
  source              text not null check (source in ('share_extension', 'email_forward', 'upload', 'manual')),
  state               text not null default 'pending'
                        check (state in ('pending', 'processing', 'ready_for_review', 'confirmed', 'discarded', 'failed')),
  title               text check (char_length(title) <= 200),
  scan_job_id         uuid,
  purchase_group_id   uuid,
  inbound_email_id    uuid,
  error_code          text,
  expires_at          timestamptz not null default now() + interval '30 days',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (id, user_id),
  foreign key (scan_job_id, user_id) references public.scan_jobs (id, user_id) on delete set null (scan_job_id),
  foreign key (purchase_group_id, user_id) references public.purchase_groups (id, user_id) on delete set null (purchase_group_id)
);
create index capture_drafts_user_idx on public.capture_drafts (user_id, created_at desc) where state not in ('confirmed', 'discarded');
create trigger capture_drafts_updated_at before update on public.capture_drafts
  for each row execute function app_private.set_updated_at();

create table public.capture_draft_attachments (
  draft_id       uuid not null,
  attachment_id  uuid not null,
  user_id        uuid not null,
  created_at     timestamptz not null default now(),
  primary key (draft_id, attachment_id),
  foreign key (draft_id, user_id) references public.capture_drafts (id, user_id) on delete cascade,
  foreign key (attachment_id, user_id) references public.attachments (id, user_id) on delete cascade
);
create index capture_draft_attachments_attachment_idx on public.capture_draft_attachments (attachment_id);

create table public.inbound_addresses (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  local_part   text not null unique check (local_part ~ '^[a-z0-9]{16,40}$'),
  state        text not null default 'active' check (state in ('active', 'rotated', 'disabled')),
  created_at   timestamptz not null default now(),
  rotated_at   timestamptz
);
create unique index inbound_addresses_one_active on public.inbound_addresses (user_id) where state = 'active';

create table public.inbound_emails (
  id                    uuid primary key default gen_random_uuid(),
  inbound_address_id    uuid references public.inbound_addresses (id) on delete set null,
  user_id               uuid references public.profiles (id) on delete cascade,
  provider              text not null default 'postmark',
  provider_message_id   text not null,
  message_id_hash       text,                     -- hash of RFC Message-ID header (dup detection)
  from_hash             text,                     -- hashed sender (no raw address retained)
  auth_verdict          text check (auth_verdict in ('pass', 'fail', 'none')),
  state                 text not null default 'received'
                          check (state in ('received', 'accepted', 'rejected_auth', 'rejected_quota', 'rejected_screening',
                                           'duplicate', 'no_attachments', 'unknown_address', 'processed', 'failed')),
  rejection_reason      text,
  attachment_count      integer not null default 0,
  accepted_attachments  integer not null default 0,
  total_bytes           bigint not null default 0,
  capture_draft_id      uuid references public.capture_drafts (id) on delete set null,
  received_at           timestamptz not null default now(),
  processed_at          timestamptz,
  unique (provider, provider_message_id)
);
create index inbound_emails_address_day_idx on public.inbound_emails (inbound_address_id, received_at);
create index inbound_emails_user_msgid_idx on public.inbound_emails (user_id, message_id_hash);

alter table public.capture_drafts add constraint capture_drafts_inbound_fk
  foreign key (inbound_email_id) references public.inbound_emails (id) on delete set null;

alter table public.capture_drafts enable row level security;
alter table public.capture_draft_attachments enable row level security;
alter table public.inbound_addresses enable row level security;
alter table public.inbound_emails enable row level security;
revoke all on public.capture_drafts, public.capture_draft_attachments, public.inbound_addresses, public.inbound_emails
  from anon, authenticated;
grant select on public.capture_drafts to authenticated;
grant insert (user_id, source, title, state) on public.capture_drafts to authenticated;
grant update (state, title) on public.capture_drafts to authenticated;
grant select, insert, delete on public.capture_draft_attachments to authenticated;
grant select on public.inbound_addresses, public.inbound_emails to authenticated;
grant all on public.capture_drafts, public.capture_draft_attachments, public.inbound_addresses, public.inbound_emails
  to service_role;

create policy capture_drafts_select_own on public.capture_drafts for select to authenticated using (user_id = auth.uid());
create policy capture_drafts_insert_own on public.capture_drafts for insert to authenticated
  with check (user_id = auth.uid() and source in ('share_extension', 'upload', 'manual'));
create policy capture_drafts_update_own on public.capture_drafts for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and state in ('discarded', 'pending', 'ready_for_review'));
create policy capture_draft_attachments_select_own on public.capture_draft_attachments for select to authenticated using (user_id = auth.uid());
create policy capture_draft_attachments_insert_own on public.capture_draft_attachments for insert to authenticated with check (user_id = auth.uid());
create policy capture_draft_attachments_delete_own on public.capture_draft_attachments for delete to authenticated using (user_id = auth.uid());
create policy inbound_addresses_select_own on public.inbound_addresses for select to authenticated using (user_id = auth.uid());
create policy inbound_emails_select_own on public.inbound_emails for select to authenticated using (user_id = auth.uid());

-- Rotate (or create) the caller's forwarding address. Old address stops accepting mail.
create or replace function public.rotate_inbound_address()
returns public.inbound_addresses
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_limits public.plan_limits := app_private.plan_limits_for(v_uid);
  v_row public.inbound_addresses;
begin
  if not v_limits.email_forwarding_enabled then
    raise exception 'plan_feature_unavailable:email_forwarding' using errcode = 'P0001';
  end if;
  perform app_private.lock_user(v_uid, 'inbound');
  update public.inbound_addresses set state = 'rotated', rotated_at = now() where user_id = v_uid and state = 'active';
  insert into public.inbound_addresses (user_id, local_part)
  values (v_uid, 'r' || substr(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 1, 27))
  returning * into v_row;
  return v_row;
end;
$$;
grant execute on function public.rotate_inbound_address() to authenticated;

create or replace function public.disable_inbound_address()
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.inbound_addresses set state = 'disabled', rotated_at = now()
   where user_id = auth.uid() and state = 'active';
$$;
grant execute on function public.disable_inbound_address() to authenticated;
