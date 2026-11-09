import pino from 'pino';
import { redactDeep } from './redact.js';

/**
 * Structured logger with aggressive redaction. Never log raw receipts, serial
 * numbers, signed URLs, tokens, credentials, AI prompts/outputs or request bodies.
 */
export const logger = pino({
  level: process.env.LOG_LEVEL ?? 'info',
  base: { service: 'warrantra-api' },
  redact: {
    paths: [
      'req.headers.authorization',
      'req.headers.cookie',
      'req.headers["x-revenuecat-authorization"]',
      'headers.authorization',
      '*.password',
      '*.token',
      '*.access_token',
      '*.refresh_token',
      '*.push_token',
      '*.serial_number',
      '*.signedUrl',
      '*.signed_url',
      '*.url',
      '*.api_key',
      '*.apiKey',
    ],
    censor: '[redacted]',
  },
  serializers: {
    err: (err: unknown) => {
      const e = err as { name?: string; message?: string; code?: string; stack?: string };
      return {
        type: e?.name,
        code: e?.code,
        // Messages from upstream libraries may echo input; scrub obvious secrets.
        message: typeof e?.message === 'string' ? scrub(e.message) : undefined,
        stack: process.env.NODE_ENV === 'production' ? undefined : e?.stack,
      };
    },
  },
  formatters: {
    log: (obj) => redactDeep(obj) as Record<string, unknown>,
  },
});

const URL_RE = /https?:\/\/[^\s"']+/g;
const BEARER_RE = /Bearer\s+[A-Za-z0-9._-]+/g;
const JWT_RE = /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g;

export function scrub(message: string): string {
  return message.replace(URL_RE, '[url]').replace(BEARER_RE, 'Bearer [redacted]').replace(JWT_RE, '[jwt]').slice(0, 500);
}
