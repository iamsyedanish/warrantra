/** Apply every migration + seed to an embedded Postgres and report the first failure. */
import { createDatabase, migrationFiles } from '../tests/sql/harness.js';

const files = migrationFiles();
const db = await createDatabase();
const tables = await db.query<{ n: number }>(`select count(*)::int as n from pg_tables where schemaname = 'public'`);
const noRls = await db.query<{ tablename: string }>(
  `select tablename from pg_tables where schemaname = 'public' and not rowsecurity order by 1`,
);
console.log(`Applied ${files.length} migrations; ${tables.rows[0]!.n} public tables.`);
if (noRls.rows.length) {
  console.error('Tables without RLS:', noRls.rows.map((r) => r.tablename).join(', '));
  process.exit(1);
}
console.log('RLS enabled on every public table.');
await db.close();
