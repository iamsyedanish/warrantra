import { randomUUID } from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';
import rateLimit, { ipKeyGenerator } from 'express-rate-limit';
import { ZodError } from 'zod';
import { AppError } from '../lib/errors.js';
import { logger } from '../lib/logger.js';

export function requestId(req: Request, res: Response, next: NextFunction): void {
  const incoming = req.header('X-Request-Id');
  req.id = incoming && /^[A-Za-z0-9-]{8,64}$/.test(incoming) ? incoming : randomUUID();
  res.setHeader('X-Request-Id', req.id);
  next();
}

/**
 * Private data must never be cached by shared caches, and must not be reused
 * across accounts on the same device (account switching clears private cache).
 */
export function noStore(_req: Request, res: Response, next: NextFunction): void {
  res.setHeader('Cache-Control', 'no-store, private');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('Vary', 'Authorization');
  next();
}

export function accessLog(req: Request, res: Response, next: NextFunction): void {
  const start = process.hrtime.bigint();
  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - start) / 1e6;
    // Route pattern only — never query strings (may contain tokens) or bodies.
    logger.info({ reqId: req.id, method: req.method, route: req.route?.path ?? req.baseUrl, status: res.statusCode, ms: Math.round(ms) }, 'request');
  });
  next();
}

export function notFoundHandler(req: Request, res: Response): void {
  res.status(404).json({ error: { code: 'route_not_found', message: 'Route not found', request_id: req.id } });
}

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export function errorHandler(err: unknown, req: Request, res: Response, _next: NextFunction): void {
  let appErr: AppError;
  if (err instanceof AppError) {
    appErr = err;
  } else if (err instanceof ZodError) {
    appErr = new AppError(400, 'validation_failed', 'Invalid request', {
      issues: err.issues.map((i) => ({ path: i.path.join('.'), message: i.message })),
    });
  } else if ((err as { type?: string })?.type === 'entity.too.large') {
    appErr = new AppError(413, 'payload_too_large', 'Request body too large');
  } else if ((err as { type?: string })?.type === 'entity.parse.failed') {
    appErr = new AppError(400, 'invalid_json', 'Malformed JSON body');
  } else {
    appErr = new AppError(500, 'internal_error', 'Something went wrong');
  }
  if (appErr.status >= 500) {
    logger.error({ reqId: req.id, err, code: appErr.code }, 'request failed');
  } else {
    logger.debug({ reqId: req.id, code: appErr.code, status: appErr.status }, 'request rejected');
  }
  res.status(appErr.status).json({
    error: { code: appErr.code, message: appErr.message, details: appErr.details, request_id: req.id },
  });
}

const keyByUserOrIp = (req: Request) => req.auth?.userId ?? ipKeyGenerator(req.ip ?? '0.0.0.0');

/** In-process limits; use a shared store (e.g. Redis) when running several instances. */
export const limits = {
  auth: rateLimit({ windowMs: 15 * 60_000, limit: 30, standardHeaders: 'draft-7', legacyHeaders: false }),
  publicForms: rateLimit({ windowMs: 60 * 60_000, limit: 10, standardHeaders: 'draft-7', legacyHeaders: false }),
  api: rateLimit({ windowMs: 60_000, limit: 240, keyGenerator: keyByUserOrIp, standardHeaders: 'draft-7', legacyHeaders: false }),
  uploads: rateLimit({ windowMs: 60 * 60_000, limit: 120, keyGenerator: keyByUserOrIp, standardHeaders: 'draft-7', legacyHeaders: false }),
  ai: rateLimit({ windowMs: 60 * 60_000, limit: 30, keyGenerator: keyByUserOrIp, standardHeaders: 'draft-7', legacyHeaders: false }),
  exports: rateLimit({ windowMs: 24 * 60 * 60_000, limit: 10, keyGenerator: keyByUserOrIp, standardHeaders: 'draft-7', legacyHeaders: false }),
};
