/**
 * Request validators. Strict objects reject unknown keys (including any attempt
 * to send user_id or other ownership fields).
 */
import { z } from 'zod';
import { isValidIsoDate, isValidTimeZone } from '../lib/dates.js';

export const IsoDate = z.string().refine(isValidIsoDate, 'Expected a valid YYYY-MM-DD date');
export const Money = z
  .union([z.number(), z.string()])
  .transform((v) => (typeof v === 'number' ? v.toFixed(2) : v.trim()))
  .refine((s) => /^\d{1,10}(\.\d{1,2})?$/.test(s), 'Expected a non-negative amount with at most 2 decimals');
export const Currency = z.enum(['USD', 'CAD', 'GBP']);
export const Country = z.enum(['US', 'CA', 'GB']);
export const Uuid = z.string().uuid();
const Url = z.string().url().max(2048).refine((u) => /^https?:\/\//i.test(u), 'Only http(s) URLs');
const Text = (max: number) => z.string().trim().max(max);

// ---------------------------------------------------------------------------
// Auth & profile
// ---------------------------------------------------------------------------
export const SignUpBody = z.strictObject({
  email: z.string().email().max(320),
  password: z.string().min(10).max(128),
  display_name: Text(120).optional(),
  acquisition_channel: z.enum(['organic', 'paid_social', 'paid_search', 'creator', 'referral', 'partner', 'app_store_search', 'other']).optional(),
  referral_code: Text(64).optional(),
});
export const SignInBody = z.strictObject({ email: z.string().email(), password: z.string().min(1).max(128) });
export const IdTokenBody = z.strictObject({
  provider: z.enum(['google', 'apple']),
  id_token: z.string().min(20).max(8192),
  nonce: z.string().max(256).optional(),
  access_token: z.string().max(8192).optional(),
});
export const RefreshBody = z.strictObject({ refresh_token: z.string().min(10).max(4096) });
export const EmailBody = z.strictObject({ email: z.string().email().max(320) });
export const PasswordUpdateBody = z.strictObject({ password: z.string().min(10).max(128) });
export const LinkIntentBody = z.strictObject({ provider: z.enum(['google', 'apple', 'email']) });

const Offsets = z.array(z.number().int().min(0).max(365)).max(6);
const PrefBlock = z.strictObject({ enabled: z.boolean(), offsets_days: Offsets.optional() });
export const ProfilePatch = z.strictObject({
  display_name: Text(120).nullable().optional(),
  avatar_url: Url.nullable().optional(),
  default_currency: Currency.optional(),
  country_code: Country.optional(),
  timezone: z.string().refine(isValidTimeZone, 'Unknown IANA timezone').optional(),
  alert_local_time: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).optional(),
  onboarding_completed: z.boolean().optional(),
  analytics_consent: z.boolean().optional(),
  notification_preferences: z
    .strictObject({
      warranty: PrefBlock.optional(),
      return: PrefBlock.optional(),
      registration: PrefBlock.optional(),
      claim_follow_up: PrefBlock.optional(),
      maintenance: PrefBlock.optional(),
      monthly_digest: z.strictObject({ enabled: z.boolean() }).optional(),
    })
    .optional(),
});
export const AiConsentBody = z.strictObject({ granted: z.boolean(), consent_version: z.string().min(1).max(32) });

export const DeviceBody = z.strictObject({
  installation_id: z.string().min(8).max(128),
  platform: z.enum(['ios', 'android', 'web']),
  push_token: z.string().max(4096).nullable().optional(),
  permission_state: z.enum(['unknown', 'granted', 'denied', 'provisional']),
  app_version: Text(32).optional(),
  locale: Text(35).optional(),
  timezone: z.string().refine(isValidTimeZone).optional(),
});

