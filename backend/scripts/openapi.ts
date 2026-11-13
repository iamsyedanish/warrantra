/**
 * Generates docs/openapi.json from the real route table (src/routes/index.ts)
 * and the zod request validators, so the spec cannot drift from the code.
 *   npm run openapi          write docs/openapi.json
 *   npm run openapi -- --check   exit 1 if docs/openapi.json is out of date (used by tests/CI)
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import * as V from '../src/validators/index.js';

const here = dirname(fileURLToPath(import.meta.url));
const ROUTES = join(here, '..', 'src', 'routes', 'index.ts');
const OUT = join(here, '..', 'docs', 'openapi.json');

/** Request body validator per controller handler. */
const BODY: Record<string, z.ZodType> = {
  'AuthController.signUp': V.SignUpBody, 'AuthController.signIn': V.SignInBody, 'AuthController.signInWithIdToken': V.IdTokenBody,
  'AuthController.refresh': V.RefreshBody, 'AuthController.passwordReset': V.EmailBody, 'AuthController.updatePassword': V.PasswordUpdateBody,
  'AuthController.linkIntent': V.LinkIntentBody,
  'MeController.update': V.ProfilePatch, 'MeController.aiConsent': V.AiConsentBody, 'MeController.registerDevice': V.DeviceBody,
  'MeController.confirmDeletion': V.DeletionConfirmBody,
  'PublicController.webDeletionStart': V.EmailBody, 'PublicController.webDeletionVerify': V.WebDeletionVerifyBody,
  'SupportController.openPublic': V.PublicSupportBody, 'SupportController.open': V.SupportTicketBody, 'SupportController.reply': V.SupportMessageBody,
  'PurchaseController.create': V.PurchaseInput, 'PurchaseController.trackLine': V.TrackLineBody,
  'ItemController.quickAdd': V.QuickAddItemInput, 'ItemController.update': V.ItemPatch,
  'CoverageController.addWarranty': V.WarrantyInput, 'CoverageController.updateWarranty': V.WarrantyPatch,
  'CoverageController.addReturnWindow': V.ReturnWindowInput, 'CoverageController.updateReturnWindow': V.ReturnWindowPatch,
  'CoverageController.addRegistration': V.RegistrationInput, 'CoverageController.updateRegistration': V.RegistrationPatch,
  'AttachmentController.begin': V.BeginUploadBody, 'AttachmentController.update': V.AttachmentPatch, 'AttachmentController.link': V.LinkAttachmentBody,
  'ScanController.start': V.ScanBody, 'CaptureController.create': V.CaptureDraftBody,
  'ReminderController.createCustom': V.CustomReminderBody,
  'ClaimController.create': V.ClaimCreateBody, 'ClaimController.update': V.ClaimPatch, 'ClaimController.reviewSnapshot': V.ClaimSnapshotBody,
  'ClaimController.pack': V.ClaimPackBody, 'OutcomeController.create': V.OutcomeBody,
  'CardController.create': V.PaymentCardBody, 'CardController.update': V.PaymentCardBody.partial(),
  'WorkspaceController.create': V.WorkspaceBody, 'WorkspaceController.update': V.WorkspacePatch, 'WorkspaceController.invite': V.InviteBody,
  'WorkspaceController.accept': V.AcceptInviteBody, 'WorkspaceController.updateMember': V.MemberPatch, 'WorkspaceController.shareItem': V.ShareItemBody,
  'WorkspaceController.createLocation': V.LocationBody, 'WorkspaceController.assign': V.AssignBody,
  'ServiceController.create': V.ServiceRecordBody, 'MaintenanceController.create': V.MaintenanceTaskBody,
  'MaintenanceController.update': V.MaintenanceTaskBody.partial(), 'MaintenanceController.complete': V.MaintenanceCompleteBody,
  'PartnerController.grant': V.PartnerConsentBody, 'AnalyticsController.ingest': V.AnalyticsBatchBody,
};
const QUERY: Record<string, z.ZodType> = { 'ItemController.list': V.ItemListQuery };
/** Handlers that require an Idempotency-Key header. */
const IDEMPOTENT = new Set(['PurchaseController.create', 'ItemController.quickAdd', 'AttachmentController.begin', 'ScanController.start', 'ClaimController.aiDraft']);
const VERSIONED = new Set(['ItemController.update', 'CoverageController.updateWarranty', 'CoverageController.updateReturnWindow',
  'CoverageController.updateRegistration', 'ClaimController.update', 'MaintenanceController.update']);

interface Route { method: string; path: string; handler: string; group: 'public' | 'webhook' | 'user' | 'admin' }

