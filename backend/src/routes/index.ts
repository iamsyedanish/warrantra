/**
 * Route table for /v1. Every user route: requireAuth -> noStore -> rate limit
 * -> controller (validation in the controller via zod).
 */
import { Router, type RequestHandler } from 'express';
import { AdminController as A } from '../controllers/admin.controller.js';
import { AuthController, MeController, PublicController } from '../controllers/account.controller.js';
import { ClaimController, OutcomeController } from '../controllers/claims.controller.js';
import { AnalyticsController, PartnerController, SupportController, WebhookController } from '../controllers/misc.controller.js';
import { CardController, CoverageController, ItemController, PurchaseController, ReferenceController } from '../controllers/purchase.controller.js';
import { AttachmentController, CaptureController, ReminderController, ScanController } from '../controllers/vault.controller.js';
import { MaintenanceController, ServiceController, WorkspaceController } from '../controllers/workspace.controller.js';
import { asyncHandler as h } from '../lib/http.js';
import { requireAdmin } from '../middleware/admin.js';
import { requireAuth, requireRecentAuth } from '../middleware/auth.js';
import { limits, noStore } from '../middleware/common.js';

const wrap = (fn: (req: any, res: any) => Promise<unknown>): RequestHandler => h(fn);

export function publicRoutes(): Router {
  const r = Router();
  r.use(noStore);
  r.post('/auth/sign-up', limits.auth, wrap(AuthController.signUp));
  r.post('/auth/sign-in', limits.auth, wrap(AuthController.signIn));
  r.post('/auth/id-token', limits.auth, wrap(AuthController.signInWithIdToken));
  r.post('/auth/refresh', limits.auth, wrap(AuthController.refresh));
  r.post('/auth/password-reset', limits.auth, wrap(AuthController.passwordReset));
  // Account deletion route outside the app (Google Play requirement).
  r.post('/public/account-deletion', limits.publicForms, wrap(PublicController.webDeletionStart));
  r.post('/public/account-deletion/verify', limits.publicForms, wrap(PublicController.webDeletionVerify));
  r.post('/public/support', limits.publicForms, wrap(SupportController.openPublic));
  r.get('/public/retention-schedule', wrap(PublicController.retention));
  r.get('/public/plans', wrap(PublicController.plans));
  return r;
}

export function webhookRoutes(): Router {
  const r = Router();
  r.post('/webhooks/revenuecat', wrap(WebhookController.revenuecat));
  r.post('/webhooks/inbound-email', wrap(WebhookController.inboundEmail));
  r.post('/internal/cron/:task', wrap(WebhookController.cron));
  return r;
}

