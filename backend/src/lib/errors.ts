/**
 * Application errors and translation of PostgreSQL / PostgREST errors into HTTP
 * responses. Database-raised exceptions use stable codes such as
 * `quota_exceeded:items:10` so the API can map them without string guessing.
 */
export class AppError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message?: string,
    public readonly details?: Record<string, unknown>,
  ) {
    super(message ?? code);
    this.name = 'AppError';
  }
}

export const badRequest = (code: string, message?: string, details?: Record<string, unknown>) =>
  new AppError(400, code, message, details);
export const unauthorized = (code = 'unauthorized', message = 'Authentication required') => new AppError(401, code, message);
export const forbidden = (code = 'forbidden', message = 'Not allowed') => new AppError(403, code, message);
export const notFound = (code = 'not_found', message = 'Not found') => new AppError(404, code, message);
export const conflict = (code: string, message?: string, details?: Record<string, unknown>) => new AppError(409, code, message, details);
export const unprocessable = (code: string, message?: string, details?: Record<string, unknown>) =>
  new AppError(422, code, message, details);
export const tooMany = (code = 'rate_limited', message = 'Too many requests') => new AppError(429, code, message);
export const unavailable = (code: string, message?: string) => new AppError(503, code, message);

export interface DbErrorLike {
  code?: string;
  message?: string;
  details?: string | null;
  hint?: string | null;
}

const KNOWN_MESSAGES: Array<[RegExp, (m: RegExpMatchArray) => AppError]> = [
  [/quota_exceeded:([a-z_]+):(\d+)/, (m) => new AppError(409, 'quota_exceeded', `Plan limit reached for ${m[1]}`, { resource: m[1], limit: Number(m[2]) })],
  [/plan_feature_unavailable:([a-z_]+)/, (m) => new AppError(402, 'plan_required', `Your plan does not include ${m[1]}`, { feature: m[1] })],
  [/file_too_large:(\d+)/, (m) => new AppError(413, 'file_too_large', 'File exceeds the size limit', { limit: Number(m[1]) })],
  [/ai_rate_limited/, () => tooMany('ai_rate_limited', 'Too many AI actions; try again later')],
  [/ai_disabled/, () => unavailable('ai_disabled', 'AI processing is temporarily unavailable. Manual entry still works.')],
  [/ai_global_budget_exhausted|ai_account_cost_ceiling_reached/, (m) => unavailable(m[0], 'AI processing is temporarily unavailable. Manual entry still works.')],
  [/ai_consent_required/, () => forbidden('ai_consent_required', 'Allow third-party AI processing in Settings first')],
  [/account_not_active/, () => forbidden('account_not_active', 'This account is being deleted')],
  [/uploads_disabled/, () => unavailable('uploads_disabled', 'Uploads are temporarily unavailable')],
  [/unsupported_file_type/, () => new AppError(415, 'unsupported_file_type', 'Only JPEG, PNG, HEIC and PDF files are accepted')],
  [/identity_link_requires_explicit_intent/, () => forbidden('identity_link_requires_explicit_intent', 'Sign in with your original method and link this provider from Settings')],
  [/invitation_email_mismatch/, () => forbidden('invitation_email_mismatch', 'This invitation was sent to a different email address')],
  [/invitation_invalid/, () => notFound('invitation_invalid', 'This invitation is no longer valid')],
  [/(warranty_not_on_claim_item|return_window_not_on_claim_item|coverage_requires_item)/, (m) => unprocessable(m[1]!)],
  [/(allocations_exceed_group_amounts|purchase_requires_at_least_one_line|return_quantity_exceeds_item_quantity|reminder_in_past|invalid_timezone|title_required|outcome_requires_exactly_one_case)/, (m) => unprocessable(m[1]!)],
  [/(item_not_owned|item_not_shared_into_workspace|only_item_owner_can_share|item_owner_not_workspace_member|workspace_owner_cannot_be_demoted_or_removed|only_workspace_owner_can_hold_owner_role)/, (m) => forbidden(m[1]!)],
  [/([a-z_]+_not_found)/, (m) => notFound(m[1]!)],
];

export function fromDbError(err: DbErrorLike): AppError {
  const msg = err.message ?? '';
  for (const [re, make] of KNOWN_MESSAGES) {
    const m = msg.match(re);
    if (m) return make(m);
  }
  switch (err.code) {
    case 'PGRST116':
      return notFound();
    case '23505':
      return conflict('duplicate', 'A matching record already exists');
    case '23503':
      // Do not reveal whether the referenced row exists for someone else.
      return unprocessable('invalid_reference', 'A referenced record was not found');
    case '23514':
    case '22023':
    case '22P02':
    case '22007':
    case '22008':
    case '23502':
      return unprocessable('invalid_data', 'The data failed validation');
    case '42501':
      return forbidden();
    case '28000':
      return unauthorized();
    case 'P0002':
      return notFound();
    default:
      return new AppError(500, 'database_error', 'Unexpected database error');
  }
}

/** Throw if a Supabase response carries an error. */
export function check<T>(res: { data: T; error: DbErrorLike | null }): T {
  if (res.error) throw fromDbError(res.error);
  return res.data;
}

/** Like `check` but converts null data into 404. */
export function checkFound<T>(res: { data: T | null; error: DbErrorLike | null }, code = 'not_found'): T {
  if (res.error) throw fromDbError(res.error);
  if (res.data === null || res.data === undefined) throw notFound(code);
  return res.data;
}
