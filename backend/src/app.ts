import cors from 'cors';
import express, { type Express } from 'express';
import helmet from 'helmet';
import { env } from './config/env.js';
import { accessLog, errorHandler, notFoundHandler, requestId } from './middleware/common.js';
import { adminRoutes, publicRoutes, userRoutes, webhookRoutes } from './routes/index.js';

export function createApp(): Express {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', env().TRUST_PROXY);

  app.use(requestId);
  app.use(helmet({ contentSecurityPolicy: { directives: { defaultSrc: ["'none'"], frameAncestors: ["'none'"] } } }));
  const origins = env().CORS_ORIGINS.split(',').map((s) => s.trim()).filter(Boolean);
  app.use(cors({ origin: origins.length ? origins : false, credentials: false, maxAge: 600 }));
  app.use(accessLog);

  // Webhooks may carry base64 attachments (inbound email); everything else is small JSON.
  app.use('/v1/webhooks/inbound-email', express.json({ limit: '30mb' }));
  app.use(express.json({ limit: '256kb' }));

  app.get('/healthz', (_req, res) => res.json({ ok: true }));
  app.get('/readyz', async (_req, res) => {
    const { serviceClient } = await import('./lib/supabase.js');
    const { error } = await serviceClient().from('system_settings').select('key').limit(1);
    res.status(error ? 503 : 200).json({ ok: !error });
  });

  app.use('/v1', webhookRoutes());
  app.use('/v1', publicRoutes());
  app.use('/v1/admin', adminRoutes());
  app.use('/v1', userRoutes());

  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}
