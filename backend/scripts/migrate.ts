/**
 * Database migration runner.
 *
 *   npm run db:migrate            apply every pending file in supabase/migrations (in order)
 *   npm run db:migrate -- --seed  ...then run supabase/seed.sql (idempotent)
 *   npm run db:migrate -- --dry-run
 *   npm run db:status             show applied / pending / changed files
 *   npm run db:seed               run supabase/seed.sql only
 *
 * Connects with DATABASE_URL (Supabase → Connect → Direct connection or Session
 * pooler, port 5432). Each file runs in its own transaction; a failure rolls that
 * file back and stops the run. A session advisory lock prevents two runs at once.
 *
 * Applied versions are recorded in supabase_migrations.schema_migrations (the same
 * table the Supabase CLI uses, so `supabase db push` stays compatible). SHA-256
 * checksums are kept alongside, so editing an already-applied file is detected.
 */
import 'dotenv/config';
import { createHash } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const here = dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = join(here, '..', 'supabase', 'migrations');
const SEED_FILE = join(here, '..', 'supabase', 'seed.sql');
const LOCK_KEY = 7_310_420_001;

interface MigrationFile {
  version: string;
  name: string;
  file: string;
  sql: string;
  checksum: string;
}

const args = new Set(process.argv.slice(2));
const command = args.has('status') ? 'status' : args.has('seed-only') ? 'seed' : 'migrate';
const dryRun = args.has('--dry-run');
const withSeed = args.has('--seed');
const allowChanged = args.has('--allow-changed');

function fail(message: string): never {
  console.error(`\n✖ ${message}`);
  process.exit(1);
}

function loadMigrations(): MigrationFile[] {
  return readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql'))
    .sort()
    .map((file) => {
      const m = /^(\d+)_(.+)\.sql$/.exec(file);
      if (!m) fail(`Migration file name must look like <version>_<name>.sql: ${file}`);
      const sql = readFileSync(join(MIGRATIONS_DIR, file), 'utf8');
      return { version: m[1]!, name: m[2]!, file, sql, checksum: createHash('sha256').update(sql).digest('hex') };
    });
}

function connectionConfig(): pg.ClientConfig {
  const url = process.env.DATABASE_URL;
  if (!url) {
    fail('DATABASE_URL is not set. Add it to backend/.env (Supabase → Connect → Direct connection / Session pooler).');
  }
  const parsed = new URL(url);
  if (parsed.port === '6543') {
    fail('DATABASE_URL points at the transaction pooler (port 6543). Use the direct connection or session pooler (port 5432) for migrations.');
  }
  const local = ['localhost', '127.0.0.1', '::1'].includes(parsed.hostname);
  const sslDisabled = parsed.searchParams.get('sslmode') === 'disable';
  let ssl: pg.ClientConfig['ssl'] = false;
  if (!local && !sslDisabled) {
    const ca = process.env.DATABASE_SSL_CA;
    ssl = ca ? { ca: readFileSync(ca, 'utf8'), rejectUnauthorized: true } : { rejectUnauthorized: false };
    if (!ca) console.warn('! TLS certificate not verified. Set DATABASE_SSL_CA to the Supabase CA file (Dashboard → Database → SSL) to verify it.');
  }
  // Strip sslmode so pg does not override the ssl object above.
  parsed.searchParams.delete('sslmode');
  return { connectionString: parsed.toString(), ssl, application_name: 'warrantra-migrate', statement_timeout: 0 };
}

async function ensureTables(client: pg.Client) {
  await client.query(`
    create schema if not exists supabase_migrations;
    create table if not exists supabase_migrations.schema_migrations (
      version text primary key,
      statements text[],
      name text
    );
    create table if not exists supabase_migrations.warrantra_checksums (
      version text primary key,
      checksum text not null,
      applied_at timestamptz not null default now(),
      duration_ms integer
    );
  `);
}

async function appliedState(client: pg.Client) {
  const versions = await client.query<{ version: string }>('select version from supabase_migrations.schema_migrations');
  const sums = await client.query<{ version: string; checksum: string; applied_at: Date }>(
    'select version, checksum, applied_at from supabase_migrations.warrantra_checksums',
  );
  return {
    applied: new Set(versions.rows.map((r) => r.version)),
    checksums: new Map(sums.rows.map((r) => [r.version, r])),
  };
}

async function checkSupabaseSchemas(client: pg.Client) {
  const r = await client.query<{ auth: boolean; storage: boolean }>(`
    select exists (select 1 from information_schema.tables where table_schema = 'auth' and table_name = 'users') as auth,
           exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'objects') as storage`);
  if (!r.rows[0]!.auth || !r.rows[0]!.storage) {
    fail('This database has no Supabase auth/storage schemas. Run migrations against a Supabase project (hosted or `supabase start`).');
  }
}

