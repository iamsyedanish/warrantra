// Design-review demo: in-memory repositories with sample purchases.
// Enabled only with --dart-define=DEMO=true; never talks to the API.

import '../core/utils/format.dart';
import '../features/account/domain/account.dart';
import '../features/account/presentation/account_providers.dart';
import '../features/auth/domain/auth_repository.dart';
import '../features/auth/presentation/session_controller.dart';
import '../features/capture/domain/capture.dart';
import '../features/capture/presentation/capture_providers.dart';
import '../features/cards/domain/cards.dart';
import '../features/cards/presentation/cards_providers.dart';
import '../features/claims/domain/claims.dart';
import '../features/claims/presentation/claims_providers.dart';
import '../features/home/domain/action_center.dart';
import '../features/home/presentation/home_providers.dart';
import '../features/items/domain/items.dart';
import '../features/items/presentation/items_providers.dart';
import '../features/household/domain/household.dart';
import '../features/household/presentation/household_providers.dart';
import '../features/maintenance/domain/maintenance.dart';
import '../features/maintenance/presentation/maintenance_providers.dart';
import '../features/settings/domain/settings.dart';
import '../features/settings/presentation/settings_providers.dart';
import '../features/vault/domain/vault.dart';
import '../features/vault/presentation/vault_providers.dart';

const demoMode = bool.fromEnvironment('DEMO');

String _d(int days) => isoDate(DateTime.now().add(Duration(days: days)))!;

final demoOverrides = [
  authRepositoryProvider.overrideWithValue(_Auth()),
  accountRepositoryProvider.overrideWithValue(_Account()),
  actionCenterRepositoryProvider.overrideWithValue(_ActionCenter()),
  itemsRepositoryProvider.overrideWithValue(_Items()),
  vaultRepositoryProvider.overrideWithValue(_Vault()),
  claimsRepositoryProvider.overrideWithValue(_Claims()),
  cardsRepositoryProvider.overrideWithValue(_Cards()),
  settingsRepositoryProvider.overrideWithValue(_Settings()),
  householdRepositoryProvider.overrideWithValue(_Household()),
  maintenanceRepositoryProvider.overrideWithValue(_Maintenance()),
  captureRepositoryProvider.overrideWithValue(_Capture()),
];

/// Writes are accepted and ignored.
mixin _NoWrites {
  @override
  dynamic noSuchMethod(Invocation i) => Future<void>.value();
}

class _Auth with _NoWrites implements AuthRepository {
  @override
  Future<bool> hasSession() async => true;
}

class _Account with _NoWrites implements AccountRepository {
  @override
  Future<Me> me() async => Me(
        profile: const Profile(
          id: 'demo-user',
          email: 'alex.rivera@example.com',
          displayName: 'Alex Rivera',
          timezone: 'America/New_York',
          alertTime: '09:00:00',
          preferences: {},
          aiConsent: true,
          analyticsConsent: false,
          country: 'US',
          currency: 'USD',
          onboardingCompleted: true,
        ),
        plan: const PlanInfo(code: 'free', maxItems: 10, storageBytes: 100 << 20, aiPerMonth: 0, aiTrial: 5, claimPackAssembled: false, aiClaimDraft: false, workspaces: false, emailForwarding: false),
        usage: const Usage(itemsUsed: 6, itemsLimit: 10, storageUsed: 14 << 20, storageLimit: 100 << 20, aiUsed: 3, aiLimit: 5, aiPeriod: 'lifetime', additionsPaused: false),
      );
  @override
  Future<PriceOffer> offer() async => const PriceOffer(annualPrice: 79.99, monthlyPrice: 19.99);
}

