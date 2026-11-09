import 'dotenv/config';
import { z } from 'zod';

const bool = (fallback: 'true' | 'false') =>
  z
    .enum(['true', 'false', '1', '0'])
    .default(fallback)
    .transform((v) => v === 'true' || v === '1');

const EnvSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(8080),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace']).default('info'),
  PUBLIC_BASE_URL: z.string().url().default('http://localhost:8080'),
  CORS_ORIGINS: z.string().default(''),
  TRUST_PROXY: bool('false'),

  // Supabase
  SUPABASE_URL: z.string().url(),
  SUPABASE_ANON_KEY: z.string().min(20),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
  AUTH_REDIRECT_URL: z.string().url().default('warrantra://auth-callback'),
  PASSWORD_RESET_REDIRECT_URL: z.string().url().default('warrantra://reset-password'),
  REAUTH_MAX_AGE_SECONDS: z.coerce.number().int().positive().default(600),
  ADMIN_REQUIRE_MFA: bool('true'),

  // Server-side secret used to hash identifiers (tokens, emails) for lookups.
  HASH_PEPPER: z.string().min(32),

  // AI (third-party provider; keys never leave the server)
  AI_PROVIDER: z.enum(['anthropic', 'disabled']).default('anthropic'),
  ANTHROPIC_API_KEY: z.string().optional(),
  AI_MODEL: z.string().default('claude-opus-5-5'),
  AI_EFFORT: z.enum(['low', 'medium', 'high']).default('low'),
  AI_MAX_OUTPUT_TOKENS: z.coerce.number().int().positive().default(4000),
  AI_CLAIM_DRAFT_MAX_TOKENS: z.coerce.number().int().positive().default(1500),
  AI_TIMEOUT_MS: z.coerce.number().int().positive().default(60_000),
  // USD per million tokens, used for cost accounting (update when pricing changes).
  AI_PRICE_INPUT_PER_MTOK: z.coerce.number().nonnegative().default(4),
  AI_PRICE_OUTPUT_PER_MTOK: z.coerce.number().nonnegative().default(20),
  AI_SERVER_FALLBACKS: bool('true'),
  AI_PROMPT_VERSION: z.string().default('receipt-extract-v1'),

  // Billing (RevenueCat)
  REVENUECAT_WEBHOOK_AUTH: z.string().min(16),
  REVENUECAT_SECRET_API_KEY: z.string().optional(),
  REVENUECAT_PRO_ENTITLEMENT: z.string().default('pro'),
  REVENUECAT_BUSINESS_ENTITLEMENT: z.string().default('business_pilot'),

  // Push (FCM HTTP v1; APNs via FCM)
  PUSH_PROVIDER: z.enum(['fcm', 'log']).default('log'),
  FCM_PROJECT_ID: z.string().optional(),
  FCM_SERVICE_ACCOUNT_JSON: z.string().optional(),

  // Outbound email (verification for web deletion, workspace invitations)
  MAIL_PROVIDER: z.enum(['resend', 'log']).default('log'),
  RESEND_API_KEY: z.string().optional(),
  MAIL_FROM: z.string().default('Warrantra <no-reply@warrantra.app>'),
  SUPPORT_EMAIL: z.string().email().default('support@warrantra.app'),

  // Inbound email forwarding (Postmark inbound webhook)
  INBOUND_DOMAIN: z.string().default('in.warrantra.app'),
  INBOUND_WEBHOOK_USER: z.string().default('postmark'),
  INBOUND_WEBHOOK_PASSWORD: z.string().optional(),
  INBOUND_REQUIRE_SENDER_AUTH: bool('true'),

  // Storage backups (S3-compatible, separate from Supabase)
  BACKUP_S3_ENDPOINT: z.string().optional(),
  BACKUP_S3_REGION: z.string().default('us-east-1'),
  BACKUP_S3_BUCKET: z.string().optional(),
  BACKUP_S3_ACCESS_KEY_ID: z.string().optional(),
  BACKUP_S3_SECRET_ACCESS_KEY: z.string().optional(),

  // Worker
  WORKER_NAME: z.string().default('worker-1'),
  WORKER_POLL_MS: z.coerce.number().int().positive().default(5000),
  CRON_SECRET: z.string().min(16).optional(),

  EXPORT_LINK_TTL_SECONDS: z.coerce.number().int().positive().default(3600),
  EXPORT_RETENTION_DAYS: z.coerce.number().int().positive().default(7),
});

export type Env = z.infer<typeof EnvSchema>;

function load(): Env {
  const parsed = EnvSchema.safeParse(process.env);
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('\n  ');
    throw new Error(`Invalid environment configuration:\n  ${issues}`);
  }
  const env = parsed.data;
  if (env.AI_PROVIDER === 'anthropic' && !env.ANTHROPIC_API_KEY && env.NODE_ENV === 'production') {
    throw new Error('ANTHROPIC_API_KEY is required when AI_PROVIDER=anthropic in production');
  }
  if (env.PUSH_PROVIDER === 'fcm' && (!env.FCM_PROJECT_ID || !env.FCM_SERVICE_ACCOUNT_JSON)) {
    throw new Error('FCM_PROJECT_ID and FCM_SERVICE_ACCOUNT_JSON are required when PUSH_PROVIDER=fcm');
  }
  return env;
}

let cached: Env | undefined;
export function env(): Env {
  cached ??= load();
  return cached;
}

/** For tests: override configuration. */
export function setEnvForTests(overrides: Partial<Env>): void {
  cached = { ...(cached ?? load()), ...overrides };
}
