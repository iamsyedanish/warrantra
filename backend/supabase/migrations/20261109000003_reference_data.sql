-- =============================================================================
-- 0003 Reference / lookup data — SELECT-only from clients, writes via service role
-- Reference data is never treated as guaranteed coverage; it can only produce
-- *suggestions* that a user must explicitly accept.
-- =============================================================================

create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique check (slug ~ '^[a-z0-9_]+$'),
  name        text not null,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);

create table public.brands (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  normalized_name   text generated always as (lower(btrim(name))) stored,
  website_url       text,
  support_url       text,
  registration_url  text,
  support_email     text,
  support_phone     text,
  logo_path         text,
  last_verified_at  timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (normalized_name)
);
create trigger brands_updated_at before update on public.brands
  for each row execute function app_private.set_updated_at();

-- Review workflow shared by curated tables.
-- draft -> in_review -> published -> retired. Only `published` rows are visible to clients.
create table public.warranty_reference (
  id                        uuid primary key default gen_random_uuid(),
  brand_id                  uuid not null references public.brands (id) on delete restrict,
  product_family            text not null,
  country_code              public.country_code not null,
  standard_duration_months  integer check (standard_duration_months > 0),
  term_kind                 text not null default 'duration'
                              check (term_kind in ('duration', 'lifetime', 'conditional')),
  conditions_summary        text,
  terms_url                 text,
  source_url                text not null,
  effective_from            date,
  effective_to              date,
  review_status             text not null default 'draft'
                              check (review_status in ('draft', 'in_review', 'published', 'retired')),
  reviewed_by               uuid,
  reviewed_at               timestamptz,
  last_verified_at          timestamptz,
  next_review_due           date,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  check (term_kind <> 'duration' or standard_duration_months is not null),
  check (effective_to is null or effective_from is null or effective_to >= effective_from)
);
create index warranty_reference_brand_idx on public.warranty_reference (brand_id, country_code) where review_status = 'published';
create trigger warranty_reference_updated_at before update on public.warranty_reference
  for each row execute function app_private.set_updated_at();

-- Retailer return policies — suggestions only; never a default 30-day entitlement.
create table public.return_policy_reference (
  id                uuid primary key default gen_random_uuid(),
  retailer_name     text not null,
  normalized_retailer text generated always as (lower(btrim(retailer_name))) stored,
  country_code      public.country_code not null,
  product_scope     text not null default 'general',
  window_days       integer check (window_days >= 0),
  policy_anchor     text not null default 'unknown'
                      check (policy_anchor in ('purchase_date', 'delivery_date', 'unknown')),
  deadline_basis    text not null default 'unknown'
                      check (deadline_basis in ('request_by', 'postmark_by', 'merchant_receipt_by', 'unknown')),
  conditions_summary text,
  source_url        text not null,
  effective_from    date,
  effective_to      date,
  review_status     text not null default 'draft'
                      check (review_status in ('draft', 'in_review', 'published', 'retired')),
  reviewed_by       uuid,
  reviewed_at       timestamptz,
  last_verified_at  timestamptz,
  next_review_due   date,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index return_policy_reference_lookup_idx on public.return_policy_reference (normalized_retailer, country_code)
  where review_status = 'published';
create trigger return_policy_reference_updated_at before update on public.return_policy_reference
  for each row execute function app_private.set_updated_at();

-- Credit-card benefit reference (P2): country/product/effective-date sourced, with exclusions.
create table public.card_benefits (
  id                            uuid primary key default gen_random_uuid(),
  card_name                     text not null,
  issuer                        text not null,
  network                       text,
  country_code                  public.country_code not null,
  product_scope                 text not null default 'consumer',
  extension_months              integer check (extension_months > 0),
  max_original_warranty_months  integer check (max_original_warranty_months > 0),
  maximum_coverage_amount       public.money_amount,
  coverage_currency             public.currency_code,
  benefit_summary               text not null,
  exclusions                    text,
  enrollment_required           text not null default 'unknown'
                                  check (enrollment_required in ('unknown', 'no', 'yes')),
  terms_url                     text,
  source_url                    text not null,
  effective_from                date,
  effective_to                  date,
  review_status                 text not null default 'draft'
                                  check (review_status in ('draft', 'in_review', 'published', 'retired')),
  reviewed_by                   uuid,
  reviewed_at                   timestamptz,
  last_verified_at              timestamptz,
  next_review_due               date,
  created_at                    timestamptz not null default now(),
  updated_at                    timestamptz not null default now()
);
create trigger card_benefits_updated_at before update on public.card_benefits
  for each row execute function app_private.set_updated_at();

create table public.reference_reviews (
  id            uuid primary key default gen_random_uuid(),
  table_name    text not null check (table_name in ('warranty_reference', 'return_policy_reference', 'card_benefits', 'brands')),
  record_id     uuid not null,
  action        text not null check (action in ('submitted', 'approved', 'rejected', 'retired', 'verified')),
  reviewer_id   uuid,
  notes         text,
  created_at    timestamptz not null default now()
);
create index reference_reviews_record_idx on public.reference_reviews (table_name, record_id);

-- RLS: read-only for authenticated clients; curated tables expose only published rows.
alter table public.categories enable row level security;
alter table public.brands enable row level security;
alter table public.warranty_reference enable row level security;
alter table public.return_policy_reference enable row level security;
alter table public.card_benefits enable row level security;
alter table public.reference_reviews enable row level security;

revoke all on public.categories, public.brands, public.warranty_reference, public.return_policy_reference,
              public.card_benefits, public.reference_reviews from anon, authenticated;
grant select on public.categories, public.brands, public.warranty_reference, public.return_policy_reference,
                public.card_benefits to authenticated;
grant all on public.categories, public.brands, public.warranty_reference, public.return_policy_reference,
             public.card_benefits, public.reference_reviews to service_role;

create policy categories_read on public.categories for select to authenticated using (true);
create policy brands_read on public.brands for select to authenticated using (true);
create policy warranty_reference_read on public.warranty_reference for select to authenticated
  using (review_status = 'published');
create policy return_policy_reference_read on public.return_policy_reference for select to authenticated
  using (review_status = 'published');
create policy card_benefits_read on public.card_benefits for select to authenticated
  using (review_status = 'published');
-- reference_reviews: no client policy => default deny.