// ---------------------------------------------------------------------------
// Coverage
// ---------------------------------------------------------------------------
export const WarrantyInput = z.strictObject({
  coverage_type: z.enum(['manufacturer', 'retailer', 'extended', 'protection_plan', 'credit_card', 'statutory_note', 'other']),
  provider_name: Text(200).nullable().optional(),
  term_kind: z.enum(['fixed_date', 'duration', 'lifetime', 'conditional', 'unknown']).default('unknown'),
  date_certainty: z.enum(['document_verified', 'user_confirmed', 'estimated', 'unknown']).optional(),
  start_anchor: z.enum(['purchase_date', 'delivery_date', 'custom', 'unknown']).optional(),
  start_date: IsoDate.nullable().optional(),
  end_date: IsoDate.nullable().optional(),
  duration_months: z.number().int().min(1).max(1200).nullable().optional(),
  conditional_terms: Text(2000).nullable().optional(),
  accept_estimate: z.boolean().optional(),
  source_kind: z.enum(['receipt', 'warranty_document', 'provider_website', 'user_entry', 'reference_suggestion', 'ai_extraction', 'card_benefit_reference']).optional(),
  source_url: Url.nullable().optional(),
  source_attachment_id: Uuid.nullable().optional(),
  source_reference_id: Uuid.nullable().optional(),
  source_checked_at: z.string().datetime().nullable().optional(),
  confirm: z.boolean().optional(),
  contract_state: z.enum(['active', 'cancelled', 'voided', 'transferred', 'superseded']).optional(),
  policy_number: Text(120).nullable().optional(),
  terms_url: Url.nullable().optional(),
  payment_card_id: Uuid.nullable().optional(),
  notes: Text(4000).nullable().optional(),
});
export const WarrantyPatch = WarrantyInput.partial();

export const ReturnWindowInput = z.strictObject({
  retailer_name: Text(200).nullable().optional(),
  terms_state: z.enum(['known', 'suggested', 'unknown']).optional(),
  policy_anchor: z.enum(['purchase_date', 'delivery_date', 'custom', 'unknown']).optional(),
  anchor_date: IsoDate.nullable().optional(),
  window_days: z.number().int().min(0).max(730).nullable().optional(),
  return_deadline: IsoDate.nullable().optional(),
  deadline_basis: z.enum(['request_by', 'postmark_by', 'merchant_receipt_by', 'unknown']).optional(),
  date_certainty: z.enum(['document_verified', 'user_confirmed', 'estimated', 'unknown']).optional(),
  accept_estimate: z.boolean().optional(),
  confirm: z.boolean().optional(),
  source_kind: z.enum(['receipt', 'retailer_website', 'user_entry', 'reference_suggestion', 'ai_extraction']).optional(),
  source_url: Url.nullable().optional(),
  source_reference_id: Uuid.nullable().optional(),
  source_attachment_id: Uuid.nullable().optional(),
  conditions: Text(2000).nullable().optional(),
  restocking_fee_percent: z.number().min(0).max(100).nullable().optional(),
  return_state: z.enum(['not_started', 'initiated', 'shipped', 'received_by_merchant', 'refunded', 'rejected', 'cancelled']).optional(),
  return_quantity: z.number().int().positive().nullable().optional(),
  rma_number: Text(120).nullable().optional(),
  tracking_reference: Text(200).nullable().optional(),
  refund_amount: Money.nullable().optional(),
  refund_currency: Currency.nullable().optional(),
  dismissed: z.boolean().optional(),
  notes: Text(4000).nullable().optional(),
});
export const ReturnWindowPatch = ReturnWindowInput.partial();

export const RegistrationInput = z.strictObject({
  requirement_state: z.enum(['unknown', 'optional', 'extra_benefit', 'terms_stated_required']).optional(),
  benefit_description: Text(1000).nullable().optional(),
  provider_name: Text(200).nullable().optional(),
  registration_url: Url.nullable().optional(),
  deadline: IsoDate.nullable().optional(),
  deadline_certainty: z.enum(['document_verified', 'user_confirmed', 'estimated', 'unknown']).optional(),
  status: z.enum(['not_started', 'link_opened', 'user_reported_complete', 'confirmed_with_evidence', 'not_applicable', 'dismissed']).optional(),
  confirmation_attachment_id: Uuid.nullable().optional(),
  confirmation_reference: Text(200).nullable().optional(),
  source_kind: z.enum(['warranty_document', 'provider_website', 'user_entry', 'reference_suggestion', 'ai_extraction']).optional(),
  source_url: Url.nullable().optional(),
  notes: Text(4000).nullable().optional(),
});
export const RegistrationPatch = RegistrationInput.partial();

// ---------------------------------------------------------------------------
// Purchases & items
// ---------------------------------------------------------------------------
const ItemCore = {
  name: Text(200).min(1),
  brand: Text(120).nullable().optional(),
  brand_id: Uuid.nullable().optional(),
  model_number: Text(120).nullable().optional(),
  serial_number: Text(120).nullable().optional(),
  sku: Text(120).nullable().optional(),
  category_id: Uuid.nullable().optional(),
  condition_at_purchase: z.enum(['new', 'open_box', 'refurbished', 'used', 'unknown']).optional(),
  quantity: z.number().int().min(1).max(10_000).optional(),
  notes: Text(4000).nullable().optional(),
};