class _ActionCenter implements ActionCenterRepository {
  @override
  Future<ActionCenter> load({int horizonDays = 60}) async => ActionCenter(
        title: '5 things need your attention',
        empty: false,
        actions: [
          ActionItem(kind: 'return_deadline', priority: 0, itemId: 'airpods', itemName: 'AirPods Pro (2nd gen)', sourceId: 'r1', dueDate: _d(1), daysLeft: 1, title: 'Return window ends tomorrow', certainty: 'user_confirmed', detail: 'Best Buy · counted from purchase'),
          ActionItem(kind: 'registration_deadline', priority: 1, itemId: 'dyson', itemName: 'Dyson V15 Detect', sourceId: 'g1', dueDate: _d(5), daysLeft: 5, title: 'Registration reminder in 5 days', certainty: 'user_confirmed', detail: 'Date you set · optional, may add benefits'),
          ActionItem(kind: 'claim_follow_up', priority: 1, itemId: 'tv', itemName: 'Samsung 65" QN90D', sourceId: 'c1', dueDate: _d(3), daysLeft: 3, title: 'Follow up on claim CS-48211', detail: 'Costco · sent 11 days ago'),
          ActionItem(kind: 'coverage_ending', priority: 2, itemId: 'tv', itemName: 'Samsung 65" QN90D', sourceId: 'w3', dueDate: _d(27), daysLeft: 27, title: 'Costco coverage ends in 27 days', certainty: 'document_verified', detail: 'Verified from Costco terms'),
          ActionItem(kind: 'maintenance_due', priority: 3, itemId: 'washer', itemName: 'LG front-load washer', dueDate: _d(9), daysLeft: 9, title: 'Drum clean due', detail: 'Your task · every 3 months'),
          ActionItem(kind: 'coverage_ending', priority: 3, itemId: 'macbook', itemName: 'MacBook Air 13"', sourceId: 'w4', dueDate: _d(48), daysLeft: 48, title: 'AppleCare+ ends', certainty: 'estimated'),
        ],
        missing: [
          const ActionItem(kind: 'missing_coverage', priority: 4, itemId: 'washer', itemName: 'LG front-load washer', title: 'Coverage terms unknown', detail: 'No reminder until you add terms'),
          const ActionItem(kind: 'missing_receipt', priority: 4, itemId: 'drill', itemName: 'DeWalt 20V drill', title: 'No receipt saved'),
        ],
      );
}

final _items = <ItemSummary>[
  ItemSummary(id: 'airpods', name: 'AirPods Pro (2nd gen)', brand: 'Apple', model: 'MTJV3AM/A', retailer: 'Best Buy', purchaseDate: _d(-14), price: '249.00', categorySlug: 'audio', nearestCoverageEnd: _d(351), coverageCount: 1, hasUnconfirmedCoverage: true, nextReturnDeadline: _d(1), documentCount: 2, hasReceipt: true),
  ItemSummary(id: 'dyson', name: 'Dyson V15 Detect', brand: 'Dyson', retailer: 'Target', purchaseDate: _d(-24), price: '749.99', categorySlug: 'home', nearestCoverageEnd: _d(706), coverageCount: 1, nextRegistrationDeadline: _d(5), registrationPending: true, documentCount: 1, hasReceipt: true),
  ItemSummary(id: 'tv', name: 'Samsung 65" QN90D', brand: 'Samsung', model: 'QN65QN90D', retailer: 'Costco', purchaseDate: _d(-338), price: '1999.99', categorySlug: 'electronics', nearestCoverageEnd: _d(27), coverageCount: 2, documentCount: 3, hasReceipt: true),
  ItemSummary(id: 'macbook', name: 'MacBook Air 13"', brand: 'Apple', model: 'M3 · 16 GB', retailer: 'Apple Store', purchaseDate: _d(-317), price: '1299.00', categorySlug: 'computers', nearestCoverageEnd: _d(48), coverageCount: 1, hasUnconfirmedCoverage: true, documentCount: 1, hasReceipt: true),
  ItemSummary(id: 'washer', name: 'LG front-load washer', brand: 'LG', model: 'WM4000HWA', retailer: 'Home Depot', purchaseDate: _d(-54), price: '899.00', categorySlug: 'appliances', documentCount: 1, hasReceipt: true),
  ItemSummary(id: 'drill', name: 'DeWalt 20V drill', brand: 'DeWalt', retailer: "Lowe's", purchaseDate: _d(-120), price: '129.00', categorySlug: 'tools', nearestCoverageEnd: _d(975), coverageCount: 1),
];

class _Items with _NoWrites implements ItemsRepository {
  @override
  Future<List<ItemSummary>> list(ItemQuery q) async {
    var out = _items.where((i) => q.q.isEmpty || i.name.toLowerCase().contains(q.q.toLowerCase())).toList();
    if (q.status == 'return_soon') out = out.where((i) => i.nextReturnDeadline != null).toList();
    if (q.status == 'registration_pending') out = out.where((i) => i.registrationPending).toList();
    if (q.status == 'unconfirmed') out = out.where((i) => i.hasUnconfirmedCoverage || i.coverageCount == 0).toList();
    return out;
  }

