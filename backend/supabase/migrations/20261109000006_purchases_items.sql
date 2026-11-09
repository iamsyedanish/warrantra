-- =============================================================================
-- 0006 Purchase groups, receipt lines, items, and file link tables
--   One receipt (purchase group) can create several selected items without
--   duplicating the receipt total or the original document.
-- =============================================================================

create table public.purchase_groups (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  retailer          text check (char_length(retailer) <= 200),
  order_number      text check (char_length(order_number) <= 120),
  purchase_date     date,
  delivery_date     date,
  currency          public.currency_code not null default 'USD',
  subtotal          public.money_amount,
  tax               public.money_amount,
  shipping          public.money_amount,
  discount          public.money_amount,
  total_paid        public.money_amount,
  source            text not null default 'manual'
                      check (source in ('manual', 'receipt_scan', 'product_scan', 'import', 'email_forward', 'share')),
  payment_card_id   uuid,
  scan_job_id       uuid,
  notes             text check (char_length(notes) <= 4000),
  idempotency_key   text not null check (char_length(idempotency_key) between 8 and 128),
  version           integer not null default 1,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (user_id, idempotency_key),
  unique (id, user_id),
  check (delivery_date is null or purchase_date is null or delivery_date >= purchase_date),
  check (purchase_date is null or purchase_date >= date '1950-01-01'),
  foreign key (payment_card_id, user_id) references public.payment_cards (id, user_id) on delete set null (payment_card_id)
);
create index purchase_groups_user_date_idx on public.purchase_groups (user_id, purchase_date desc nulls last);
create index purchase_groups_card_idx on public.purchase_groups (payment_card_id) where payment_card_id is not null;
create trigger purchase_groups_updated_at before update on public.purchase_groups
  for each row execute function app_private.set_updated_at();
create trigger purchase_groups_version before update on public.purchase_groups
  for each row execute function app_private.bump_version();

create table public.items (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references public.profiles (id) on delete cascade,
  purchase_group_id       uuid,
  name                    text not null check (char_length(btrim(name)) between 1 and 200),
  brand                   text check (char_length(brand) <= 120),
  brand_id                uuid references public.brands (id) on delete set null,
  model_number            text check (char_length(model_number) <= 120),
  serial_number           text check (char_length(serial_number) <= 120),
  sku                     text check (char_length(sku) <= 120),
  order_number            text check (char_length(order_number) <= 120),
  category_id             uuid references public.categories (id) on delete set null,
  retailer_name           text check (char_length(retailer_name) <= 200),
  purchase_date           date,
  delivery_date           date,
  -- Item value is its own line value (+ allocated tax/shipping - discount), never the receipt total.
  purchase_price          public.money_amount,
  price_is_estimated      boolean not null default false,
  currency                public.currency_code not null default 'USD',
  quantity                integer not null default 1 check (quantity > 0),
  condition_at_purchase   text not null default 'unknown'
                            check (condition_at_purchase in ('new', 'open_box', 'refurbished', 'used', 'unknown')),
  lifecycle_state         text not null default 'owned'
                            check (lifecycle_state in ('owned', 'returned', 'sold', 'gifted', 'lost', 'disposed')),
  lifecycle_changed_at    timestamptz,
  primary_image_attachment_id uuid,
  payment_card_id         uuid,
  notes                   text check (char_length(notes) <= 4000),
  source                  text not null default 'manual'
                            check (source in ('manual', 'receipt_scan', 'product_scan', 'import', 'email_forward', 'share')),
  -- Archive is display-only; archived items still consume retained-item quota.
  archived                boolean not null default false,
  version                 integer not null default 1,
  search_text             text generated always as (
                            lower(coalesce(name, '') || ' ' || coalesce(brand, '') || ' ' || coalesce(model_number, '') || ' ' ||
                                  coalesce(serial_number, '') || ' ' || coalesce(retailer_name, '') || ' ' || coalesce(order_number, ''))
                          ) stored,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  unique (id, user_id),
  check (delivery_date is null or purchase_date is null or delivery_date >= purchase_date),
  foreign key (purchase_group_id, user_id) references public.purchase_groups (id, user_id) on delete set null (purchase_group_id),
  foreign key (payment_card_id, user_id) references public.payment_cards (id, user_id) on delete set null (payment_card_id),
  foreign key (primary_image_attachment_id, user_id) references public.attachments (id, user_id) on delete set null (primary_image_attachment_id)
);
create index items_user_created_idx on public.items (user_id, created_at desc);
create index items_user_purchase_date_idx on public.items (user_id, purchase_date desc nulls last);
create index items_user_archived_idx on public.items (user_id, archived, lifecycle_state);
create index items_group_idx on public.items (purchase_group_id) where purchase_group_id is not null;
create index items_category_idx on public.items (category_id) where category_id is not null;
create index items_card_idx on public.items (payment_card_id) where payment_card_id is not null;
create index items_search_trgm_idx on public.items using gin (search_text extensions.gin_trgm_ops);

