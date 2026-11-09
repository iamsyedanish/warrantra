import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { env } from '../config/env.js';

/**
 * Two kinds of client:
 *  - userClient(token): anon key + the caller's JWT. Every query runs under RLS
 *    as that user, and RPCs see auth.uid(). Used for all user-scoped requests
 *    (defense in depth: API checks AND database policies).
 *  - serviceClient(): service role, bypasses RLS. Used only by webhooks, workers
 *    and admin endpoints, which perform their own authorization.
 */
export type Db = SupabaseClient;

const baseOptions = {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
} as const;

let service: Db | undefined;
let anon: Db | undefined;

export function serviceClient(): Db {
  service ??= createClient(env().SUPABASE_URL, env().SUPABASE_SERVICE_ROLE_KEY, baseOptions);
  return service;
}

/** Unauthenticated client for auth flows (sign-in, sign-up, password reset). */
export function anonClient(): Db {
  anon ??= createClient(env().SUPABASE_URL, env().SUPABASE_ANON_KEY, baseOptions);
  return anon;
}

/** Fresh anon client (no shared session state) for per-request auth operations. */
export function freshAnonClient(): Db {
  return createClient(env().SUPABASE_URL, env().SUPABASE_ANON_KEY, baseOptions);
}

export function userClient(accessToken: string): Db {
  return createClient(env().SUPABASE_URL, env().SUPABASE_ANON_KEY, {
    ...baseOptions,
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
}

export const BUCKETS = {
  files: 'warranty-files',
  exports: 'exports',
  claimPacks: 'claim-packs',
} as const;
