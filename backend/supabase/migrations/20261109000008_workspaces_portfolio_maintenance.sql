-- =============================================================================
-- 0008 Household vault & business/property portfolio (shared workspaces),
--      locations, asset assignment, service history, maintenance tasks.
--
-- Authorization model (dedicated tests in tests/sql):
--   * An item always has exactly one owner (items.user_id). Sharing never
--     transfers ownership; child records (warranties, returns...) stay owned by
--     the item owner and remain editable only by that owner.
--   * Owners share items into a workspace. Active members can READ shared items
--     and their coverage/documents. Editors/admins can WRITE workspace-owned
--     records (locations, assignments, service records, maintenance tasks).
--   * Revocation is immediate for database access. Already-issued signed URLs are
--     bearer credentials and stay valid until their short expiry.
--   * Shared entitlement rule: workspace features follow the OWNER's plan.
--     Shared items count against the owner's retained-item quota only.
-- =============================================================================

create table public.workspaces (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.profiles (id) on delete cascade,
  kind        text not null check (kind in ('household', 'business')),
  name        text not null check (char_length(btrim(name)) between 1 and 120),
  archived    boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index workspaces_owner_idx on public.workspaces (owner_id);
create trigger workspaces_updated_at before update on public.workspaces
  for each row execute function app_private.set_updated_at();

create table public.workspace_members (
  workspace_id  uuid not null references public.workspaces (id) on delete cascade,
  user_id       uuid not null references public.profiles (id) on delete cascade,
  role          text not null check (role in ('owner', 'admin', 'editor', 'viewer')),
  state         text not null default 'active' check (state in ('active', 'revoked', 'left')),
  invited_by    uuid,
  joined_at     timestamptz not null default now(),
  revoked_at    timestamptz,
  primary key (workspace_id, user_id)
);
create index workspace_members_user_idx on public.workspace_members (user_id) where state = 'active';

create table public.workspace_invitations (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces (id) on delete cascade,
  email_normalized text not null check (char_length(email_normalized) <= 320),
  role          text not null check (role in ('admin', 'editor', 'viewer')),
  token_hash    text not null unique,
  invited_by    uuid not null references public.profiles (id) on delete cascade,
  expires_at    timestamptz not null default now() + interval '7 days',
  accepted_at   timestamptz,
  accepted_by   uuid,
  revoked_at    timestamptz,
  created_at    timestamptz not null default now()
);
create index workspace_invitations_ws_idx on public.workspace_invitations (workspace_id) where accepted_at is null and revoked_at is null;

-- ---- membership helpers (SECURITY DEFINER to avoid recursive RLS) ------------
create or replace function app_private.workspace_role(p_workspace_id uuid, p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.role
    from public.workspace_members m
    join public.workspaces w on w.id = m.workspace_id
   where m.workspace_id = p_workspace_id
     and m.user_id = p_user_id
     and m.state = 'active'
     and w.archived = false;
$$;

create or replace function app_private.is_workspace_member(p_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app_private.workspace_role(p_workspace_id, auth.uid()) is not null;
$$;

create or replace function app_private.can_write_workspace(p_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(app_private.workspace_role(p_workspace_id, auth.uid()) in ('owner', 'admin', 'editor'), false);
$$;

create or replace function app_private.can_admin_workspace(p_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(app_private.workspace_role(p_workspace_id, auth.uid()) in ('owner', 'admin'), false);
$$;

grant execute on function app_private.workspace_role(uuid, uuid) to authenticated, service_role;
grant execute on function app_private.is_workspace_member(uuid) to authenticated, service_role;
grant execute on function app_private.can_write_workspace(uuid) to authenticated, service_role;
grant execute on function app_private.can_admin_workspace(uuid) to authenticated, service_role;

-- Workspace creation follows the creator's plan; the owner becomes a member.
create or replace function app_private.workspace_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limits public.plan_limits := app_private.plan_limits_for(new.owner_id);
begin
  if not v_limits.workspaces_enabled then
    raise exception 'plan_feature_unavailable:workspaces' using errcode = 'P0001';
  end if;
  if new.kind = 'business' and not v_limits.business_portfolio_enabled then
    raise exception 'plan_feature_unavailable:business_portfolio' using errcode = 'P0001';
  end if;
  insert into public.workspace_members (workspace_id, user_id, role, state, invited_by)
  values (new.id, new.owner_id, 'owner', 'active', new.owner_id);
  return new;
end;
$$;
create trigger workspaces_after_insert after insert on public.workspaces
  for each row execute function app_private.workspace_after_insert();

create or replace function app_private.guard_workspace_members()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid;
  v_limits public.plan_limits;
  v_count integer;
begin
  select owner_id into v_owner from public.workspaces where id = new.workspace_id;
  if new.role = 'owner' and new.user_id <> v_owner then
    raise exception 'only_workspace_owner_can_hold_owner_role' using errcode = '42501';
  end if;
  if new.user_id = v_owner and (new.role <> 'owner' or new.state <> 'active') then
    raise exception 'workspace_owner_cannot_be_demoted_or_removed' using errcode = '42501';
  end if;
  if new.state = 'active' and (tg_op = 'INSERT' or old.state <> 'active') then
    v_limits := app_private.plan_limits_for(v_owner);
    select count(*) into v_count from public.workspace_members
     where workspace_id = new.workspace_id and state = 'active' and user_id <> new.user_id;
    if v_count + 1 > v_limits.max_workspace_members then
      raise exception 'quota_exceeded:workspace_members:%', v_limits.max_workspace_members using errcode = 'P0001';
    end if;
  end if;
  if new.state in ('revoked', 'left') and new.revoked_at is null then
    new.revoked_at := now();
  end if;
  return new;
end;
$$;
create trigger workspace_members_guard before insert or update on public.workspace_members
  for each row execute function app_private.guard_workspace_members();

-- ---- locations (business/property) -----------------------------------------
create table public.locations (
  id                  uuid primary key default gen_random_uuid(),
  workspace_id        uuid not null references public.workspaces (id) on delete cascade,
  parent_location_id  uuid references public.locations (id) on delete set null,
  kind                text not null default 'site' check (kind in ('property', 'unit', 'site', 'room', 'other')),
  name                text not null check (char_length(btrim(name)) between 1 and 120),
  address_line        text check (char_length(address_line) <= 300),
  notes               text check (char_length(notes) <= 2000),
  archived            boolean not null default false,
  created_by          uuid references public.profiles (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (id, workspace_id)
);
create index locations_workspace_idx on public.locations (workspace_id);
create index locations_parent_idx on public.locations (parent_location_id) where parent_location_id is not null;
create trigger locations_updated_at before update on public.locations
  for each row execute function app_private.set_updated_at();

-- ---- items shared into a workspace -----------------------------------------
create table public.workspace_items (
  workspace_id  uuid not null references public.workspaces (id) on delete cascade,
  item_id       uuid not null,
  user_id       uuid not null,      -- the item owner
  location_id   uuid,
  shared_by     uuid not null references public.profiles (id) on delete cascade,
  shared_at     timestamptz not null default now(),
  primary key (workspace_id, item_id),
  foreign key (item_id, user_id) references public.items (id, user_id) on delete cascade,
  foreign key (location_id, workspace_id) references public.locations (id, workspace_id) on delete set null (location_id)
);
create index workspace_items_item_idx on public.workspace_items (item_id);
create index workspace_items_location_idx on public.workspace_items (location_id) where location_id is not null;

create or replace function app_private.guard_workspace_items()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Only the item owner, who must be an active member, can share an item.
  if tg_op = 'INSERT' then
    if new.shared_by <> new.user_id then
      raise exception 'only_item_owner_can_share' using errcode = '42501';
    end if;
    if app_private.workspace_role(new.workspace_id, new.user_id) is null then
      raise exception 'item_owner_not_workspace_member' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger workspace_items_guard before insert or update on public.workspace_items
  for each row execute function app_private.guard_workspace_items();

create table public.asset_assignments (
  id             uuid primary key default gen_random_uuid(),
  workspace_id   uuid not null,
  item_id        uuid not null,
  location_id    uuid not null,
  assigned_by    uuid references public.profiles (id) on delete set null,
  assigned_at    timestamptz not null default now(),
  unassigned_at  timestamptz,
  note           text check (char_length(note) <= 1000),
  foreign key (workspace_id, item_id) references public.workspace_items (workspace_id, item_id) on delete cascade,
  foreign key (location_id, workspace_id) references public.locations (id, workspace_id) on delete cascade,
  check (unassigned_at is null or unassigned_at >= assigned_at)
);
create unique index asset_assignments_current_uniq on public.asset_assignments (workspace_id, item_id) where unassigned_at is null;
create index asset_assignments_location_idx on public.asset_assignments (location_id);

-- Item-level read access: owner, or active member of a workspace the item is shared into.
create or replace function app_private.can_read_item(p_item_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.items i where i.id = p_item_id and i.user_id = auth.uid())
      or exists (
           select 1
             from public.workspace_items wi
             join public.workspace_members m on m.workspace_id = wi.workspace_id
             join public.workspaces w on w.id = wi.workspace_id
            where wi.item_id = p_item_id
              and m.user_id = auth.uid()
              and m.state = 'active'
              and w.archived = false);
$$;

create or replace function app_private.can_write_item_in_workspace(p_item_id uuid, p_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.items i where i.id = p_item_id and i.user_id = auth.uid())
      or (p_workspace_id is not null
          and app_private.can_write_workspace(p_workspace_id)
          and exists (select 1 from public.workspace_items wi where wi.item_id = p_item_id and wi.workspace_id = p_workspace_id));
$$;
grant execute on function app_private.can_read_item(uuid) to authenticated, service_role;
grant execute on function app_private.can_write_item_in_workspace(uuid, uuid) to authenticated, service_role;

-- ---- service history & maintenance -----------------------------------------
create table public.service_records (
  id              uuid primary key default gen_random_uuid(),
  item_id         uuid not null references public.items (id) on delete cascade,
  workspace_id    uuid references public.workspaces (id) on delete cascade,
  created_by      uuid not null references public.profiles (id) on delete cascade,
  service_date    date not null,
  service_type    text not null check (service_type in ('repair', 'maintenance', 'inspection', 'installation', 'warranty_service', 'other')),
  provider_name   text check (char_length(provider_name) <= 200),
  description     text check (char_length(description) <= 4000),
  cost_amount     public.money_amount,
  cost_currency   public.currency_code,
  claim_id        uuid,
  maintenance_task_id uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (cost_amount is null or cost_currency is not null)
);
create index service_records_item_idx on public.service_records (item_id, service_date desc);
create index service_records_workspace_idx on public.service_records (workspace_id) where workspace_id is not null;
create index service_records_creator_idx on public.service_records (created_by);
create trigger service_records_updated_at before update on public.service_records
  for each row execute function app_private.set_updated_at();

create table public.service_record_attachments (
  service_record_id  uuid not null references public.service_records (id) on delete cascade,
  attachment_id      uuid not null,
  user_id            uuid not null,        -- attachment owner (must be the linker)
  created_at         timestamptz not null default now(),
  primary key (service_record_id, attachment_id),
  foreign key (attachment_id, user_id) references public.attachments (id, user_id) on delete cascade
);
create index service_record_attachments_attachment_idx on public.service_record_attachments (attachment_id);

create table public.maintenance_tasks (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null references public.profiles (id) on delete cascade,
  workspace_id        uuid references public.workspaces (id) on delete cascade,
  item_id             uuid references public.items (id) on delete cascade,
  title               text not null check (char_length(btrim(title)) between 1 and 200),
  description         text check (char_length(description) <= 2000),
  -- Avoid implying every task is legally or contractually required.
  requirement_basis   text not null default 'user_preference'
                        check (requirement_basis in ('user_preference', 'manufacturer_recommended', 'warranty_terms_stated', 'unknown')),
  recurrence_unit     text check (recurrence_unit in ('day', 'week', 'month', 'year')),
  recurrence_interval integer check (recurrence_interval > 0 and recurrence_interval <= 120),
  next_due_on         date,
  last_completed_on   date,
  reminder_enabled    boolean not null default true,
  state               text not null default 'active' check (state in ('active', 'paused', 'archived')),
  version             integer not null default 1,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check ((recurrence_unit is null) = (recurrence_interval is null))
);
create index maintenance_tasks_owner_due_idx on public.maintenance_tasks (owner_id, next_due_on) where state = 'active';
create index maintenance_tasks_workspace_idx on public.maintenance_tasks (workspace_id) where workspace_id is not null;
create index maintenance_tasks_item_idx on public.maintenance_tasks (item_id) where item_id is not null;
create trigger maintenance_tasks_updated_at before update on public.maintenance_tasks
  for each row execute function app_private.set_updated_at();
create trigger maintenance_tasks_version before update on public.maintenance_tasks
  for each row execute function app_private.bump_version();

alter table public.service_records add constraint service_records_maintenance_fk
  foreign key (maintenance_task_id) references public.maintenance_tasks (id) on delete set null;

create or replace function app_private.assert_workspace_scoped_item(p_item_id uuid, p_workspace_id uuid, p_actor uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid;
begin
  if p_item_id is null then
    return;
  end if;
  select user_id into v_owner from public.items where id = p_item_id;
  if p_workspace_id is null then
    -- Personal record: only for the item owner.
    if v_owner is distinct from p_actor then
      raise exception 'item_not_owned' using errcode = '42501';
    end if;
  elsif not exists (select 1 from public.workspace_items wi
                     where wi.workspace_id = p_workspace_id and wi.item_id = p_item_id) then
    raise exception 'item_not_shared_into_workspace' using errcode = '42501';
  end if;
end;
$$;

create or replace function app_private.guard_service_record()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform app_private.assert_workspace_scoped_item(new.item_id, new.workspace_id, new.created_by);
  return new;
end;
$$;

create or replace function app_private.guard_maintenance_task()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform app_private.assert_workspace_scoped_item(new.item_id, new.workspace_id, new.owner_id);
  return new;
end;
$$;

create trigger service_records_guard before insert or update on public.service_records
  for each row execute function app_private.guard_service_record();
create trigger maintenance_tasks_guard before insert or update on public.maintenance_tasks
  for each row execute function app_private.guard_maintenance_task();

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.workspace_invitations enable row level security;
alter table public.locations enable row level security;
alter table public.workspace_items enable row level security;
alter table public.asset_assignments enable row level security;
alter table public.service_records enable row level security;
alter table public.service_record_attachments enable row level security;
alter table public.maintenance_tasks enable row level security;

revoke all on public.workspaces, public.workspace_members, public.workspace_invitations, public.locations,
              public.workspace_items, public.asset_assignments, public.service_records,
              public.service_record_attachments, public.maintenance_tasks from anon, authenticated;
grant select, insert on public.workspaces to authenticated;
grant update (name, archived) on public.workspaces to authenticated;
grant select on public.workspace_members to authenticated;
-- Column-level: membership rows can never be moved to another workspace or user.
grant update (role, state, revoked_at) on public.workspace_members to authenticated;
grant select on public.workspace_invitations to authenticated;
grant select, insert, update, delete on public.locations, public.asset_assignments to authenticated;
grant select, insert, delete on public.workspace_items, public.service_records, public.maintenance_tasks to authenticated;
grant update (location_id) on public.workspace_items to authenticated;
grant update (service_date, service_type, provider_name, description, cost_amount, cost_currency, claim_id)
  on public.service_records to authenticated;
grant update (title, description, requirement_basis, recurrence_unit, recurrence_interval, next_due_on, last_completed_on,
              reminder_enabled, state) on public.maintenance_tasks to authenticated;
grant select, insert, delete on public.service_record_attachments to authenticated;
grant all on public.workspaces, public.workspace_members, public.workspace_invitations, public.locations,
             public.workspace_items, public.asset_assignments, public.service_records,
             public.service_record_attachments, public.maintenance_tasks to service_role;

create policy workspaces_select_member on public.workspaces for select to authenticated
  using (owner_id = auth.uid() or app_private.is_workspace_member(id));
create policy workspaces_insert_owner on public.workspaces for insert to authenticated
  with check (owner_id = auth.uid());
create policy workspaces_update_owner on public.workspaces for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy workspace_members_select on public.workspace_members for select to authenticated
  using (user_id = auth.uid() or app_private.is_workspace_member(workspace_id));
-- Admins manage roles/revocation; any member may leave (set own state = 'left').
create policy workspace_members_update_admin on public.workspace_members for update to authenticated
  using (app_private.can_admin_workspace(workspace_id) or user_id = auth.uid())
  with check (app_private.can_admin_workspace(workspace_id) or (user_id = auth.uid() and state = 'left'));

create policy workspace_invitations_select_admin on public.workspace_invitations for select to authenticated
  using (app_private.can_admin_workspace(workspace_id));

create policy locations_select on public.locations for select to authenticated
  using (app_private.is_workspace_member(workspace_id));
create policy locations_insert on public.locations for insert to authenticated
  with check (app_private.can_write_workspace(workspace_id));
create policy locations_update on public.locations for update to authenticated
  using (app_private.can_write_workspace(workspace_id)) with check (app_private.can_write_workspace(workspace_id));
create policy locations_delete on public.locations for delete to authenticated
  using (app_private.can_admin_workspace(workspace_id));

create policy workspace_items_select on public.workspace_items for select to authenticated
  using (app_private.is_workspace_member(workspace_id));
create policy workspace_items_insert on public.workspace_items for insert to authenticated
  with check (user_id = auth.uid() and shared_by = auth.uid() and app_private.is_workspace_member(workspace_id));
create policy workspace_items_update on public.workspace_items for update to authenticated
  using (app_private.can_write_workspace(workspace_id)) with check (app_private.can_write_workspace(workspace_id));
-- Unshare: the item owner or a workspace admin.
create policy workspace_items_delete on public.workspace_items for delete to authenticated
  using (user_id = auth.uid() or app_private.can_admin_workspace(workspace_id));

create policy asset_assignments_select on public.asset_assignments for select to authenticated
  using (app_private.is_workspace_member(workspace_id));
create policy asset_assignments_write on public.asset_assignments for insert to authenticated
  with check (app_private.can_write_workspace(workspace_id));
create policy asset_assignments_update on public.asset_assignments for update to authenticated
  using (app_private.can_write_workspace(workspace_id)) with check (app_private.can_write_workspace(workspace_id));
create policy asset_assignments_delete on public.asset_assignments for delete to authenticated
  using (app_private.can_admin_workspace(workspace_id));

create policy service_records_select on public.service_records for select to authenticated
  using (created_by = auth.uid()
         or (workspace_id is not null and app_private.is_workspace_member(workspace_id))
         or (workspace_id is null and exists (select 1 from public.items i where i.id = item_id and i.user_id = auth.uid())));
create policy service_records_insert on public.service_records for insert to authenticated
  with check (created_by = auth.uid() and app_private.can_write_item_in_workspace(item_id, workspace_id));
create policy service_records_update on public.service_records for update to authenticated
  using (created_by = auth.uid() or (workspace_id is not null and app_private.can_admin_workspace(workspace_id)))
  with check (app_private.can_write_item_in_workspace(item_id, workspace_id));
create policy service_records_delete on public.service_records for delete to authenticated
  using (created_by = auth.uid() or (workspace_id is not null and app_private.can_admin_workspace(workspace_id)));

create policy service_record_attachments_select on public.service_record_attachments for select to authenticated
  using (user_id = auth.uid() or exists (
    select 1 from public.service_records s
     where s.id = service_record_id and s.workspace_id is not null and app_private.is_workspace_member(s.workspace_id)));
create policy service_record_attachments_insert on public.service_record_attachments for insert to authenticated
  with check (user_id = auth.uid() and exists (
    select 1 from public.service_records s
     where s.id = service_record_id and app_private.can_write_item_in_workspace(s.item_id, s.workspace_id)));
create policy service_record_attachments_delete on public.service_record_attachments for delete to authenticated
  using (user_id = auth.uid());

create policy maintenance_tasks_select on public.maintenance_tasks for select to authenticated
  using (owner_id = auth.uid() or (workspace_id is not null and app_private.is_workspace_member(workspace_id)));
create policy maintenance_tasks_insert on public.maintenance_tasks for insert to authenticated
  with check (owner_id = auth.uid()
              and (workspace_id is null or app_private.can_write_workspace(workspace_id))
              and (item_id is null or app_private.can_write_item_in_workspace(item_id, workspace_id)));
create policy maintenance_tasks_update on public.maintenance_tasks for update to authenticated
  using (owner_id = auth.uid() or (workspace_id is not null and app_private.can_write_workspace(workspace_id)))
  with check (owner_id = auth.uid() or (workspace_id is not null and app_private.can_write_workspace(workspace_id)));
create policy maintenance_tasks_delete on public.maintenance_tasks for delete to authenticated
  using (owner_id = auth.uid() or (workspace_id is not null and app_private.can_admin_workspace(workspace_id)));

-- -----------------------------------------------------------------------------
-- Extra READ policies on item-owned tables for workspace members (permissive
-- policies are OR-ed with the owner policies created earlier). Writes stay owner-only.
-- -----------------------------------------------------------------------------
create policy items_select_shared on public.items for select to authenticated
  using (app_private.can_read_item(id));
create policy warranties_select_shared on public.warranties for select to authenticated
  using (app_private.can_read_item(item_id));
create policy return_windows_select_shared on public.return_windows for select to authenticated
  using (app_private.can_read_item(item_id));
create policy registrations_select_shared on public.registrations for select to authenticated
  using (app_private.can_read_item(item_id));
create policy item_attachments_select_shared on public.item_attachments for select to authenticated
  using (app_private.can_read_item(item_id));

create or replace function app_private.can_read_attachment(p_attachment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.attachments a where a.id = p_attachment_id and a.user_id = auth.uid()
                   and a.deletion_state = 'active')
      or exists (select 1 from public.item_attachments ia
                   join public.attachments a on a.id = ia.attachment_id and a.deletion_state = 'active'
                  where ia.attachment_id = p_attachment_id and app_private.can_read_item(ia.item_id))
      or exists (select 1 from public.service_record_attachments sra
                   join public.service_records s on s.id = sra.service_record_id
                   join public.attachments a on a.id = sra.attachment_id and a.deletion_state = 'active'
                  where sra.attachment_id = p_attachment_id
                    and s.workspace_id is not null and app_private.is_workspace_member(s.workspace_id));
$$;
grant execute on function app_private.can_read_attachment(uuid) to authenticated, service_role;

create policy attachments_select_shared on public.attachments for select to authenticated
  using (processing_state = 'ready' and app_private.can_read_attachment(id));