  @override
  Future<ItemDetail> detail(String id) async {
    final s = _items.firstWhere((i) => i.id == id, orElse: () => _items.first);
    return ItemDetail(
      summary: s,
      serial: 'H7KQ2LMX9P',
      orderNumber: 'BBY01-806512',
      condition: 'new',
      version: 1,
      warranties: s.coverageCount == 0
          ? const []
          : [
              Warranty(id: 'w-$id', coverageType: 'manufacturer', provider: s.brand, termKind: 'duration', certainty: s.hasUnconfirmedCoverage ? 'estimated' : 'document_verified', startAnchor: 'purchase_date', startDate: s.purchaseDate, endDate: s.nearestCoverageEnd, durationMonths: 12, timeStatus: 'active', daysRemaining: daysUntil(s.nearestCoverageEnd)),
              if (id == 'tv') Warranty(id: 'w3', coverageType: 'retailer', provider: 'Costco', termKind: 'fixed_date', certainty: 'document_verified', startDate: s.purchaseDate, endDate: _d(27), timeStatus: 'active', daysRemaining: 27),
            ],
      returns: s.nextReturnDeadline == null
          ? const []
          : [ReturnWindow(id: 'r1', retailer: s.retailer, termsState: 'known', anchor: 'purchase_date', windowDays: 15, deadline: s.nextReturnDeadline, deadlineBasis: 'request_by', certainty: 'user_confirmed', state: 'not_started')],
      registrations: s.registrationPending
          ? [Registration(id: 'g1', requirement: 'optional', provider: s.brand, url: 'https://www.dyson.com/register', deadline: _d(5), certainty: 'user_confirmed', status: 'not_started')]
          : const [],
      documents: s.hasReceipt
          ? [ItemDoc(attachmentId: 'doc-$id', fileType: 'receipt', filename: '${s.retailer} receipt.pdf', mime: 'application/pdf', pages: 1, role: 'receipt', state: 'ready')]
          : const [],
      claims: id == 'tv' ? const [ClaimRef(id: 'c1', status: 'submitted_by_user', kind: 'warranty_repair', provider: 'Samsung')] : const [],
      timeline: [
        TimelineEvent(date: s.purchaseDate, kind: 'purchase', label: 'Bought at ${s.retailer}'),
        if (s.nearestCoverageEnd != null) TimelineEvent(date: s.nearestCoverageEnd, kind: 'coverage_end', label: 'Coverage ends', certainty: 'estimated'),
      ],
    );
  }

  @override
  Future<Map<String, dynamic>> suggestions(String id) async => {'warranties': [], 'return_policies': []};

  @override
  Future<List<Category>> categories() async => const [Category('c1', 'appliances', 'Appliances'), Category('c2', 'electronics', 'Electronics'), Category('c3', 'audio', 'Audio'), Category('c4', 'tools', 'Tools')];
}

class _Vault with _NoWrites implements VaultRepository {
  final _docs = [
    VaultDoc(id: 'doc-airpods', fileType: 'receipt', filename: 'Best Buy receipt.pdf', mime: 'application/pdf', size: 182000, pages: 1, state: 'ready', createdAt: _d(-14), itemIds: const ['airpods']),
    VaultDoc(id: 'doc-tv', fileType: 'receipt', filename: 'Costco order 1129.pdf', mime: 'application/pdf', size: 240000, pages: 2, state: 'ready', createdAt: _d(-338), itemIds: const ['tv']),
    VaultDoc(id: 'doc-w', fileType: 'warranty_card', filename: 'LG warranty card.jpg', mime: 'image/jpeg', size: 910000, state: 'ready', createdAt: _d(-54), itemIds: const ['washer']),
    VaultDoc(id: 'doc-m', fileType: 'manual', filename: 'Dyson V15 manual.pdf', mime: 'application/pdf', size: 4200000, pages: 9, state: 'ready', createdAt: _d(-24)),
  ];
  @override
  Future<List<VaultDoc>> list({String? fileType}) async => _docs.where((d) => fileType == null || d.fileType == fileType).toList();
  @override
  Future<VaultDoc> get(String id) async => _docs.firstWhere((d) => d.id == id, orElse: () => _docs.first);
  @override
  Future<DocImpact> impact(String id) async => const DocImpact(items: [('airpods', 'AirPods Pro (2nd gen)')]);
  @override
  Future<String> url(String id, {int? previewWidth, bool download = false}) async => 'https://example.invalid/$id';
}

class _Claims with _NoWrites implements ClaimsRepository {
  final _c = Claim(id: 'c1', itemId: 'tv', itemLabel: 'Samsung 65" QN90D', kind: 'warranty_repair', status: 'submitted_by_user', issue: 'Vertical green line on the left third of the screen.', providerName: 'Samsung', claimNumber: 'CS-48211', followUpOn: _d(3), submittedAt: _d(-11), snapshotReviewed: true, packs: [ClaimPack(id: 'p1', format: 'pdf', level: 'basic', generatedAt: _d(-11))]);
  @override
  Future<List<Claim>> list() async => [_c];
  @override
  Future<Claim> get(String id) async => _c;
  @override
  Future<List<Outcome>> outcomes() async => [Outcome(id: 'o1', type: 'refund_received', amount: '699.95', currency: 'USD', date: _d(-60), evidence: 'document_attached', helped: 'yes_significantly', returnWindowId: 'r0')];
  @override
  Future<OutcomeSummary> outcomeSummary() async => const OutcomeSummary(byType: {'refund_received': 1}, refunds: {'USD': 699.95}, note: '');
}

