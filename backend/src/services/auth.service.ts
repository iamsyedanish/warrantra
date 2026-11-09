/**
 * Accounts & identity. Supabase Auth issues sessions; this service wraps the
 * flows the mobile app needs, and enforces that a new provider identity never
 * merges into an existing account by email alone (see guard_identity_linking).
 */
import { env } from '../config/env.js';
import { AppError, badRequest, check, unauthorized } from '../lib/errors.js';
import { freshAnonClient, serviceClient, type Db } from '../lib/supabase.js';
import { audit } from './ops.service.js';

const sessionView = (session: { access_token: string; refresh_token: string; expires_at?: number; expires_in?: number } | null) =>
  session
    ? { access_token: session.access_token, refresh_token: session.refresh_token, expires_at: session.expires_at, expires_in: session.expires_in }
    : null;

function authError(err: { message?: string; status?: number; code?: string } | null): never {
  const msg = err?.message ?? '';
  if (/identity_link_requires_explicit_intent|Database error/i.test(msg)) {
    throw new AppError(409, 'account_exists_use_original_sign_in',
      'An account already uses this email. Sign in with your original method, then link this provider in Settings.');
  }
  if (err?.status === 400 || err?.status === 401 || err?.status === 422) {
    // Generic message — never reveal whether an email is registered.
    throw unauthorized('invalid_credentials', 'Email or password is incorrect');
  }
  if (err?.status === 429) throw new AppError(429, 'rate_limited', 'Too many attempts; try again later');
  throw new AppError(502, 'auth_provider_error', 'Authentication service error');
}

export async function signUp(input: { email: string; password: string; display_name?: string; acquisition_channel?: string; referral_code?: string }) {
  const client = freshAnonClient();
  const { data, error } = await client.auth.signUp({
    email: input.email,
    password: input.password,
    options: { emailRedirectTo: env().AUTH_REDIRECT_URL },
  });
  if (error) {
    if (/already registered|exists/i.test(error.message)) {
      // Same response as success to avoid account enumeration.
      return { user_id: null, session: null, email_confirmation_required: true };
    }
    authError(error);
  }
  if (data.user) {
    await serviceClient()
      .from('profiles')
      .update({
        display_name: input.display_name ?? null,
        acquisition_channel: input.acquisition_channel ?? null,
        referral_code: input.referral_code ?? null,
      })
      .eq('id', data.user.id);
    await audit({ actorType: 'user', actorId: data.user.id, action: 'account.signup', targetType: 'user', targetId: data.user.id });
  }
  return { user_id: data.user?.id ?? null, session: sessionView(data.session), email_confirmation_required: !data.session };
}

export async function signInWithPassword(email: string, password: string) {
  const { data, error } = await freshAnonClient().auth.signInWithPassword({ email, password });
  if (error) authError(error);
  return { user_id: data.user?.id, session: sessionView(data.session) };
}

/** Native Google / Apple sign-in: exchange the provider ID token for a Supabase session. */
export async function signInWithIdToken(input: { provider: 'google' | 'apple'; id_token: string; nonce?: string; access_token?: string }) {
  const { data, error } = await freshAnonClient().auth.signInWithIdToken({
    provider: input.provider,
    token: input.id_token,
    nonce: input.nonce,
    access_token: input.access_token,
  });
  if (error) authError(error);
  return { user_id: data.user?.id, session: sessionView(data.session) };
}

export async function refresh(refreshToken: string) {
  const { data, error } = await freshAnonClient().auth.refreshSession({ refresh_token: refreshToken });
  if (error || !data.session) throw unauthorized('invalid_refresh_token', 'Please sign in again');
  return { session: sessionView(data.session) };
}

/** Signs out the current session server-side (the client must also clear its private cache). */
export async function signOut(accessToken: string, scope: 'local' | 'global' = 'local') {
  const { error } = await serviceClient().auth.admin.signOut(accessToken, scope);
  if (error && error.status !== 401 && error.status !== 404) authError(error);
  return { signed_out: true, clear_local_cache: true };
}

export async function sendPasswordReset(email: string) {
  await freshAnonClient().auth.resetPasswordForEmail(email, { redirectTo: env().PASSWORD_RESET_REDIRECT_URL });
  // Always the same response (no enumeration).
  return { sent: true };
}

export async function updatePassword(userId: string, password: string) {
  const { error } = await serviceClient().auth.admin.updateUserById(userId, { password });
  if (error) {
    if (/weak|short|password/i.test(error.message)) throw badRequest('weak_password', 'Choose a stronger password');
    authError(error);
  }
  await audit({ actorType: 'user', actorId: userId, action: 'account.password_changed', targetType: 'user', targetId: userId });
  return { updated: true };
}

/** Records an explicit link intent; the client then calls supabase.auth.linkIdentity(). */
export async function requestIdentityLink(db: Db, userId: string, provider: string) {
  const expiresAt = check(await db.rpc('request_identity_link', { p_provider: provider }));
  await audit({ actorType: 'user', actorId: userId, action: 'account.identity_link_requested', metadata: { provider } });
  return { provider, expires_at: expiresAt, next_step: 'Call linkIdentity in the app within 10 minutes.' };
}

export async function listIdentities(userId: string) {
  const { data, error } = await serviceClient().auth.admin.getUserById(userId);
  if (error) authError(error);
  return (data.user?.identities ?? []).map((i) => ({ provider: i.provider, created_at: i.created_at, last_sign_in_at: i.last_sign_in_at }));
}

export async function recordAiConsent(userId: string, granted: boolean, version: string) {
  check(
    await serviceClient()
      .from('profiles')
      .update({ ai_processing_consent_at: granted ? new Date().toISOString() : null, ai_consent_version: granted ? version : null })
      .eq('id', userId),
  );
  await audit({ actorType: 'user', actorId: userId, action: granted ? 'consent.ai_granted' : 'consent.ai_withdrawn', metadata: { version } });
  return { ai_processing_consent: granted, consent_version: granted ? version : null };
}