create trigger items_updated_at before update on public.items
  for each row execute function app_private.set_updated_at();
create trigger items_version before update on public.items
  for each row execute function app_private.bump_version();

create table public.receipt_lines (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null,
  purchase_group_id     uuid not null,
  item_id               uuid,
  line_index            integer not null check (line_index >= 0),
  original_description  text check (char_length(original_description) <= 500),
  confirmed_name        text check (char_length(confirmed_name) <= 200),
  sku                   text check (char_length(sku) <= 120),
  -- A quantity of 3 is not necessarily three separately serial-numbered objects.
  quantity              numeric(10, 3) not null default 1 check (quantity > 0),
  unit_amount           public.money_amount,
  line_amount           public.money_amount,
  allocated_tax         public.money_amount,
  allocated_discount    public.money_amount,
  allocated_shipping    public.money_amount,
  allocation_is_estimated boolean not null default false,
  confirmation_state    text not null default 'extracted'
                          check (confirmation_state in ('extracted', 'user_confirmed', 'user_edited', 'excluded')),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (purchase_group_id, line_index),
  unique (id, user_id),
  foreign key (purchase_group_id, user_id) references public.purchase_groups (id, user_id) on delete cascade,
  foreign key (item_id, user_id) references public.items (id, user_id) on delete set null (item_id)
);
create unique index receipt_lines_item_uniq on public.receipt_lines (item_id) where item_id is not null;
create index receipt_lines_user_idx on public.receipt_lines (user_id);
create trigger receipt_lines_updated_at before update on public.receipt_lines
  for each row execute function app_private.set_updated_at();

-- File links: each link is same-owner (composite FKs) and unique per pair.
create table public.item_attachments (
  item_id        uuid not null,
  attachment_id  uuid not null,
  user_id        uuid not null,
  role           text not null default 'document'
                   check (role in ('receipt', 'product_photo', 'warranty_card', 'manual', 'registration', 'document')),
  created_at     timestamptz not null default now(),
  primary key (item_id, attachment_id),
  foreign key (item_id, user_id) references public.items (id, user_id) on delete cascade,
  foreign key (attachment_id, user_id) references public.attachments (id, user_id) on delete cascade
);
create index item_attachments_attachment_idx on public.item_attachments (attachment_id);
create index item_attachments_user_idx on public.item_attachments (user_id);

create table public.purchase_attachments (
  purchase_group_id  uuid not null,
  attachment_id      uuid not null,
  user_id            uuid not null,
  created_at         timestamptz not null default now(),
  primary key (purchase_group_id, attachment_id),
  foreign key (purchase_group_id, user_id) references public.purchase_groups (id, user_id) on delete cascade,
  foreign key (attachment_id, user_id) references public.attachments (id, user_id) on delete cascade
);
create index purchase_attachments_attachment_idx on public.purchase_attachments (attachment_id);
create index purchase_attachments_user_idx on public.purchase_attachments (user_id);

-- -----------------------------------------------------------------------------
-- Retained-item quota (archived items count). Enforced in the database so every
-- insert path — API, RPC, import — is covered, serialised per user.
-- On downgrade nothing is deleted; additions beyond the free quota pause.
-- -----------------------------------------------------------------------------
create or replace function app_private.enforce_item_quota()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limits public.plan_limits;
  v_count integer;
  v_state text;
