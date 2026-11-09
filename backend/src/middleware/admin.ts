import type { NextFunction, Request, Response } from 'express';
import { env } from '../config/env.js';
import { forbidden } from '../lib/errors.js';
import { serviceClient } from '../lib/supabase.js';
import type { AdminContext } from '../types/express.js';

type Role = AdminContext['role'];

const RANK: Record<Role, number> = { support: 1, finance: 2, operator: 3, superadmin: 4 };

/**
 * Restricted admin access: the caller must be an active row in admin_users,
 * must hold one of the allowed roles, and (by default) must have completed MFA
 * for this session (JWT aal = aal2). Every admin action is audited by the caller.
 */
export function requireAdmin(...allowed: Role[]) {
  return async (req: Request, _res: Response, next: NextFunction) => {
    try {
      const auth = req.auth;
      if (!auth) throw forbidden();
      const { data, error } = await serviceClient()
        .from('admin_users')
        .select('user_id, role, mfa_required, revoked_at')
        .eq('user_id', auth.userId)
        .maybeSingle();
      if (error || !data || data.revoked_at) throw forbidden('admin_required');
      const role = data.role as Role;
      if (allowed.length > 0 && !allowed.includes(role) && role !== 'superadmin') throw forbidden('admin_role_insufficient');
      if (env().ADMIN_REQUIRE_MFA && data.mfa_required && auth.claims.aal !== 'aal2') {
        throw forbidden('admin_mfa_required', 'Complete multi-factor authentication to use admin tools');
      }
      req.admin = { userId: auth.userId, role };
      next();
    } catch (err) {
      next(err);
    }
  };
}

export const hasRank = (role: Role, min: Role) => RANK[role] >= RANK[min];
