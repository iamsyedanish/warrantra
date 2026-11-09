import type { NextFunction, Request, Response } from 'express';
import { env } from '../config/env.js';
import { forbidden, unauthorized } from '../lib/errors.js';
import { serviceClient, userClient } from '../lib/supabase.js';

/**
 * Verifies the Supabase access token and binds a user-scoped client. Identity is
 * ONLY ever taken from the verified token — never from a request-body user_id.
 */
export async function requireAuth(req: Request, _res: Response, next: NextFunction): Promise<void> {
  try {
    const header = req.header('Authorization') ?? '';
    const match = /^Bearer\s+(.+)$/i.exec(header);
    if (!match) throw unauthorized();
    const token = match[1]!.trim();

    const { data, error } = await serviceClient().auth.getClaims(token);
    if (error || !data?.claims?.sub) throw unauthorized('invalid_token', 'Session expired or invalid');
    const claims = data.claims as unknown as Record<string, unknown>;
    if (claims.role !== 'authenticated') throw unauthorized('invalid_token');

    req.auth = { userId: String(claims.sub), token, claims, db: userClient(token) };
    next();
  } catch (err) {
    next(err);
  }
}

/** Optional auth: attaches context when a valid token is present. */
export async function optionalAuth(req: Request, res: Response, next: NextFunction): Promise<void> {
  if (!req.header('Authorization')) return next();
  return requireAuth(req, res, next);
}

/**
 * Sensitive operations (account deletion, identity linking, email change) require
 * a recent sign-in. The client re-authenticates and sends the fresh token.
 */
export function requireRecentAuth(req: Request, _res: Response, next: NextFunction): void {
  const iat = Number(req.auth?.claims.iat ?? 0);
  const ageSeconds = Math.floor(Date.now() / 1000) - iat;
  if (!iat || ageSeconds > env().REAUTH_MAX_AGE_SECONDS) {
    return next(forbidden('reauthentication_required', 'Please sign in again to continue'));
  }
  next();
}

export function authOf(req: Request) {
  if (!req.auth) throw unauthorized();
  return req.auth;
}
