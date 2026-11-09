-- =============================================================================
-- 0005 Document vault (attachments as shared file objects) and payment-card labels
-- =============================================================================

create table public.attachments (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references public.profiles (id) on delete cascade,
  bucket                text not null default 'warranty-files' check (bucket in ('warranty-files')),
  storage_path          text not null check (char_length(storage_path) <= 1024),
  file_type             text not null default 'other'
                          check (file_type in ('receipt', 'product_photo', 'warranty_card', 'manual', 'registration',
                                               'claim_evidence', 'service_record', 'other')),
  original_filename     text check (char_length(original_filename) <= 255),
  declared_mime_type    text,
  verified_mime_type    text check (verified_mime_type in ('image/jpeg', 'image/png', 'image/heic', 'image/heif', 'application/pdf')),
  declared_byte_size    bigint not null check (declared_byte_size > 0),
  actual_byte_size      bigint check (actual_byte_size > 0),
  page_count            integer check (page_count > 0),
  checksum_sha256       text check (checksum_sha256 ~ '^[0-9a-f]{64}$'),
  processing_state      text not null default 'pending_upload'
                          check (processing_state in ('pending_upload', 'verifying', 'ready', 'quarantined', 'failed')),
  quarantine_reason     text,
  preview_path          text,
  deletion_state        text not null default 'active' check (deletion_state in ('active', 'pending_deletion', 'deleted')),
  source                text not null default 'upload' check (source in ('upload', 'email_forward', 'share', 'system')),
  idempotency_key       text check (char_length(idempotency_key) between 8 and 128),
  usage_reservation_id  uuid,
  upload_expires_at     timestamptz,
  verified_at           timestamptz,
  deleted_at            timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (bucket, storage_path),
  unique (id, user_id),
  unique (user_id, idempotency_key),
  -- Object paths are always prefixed by the owner's id.
  check (split_part(storage_path, '/', 1) = user_id::text),
  check (processing_state <> 'ready' or (actual_byte_size is not null and verified_mime_type is not null and checksum_sha256 is not null))
);
create index attachments_user_state_idx on public.attachments (user_id, created_at desc) where deletion_state = 'active';
-- Account-local duplicate detection only (never reveal cross-account matches).
create index attachments_user_checksum_idx on public.attachments (user_id, checksum_sha256) where checksum_sha256 is not null;
create index attachments_pending_idx on public.attachments (upload_expires_at) where processing_state = 'pending_upload';
create trigger attachments_updated_at before update on public.attachments
  for each row execute function app_private.set_updated_at();

alter table public.attachments enable row level security;
revoke all on public.attachments from anon, authenticated;
-- Clients read metadata and may rename/re-type; every state transition is server-only.
grant select on public.attachments to authenticated;
grant update (original_filename, file_type) on public.attachments to authenticated;
grant all on public.attachments to service_role;
create policy attachments_select_own on public.attachments
  for select to authenticated using (user_id = auth.uid() and deletion_state <> 'deleted');
create policy attachments_update_own on public.attachments
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Payment-card labels (never numbers, CVVs, expiry or credentials)
-- -----------------------------------------------------------------------------
create table public.payment_cards (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references public.profiles (id) on delete cascade,
  nickname         text not null check (char_length(nickname) between 1 and 60),
  issuer_label     text check (char_length(issuer_label) <= 60),
  network          text check (network in ('visa', 'mastercard', 'amex', 'discover', 'other')),
  card_benefit_id  uuid references public.card_benefits (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (id, user_id),
  -- Reject anything resembling a PAN (12+ digits once separators are removed).
  check (regexp_replace(nickname, '[\s\-\.]', '', 'g') !~ '\d{12,}'),
  check (issuer_label is null or regexp_replace(issuer_label, '[\s\-\.]', '', 'g') !~ '\d{12,}')
);
create index payment_cards_user_idx on public.payment_cards (user_id);
create trigger payment_cards_updated_at before update on public.payment_cards
  for each row execute function app_private.set_updated_at();

alter table public.payment_cards enable row level security;
revoke all on public.payment_cards from anon, authenticated;
grant select, insert, update, delete on public.payment_cards to authenticated;
grant all on public.payment_cards to service_role;
create policy payment_cards_select_own on public.payment_cards for select to authenticated using (user_id = auth.uid());
create policy payment_cards_insert_own on public.payment_cards for insert to authenticated with check (user_id = auth.uid());
create policy payment_cards_update_own on public.payment_cards for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy payment_cards_delete_own on public.payment_cards for delete to authenticated using (user_id = auth.uid());
