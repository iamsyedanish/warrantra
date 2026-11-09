/**
 * Embedded-Postgres test harness (PGlite) that emulates the parts of Supabase the
 * migrations depend on: roles, auth schema (users, identities, uid()/jwt()) and
 * storage schema (buckets, objects, foldername()). It lets us run every migration
 * and exercise RLS with two different authenticated users without Docker.
 *
 * It is a faithful-enough shim for authorization tests; it is NOT a substitute for
 * running `supabase db reset` + pgTAP against the real stack before release.
 */
import { PGlite } from '@electric-sql/pglite';
import { pg_trgm } from '@electric-sql/pglite/contrib/pg_trgm';
import { readdirSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const MIGRATIONS_DIR = join(here, '..', '..', 'supabase', 'migrations');
export const SEED_FILE = join(here, '..', '..', 'supabase', 'seed.sql');

const SUPABASE_SHIM = `
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
grant anon, authenticated, service_role to current_user;
grant usage on schema public to anon, authenticated, service_role;

create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  email_confirmed_at timestamptz,
  created_at timestamptz not null default now()
);
create table auth.identities (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  provider text not null,
  created_at timestamptz not null default now()
);
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant execute on function auth.jwt() to anon, authenticated, service_role;

create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role;
create table storage.buckets (
  id text primary key, name text not null, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text not null,
  owner uuid,
  created_at timestamptz default now()
);
alter table storage.objects enable row level security;
grant select on storage.objects to authenticated;
grant all on storage.objects to service_role;
create or replace function storage.foldername(name text) returns text[] language sql immutable as $$
  select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1]
$$;
grant execute on function storage.foldername(text) to anon, authenticated, service_role;
`;

export function migrationFiles(): string[] {
  return readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql'))
    .sort();
}

/** A database with only the Supabase shim (no migrations), for testing the migration runner. */
export async function createShimDatabase(): Promise<PGlite> {
  const db = new PGlite({ extensions: { pg_trgm } });
  await db.exec(SUPABASE_SHIM);
  return db;
}

export async function createDatabase(opts: { seed?: boolean } = {}): Promise<PGlite> {
  const db = new PGlite({ extensions: { pg_trgm } });
  await db.exec(SUPABASE_SHIM);
  for (const file of migrationFiles()) {
    const sql = readFileSync(join(MIGRATIONS_DIR, file), 'utf8');
    try {
      await db.exec(sql);
    } catch (err) {
      const e = err as Error & { position?: string };
      throw new Error(`Migration ${file} failed: ${e.message}${e.position ? ` (position ${e.position})` : ''}`);
    }
  }
  if (opts.seed !== false) {
    await db.exec(readFileSync(SEED_FILE, 'utf8'));
  }
  return db;
}

/** Create an auth user (profile row is created by the trigger). */
export async function createUser(db: PGlite, email: string): Promise<string> {
  await db.exec('reset role');
  const res = await db.query<{ id: string }>(
    `insert into auth.users (email, email_confirmed_at) values ($1, now()) returning id`,
    [email],
  );
  const id = res.rows[0]!.id;
  await db.query(`insert into auth.identities (user_id, provider) values ($1, 'email')`, [id]);
  return id;
}

/** Run `fn` as an authenticated user (RLS applies), inside a transaction that is rolled back on error. */
export async function asUser<T>(db: PGlite, userId: string, fn: (tx: PGlite) => Promise<T>): Promise<T> {
  await db.exec('reset role');
  await db.query(`select set_config('request.jwt.claim.sub', $1, false)`, [userId]);
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ sub: userId, role: 'authenticated' })]);
  await db.exec('set role authenticated');
  try {
    return await fn(db);
  } finally {
    await db.exec('reset role');
    await db.query(`select set_config('request.jwt.claim.sub', '', false)`);
  }
}

export async function asService<T>(db: PGlite, fn: (tx: PGlite) => Promise<T>): Promise<T> {
  await db.exec('reset role');
  await db.query(`select set_config('request.jwt.claim.sub', '', false)`);
  await db.exec('set role service_role');
  try {
    return await fn(db);
  } finally {
    await db.exec('reset role');
  }
}

export async function expectError(p: Promise<unknown>, match: RegExp | string): Promise<string> {
  try {
    await p;
  } catch (err) {
    const msg = (err as Error).message;
    const ok = typeof match === 'string' ? msg.includes(match) : match.test(msg);
    if (!ok) throw new Error(`Expected error matching ${match} but got: ${msg}`);
    return msg;
  }
  throw new Error(`Expected error matching ${match} but the operation succeeded`);
}
