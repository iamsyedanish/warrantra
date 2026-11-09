import type { NextFunction, Request, RequestHandler, Response } from 'express';
import { z } from 'zod';
import { badRequest } from './errors.js';

/** Wrap async handlers so rejected promises reach the error middleware. */
export const asyncHandler =
  (fn: (req: Request, res: Response, next: NextFunction) => Promise<unknown>): RequestHandler =>
  (req, res, next) => {
    fn(req, res, next).catch(next);
  };

export const PaginationQuery = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(25),
  offset: z.coerce.number().int().min(0).max(100_000).default(0),
});
export type Pagination = z.infer<typeof PaginationQuery>;

export const UuidParam = z.object({ id: z.string().uuid() });

export function parseOrThrow<T extends z.ZodType>(schema: T, data: unknown, where: 'body' | 'query' | 'params'): z.infer<T> {
  const parsed = schema.safeParse(data);
  if (!parsed.success) {
    throw badRequest('validation_failed', `Invalid ${where}`, {
      issues: parsed.error.issues.map((i) => ({ path: i.path.join('.'), message: i.message, code: i.code })),
    });
  }
  return parsed.data;
}

/** Idempotency key header used by every create endpoint (client-generated UUID/ULID). */
export function idempotencyKey(req: Request, required = true): string | undefined {
  const key = req.header('Idempotency-Key') ?? undefined;
  if (!key) {
    if (required) throw badRequest('idempotency_key_required', 'Send an Idempotency-Key header');
    return undefined;
  }
  if (!/^[A-Za-z0-9_-]{8,128}$/.test(key)) throw badRequest('invalid_idempotency_key');
  return key;
}

/** Expected optimistic-concurrency version from If-Match: "<version>". */
export function expectedVersion(req: Request): number | undefined {
  const h = req.header('If-Match');
  if (!h) return undefined;
  const n = Number(h.replace(/"/g, ''));
  if (!Number.isInteger(n) || n < 1) throw badRequest('invalid_if_match');
  return n;
}