begin
  select account_state into v_state from public.profiles where id = new.user_id;
  if v_state is distinct from 'active' then
    raise exception 'account_not_active' using errcode = '42501';
  end if;

  perform app_private.lock_user(new.user_id, 'items');
  v_limits := app_private.plan_limits_for(new.user_id);
  select count(*) into v_count from public.items where user_id = new.user_id;
  if v_count >= v_limits.max_items then
    raise exception 'quota_exceeded:items:%', v_limits.max_items using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger items_enforce_quota before insert on public.items
  for each row execute function app_private.enforce_item_quota();

create or replace function app_private.track_lifecycle_change()
returns trigger
language plpgsql
as $$
begin
  if new.lifecycle_state is distinct from old.lifecycle_state then
    new.lifecycle_changed_at := now();
  end if;
  return new;
end;
$$;
create trigger items_lifecycle_change before update on public.items
  for each row execute function app_private.track_lifecycle_change();

-- Group delivery-date changes flow to items still following the group's date.
create or replace function app_private.propagate_group_dates()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.delivery_date is distinct from old.delivery_date then
    update public.items
       set delivery_date = new.delivery_date
     where purchase_group_id = new.id
       and user_id = new.user_id
       and delivery_date is not distinct from old.delivery_date;
  end if;
  if new.purchase_date is distinct from old.purchase_date then
    update public.items
       set purchase_date = new.purchase_date
     where purchase_group_id = new.id
       and user_id = new.user_id
       and purchase_date is not distinct from old.purchase_date;
  end if;
  return new;
end;
$$;
create trigger purchase_groups_propagate_dates after update of delivery_date, purchase_date on public.purchase_groups
  for each row execute function app_private.propagate_group_dates();

-- -----------------------------------------------------------------------------
-- RLS — operation-specific
-- -----------------------------------------------------------------------------
alter table public.purchase_groups enable row level security;
alter table public.items enable row level security;
alter table public.receipt_lines enable row level security;
alter table public.item_attachments enable row level security;
alter table public.purchase_attachments enable row level security;

revoke all on public.purchase_groups, public.items, public.receipt_lines,
              public.item_attachments, public.purchase_attachments from anon, authenticated;
grant select, insert, update, delete on public.purchase_groups, public.items, public.receipt_lines to authenticated;
grant select, insert, delete on public.item_attachments, public.purchase_attachments to authenticated;
grant all on public.purchase_groups, public.items, public.receipt_lines,
             public.item_attachments, public.purchase_attachments to service_role;

create policy purchase_groups_select_own on public.purchase_groups for select to authenticated using (user_id = auth.uid());
create policy purchase_groups_insert_own on public.purchase_groups for insert to authenticated with check (user_id = auth.uid());
create policy purchase_groups_update_own on public.purchase_groups for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy purchase_groups_delete_own on public.purchase_groups for delete to authenticated using (user_id = auth.uid());

create policy items_select_own on public.items for select to authenticated using (user_id = auth.uid());
create policy items_insert_own on public.items for insert to authenticated with check (user_id = auth.uid());
create policy items_update_own on public.items for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy items_delete_own on public.items for delete to authenticated using (user_id = auth.uid());

create policy receipt_lines_select_own on public.receipt_lines for select to authenticated using (user_id = auth.uid());
create policy receipt_lines_insert_own on public.receipt_lines for insert to authenticated with check (user_id = auth.uid());
create policy receipt_lines_update_own on public.receipt_lines for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy receipt_lines_delete_own on public.receipt_lines for delete to authenticated using (user_id = auth.uid());

create policy item_attachments_select_own on public.item_attachments for select to authenticated using (user_id = auth.uid());
create policy item_attachments_insert_own on public.item_attachments for insert to authenticated with check (user_id = auth.uid());
create policy item_attachments_delete_own on public.item_attachments for delete to authenticated using (user_id = auth.uid());

create policy purchase_attachments_select_own on public.purchase_attachments for select to authenticated using (user_id = auth.uid());
create policy purchase_attachments_insert_own on public.purchase_attachments for insert to authenticated with check (user_id = auth.uid());
create policy purchase_attachments_delete_own on public.purchase_attachments for delete to authenticated using (user_id = auth.uid());
