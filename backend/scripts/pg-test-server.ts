/** Dev aid: serve an empty Supabase-shim Postgres on a TCP port (for testing db:migrate without Docker). */
import { PGLiteSocketServer } from '@electric-sql/pglite-socket';
import { createShimDatabase } from '../tests/sql/harness.js';

const port = Number(process.env.PG_TEST_PORT ?? 55432);
const db = await createShimDatabase();
const server = new PGLiteSocketServer({ db, port, host: '127.0.0.1' });
await server.start();
console.log(`shim postgres listening on 127.0.0.1:${port}`);
