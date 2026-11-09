-- =============================================================================
-- 0013 Export, durable account deletion, deletion tombstones, backups & drills
--   * Export is never paywalled and works after cancellation.
--   * Deletion is a retryable job; its manifest lives OUTSIDE the profile cascade
--     until completion, then is purged.
--   * Tombstones are replayed after any restore so completed deletions are not
--     resurrected.
--   * Database backups do not include Storage objects: originals are backed up
--     separately and the combined restore is drilled.
-- =============================================================================

create table public.export_jobs (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles (id) on delete cascade,
  scope           text not null default 'account' check (scope in ('account', 'workspace')),
  workspace_id    uuid references public.workspaces (id) on delete cascade,
  state           text not null default 'queued' check (state in ('queued', 'running', 'ready', 'failed', 'expired')),
  include_files   boolean not null default true,
  data_path       text,
  manifest_path   text,
  item_count      integer,
  file_count      integer,
  expires_at      timestamptz,
  error_code      text,
  attempts        integer not null default 0,
  requested_at    timestamptz not null default now(),
  completed_at    timestamptz,
  check (scope <> 'workspace' or workspace_id is not null)
);
create index export_jobs_user_idx on public.export_jobs (user_id, requested_at desc);

alter table public.export_jobs enable row level security;
revoke all on public.export_jobs from anon, authenticated;
grant select on public.export_jobs to authenticated;
grant all on public.export_jobs to service_role;
create policy export_jobs_select_own on public.export_jobs for select to authenticated using (user_id = auth.uid());

-- Deletion requests deliberately have NO foreign key to profiles/auth.users.
create table public.deletion_requests (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null,
  source              text not null check (source in ('in_app', 'web')),
  state               text not null default 'requested'
                        check (state in ('requested', 'confirmed', 'deleting_objects', 'deleting_records', 'verifying',
                                         'completed', 'failed', 'cancelled')),
  reauthenticated_at  timestamptz,
  confirmed_at        timestamptz,
  attempts            integer not null default 0,
  next_attempt_at     timestamptz,
  last_error          text,
  objects_total       integer,
  objects_deleted     integer not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  completed_at        timestamptz
);
create unique index deletion_requests_one_open on public.deletion_requests (user_id)
  where state not in ('completed', 'cancelled', 'failed');
create trigger deletion_requests_updated_at before update on public.deletion_requests
  for each row execute function app_private.set_updated_at();

-- Out-of-app (website) deletion route, verified by an emailed one-time token.
create table public.web_deletion_requests (
  id                  uuid primary key default gen_random_uuid(),
  email_hash          text not null,
  token_hash          text not null unique,
  state               text not null default 'pending_verification'
                        check (state in ('pending_verification', 'verified', 'expired', 'no_account')),
  deletion_request_id uuid references public.deletion_requests (id) on delete set null,
  expires_at          timestamptz not null default now() + interval '24 hours',
  created_at          timestamptz not null default now(),
  verified_at         timestamptz
);

create table public.deletion_manifests (
  id                   uuid primary key default gen_random_uuid(),
  deletion_request_id  uuid not null references public.deletion_requests (id) on delete cascade,
  user_id              uuid not null,
  bucket               text not null,
  storage_path         text not null,
  state                text not null default 'pending' check (state in ('pending', 'deleted', 'failed')),
  attempts             integer not null default 0,
  last_error           text,
  unique (deletion_request_id, bucket, storage_path)
);
create index deletion_manifests_pending_idx on public.deletion_manifests (deletion_request_id) where state <> 'deleted';

create table public.deletion_tombstones (
  user_id        uuid primary key,
  completed_at   timestamptz not null default now(),
  request_id     uuid
);

alter table public.deletion_requests enable row level security;
alter table public.web_deletion_requests enable row level security;
alter table public.deletion_manifests enable row level security;
alter table public.deletion_tombstones enable row level security;
revoke all on public.deletion_requests, public.web_deletion_requests, public.deletion_manifests, public.deletion_tombstones
  from anon, authenticated;
grant select on public.deletion_requests to authenticated;
grant all on public.deletion_requests, public.web_deletion_requests, public.deletion_manifests, public.deletion_tombstones
  to service_role;
create policy deletion_requests_select_own on public.deletion_requests for select to authenticated using (user_id = auth.uid());

-- Replay tombstones after a restore (service_role). Returns affected user ids so
-- the caller can also purge Storage objects for them.
create or replace function public.replay_deletion_tombstones()
returns table (user_id uuid)
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  return query
  with resurrected as (
    select t.user_id from public.deletion_tombstones t
     where exists (select 1 from auth.users u where u.id = t.user_id)
        or exists (select 1 from public.profiles p where p.id = t.user_id)
  ), del_profiles as (
    delete from public.profiles p using resurrected r where p.id = r.user_id returning p.id
  ), del_users as (
    delete from auth.users u using resurrected r where u.id = r.user_id returning u.id
  )
  select r.user_id from resurrected r;
end;
$$;
revoke all on function public.replay_deletion_tombstones() from public, anon, authenticated;
grant execute on function public.replay_deletion_tombstones() to service_role;

-- -----------------------------------------------------------------------------
-- Backups of Storage originals + restore drills
-- -----------------------------------------------------------------------------
create table public.backup_runs (
  id               uuid primary key default gen_random_uuid(),
  kind             text not null check (kind in ('storage_objects')),
  state            text not null default 'running' check (state in ('running', 'succeeded', 'partial', 'failed')),
  target           text not null,
  objects_scanned  integer not null default 0,
  objects_copied   integer not null default 0,
  bytes_copied     bigint not null default 0,
  error_count      integer not null default 0,
  last_error       text,
  started_at       timestamptz not null default now(),
  completed_at     timestamptz
);

create table public.backup_objects (
  bucket         text not null,
  storage_path   text not null,
  attachment_id  uuid,
  user_id        uuid,
  checksum_sha256 text,
  byte_size      bigint,
  backup_key     text not null,
  backed_up_at   timestamptz not null default now(),
  purged_at      timestamptz,                    -- removed from backup after account deletion
  primary key (bucket, storage_path)
);
create index backup_objects_user_idx on public.backup_objects (user_id) where purged_at is null;

create table public.restore_drills (
  id            uuid primary key default gen_random_uuid(),
  started_at    timestamptz not null default now(),
  completed_at  timestamptz,
  passed        boolean,
  checks        jsonb not null default '[]'::jsonb,
  notes         text,
  performed_by  uuid
);

alter table public.backup_runs enable row level security;
alter table public.backup_objects enable row level security;
alter table public.restore_drills enable row level security;
revoke all on public.backup_runs, public.backup_objects, public.restore_drills from anon, authenticated;
grant all on public.backup_runs, public.backup_objects, public.restore_drills to service_role;
