import './setup-env.js';
import type { NextFunction, Request, Response } from 'express';
import { describe, expect, it } from 'vitest';
import { requireRecentAuth } from '../../src/middleware/auth.js';

const now = () => Math.floor(Date.now() / 1000);

function run(claims: Record<string, unknown>) {
  let err: unknown = 'not-called';
  const next: NextFunction = (e?: unknown) => { err = e; };
  requireRecentAuth({ auth: { claims } } as unknown as Request, {} as Response, next);
  return err as { code?: string } | undefined;
}

describe('requireRecentAuth', () => {
  it('allows a fresh password sign-in', () => {
    expect(run({ iat: now(), amr: [{ method: 'password', timestamp: now() - 30 }] })).toBeUndefined();
  });

  it('refuses a refreshed token whose real sign-in was long ago', () => {
    // A token refresh renews iat; amr keeps the original sign-in time.
    const err = run({ iat: now(), amr: [{ method: 'password', timestamp: now() - 3 * 3600 }] });
    expect(err?.code).toBe('reauthentication_required');
  });

  it('uses the most recent authentication method', () => {
    expect(run({ iat: now(), amr: [{ method: 'oauth', timestamp: now() - 9000 }, { method: 'password', timestamp: now() - 10 }] })).toBeUndefined();
  });

  it('refuses tokens without an amr sign-in time', () => {
    expect(run({ iat: now() })?.code).toBe('reauthentication_required');
  });
});