export const PurchaseLineInput = z.strictObject({
  original_description: Text(500).nullable().optional(),
  confirmed_name: Text(200).nullable().optional(),
  sku: Text(120).nullable().optional(),
  quantity: z.number().positive().max(100_000).optional(),
  unit_amount: Money.nullable().optional(),
  line_amount: Money.nullable().optional(),
  confirmation_state: z.enum(['extracted', 'user_confirmed', 'user_edited', 'excluded']).optional(),
  /** Present when the user selects this line to become a tracked item. */
  track: z
    .strictObject({
      ...ItemCore,
      name: Text(200).min(1).optional(),
      attachment_ids: z.array(Uuid).max(20).optional(),
      warranties: z.array(WarrantyInput).max(10).optional(),
      return_window: ReturnWindowInput.nullable().optional(),
      registration: RegistrationInput.nullable().optional(),
    })
    .nullable()
    .optional(),
});

export const PurchaseInput = z.strictObject({
  retailer: Text(200).nullable().optional(),
  order_number: Text(120).nullable().optional(),
  purchase_date: IsoDate.nullable().optional(),
  delivery_date: IsoDate.nullable().optional(),
  currency: Currency.optional(),
  subtotal: Money.nullable().optional(),
  tax: Money.nullable().optional(),
  shipping: Money.nullable().optional(),
  discount: Money.nullable().optional(),
  total_paid: Money.nullable().optional(),
  source: z.enum(['manual', 'receipt_scan', 'product_scan', 'import', 'email_forward', 'share']).optional(),
  payment_card_id: Uuid.nullable().optional(),
  scan_job_id: Uuid.nullable().optional(),
  capture_draft_id: Uuid.nullable().optional(),
  correction_count: z.number().int().min(0).max(1000).optional(),
  notes: Text(4000).nullable().optional(),
  attachment_ids: z.array(Uuid).max(20).optional(),
  lines: z.array(PurchaseLineInput).min(1).max(100),
});

/** Manual quick-add: one item, optional receipt and coverage. */
export const QuickAddItemInput = z.strictObject({
  ...ItemCore,
  retailer_name: Text(200).nullable().optional(),
  order_number: Text(120).nullable().optional(),
  purchase_date: IsoDate.nullable().optional(),
  delivery_date: IsoDate.nullable().optional(),
  purchase_price: Money.nullable().optional(),
  currency: Currency.optional(),
  payment_card_id: Uuid.nullable().optional(),
  attachment_ids: z.array(Uuid).max(20).optional(),
  warranties: z.array(WarrantyInput).max(10).optional(),
  return_window: ReturnWindowInput.nullable().optional(),
  registration: RegistrationInput.nullable().optional(),
});

export const ItemPatch = z.strictObject({
  ...ItemCore,
  name: Text(200).min(1).optional(),
  retailer_name: Text(200).nullable().optional(),
  order_number: Text(120).nullable().optional(),
  purchase_date: IsoDate.nullable().optional(),
  delivery_date: IsoDate.nullable().optional(),
  purchase_price: Money.nullable().optional(),
  price_is_estimated: z.boolean().optional(),
  currency: Currency.optional(),
  lifecycle_state: z.enum(['owned', 'returned', 'sold', 'gifted', 'lost', 'disposed']).optional(),
  archived: z.boolean().optional(),
  payment_card_id: Uuid.nullable().optional(),
  primary_image_attachment_id: Uuid.nullable().optional(),
});

export const ItemListQuery = z.object({
  q: z.string().trim().max(100).optional(),
  category_id: Uuid.optional(),
  status: z.enum(['active_coverage', 'expired_coverage', 'return_soon', 'registration_pending', 'unconfirmed']).optional(),
  lifecycle: z.enum(['owned', 'returned', 'sold', 'gifted', 'lost', 'disposed', 'any']).default('owned'),
  archived: z.enum(['true', 'false', 'any']).default('false'),
  sort: z.enum(['purchase_date', 'created_at', 'coverage_urgency', 'value', 'name']).default('created_at'),
  limit: z.coerce.number().int().min(1).max(100).default(25),
  offset: z.coerce.number().int().min(0).default(0),
});

export const TrackLineBody = z.strictObject({ ...ItemCore, name: Text(200).min(1).optional(), purchase_price: Money.nullable().optional() });