class _Cards with _NoWrites implements CardsRepository {
  @override
  Future<List<PaymentCard>> list() async => const [PaymentCard(id: 'k1', nickname: 'Costco Visa · Household')];
  @override
  Future<List<CardBenefit>> benefits() async => const [];
}

class _Settings with _NoWrites implements SettingsRepository {
  @override
  Future<List<ExportJob>> exports() async => const [];
  @override
  Future<List<DeletionStatus>> deletionStatus() async => const [];
  @override
  Future<AnnualSummary> annual(int year) async => const AnnualSummary({'purchases_tracked': 8, 'receipts_stored': 11, 'returns_completed_before_deadline': 2, 'claims_started': 1, 'registrations_completed': 1, 'outcomes': 1, 'refunds_reported': {'USD': 699.95}});
  @override
  Future<List<SupportTicket>> tickets() async => const [];
}


class _Household with _NoWrites implements HouseholdRepository {
  final _ws = const Workspace(
    id: 'ws1',
    kind: 'household',
    name: 'Rivera home',
    ownerId: 'demo-user',
    members: [Member(userId: 'demo-user', role: 'owner', state: 'active', name: 'Alex Rivera'), Member(userId: 'u2', role: 'editor', state: 'active', name: 'Sam Rivera')],
    items: [SharedItem(itemId: 'washer', name: 'LG front-load washer', brand: 'LG', model: 'WM4000HWA')],
  );
  @override
  Future<List<Workspace>> list() async => [_ws];
  @override
  Future<Workspace> get(String id) async => _ws;
  @override
  Future<ForwardingAddress?> forwardingAddress() async => const ForwardingAddress('alex-7f3k2@in.warrantra.app', null);
  @override
  Future<List<InboundEmail>> inboundLog() async => [InboundEmail(id: 'e1', state: 'draft_created', attachments: 1, receivedAt: _d(-3), draftId: 'd1')];
}

class _Maintenance with _NoWrites implements MaintenanceRepository {
  @override
  Future<List<MaintenanceTask>> tasks({String? itemId}) async => [MaintenanceTask(id: 't1', title: 'Drum clean', itemId: 'washer', unit: 'month', interval: 3, nextDue: _d(9), basis: 'manufacturer_recommended')];
  @override
  Future<List<ServiceRecord>> records(String itemId) async => [ServiceRecord(id: 's1', date: _d(-50), type: 'installation', provider: 'Home Depot installer', cost: '0.00', currency: 'USD')];
}

class _Capture with _NoWrites implements CaptureRepository {
  @override
  Future<List<CaptureDraftSummary>> drafts() async => [CaptureDraftSummary(id: 'd1', source: 'email_forward', state: 'ready_for_review', title: 'Target order 9021-4471', scanJobId: 'scan1', createdAt: _d(-3))];
  @override
  Future<ScanJob> scan(String id) async => id == 'label1'
      ? const ScanJob(
          id: 'label1',
          feature: 'product_label_extraction',
          state: 'succeeded',
          label: LabelDraft(
            productName: DraftField(value: 'Sony WH-1000XM5 headphones', status: 'extracted'),
            category: 'audio',
            brand: DraftField(value: 'Sony', evidence: 'SONY', status: 'extracted'),
            model: DraftField(value: 'WH-1000XM5', evidence: 'MODEL WH-1000XM5', status: 'extracted'),
            serial: DraftField(value: '5512408', evidence: 'S/N 5512408', status: 'extracted'),
            manufactureDate: DraftField(),
            warnings: [],
          ),
        )
      : ScanJob(
          id: id,
          feature: 'receipt_extraction',
          state: 'succeeded',
          receipt: ReceiptDraft(
            merchant: const DraftField(value: "Lowe's", evidence: "LOWE'S #1842", status: 'extracted'),
            purchaseDate: DraftField(value: _d(-1), evidence: '11/12/26', status: 'extracted'),
            deliveryDate: const DraftField(),
            orderNumber: const DraftField(value: '41872', evidence: 'TRANS 41872', status: 'extracted'),
            currency: const DraftField(value: 'USD', status: 'extracted'),
            subtotal: const DraftField(value: '306.98', status: 'extracted'),
            tax: const DraftField(value: '22.26', status: 'extracted'),
            shipping: const DraftField(),
            discount: const DraftField(),
            total: const DraftField(value: '329.24', evidence: 'TOTAL 329.24', status: 'extracted'),
            lines: const [
              DraftLine(index: 0, description: 'DEWALT 20V DRILL', quantity: 1, lineAmount: '129.00'),
              DraftLine(index: 1, description: 'RING DOORBELL 4', quantity: 1, lineAmount: '177.98'),
            ],
            returnMentions: const [],
            warrantyMentions: const [],
            warnings: const ['delivery date: not found'],
          ),
        );
}