export function parseRoutes(source: string): Route[] {
  const routes: Route[] = [];
  let group: Route['group'] = 'public';
  for (const line of source.split('\n')) {
    const g = /export function (public|webhook|user|admin)Routes/.exec(line);
    if (g) group = g[1] as Route['group'];
    const m = /r\.(get|post|put|patch|delete)\('([^']+)',.*wrap\(([A-Za-z]+)\.([A-Za-z]+)\)/.exec(line);
    if (!m) continue;
    const ctrl = m[3] === 'A' ? 'AdminController' : m[3];
    routes.push({ method: m[1]!, path: (group === 'admin' ? '/admin' : '') + m[2]!, handler: `${ctrl}.${m[4]}`, group });
  }
  return routes;
}

const humanize = (h: string) => h.split('.')[1]!.replace(/([A-Z])/g, ' $1').replace(/^./, (c) => c.toUpperCase());
const toSchema = (s: z.ZodType) => z.toJSONSchema(s, { io: 'input', unrepresentable: 'any' }) as Record<string, unknown>;

export function buildSpec(routes: Route[]) {
  const paths: Record<string, Record<string, unknown>> = {};
  for (const r of routes) {
    const oaPath = '/v1' + r.path.replace(/:([A-Za-z]+)/g, '{$1}');
    const params: unknown[] = [...r.path.matchAll(/:([A-Za-z]+)/g)].map((m) => ({
      name: m[1], in: 'path', required: true, schema: { type: 'string', ...(m[1] === 'target' || m[1] === 'table' || m[1] === 'task' || m[1] === 'key' ? {} : { format: 'uuid' }) },
    }));
    if (IDEMPOTENT.has(r.handler)) params.push({ name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', pattern: '^[A-Za-z0-9_-]{8,128}$' } });
    if (VERSIONED.has(r.handler)) params.push({ name: 'If-Match', in: 'header', required: false, description: 'Version you read; stale versions return 409 version_conflict', schema: { type: 'string' } });
    const q = QUERY[r.handler];
    if (q) {
      const js = toSchema(q) as { properties?: Record<string, unknown>; required?: string[] };
      for (const [name, schema] of Object.entries(js.properties ?? {})) params.push({ name, in: 'query', required: (js.required ?? []).includes(name), schema });
    }
    const body = BODY[r.handler];
    const security = r.group === 'user' || r.group === 'admin' ? [{ bearer: [] }] : r.group === 'webhook' ? [{ webhookAuth: [] }] : [];
    paths[oaPath] ??= {};
    paths[oaPath]![r.method] = {
      operationId: r.handler.replace('.', '_'),
      tags: [r.group === 'admin' ? 'admin' : r.group === 'webhook' ? 'webhooks' : r.path.split('/')[1]!],
      summary: humanize(r.handler),
      security,
      ...(params.length ? { parameters: params } : {}),
      ...(body ? { requestBody: { required: true, content: { 'application/json': { schema: toSchema(body) } } } } : {}),
      responses: {
        '200': { description: 'OK — `{ "data": ... }`' },
        ...(r.method === 'post' ? { '201': { description: 'Created' }, '202': { description: 'Accepted (queued)' } } : {}),
        default: { description: 'Error', content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } } },
      },
    };
  }
  return {
    openapi: '3.1.0',
    info: {
      title: 'Warrantra API', version: '1.0.0',
      description: 'Purchase-protection backend. Authenticate with the Supabase access token. Generated from src/routes and src/validators — do not edit by hand.',
    },
    servers: [{ url: 'http://localhost:8080' }],
    components: {
      securitySchemes: {
        bearer: { type: 'http', scheme: 'bearer', bearerFormat: 'Supabase JWT' },
        webhookAuth: { type: 'apiKey', in: 'header', name: 'Authorization', description: 'Provider-specific shared secret / basic auth' },
      },
      schemas: {
        Error: { type: 'object', required: ['error'], properties: { error: { type: 'object', required: ['code', 'message', 'request_id'],
          properties: { code: { type: 'string' }, message: { type: 'string' }, details: { type: 'object' }, request_id: { type: 'string' } } } } },
      },
    },
    paths,
  };
}

export function generate(): string {
  return JSON.stringify(buildSpec(parseRoutes(readFileSync(ROUTES, 'utf8'))), null, 2) + '\n';
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const next = generate();
  if (process.argv.includes('--check')) {
    const current = (() => { try { return readFileSync(OUT, 'utf8'); } catch { return ''; } })();
    if (current !== next) {
      console.error('docs/openapi.json is out of date. Run: npm run openapi');
      process.exit(1);
    }
    console.log('docs/openapi.json is up to date.');
  } else {
    writeFileSync(OUT, next);
    const spec = JSON.parse(next) as { paths: Record<string, object> };
    const ops = Object.values(spec.paths).reduce((a, p) => a + Object.keys(p).length, 0);
    console.log(`Wrote docs/openapi.json (${ops} operations).`);
  }
}
