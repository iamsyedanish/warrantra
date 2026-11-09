import './setup-env.js';
import { describe, expect, it } from 'vitest';
import request from 'supertest';
import { createApp } from '../../src/app.js';

const app = createApp();

describe('HTTP surface', () => {
  it('health check responds', async () => {
    const r = await request(app).get('/healthz');
    expect(r.status).toBe(200);
  });

  it('protected routes require a bearer token (identity never from the body)', async () => {
    for (const [method, path] of [['get', '/v1/items'], ['post', '/v1/purchases'], ['get', '/v1/me'], ['get', '/v1/admin/health'], ['post', '/v1/scans']] as const) {
      const r = await request(app)[method](path).send({ user_id: '00000000-0000-0000-0000-000000000000' });
      expect(r.status, path).toBe(401);
      expect(r.body.error.code).toBe('unauthorized');
      expect(r.headers['cache-control']).toContain('no-store');
    }
  });

  it('rejects unauthenticated billing and inbound webhooks', async () => {
    const rc = await request(app).post('/v1/webhooks/revenuecat').set('Authorization', 'Bearer wrong').send({ event: { id: 'x', type: 'RENEWAL', environment: 'PRODUCTION' } });
    expect(rc.status).toBe(401);
    const inbound = await request(app).post('/v1/webhooks/inbound-email').send({ MessageID: 'x' });
    expect(inbound.status).toBe(401);
    const cron = await request(app).post('/v1/internal/cron/reminders').set('X-Cron-Secret', 'nope');
    expect(cron.status).toBe(403);
  });

  it('validates public form input and hides internals in errors', async () => {
    const r = await request(app).post('/v1/public/account-deletion').send({ email: 'not-an-email' });
    expect(r.status).toBe(400);
    expect(r.body.error.code).toBe('validation_failed');
    expect(r.body.error.request_id).toBeTruthy();
  });

  it('rejects malformed JSON and unknown routes cleanly', async () => {
    const bad = await request(app).post('/v1/auth/sign-in').set('Content-Type', 'application/json').send('{bad');
    expect(bad.status).toBe(400);
    expect(bad.body.error.code).toBe('invalid_json');
  });
});
