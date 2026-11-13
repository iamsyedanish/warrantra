/**
 * Worker process: a database-backed queue (jobs table, FOR UPDATE SKIP LOCKED)
 * plus an in-process scheduler for periodic tasks. Several workers can run
 * concurrently; locks expire so crashed workers' jobs are retried.
 */
import { env } from '../config/env.js';
import { check } from '../lib/errors.js';
import { logger } from '../lib/logger.js';
import { serviceClient } from '../lib/supabase.js';
import { processBillingEvent, reconcileUser } from '../services/billing/billing.service.js';
import { completeUpload } from '../services/attachment.service.js';
import { purgeUserFromBackup, runStorageBackup } from '../services/backup.service.js';
import { processInbound } from '../services/capture.service.js';
import { runDeletion } from '../services/deletion.service.js';
import { buildExport } from '../services/export.service.js';
import { heartbeat } from '../services/ops.service.js';
import { computeSnapshot } from '../services/profitability/profitability.service.js';
import { queueMonthlyDigests } from '../services/reminder.service.js';
import { processScanJob } from '../services/scan.service.js';
import { BUCKETS } from '../lib/supabase.js';
import { retentionPurge, runPeriodicTask, SCHEDULE } from './periodic.js';

type Job = { id: string; kind: string; payload: Record<string, any>; attempts: number; max_attempts: number };

/** Payload keys that may carry receipt contents and are wiped once a job finishes. */
const SENSITIVE_PAYLOAD_KEYS: Record<string, string[]> = { scan_process: ['ocr_text'], email_ingest: ['attachments'] };

const HANDLERS: Record<string, (p: Record<string, any>) => Promise<unknown>> = {
  scan_process: (p) => processScanJob(p as { scan_job_id: string; ocr_text: string | null }),
  export_build: (p) => buildExport(p.export_job_id),
  account_deletion: (p) => runDeletion(p.deletion_request_id),
  billing_process: (p) => processBillingEvent(p.billing_event_id),
  billing_reconcile: (p) => reconcileUser(p.user_id),
  email_ingest: (p) => processInbound(p as never),
  storage_backup: async (p) => {
    // Nothing can have been backed up when no backup target is configured.
    if (!env().BACKUP_S3_BUCKET || !env().BACKUP_S3_ACCESS_KEY_ID) return { skipped: 'backup_not_configured' };
    return p.purge_user_id ? purgeUserFromBackup(p.purge_user_id) : runStorageBackup();
  },
  profitability_snapshot: (p) => computeSnapshot(p.month),
  monthly_digest: () => queueMonthlyDigests(),
  retention_purge: () => retentionPurge(),
  upload_verify: async (p) => {
    try {
      return await completeUpload(p.attachment_id);
    } catch (err) {
      // Object not uploaded yet: leave it; the reservation cleanup expires it after 1 hour.
      if ((err as { code?: string }).code === 'upload_not_found') return { pending: true };
      throw err;
    }
  },
  maintenance: async (p) => {
    if (p.task === 'delete_attachment') {
      const svc = serviceClient();
      const att = check(await svc.from('attachments').select('storage_path').eq('id', p.attachment_id).maybeSingle()) as { storage_path: string } | null;
      if (!att) return { gone: true };
      const rm = await svc.storage.from(BUCKETS.files).remove([att.storage_path]);
      if (rm.error) throw new Error('storage_remove_failed');
      check(await svc.from('attachments').delete().eq('id', p.attachment_id));
      return { deleted: true };
    }
    return { skipped: p.task };
  },
};

async function runJob(job: Job) {
  const svc = serviceClient();
  const handler = HANDLERS[job.kind];
  try {
    if (!handler) throw new Error(`no_handler:${job.kind}`);
    const result = await handler(job.payload);
    await svc.rpc('worker_finish_job', { p_job_id: job.id, p_success: true, p_result: (result ?? null) as never });
  } catch (err) {
    logger.warn({ jobId: job.id, kind: job.kind, attempts: job.attempts, err }, 'job failed');
    await svc.rpc('worker_finish_job', { p_job_id: job.id, p_success: false, p_error: (err as Error).message?.slice(0, 500) ?? 'error' });
  } finally {
    const keys = SENSITIVE_PAYLOAD_KEYS[job.kind];
    if (keys) {
      const { data } = await svc.from('jobs').select('state, payload').eq('id', job.id).maybeSingle();
      // Keep the payload while a retry is pending; wipe it once the job is terminal.
      if (data && ['succeeded', 'dead', 'cancelled'].includes(String(data.state))) {
        const cleaned = { ...(data.payload as Record<string, unknown>) };
        for (const k of keys) delete cleaned[k];
        await svc.from('jobs').update({ payload: cleaned }).eq('id', job.id);
      }
    }
  }
}

let stopping = false;

async function pollOnce(): Promise<number> {
  const jobs = check(await serviceClient().rpc('worker_claim_jobs', {
    p_kinds: Object.keys(HANDLERS), p_worker: env().WORKER_NAME, p_batch: 10,
  })) as Job[];
  await Promise.all(jobs.map(runJob));
  return jobs.length;
}

export async function startWorker() {
  logger.info({ worker: env().WORKER_NAME }, 'worker started');
  const lastRun = new Map<string, number>();
  let lastDigestMonth = '';
  while (!stopping) {
    try {
      const n = await pollOnce();
      const now = Date.now();
      for (const s of SCHEDULE) {
        if (now - (lastRun.get(s.task) ?? 0) >= s.everyMs) {
          lastRun.set(s.task, now);
          runPeriodicTask(s.task).catch((err) => logger.warn({ err, task: s.task }, 'periodic task failed'));
        }
      }
      const d = new Date();
      const month = d.toISOString().slice(0, 7);
      if (d.getUTCDate() === 1 && d.getUTCHours() >= 14 && lastDigestMonth !== month) {
        lastDigestMonth = month;
        runPeriodicTask('monthly_digest').catch((err) => logger.warn({ err }, 'digest failed'));
      }
      await heartbeat(env().WORKER_NAME, { last_batch: n });
      if (n === 0) await new Promise((r) => setTimeout(r, env().WORKER_POLL_MS));
    } catch (err) {
      logger.error({ err }, 'worker loop error');
      await new Promise((r) => setTimeout(r, env().WORKER_POLL_MS));
    }
  }
}

process.on('SIGTERM', () => { stopping = true; });
process.on('SIGINT', () => { stopping = true; });

if (import.meta.url === `file://${process.argv[1]}`) {
  void startWorker();
}