// ---------------------------------------------------------------------------
// Attachments, scans, capture
// ---------------------------------------------------------------------------
export const BeginUploadBody = z.strictObject({
  file_type: z.enum(['receipt', 'product_photo', 'warranty_card', 'manual', 'registration', 'claim_evidence', 'service_record', 'other']),
  filename: Text(255).min(1),
  mime_type: z.enum(['image/jpeg', 'image/png', 'image/heic', 'image/heif', 'application/pdf']),
  byte_size: z.number().int().positive(),
});
export const AttachmentPatch = z.strictObject({
  original_filename: Text(255).optional(),
  file_type: BeginUploadBody.shape.file_type.optional(),
});
export const LinkAttachmentBody = z.strictObject({
  target: z.enum(['item', 'purchase', 'claim']),
  target_id: Uuid,
  role: z.enum(['receipt', 'product_photo', 'warranty_card', 'manual', 'registration', 'document']).optional(),
  include_in_pack: z.boolean().optional(),
  caption: Text(300).optional(),
});
export const ScanBody = z
  .strictObject({
    feature: z.enum(['receipt_extraction', 'product_label_extraction']).default('receipt_extraction'),
    attachment_id: Uuid.optional(),
    ocr_text: z.string().max(20_000).optional(),
    capture_draft_id: Uuid.optional(),
  })
  .refine((b) => Boolean(b.attachment_id) !== Boolean(b.ocr_text), 'Provide exactly one of attachment_id or ocr_text');
export const CaptureDraftBody = z.strictObject({
  source: z.enum(['share_extension', 'upload', 'manual']),
  title: Text(200).optional(),
  attachment_ids: z.array(Uuid).min(1).max(10),
  auto_scan: z.boolean().default(false),
});

// ---------------------------------------------------------------------------
// Reminders
// ---------------------------------------------------------------------------
export const CustomReminderBody = z.strictObject({
  title: Text(200).min(1),
  body: Text(500).optional(),
  date: IsoDate,
  local_time: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).optional(),
  item_id: Uuid.optional(),
});

// ---------------------------------------------------------------------------
// Claims & outcomes
// ---------------------------------------------------------------------------
export const ClaimCreateBody = z.strictObject({
  item_id: Uuid,
  warranty_id: Uuid.nullable().optional(),
  return_window_id: Uuid.nullable().optional(),
  claim_kind: z.enum(['warranty_repair', 'warranty_replacement', 'return_refund', 'protection_plan', 'credit_card_benefit', 'other']),
  issue_description: Text(5000).min(1),
  issue_started_on: IsoDate.nullable().optional(),
  provider_name: Text(200).nullable().optional(),
  provider_contact: z
    .strictObject({ email: z.string().email().optional(), phone: Text(40).optional(), url: Url.optional(), address: Text(500).optional() })
    .optional(),
  attachment_ids: z.array(Uuid).max(30).optional(),
});
export const ClaimPatch = z.strictObject({
  claim_kind: ClaimCreateBody.shape.claim_kind.optional(),
  issue_description: Text(5000).min(1).optional(),
  issue_started_on: IsoDate.nullable().optional(),
  provider_name: Text(200).nullable().optional(),
  provider_contact: ClaimCreateBody.shape.provider_contact,
  claim_number: Text(120).nullable().optional(),
  status: z.enum(['draft', 'ready_to_submit', 'submitted_by_user', 'in_review', 'info_requested', 'approved', 'denied', 'resolved', 'withdrawn']).optional(),
  follow_up_on: IsoDate.nullable().optional(),
  resolution_notes: Text(4000).nullable().optional(),
  ai_draft_reviewed: z.boolean().optional(),
});
/** The user reviews (and may edit) the facts that go into the snapshot. */
export const ClaimSnapshotBody = z.strictObject({
  facts: z.record(z.string(), z.unknown()).refine((v) => JSON.stringify(v).length <= 20_000, 'Snapshot too large'),
});
export const ClaimPackBody = z.strictObject({ format: z.enum(['text', 'pdf']).default('pdf') });
export const OutcomeBody = z.strictObject({
  claim_id: Uuid.optional(),
  return_window_id: Uuid.optional(),
  outcome_type: z.enum(['refund_received', 'repair_completed', 'replacement_received', 'denied', 'withdrawn']),
  amount: Money.nullable().optional(),
  currency: Currency.nullable().optional(),
  outcome_date: IsoDate.optional(),
  evidence_level: z.enum(['user_reported', 'document_attached', 'provider_confirmation']).default('user_reported'),
  evidence_attachment_id: Uuid.nullable().optional(),
  warrantra_helped: z.enum(['yes_significantly', 'yes_somewhat', 'no', 'unsure']).optional(),
  user_comment: Text(2000).optional(),
});

