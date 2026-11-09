/**
 * Models: table-level data access. Each factory binds a repository to a client —
 * pass `req.auth.db` (RLS-scoped) for user requests, `serviceClient()` only in
 * workers/webhooks/admin code that performs its own authorization.
 */
import type { Db } from '../lib/supabase.js';
import { Repository, type Row } from './base.model.js';
import { check } from '../lib/errors.js';

export const Profiles = (db: Db) => new Repository(db, 'profiles');
export const Devices = (db: Db) =>
  new Repository(db, 'devices', 'id, installation_id, platform, push_provider, permission_state, token_state, app_version, locale, timezone, last_seen_at, created_at');
export const PaymentCards = (db: Db) => new Repository(db, 'payment_cards');
export const PurchaseGroups = (db: Db) => new Repository(db, 'purchase_groups');
export const ReceiptLines = (db: Db) => new Repository(db, 'receipt_lines');
export const Items = (db: Db) => new Repository(db, 'items');
export const Warranties = (db: Db) => new Repository(db, 'warranties');
export const ReturnWindows = (db: Db) => new Repository(db, 'return_windows');
export const Registrations = (db: Db) => new Repository(db, 'registrations');
export const Attachments = (db: Db) => new Repository(db, 'attachments');
export const Reminders = (db: Db) => new Repository(db, 'reminders');
export const ScanJobs = (db: Db) => new Repository(db, 'scan_jobs');
export const Claims = (db: Db) => new Repository(db, 'claims');
export const ClaimPacks = (db: Db) => new Repository(db, 'claim_packs');
export const Outcomes = (db: Db) => new Repository(db, 'outcomes');
export const Entitlements = (db: Db) => new Repository(db, 'entitlements');
export const BillingEvents = (db: Db) => new Repository(db, 'billing_events');
export const ExportJobs = (db: Db) => new Repository(db, 'export_jobs');
export const DeletionRequests = (db: Db) => new Repository(db, 'deletion_requests');
export const Jobs = (db: Db) => new Repository(db, 'jobs');
export const SupportTickets = (db: Db) => new Repository(db, 'support_tickets');
export const Workspaces = (db: Db) => new Repository(db, 'workspaces');
export const Locations = (db: Db) => new Repository(db, 'locations');
export const ServiceRecords = (db: Db) => new Repository(db, 'service_records');
export const MaintenanceTasks = (db: Db) => new Repository(db, 'maintenance_tasks');
export const CaptureDrafts = (db: Db) => new Repository(db, 'capture_drafts');
export const Partners = (db: Db) => new Repository(db, 'partners');

/** Link-table helpers (composite primary keys). */
export async function linkRows(db: Db, table: string, rows: Row[]): Promise<void> {
  if (rows.length === 0) return;
  check(await db.from(table).upsert(rows, { ignoreDuplicates: true }));
}

export async function unlinkRow(db: Db, table: string, match: Record<string, string>): Promise<number> {
  const data = check(await db.from(table).delete().match(match).select());
  return (data as unknown[]).length;
}