export function userRoutes(): Router {
  const r = Router();
  r.use(requireAuth, noStore, limits.api);

  // Accounts & identity
  r.post('/auth/sign-out', wrap(AuthController.signOut));
  r.post('/auth/password', requireRecentAuth, wrap(AuthController.updatePassword));
  r.get('/auth/identities', wrap(AuthController.identities));
  r.post('/auth/identities/link-intent', requireRecentAuth, wrap(AuthController.linkIntent));

  r.get('/me', wrap(MeController.get));
  r.patch('/me', wrap(MeController.update));
  r.post('/me/ai-consent', wrap(MeController.aiConsent));
  r.get('/me/entitlement', wrap(MeController.entitlement));
  r.get('/me/usage', wrap(MeController.usage));
  r.get('/me/annual-summary', wrap(MeController.annualSummary));
  r.post('/me/restore-purchases', wrap(MeController.restorePurchases));
  r.get('/me/devices', wrap(MeController.listDevices));
  r.put('/me/devices', wrap(MeController.registerDevice));
  r.delete('/me/devices/:id', wrap(MeController.removeDevice));
  r.post('/me/exports', limits.exports, wrap(MeController.requestExport));
  r.get('/me/exports', wrap(MeController.listExports));
  r.get('/me/exports/:id', wrap(MeController.exportLinks));
  r.post('/me/deletion', requireRecentAuth, wrap(MeController.requestDeletion));
  r.post('/me/deletion/confirm', requireRecentAuth, wrap(MeController.confirmDeletion));
  r.post('/me/deletion/cancel', wrap(MeController.cancelDeletion));
  r.get('/me/deletion', wrap(MeController.deletionStatus));

  // Home / Action Center
  r.get('/action-center', wrap(ItemController.actionCenter));

  // Purchases, lines, items
  r.post('/purchases', wrap(PurchaseController.create));
  r.get('/purchases', wrap(PurchaseController.list));
  r.get('/purchases/:id', wrap(PurchaseController.get));
  r.patch('/purchases/:id', wrap(PurchaseController.update));
  r.delete('/purchases/:id', wrap(PurchaseController.remove));
  r.post('/receipt-lines/:lineId/track', wrap(PurchaseController.trackLine));

  r.post('/items', wrap(ItemController.quickAdd));
  r.get('/items', wrap(ItemController.list));
  r.get('/items/:id', wrap(ItemController.get));
  r.patch('/items/:id', wrap(ItemController.update));
  r.delete('/items/:id', wrap(ItemController.remove));
  r.get('/items/:id/timeline', wrap(ItemController.timeline));
  r.get('/items/:id/coverage-suggestions', wrap(ItemController.suggestions));
  r.get('/items/:id/coverage', wrap(CoverageController.listForItem));
  r.post('/items/:id/warranties', wrap(CoverageController.addWarranty));
  r.post('/items/:id/return-windows', wrap(CoverageController.addReturnWindow));
  r.post('/items/:id/registrations', wrap(CoverageController.addRegistration));
  r.get('/items/:id/service-records', wrap(ServiceController.listForItem));

  r.patch('/warranties/:id', wrap(CoverageController.updateWarranty));
  r.delete('/warranties/:id', wrap(CoverageController.removeWarranty));
  r.patch('/return-windows/:id', wrap(CoverageController.updateReturnWindow));
  r.delete('/return-windows/:id', wrap(CoverageController.removeReturnWindow));
  r.patch('/registrations/:id', wrap(CoverageController.updateRegistration));
  r.delete('/registrations/:id', wrap(CoverageController.removeRegistration));

  // Document vault
  r.post('/attachments', limits.uploads, wrap(AttachmentController.begin));
  r.post('/attachments/:id/complete', limits.uploads, wrap(AttachmentController.complete));
  r.get('/vault', wrap(AttachmentController.vault));
  r.get('/attachments/:id', wrap(AttachmentController.get));
  r.patch('/attachments/:id', wrap(AttachmentController.update));
  r.get('/attachments/:id/url', wrap(AttachmentController.url));
  r.get('/attachments/:id/impact', wrap(AttachmentController.impact));
  r.delete('/attachments/:id', wrap(AttachmentController.remove));
  r.post('/attachments/:id/links', wrap(AttachmentController.link));
  r.delete('/attachments/:id/links/:target/:targetId', wrap(AttachmentController.unlink));

  // Capture & AI extraction
  r.post('/scans', limits.ai, wrap(ScanController.start));
  r.get('/scans', wrap(ScanController.list));
  r.get('/scans/:id', wrap(ScanController.get));
  r.post('/scans/:id/discard', wrap(ScanController.discard));
  r.post('/capture-drafts', wrap(CaptureController.create));
  r.get('/capture-drafts', wrap(CaptureController.list));
  r.post('/capture-drafts/:id/discard', wrap(CaptureController.discard));
  r.get('/email-forwarding', wrap(CaptureController.address));
  r.post('/email-forwarding/rotate', wrap(CaptureController.rotate));
  r.post('/email-forwarding/disable', wrap(CaptureController.disable));
  r.get('/email-forwarding/log', wrap(CaptureController.inboundLog));

  // Reminders
  r.get('/reminders', wrap(ReminderController.list));
  r.post('/reminders', wrap(ReminderController.createCustom));
  r.post('/reminders/:id/cancel', wrap(ReminderController.cancelCustom));
  r.get('/notification-deliveries', wrap(ReminderController.deliveries));
  r.post('/notification-deliveries/:id/opened', wrap(ReminderController.opened));

  // Claims & outcomes
  r.post('/claims', wrap(ClaimController.create));
  r.get('/claims', wrap(ClaimController.list));
  r.get('/claims/:id', wrap(ClaimController.get));
  r.patch('/claims/:id', wrap(ClaimController.update));
  r.delete('/claims/:id', wrap(ClaimController.remove));
  r.get('/claims/:id/facts', wrap(ClaimController.proposedFacts));
  r.put('/claims/:id/snapshot', wrap(ClaimController.reviewSnapshot));
  r.post('/claims/:id/packs', wrap(ClaimController.pack));
  r.get('/claim-packs/:packId/url', wrap(ClaimController.packUrl));
  r.post('/claims/:id/ai-draft', limits.ai, wrap(ClaimController.aiDraft));
  r.post('/outcomes', wrap(OutcomeController.create));
  r.get('/outcomes', wrap(OutcomeController.list));
  r.get('/outcomes/summary', wrap(OutcomeController.summary));
  r.patch('/outcomes/:id', wrap(OutcomeController.update));
  r.delete('/outcomes/:id', wrap(OutcomeController.remove));

  // Payment-card labels & reference data
  r.get('/payment-cards', wrap(CardController.list));
  r.post('/payment-cards', wrap(CardController.create));
  r.patch('/payment-cards/:id', wrap(CardController.update));
  r.delete('/payment-cards/:id', wrap(CardController.remove));
  r.get('/reference/categories', wrap(ReferenceController.categories));
  r.get('/reference/brands', wrap(ReferenceController.brands));
  r.get('/reference/card-benefits', wrap(ReferenceController.cardBenefits));

  // Household vault & business portfolio pilot
  r.post('/workspaces', wrap(WorkspaceController.create));
  r.get('/workspaces', wrap(WorkspaceController.list));
  r.post('/workspaces/invitations/accept', wrap(WorkspaceController.accept));
  r.get('/workspaces/:id', wrap(WorkspaceController.get));
  r.patch('/workspaces/:id', wrap(WorkspaceController.update));
  r.post('/workspaces/:id/invitations', wrap(WorkspaceController.invite));
  r.delete('/workspaces/:id/invitations/:invitationId', wrap(WorkspaceController.revokeInvite));
  r.patch('/workspaces/:id/members/:userId', wrap(WorkspaceController.updateMember));
  r.post('/workspaces/:id/leave', wrap(WorkspaceController.leave));
  r.post('/workspaces/:id/items', wrap(WorkspaceController.shareItem));
  r.delete('/workspaces/:id/items/:itemId', wrap(WorkspaceController.unshareItem));
  r.post('/workspaces/:id/locations', wrap(WorkspaceController.createLocation));
  r.patch('/workspaces/:id/locations/:locationId', wrap(WorkspaceController.updateLocation));
  r.post('/workspaces/:id/assignments', wrap(WorkspaceController.assign));
  r.get('/workspaces/:id/assets', wrap(WorkspaceController.assets));
  r.post('/service-records', wrap(ServiceController.create));
  r.delete('/service-records/:id', wrap(ServiceController.remove));
  r.post('/maintenance-tasks', wrap(MaintenanceController.create));
  r.get('/maintenance-tasks', wrap(MaintenanceController.list));
  r.patch('/maintenance-tasks/:id', wrap(MaintenanceController.update));
  r.post('/maintenance-tasks/:id/complete', wrap(MaintenanceController.complete));
  r.delete('/maintenance-tasks/:id', wrap(MaintenanceController.remove));

  // Partners (consent only), support, analytics
  r.get('/partners', wrap(PartnerController.list));
  r.get('/partner-consents', wrap(PartnerController.consents));
  r.post('/partner-consents', wrap(PartnerController.grant));
  r.delete('/partner-consents/:id', wrap(PartnerController.revoke));
  r.post('/support/tickets', wrap(SupportController.open));
  r.get('/support/tickets', wrap(SupportController.mine));
  r.get('/support/tickets/:id', wrap(SupportController.thread));
  r.post('/support/tickets/:id/messages', wrap(SupportController.reply));
  r.post('/analytics/events', wrap(AnalyticsController.ingest));
  return r;
}

