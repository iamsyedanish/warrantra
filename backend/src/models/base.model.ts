import { check, checkFound, conflict } from '../lib/errors.js';
import type { Db } from '../lib/supabase.js';

export type Row = Record<string, unknown>;

export interface ListOptions {
  limit?: number;
  offset?: number;
  orderBy?: string;
  ascending?: boolean;
  eq?: Record<string, string | number | boolean | null>;
}

/**
 * Generic repository over a single table. With a user-scoped client every query
 * is additionally constrained by RLS; ownership is never taken from input.
 */
export class Repository<T extends Row = Row> {
  constructor(
    protected readonly db: Db,
    protected readonly table: string,
    protected readonly columns = '*',
  ) {}

  async list(opts: ListOptions = {}): Promise<T[]> {
    let q = this.db.from(this.table).select(this.columns);
    for (const [k, v] of Object.entries(opts.eq ?? {})) {
      q = v === null ? q.is(k, null) : q.eq(k, v);
    }
    if (opts.orderBy) q = q.order(opts.orderBy, { ascending: opts.ascending ?? false });
    const limit = opts.limit ?? 50;
    const offset = opts.offset ?? 0;
    q = q.range(offset, offset + limit - 1);
    return check(await q) as unknown as T[];
  }

  async get(id: string, code = 'not_found'): Promise<T> {
    return checkFound(await this.db.from(this.table).select(this.columns).eq('id', id).maybeSingle(), code) as unknown as T;
  }

  async find(id: string): Promise<T | null> {
    return check(await this.db.from(this.table).select(this.columns).eq('id', id).maybeSingle()) as unknown as T | null;
  }

  async insert(values: Row): Promise<T> {
    return check(await this.db.from(this.table).insert(values).select(this.columns).single()) as unknown as T;
  }

  /**
   * Update with optional optimistic concurrency. A stale `expectedVersion`
   * updates zero rows and is reported as a conflict.
   */
  async update(id: string, patch: Row, expectedVersion?: number, code = 'not_found'): Promise<T> {
    let q = this.db.from(this.table).update(patch).eq('id', id);
    if (expectedVersion !== undefined) q = q.eq('version', expectedVersion);
    const data = check(await q.select(this.columns).maybeSingle()) as unknown as T | null;
    if (!data) {
      if (expectedVersion !== undefined && (await this.find(id))) {
        throw conflict('version_conflict', 'This record changed since you loaded it. Reload and try again.');
      }
      throw checkFound({ data: null, error: null }, code);
    }
    return data;
  }

  async remove(id: string, code = 'not_found'): Promise<void> {
    const data = check(await this.db.from(this.table).delete().eq('id', id).select('id'));
    if (!data || (data as unknown[]).length === 0) throw checkFound({ data: null, error: null }, code);
  }
}

export async function rpc<T = unknown>(db: Db, fn: string, args: Record<string, unknown> = {}): Promise<T> {
  return check(await db.rpc(fn, args)) as T;
}
