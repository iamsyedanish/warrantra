/**
 * Push transport. FCM HTTP v1 carries both Android and iOS (APNs via FCM);
 * Supabase remains the backend of record. A provider accepting a message does
 * not prove delivery or reading.
 */
import { JWT } from 'google-auth-library';
import { env } from '../../config/env.js';
import { logger } from '../../lib/logger.js';

export interface PushMessage {
  token: string;
  title: string;
  body: string;
  data: Record<string, string>;
}

export type PushResult =
  | { status: 'accepted'; providerMessageId: string | null }
  | { status: 'invalid_token'; errorCode: string }
  | { status: 'retryable_error'; errorCode: string; retryAfterSeconds?: number }
  | { status: 'permanent_error'; errorCode: string };

export interface PushProvider {
  name: string;
  send(msg: PushMessage): Promise<PushResult>;
}

class LogPushProvider implements PushProvider {
  name = 'log';
  async send(msg: PushMessage): Promise<PushResult> {
    logger.info({ title: msg.title, dataKeys: Object.keys(msg.data) }, 'push (log provider)');
    return { status: 'accepted', providerMessageId: null };
  }
}

class FcmPushProvider implements PushProvider {
  name = 'fcm';
  private jwt: JWT;
  constructor(private readonly projectId: string, serviceAccountJson: string) {
    const sa = JSON.parse(serviceAccountJson) as { client_email: string; private_key: string };
    this.jwt = new JWT({ email: sa.client_email, key: sa.private_key, scopes: ['https://www.googleapis.com/auth/firebase.messaging'] });
  }

  async send(msg: PushMessage): Promise<PushResult> {
    const { token: accessToken } = await this.jwt.getAccessToken();
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${this.projectId}/messages:send`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        message: {
          token: msg.token,
          notification: { title: msg.title, body: msg.body },
          data: msg.data,
          android: { priority: 'normal', notification: { channel_id: 'deadlines' } },
          apns: { headers: { 'apns-priority': '5' }, payload: { aps: { sound: 'default' } } },
        },
      }),
      signal: AbortSignal.timeout(10_000),
    }).catch((err: Error) => ({ ok: false, status: 0, json: async () => ({ error: { status: err.name } }) }) as unknown as Response);

    if (res.ok) {
      const body = (await res.json()) as { name?: string };
      return { status: 'accepted', providerMessageId: body.name ?? null };
    }
    const body = (await res.json().catch(() => ({}))) as { error?: { status?: string; details?: Array<{ errorCode?: string }> } };
    const code = body.error?.details?.find((d) => d.errorCode)?.errorCode ?? body.error?.status ?? `HTTP_${res.status}`;
    if (code === 'UNREGISTERED' || (res.status === 400 && code === 'INVALID_ARGUMENT') || res.status === 404) {
      return { status: 'invalid_token', errorCode: code };
    }
    if (res.status === 0 || res.status === 429 || res.status >= 500 || code === 'UNAVAILABLE' || code === 'INTERNAL') {
      const retryAfter = Number(res.headers?.get?.('retry-after') ?? '') || undefined;
      return { status: 'retryable_error', errorCode: code, retryAfterSeconds: retryAfter };
    }
    return { status: 'permanent_error', errorCode: code };
  }
}

let provider: PushProvider | undefined;
export function pushProvider(): PushProvider {
  if (!provider) {
    const e = env();
    provider = e.PUSH_PROVIDER === 'fcm' ? new FcmPushProvider(e.FCM_PROJECT_ID!, e.FCM_SERVICE_ACCOUNT_JSON!) : new LogPushProvider();
  }
  return provider;
}

export function setPushProviderForTests(p: PushProvider): void {
  provider = p;
}