async function runSeed(client: pg.Client) {
  process.stdout.write('→ seed.sql ... ');
  await client.query('begin');
  try {
    await client.query(readFileSync(SEED_FILE, 'utf8'));
    await client.query('commit');
    console.log('done');
  } catch (err) {
    await client.query('rollback');
    fail(`Seed failed: ${(err as Error).message}`);
  }
}

async function verifyRls(client: pg.Client) {
  const r = await client.query<{ tablename: string }>(
    `select tablename from pg_tables where schemaname = 'public' and not rowsecurity order by 1`,
  );
  if (r.rows.length) fail(`RLS is disabled on: ${r.rows.map((x) => x.tablename).join(', ')}`);
  console.log('✔ Row-level security is enabled on every public table.');
}

async function main() {
  const migrations = loadMigrations();
  const client = new pg.Client(connectionConfig());
  await client.connect();

  try {
    await ensureTables(client);
    const { applied, checksums } = await appliedState(client);

    const changed = migrations.filter((m) => applied.has(m.version) && checksums.has(m.version) && checksums.get(m.version)!.checksum !== m.checksum);
    const pending = migrations.filter((m) => !applied.has(m.version));
    const unknown = [...applied].filter((v) => !migrations.some((m) => m.version === v));

    if (command === 'status') {
      for (const m of migrations) {
        const state = !applied.has(m.version) ? 'pending ' : changed.includes(m) ? 'CHANGED ' : 'applied ';
        const at = checksums.get(m.version)?.applied_at;
        console.log(`${state} ${m.file}${at ? `  (${at.toISOString()})` : ''}`);
      }
      for (const v of unknown) console.log(`missing  ${v} (applied in the database but no file here)`);
      console.log(`\n${migrations.length - pending.length} applied, ${pending.length} pending${changed.length ? `, ${changed.length} changed` : ''}.`);
      return;
    }

    if (command === 'seed') {
      await runSeed(client);
      return;
    }

    if (changed.length && !allowChanged) {
      fail(`These already-applied migrations were edited:\n  ${changed.map((m) => m.file).join('\n  ')}\n` +
           'Never edit an applied migration; add a new file instead. (Override with --allow-changed.)');
    }
    if (unknown.length) console.warn(`! Database has versions with no matching file: ${unknown.join(', ')}`);

    if (pending.length === 0) {
      console.log('✔ Database is up to date. Nothing to migrate.');
    } else {
      // Only one migration run at a time, across all machines.
      const lock = await client.query<{ ok: boolean }>('select pg_try_advisory_lock($1) as ok', [LOCK_KEY]);
      if (!lock.rows[0]!.ok) fail('Another migration run holds the lock. Wait for it to finish.');
      await checkSupabaseSchemas(client);

      console.log(`${dryRun ? 'Would apply' : 'Applying'} ${pending.length} migration(s):`);
      for (const m of pending) {
        if (dryRun) {
          console.log(`  · ${m.file}`);
          continue;
        }
        process.stdout.write(`→ ${m.file} ... `);
        const started = Date.now();
        await client.query('begin');
        try {
          await client.query(m.sql);
          await client.query('insert into supabase_migrations.schema_migrations (version, name, statements) values ($1, $2, $3)',
            [m.version, m.name, [m.sql]]);
          await client.query(
            `insert into supabase_migrations.warrantra_checksums (version, checksum, duration_ms) values ($1, $2, $3)
             on conflict (version) do update set checksum = excluded.checksum, applied_at = now(), duration_ms = excluded.duration_ms`,
            [m.version, m.checksum, Date.now() - started]);
          await client.query('commit');
          console.log(`ok (${Date.now() - started} ms)`);
        } catch (err) {
          await client.query('rollback');
          const e = err as Error & { position?: string; detail?: string; hint?: string };
          console.log('FAILED');
          fail(`${m.file} rolled back: ${e.message}${e.position ? ` (at character ${e.position})` : ''}` +
               `${e.detail ? `\n  detail: ${e.detail}` : ''}${e.hint ? `\n  hint: ${e.hint}` : ''}\nLater migrations were not applied.`);
        }
      }
      await client.query('select pg_advisory_unlock($1)', [LOCK_KEY]);
      if (dryRun) return;
      console.log(`✔ Applied ${pending.length} migration(s).`);
    }

    // Record checksums for versions applied earlier by the Supabase CLI.
    for (const m of migrations) {
      if (applied.has(m.version) && !checksums.has(m.version)) {
        await client.query('insert into supabase_migrations.warrantra_checksums (version, checksum) values ($1, $2) on conflict do nothing',
          [m.version, m.checksum]);
      }
    }

    if (withSeed) await runSeed(client);
    await verifyRls(client);
  } finally {
    await client.end();
  }
}

main().catch((err) => fail((err as Error).message));
