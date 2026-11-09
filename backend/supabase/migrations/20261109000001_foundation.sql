-- =============================================================================
-- Warrantra v4 — 0001 Foundation: schemas, privileges, domains, helper functions
-- =============================================================================
-- Conventions used across all migrations
--   * UUID primary keys, timestamptz timestamps, numeric(12,2) money (never float).
--   * Every user-owned parent exposes UNIQUE (id, user_id) so children can use
--     composite foreign keys (parent_id, user_id) — ownership is enforced by the
--     database, not only by the API or Flutter client.
--   * RLS is enabled on every table in `public`. A table with RLS and no allowing
--     policy is default-deny for anon/authenticated. service_role bypasses RLS, so
--     every server-side RPC performs its own authorization.
--   * Grants are explicit. Functions are NOT executable by PUBLIC by default.
--   * Internal helpers live in schema `app_private`, which is not exposed via the
--     Supabase Data API.
-- =============================================================================

create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;

create schema if not exists app_private;
revoke all on schema app_private from public;
grant usage on schema app_private to service_role;
-- authenticated needs USAGE to evaluate RLS helper functions referenced in policies.
grant usage on schema app_private to authenticated;

-- Functions are executable by PUBLIC by default in PostgreSQL. Turn that off so
-- every RPC must be granted deliberately.
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema app_private revoke execute on functions from public;
-- Supabase grants table privileges to anon/authenticated by default; revoke and
-- grant table-by-table instead.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Domains
-- -----------------------------------------------------------------------------
-- Initial scope is USD/CAD/GBP (two minor units). Broader currencies require
-- explicit minor-unit handling before this domain is widened.
create domain public.currency_code as text
  check (value in ('USD', 'CAD', 'GBP'));

create domain public.money_amount as numeric(12, 2)
  check (value >= 0);

create domain public.country_code as text
  check (value in ('US', 'CA', 'GB'));

-- -----------------------------------------------------------------------------
-- Generic helpers
-- -----------------------------------------------------------------------------
create or replace function app_private.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Optimistic concurrency: every UPDATE increments `version`. Clients send the
-- version they read; the API filters on it so a stale write updates zero rows.
create or replace function app_private.bump_version()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' then
    new.version := coalesce(old.version, 0) + 1;
  end if;
  return new;
end;
$$;

create or replace function app_private.is_valid_timezone(p_tz text)
returns boolean
language sql
stable
as $$
  select p_tz is not null and exists (select 1 from pg_timezone_names where name = p_tz);
$$;

-- Per-user transaction-scoped advisory lock: serialises quota checks for one
-- account (two simultaneous uploads/scans cannot both pass a quota check).
create or replace function app_private.lock_user(p_user_id uuid, p_scope text)
returns void
language sql
as $$
  select pg_advisory_xact_lock(hashtextextended(p_scope || ':' || p_user_id::text, 7310));
$$;

create or replace function app_private.require_uid()
returns uuid
language plpgsql
stable
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  return v_uid;
end;
$$;

-- Add `months` to a date with PostgreSQL month-end clamping
-- (2024-01-31 + 1 month = 2024-02-29; 2023-01-31 + 1 month = 2023-02-28).
create or replace function app_private.add_months(p_date date, p_months integer)
returns date
language sql
immutable
as $$
  select (p_date + make_interval(months => p_months))::date;
$$;

-- Convert a local calendar date + local wall-clock time in an IANA zone into an
-- absolute instant. DST gaps/overlaps follow PostgreSQL's AT TIME ZONE rules.
create or replace function app_private.local_to_instant(p_date date, p_time time, p_tz text)
returns timestamptz
language sql
stable
as $$
  select (p_date + p_time) at time zone p_tz;
$$;

grant execute on function app_private.set_updated_at() to authenticated, service_role;
grant execute on function app_private.bump_version() to authenticated, service_role;
grant execute on function app_private.is_valid_timezone(text) to authenticated, service_role;
grant execute on function app_private.add_months(date, integer) to authenticated, service_role;
grant execute on function app_private.local_to_instant(date, time, text) to authenticated, service_role;
grant execute on function app_private.require_uid() to authenticated, service_role;
grant execute on function app_private.lock_user(uuid, text) to authenticated, service_role;
