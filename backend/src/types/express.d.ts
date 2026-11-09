import type { Db } from '../lib/supabase.js';

export interface AuthContext {
  userId: string;
  token: string;
  /** Verified JWT claims (sub, aal, iat, amr, session_id...). */
  claims: Record<string, unknown>;
  /** Supabase client bound to the caller's JWT: queries run under RLS. */
  db: Db;
}

export interface AdminContext {
  userId: string;
  role: 'support' | 'operator' | 'finance' | 'superadmin';
}

declare global {
  namespace Express {
    interface Request {
      id: string;
      auth?: AuthContext;
      admin?: AdminContext;
      rawBody?: Buffer;
    }
  }
}

export {};
