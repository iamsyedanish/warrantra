/**
 * Restore drill (run against a RESTORED or staging project, never casually on production):
 *   npm run restore:drill
 * Verifies backed-up originals byte-for-byte, replays deletion tombstones, and
 * confirms no completed deletion was resurrected. Exit code 1 if any check fails.
 */
import { runRestoreDrill } from '../src/services/backup.service.js';

const result = await runRestoreDrill({ sampleSize: Number(process.env.DRILL_SAMPLE ?? 50) });
for (const c of result.checks) console.log(`${c.passed ? 'PASS' : 'FAIL'}  ${c.name}  ${c.detail ?? ''}`);
console.log(result.passed ? 'Restore drill passed.' : 'Restore drill FAILED.');
process.exit(result.passed ? 0 : 1);
