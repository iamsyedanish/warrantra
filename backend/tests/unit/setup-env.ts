// Minimal environment so modules that read configuration can load in unit tests.
process.env.SUPABASE_URL ??= 'http://127.0.0.1:54321';
process.env.SUPABASE_ANON_KEY ??= 'anon-key-for-tests-0000000000';
process.env.SUPABASE_SERVICE_ROLE_KEY ??= 'service-key-for-tests-000000000';
process.env.HASH_PEPPER ??= 'test-pepper-0123456789abcdef0123456789abcdef';
process.env.REVENUECAT_WEBHOOK_AUTH ??= 'rc-webhook-secret-for-tests';
process.env.INBOUND_WEBHOOK_PASSWORD ??= 'inbound-password-for-tests';
process.env.CRON_SECRET ??= 'cron-secret-for-tests-123';
process.env.AI_PROVIDER ??= 'disabled';
process.env.LOG_LEVEL ??= 'fatal';