// ---------------------------------------------------------------------------
// Cards, workspaces, portfolio, maintenance, partners, support, analytics
// ---------------------------------------------------------------------------
export const PaymentCardBody = z.strictObject({
  nickname: Text(60).min(1).refine((s) => !/\d{12,}/.test(s.replace(/[\s.-]/g, '')), 'Never enter card numbers'),
  issuer_label: Text(60).optional(),
  network: z.enum(['visa', 'mastercard', 'amex', 'discover', 'other']).optional(),
  card_benefit_id: Uuid.nullable().optional(),
});

export const WorkspaceBody = z.strictObject({ kind: z.enum(['household', 'business']), name: Text(120).min(1) });
export const WorkspacePatch = z.strictObject({ name: Text(120).min(1).optional(), archived: z.boolean().optional() });
export const InviteBody = z.strictObject({ email: z.string().email(), role: z.enum(['admin', 'editor', 'viewer']) });
export const MemberPatch = z.strictObject({ role: z.enum(['admin', 'editor', 'viewer']).optional(), state: z.enum(['active', 'revoked']).optional() });
export const AcceptInviteBody = z.strictObject({ token: z.string().min(20).max(200) });
export const ShareItemBody = z.strictObject({ item_id: Uuid, location_id: Uuid.nullable().optional() });
export const LocationBody = z.strictObject({
  name: Text(120).min(1),
  kind: z.enum(['property', 'unit', 'site', 'room', 'other']).optional(),
  parent_location_id: Uuid.nullable().optional(),
  address_line: Text(300).nullable().optional(),
  notes: Text(2000).nullable().optional(),
});
export const AssignBody = z.strictObject({ item_id: Uuid, location_id: Uuid, note: Text(1000).optional() });
export const ServiceRecordBody = z.strictObject({
  item_id: Uuid,
  workspace_id: Uuid.nullable().optional(),
  service_date: IsoDate,
  service_type: z.enum(['repair', 'maintenance', 'inspection', 'installation', 'warranty_service', 'other']),
  provider_name: Text(200).nullable().optional(),
  description: Text(4000).nullable().optional(),
  cost_amount: Money.nullable().optional(),
  cost_currency: Currency.nullable().optional(),
  claim_id: Uuid.nullable().optional(),
  attachment_ids: z.array(Uuid).max(20).optional(),
});
export const MaintenanceTaskBody = z.strictObject({
  title: Text(200).min(1),
  description: Text(2000).nullable().optional(),
  item_id: Uuid.nullable().optional(),
  workspace_id: Uuid.nullable().optional(),
  requirement_basis: z.enum(['user_preference', 'manufacturer_recommended', 'warranty_terms_stated', 'unknown']).optional(),
  recurrence_unit: z.enum(['day', 'week', 'month', 'year']).nullable().optional(),
  recurrence_interval: z.number().int().min(1).max(120).nullable().optional(),
  next_due_on: IsoDate.nullable().optional(),
  reminder_enabled: z.boolean().optional(),
  state: z.enum(['active', 'paused', 'archived']).optional(),
});
export const MaintenanceCompleteBody = z.strictObject({
  service_date: IsoDate,
  notes: Text(2000).optional(),
  provider_name: Text(200).optional(),
  cost_amount: Money.optional(),
  cost_currency: Currency.optional(),
});
export const PartnerConsentBody = z.strictObject({
  partner_id: Uuid,
  scope: z.enum(['share_contact', 'share_purchase_summary', 'receive_offers']),
  consent_text_version: z.string().min(1).max(32),
});
export const SupportTicketBody = z.strictObject({
  subject: Text(200).min(1),
  category: z.enum(['general', 'billing', 'privacy', 'deletion', 'bug', 'reminders', 'claims', 'data_export']).default('general'),
  message: Text(10_000).min(1),
});
export const PublicSupportBody = SupportTicketBody.extend({ contact_email: z.string().email() });
export const SupportMessageBody = z.strictObject({ message: Text(10_000).min(1) });
export const AnalyticsBatchBody = z.strictObject({
  events: z
    .array(
      z.strictObject({
        event_name: z.string().min(1).max(64),
        properties: z.record(z.string(), z.union([z.string().max(64), z.number(), z.boolean()])).optional(),
        occurred_at: z.string().datetime(),
      }),
    )
    .min(1)
    .max(50),
  platform: z.enum(['ios', 'android', 'web']),
  app_version: Text(32).optional(),
});

export const DeletionConfirmBody = z.strictObject({ confirm: z.literal('DELETE MY ACCOUNT') });
export const WebDeletionVerifyBody = z.strictObject({ token: z.string().min(20).max(200) });
