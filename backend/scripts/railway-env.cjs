/**
 * Copy runtime configuration from backend/.env to the Railway services without
 * printing any value (values are passed on stdin). Usage:
 *   node scripts/railway-env.cjs <public-base-url>
 * DATABASE_URL / DATABASE_SSL_CA are not copied: they are only for running migrations.
 */
const { execFileSync } = require('node:child_process');
const { readFileSync } = require('node:fs');
const { parse } = require('dotenv');

const publicUrl = process.argv[2] || '';
const env = parse(readFileSync(require('node:path').join(__dirname, '..', '.env')));
const SKIP = new Set(['DATABASE_URL', 'DATABASE_SSL_CA', 'NODE_ENV', 'PORT', 'PUBLIC_BASE_URL', 'TRUST_PROXY', 'LOG_LEVEL', 'WORKER_NAME', 'PROCESS_TYPE']);
const common = Object.fromEntries(Object.entries(env).filter(([k, v]) => !SKIP.has(k) && v !== ''));
Object.assign(common, { NODE_ENV: 'production', TRUST_PROXY: 'true', LOG_LEVEL: 'info' });
if (publicUrl) common.PUBLIC_BASE_URL = publicUrl;

const services = {
  'warrantra-api': { ...common, PROCESS_TYPE: 'api' },
  'warrantra-worker': { ...common, PROCESS_TYPE: 'worker', WORKER_NAME: 'railway-worker' },
};
for (const [service, vars] of Object.entries(services)) {
  for (const [key, value] of Object.entries(vars)) {
    execFileSync('railway', ['variable', 'set', key, '--stdin', '--service', service, '--skip-deploys'], { input: value, stdio: ['pipe', 'ignore', 'pipe'] });
  }
  console.log(`${service}: set ${Object.keys(vars).length} variables (${Object.keys(vars).sort().join(', ')})`);
}