export function adminRoutes(): Router {
  const r = Router();
  r.use(requireAuth, noStore, requireAdmin());
  r.get('/health', wrap(A.health));
  r.get('/jobs', wrap(A.jobs));
  r.post('/jobs/:id/retry', wrap(A.retryJob));
  r.post('/jobs/:id/cancel', wrap(A.cancelJob));
  r.get('/notification-deliveries/failed', wrap(A.failedDeliveries));
  r.get('/scans/failed', wrap(A.failedScans));
  r.get('/users/:id', wrap(A.userLookup));
  r.post('/users/:id/reconcile-entitlements', wrap(A.reconcileUser));
  r.post('/users/:id/promotional-entitlement', requireAdmin('operator'), wrap(A.grantPromotional));
  r.get('/audit-events', wrap(A.auditLog));
  r.get('/settings', wrap(A.settings));
  r.put('/settings/:key', requireAdmin('operator'), wrap(A.setSetting));
  r.get('/plan-limits', wrap(A.planLimits));
  r.post('/plan-limits', requireAdmin('superadmin'), wrap(A.newPlanVersion));
  r.get('/support/tickets', wrap(A.tickets));
  r.get('/support/tickets/:id', wrap(A.ticket));
  r.post('/support/tickets/:id/messages', wrap(A.replyTicket));
  r.get('/reference/:table', wrap(A.listReference));
  r.post('/reference/:table', requireAdmin('operator'), wrap(A.upsertReference));
  r.post('/reference/:table/:id/review', requireAdmin('operator'), wrap(A.reviewReference));
  r.get('/metrics', requireAdmin('finance', 'operator'), wrap(A.metrics));
  r.get('/profitability', requireAdmin('finance'), wrap(A.profitHistory));
  r.post('/profitability/snapshot', requireAdmin('finance'), wrap(A.profitSnapshot));
  r.post('/profitability/alerts/:id/ack', requireAdmin('finance'), wrap(A.ackAlert));
  r.post('/profitability/costs', requireAdmin('finance'), wrap(A.addCost));
  r.post('/profitability/acquisition-spend', requireAdmin('finance'), wrap(A.addAcquisitionSpend));
  r.get('/profitability/settings', requireAdmin('finance'), wrap(A.profitSettings));
  r.post('/profitability/settings', requireAdmin('finance'), wrap(A.newProfitSettings));
  r.post('/profitability/calculator', requireAdmin('finance'), wrap(A.calculator));
  r.get('/backups', requireAdmin('operator'), wrap(A.backups));
  r.post('/backups/run', requireAdmin('operator'), wrap(A.runBackup));
  r.post('/backups/restore-drill', requireAdmin('operator'), wrap(A.runRestoreDrill));
  r.get('/partners', requireAdmin('operator'), wrap(A.partners));
  r.post('/partners', requireAdmin('operator'), wrap(A.upsertPartner));
  r.post('/partners/:id/referral-codes', requireAdmin('operator'), wrap(A.addReferralCode));
  r.get('/partners/:id/consented-share', requireAdmin('operator'), wrap(A.consentedShare));
  return r;
}
