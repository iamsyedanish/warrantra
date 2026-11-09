/**
 * Supabase database backups do NOT include Storage objects. This service keeps
 * a separate, checksummed copy of every ready original in an S3-compatible
 * bucket, purges a deleted account's copies, and runs restore drills that prove
 * files are recoverable and that completed deletions are not resurrected.
 */
import { DeleteObjectsCommand, GetObjectCommand, HeadObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { env } from '../config/env.js';
import { AppError, check } from '../lib/errors.js';
import { sha256Hex } from '../lib/crypto.js';
import { logger } from '../lib/logger.js';
import { BUCKETS, serviceClient } from '../lib/supabase.js';

type Row = Record<string, unknown>;

let s3: S3Client | undefined;
function backupClient(): { client: S3Client; bucket: string } {
  const e = env();
  if (!e.BACKUP_S3_BUCKET || !e.BACKUP_S3_ACCESS_KEY_ID || !e.BACKUP_S3_SECRET_ACCESS_KEY) {
    throw new AppError(503, 'backup_not_configured', 'Storage backup target is not configured');
  }
  s3 ??= new S3Client({
    region: e.BACKUP_S3_REGION,
    endpoint: e.BACKUP_S3_ENDPOINT,
    forcePathStyle: Boolean(e.BACKUP_S3_ENDPOINT),
    credentials: { accessKeyId: e.BACKUP_S3_ACCESS_KEY_ID, secretAccessKey: e.BACKUP_S3_SECRET_ACCESS_KEY },
  });
  return { client: s3, bucket: e.BACKUP_S3_BUCKET };
}

const backupKey = (bucket: string, path: string) => `${bucket}/${path}`;

/** Incremental backup: copy ready originals not yet backed up (or changed). */
export async function runStorageBackup(batch = 500) {
  const { client, bucket } = backupClient();
  const svc = serviceClient();
  const run = check(await svc.from('backup_runs').insert({ kind: 'storage_objects', target: `s3://${bucket}` }).select('id').single()) as Row;
  let scanned = 0, copied = 0, bytes = 0, errors = 0;
  let lastError: string | null = null;

  const tombstoned = new Set(((check(await svc.from('deletion_tombstones').select('user_id')) as Row[]).map((t) => String(t.user_id))));
  for (let from = 0; ; from += batch) {
    const atts = check(await svc.from('attachments').select('id, user_id, storage_path, checksum_sha256, actual_byte_size')
      .eq('processing_state', 'ready').eq('deletion_state', 'active').order('created_at').range(from, from + batch - 1)) as Row[];
    if (atts.length === 0) break;
    const existing = check(await svc.from('backup_objects').select('storage_path, checksum_sha256').eq('bucket', BUCKETS.files)
      .in('storage_path', atts.map((a) => String(a.storage_path)))) as Row[];
    const known = new Map(existing.map((e) => [String(e.storage_path), String(e.checksum_sha256)]));
    for (const a of atts) {
      scanned++;
      if (tombstoned.has(String(a.user_id))) continue;
      if (known.get(String(a.storage_path)) === a.checksum_sha256) continue;
      try {
        const dl = await svc.storage.from(BUCKETS.files).download(String(a.storage_path));
        if (dl.error || !dl.data) throw new Error('download_failed');
        const buf = Buffer.from(await dl.data.arrayBuffer());
        const sum = sha256Hex(buf);
        if (a.checksum_sha256 && sum !== a.checksum_sha256) throw new Error('checksum_mismatch_at_source');
        const key = backupKey(BUCKETS.files, String(a.storage_path));
        await client.send(new PutObjectCommand({ Bucket: bucket, Key: key, Body: buf, ChecksumSHA256: Buffer.from(sum, 'hex').toString('base64'),
          ServerSideEncryption: env().BACKUP_S3_ENDPOINT ? undefined : 'AES256', Metadata: { sha256: sum } }));
        await svc.from('backup_objects').upsert({ bucket: BUCKETS.files, storage_path: a.storage_path, attachment_id: a.id, user_id: a.user_id,
          checksum_sha256: sum, byte_size: buf.length, backup_key: key, backed_up_at: new Date().toISOString(), purged_at: null });
        copied++;
        bytes += buf.length;
      } catch (err) {
        errors++;
        lastError = (err as Error).message.slice(0, 200);
        logger.warn({ attachmentId: a.id, err }, 'backup copy failed');
      }
    }
    if (atts.length < batch) break;
  }
  await svc.from('backup_runs').update({
    state: errors === 0 ? 'succeeded' : copied > 0 ? 'partial' : scanned === 0 ? 'succeeded' : 'failed',
    objects_scanned: scanned, objects_copied: copied, bytes_copied: bytes, error_count: errors, last_error: lastError,
    completed_at: new Date().toISOString(),
  }).eq('id', run.id as string);
  return { scanned, copied, bytes, errors };
}

/** Remove a deleted account's originals from the backup target. */
export async function purgeUserFromBackup(userId: string) {
  const { client, bucket } = backupClient();
  const svc = serviceClient();
  const rows = check(await svc.from('backup_objects').select('bucket, storage_path, backup_key').eq('user_id', userId).is('purged_at', null)) as Row[];
  for (let i = 0; i < rows.length; i += 1000) {
    const chunk = rows.slice(i, i + 1000);
    const res = await client.send(new DeleteObjectsCommand({ Bucket: bucket, Delete: { Objects: chunk.map((r) => ({ Key: String(r.backup_key) })), Quiet: true } }));
    if (res.Errors?.length) throw new AppError(502, 'backup_purge_failed', `${res.Errors.length} objects failed`);
    await svc.from('backup_objects').update({ purged_at: new Date().toISOString() }).eq('user_id', userId).in('storage_path', chunk.map((r) => String(r.storage_path)));
  }
  return { purged: rows.length };
}

/**
 * Restore drill (run against a restored/staging project): verify a sample of
 * backed-up objects byte-for-byte, replay deletion tombstones, and confirm no
 * tombstoned account or backup object survives. Records the outcome.
 */
export async function runRestoreDrill(opts: { sampleSize?: number; performedBy?: string } = {}) {
  const svc = serviceClient();
  const drill = check(await svc.from('restore_drills').insert({ performed_by: opts.performedBy ?? null }).select('id').single()) as Row;
  const checks: Array<{ name: string; passed: boolean; detail?: string }> = [];
  try {
    const { client, bucket } = backupClient();
    const sample = check(await svc.from('backup_objects').select('*').is('purged_at', null).limit(opts.sampleSize ?? 25)) as Row[];
    let ok = 0;
    for (const o of sample) {
      const head = await client.send(new HeadObjectCommand({ Bucket: bucket, Key: String(o.backup_key) })).catch(() => null);
      if (!head) continue;
      const obj = await client.send(new GetObjectCommand({ Bucket: bucket, Key: String(o.backup_key) }));
      const buf = Buffer.from(await obj.Body!.transformToByteArray());
      if (sha256Hex(buf) === o.checksum_sha256) ok++;
    }
    checks.push({ name: 'backup_objects_readable_and_checksums_match', passed: sample.length > 0 && ok === sample.length, detail: `${ok}/${sample.length}` });

    const unbacked = await svc.from('attachments').select('id', { count: 'exact', head: true }).eq('processing_state', 'ready').eq('deletion_state', 'active')
      .lt('verified_at', new Date(Date.now() - 2 * 86_400_000).toISOString());
    const backedCount = await svc.from('backup_objects').select('storage_path', { count: 'exact', head: true }).is('purged_at', null);
    checks.push({ name: 'backup_coverage', passed: (backedCount.count ?? 0) >= (unbacked.count ?? 0), detail: `${backedCount.count ?? 0} backed / ${unbacked.count ?? 0} older ready files` });

    const replayed = check(await svc.rpc('replay_deletion_tombstones')) as Row[];
    checks.push({ name: 'tombstones_replayed', passed: true, detail: `${replayed.length} resurrected accounts removed` });
    for (const r of replayed) await purgeUserFromBackup(String(r.user_id)).catch(() => undefined);

    const tomb = check(await svc.from('deletion_tombstones').select('user_id')) as Row[];
    const ids = tomb.map((t) => String(t.user_id));
    const survivors = ids.length ? (await svc.from('profiles').select('id', { count: 'exact', head: true }).in('id', ids)).count ?? 0 : 0;
    const backupSurvivors = ids.length ? (await svc.from('backup_objects').select('storage_path', { count: 'exact', head: true }).in('user_id', ids).is('purged_at', null)).count ?? 0 : 0;
    checks.push({ name: 'completed_deletions_not_resurrected', passed: survivors === 0 && backupSurvivors === 0, detail: `profiles=${survivors} backup_objects=${backupSurvivors}` });
  } catch (err) {
    checks.push({ name: 'drill_execution', passed: false, detail: (err as Error).message.slice(0, 200) });
  }
  const passed = checks.every((c) => c.passed);
  await svc.from('restore_drills').update({ completed_at: new Date().toISOString(), passed, checks }).eq('id', drill.id as string);
  return { drill_id: drill.id, passed, checks };
}
