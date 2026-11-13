/// Items & coverage domain: entities and repository contract.
class ItemSummary {
  const ItemSummary({
    required this.id,
    required this.name,
    this.brand,
    this.model,
    this.retailer,
    this.purchaseDate,
    this.price,
    this.currency = 'USD',
    this.categorySlug,
    this.lifecycle = 'owned',
    this.archived = false,
    this.nearestCoverageEnd,
    this.coverageCount = 0,
    this.hasUnconfirmedCoverage = false,
    this.nextReturnDeadline,
    this.nextRegistrationDeadline,
    this.registrationPending = false,
    this.documentCount = 0,
    this.hasReceipt = false,
    this.createdAt,
  });
  final String id, name;
  final String? brand, model, retailer, purchaseDate, price, categorySlug, nearestCoverageEnd, nextReturnDeadline, nextRegistrationDeadline, createdAt;
  final String currency, lifecycle;
  final bool archived, hasUnconfirmedCoverage, registrationPending, hasReceipt;
  final int coverageCount, documentCount;
}

class Warranty {
  const Warranty({
    required this.id,
    required this.coverageType,
    this.provider,
    required this.termKind,
    required this.certainty,
    this.startAnchor,
    this.startDate,
    this.endDate,
    this.durationMonths,
    this.conditions,
    this.estimateAccepted = false,
    this.contractState = 'active',
    this.timeStatus,
    this.daysRemaining,
    this.disclosure,
    this.policyNumber,
    this.termsUrl,
    this.notes,
    this.version = 1,
    this.alertsEnabled = false,
  });
  final String id, coverageType, termKind, certainty, contractState;
  final String? provider, startAnchor, startDate, endDate, conditions, timeStatus, disclosure, policyNumber, termsUrl, notes;
  final int? durationMonths, daysRemaining;
  final bool estimateAccepted, alertsEnabled;
  final int version;
}

class ReturnWindow {
  const ReturnWindow({
    required this.id,
    this.retailer,
    required this.termsState,
    required this.anchor,
    this.anchorDate,
    this.windowDays,
    this.deadline,
    required this.deadlineBasis,
    required this.certainty,
    this.estimateAccepted = false,
    required this.state,
    this.returnQuantity,
    this.rma,
    this.tracking,
    this.initiatedAt,
    this.shippedAt,
    this.receivedAt,
    this.refundedAt,
    this.refundAmount,
    this.dismissed = false,
    this.version = 1,
    this.meaningLabel,
  });
  final String id, termsState, anchor, deadlineBasis, certainty, state;
  final String? retailer, anchorDate, deadline, rma, tracking, initiatedAt, shippedAt, receivedAt, refundedAt, refundAmount, meaningLabel;
  final int? windowDays, returnQuantity;
  final bool estimateAccepted, dismissed;
  final int version;
}

class Registration {
  const Registration({
    required this.id,
    required this.requirement,
    this.provider,
    this.url,
    this.deadline,
    required this.certainty,
    required this.status,
    this.completedAt,
    this.reference,
    this.benefit,
    this.version = 1,
  });
  final String id, requirement, certainty, status;
  final String? provider, url, deadline, completedAt, reference, benefit;
  final int version;
  bool get done => status == 'user_reported_complete' || status == 'confirmed_with_evidence';
}

class ItemDoc {
  const ItemDoc({required this.attachmentId, required this.fileType, this.filename, this.mime, this.pages, required this.role, this.state, this.createdAt});
  final String attachmentId, fileType, role;
  final String? filename, mime, state, createdAt;
  final int? pages;
}

class TimelineEvent {
  const TimelineEvent({this.date, required this.kind, required this.label, this.certainty});
  final String? date, certainty;
  final String kind, label;
}

class ClaimRef {
  const ClaimRef({required this.id, required this.status, required this.kind, this.provider});
  final String id, status, kind;
  final String? provider;
}

class ItemDetail {
  const ItemDetail({
    required this.summary,
    this.serial,
    this.sku,
    this.orderNumber,
    this.deliveryDate,
    this.priceIsEstimated = false,
    this.condition = 'unknown',
    this.notes,
    this.categoryId,
    this.purchaseGroupId,
    this.paymentCardId,
    this.quantity = 1,
    required this.version,
    required this.warranties,
    required this.returns,
    required this.registrations,
    required this.documents,
    required this.claims,
    required this.timeline,
  });
  final ItemSummary summary;
  final String? serial, sku, orderNumber, deliveryDate, notes, categoryId, purchaseGroupId, paymentCardId;
  final bool priceIsEstimated;
  final String condition;
  final int quantity, version;
  final List<Warranty> warranties;
  final List<ReturnWindow> returns;
  final List<Registration> registrations;
  final List<ItemDoc> documents;
  final List<ClaimRef> claims;
  final List<TimelineEvent> timeline;
}

class Category {
  const Category(this.id, this.slug, this.name);
  final String id, slug, name;
}

class ItemQuery {
  const ItemQuery({this.q = '', this.status, this.categoryId, this.sort = 'coverage_urgency', this.archived = 'false', this.lifecycle = 'owned'});
  final String q;
  final String? status, categoryId;
  final String sort, archived, lifecycle;
  ItemQuery copyWith({String? q, String? status, bool clearStatus = false, String? categoryId, bool clearCategory = false, String? sort, String? archived, String? lifecycle}) =>
      ItemQuery(
        q: q ?? this.q,
        status: clearStatus ? null : (status ?? this.status),
        categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
        sort: sort ?? this.sort,
        archived: archived ?? this.archived,
        lifecycle: lifecycle ?? this.lifecycle,
      );
  @override
  bool operator ==(Object o) => o is ItemQuery && o.q == q && o.status == status && o.categoryId == categoryId && o.sort == sort && o.archived == archived && o.lifecycle == lifecycle;
  @override
  int get hashCode => Object.hash(q, status, categoryId, sort, archived, lifecycle);
}

class SaveResult {
  const SaveResult({required this.purchaseGroupId, required this.itemIds, required this.created, this.warnings = const []});
  final String purchaseGroupId;
  final List<String> itemIds;
  final bool created;
  final List<String> warnings;
}

abstract interface class ItemsRepository {
  Future<List<ItemSummary>> list(ItemQuery query);
  Future<ItemDetail> detail(String id);
  Future<SaveResult> quickAdd(Map<String, dynamic> body, {required String idempotencyKey});
  Future<SaveResult> savePurchase(Map<String, dynamic> body, {required String idempotencyKey});
  Future<void> update(String id, Map<String, dynamic> patch, {int? version});
  Future<void> delete(String id);
  Future<Map<String, dynamic>> suggestions(String id);
  Future<List<Category>> categories();

  Future<void> addWarranty(String itemId, Map<String, dynamic> body);
  Future<void> updateWarranty(String id, Map<String, dynamic> patch, {int? version});
  Future<void> deleteWarranty(String id);
  Future<void> addReturnWindow(String itemId, Map<String, dynamic> body);
  Future<void> updateReturnWindow(String id, Map<String, dynamic> patch, {int? version});
  Future<void> addRegistration(String itemId, Map<String, dynamic> body);
  Future<void> updateRegistration(String id, Map<String, dynamic> patch, {int? version});
}
