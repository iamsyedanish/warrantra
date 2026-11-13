import '../../../core/network/api_client.dart';
import '../../../core/utils/format.dart';
import '../domain/items.dart';

class ItemsRepositoryImpl implements ItemsRepository {
  ItemsRepositoryImpl(this._api);
  final ApiClient _api;

  @override
  Future<List<ItemSummary>> list(ItemQuery q) async {
    final rows = await _api.get<List<dynamic>>('/items', query: {
      if (q.q.isNotEmpty) 'q': q.q,
      if (q.status != null) 'status': q.status,
      if (q.categoryId != null) 'category_id': q.categoryId,
      'sort': q.sort,
      'archived': q.archived,
      'lifecycle': q.lifecycle,
      'limit': 100,
    });
    return rows.whereType<Map>().map((r) => itemSummaryFromJson(Map<String, dynamic>.from(r))).toList();
  }

  @override
  Future<ItemDetail> detail(String id) async => itemDetailFromJson(await _api.get<Json>('/items/$id'));

  SaveResult _save(Json j) => SaveResult(
        purchaseGroupId: j.str('purchase_group_id'),
        itemIds: (j['item_ids'] as List? ?? const []).map((e) => e.toString()).toList(),
        created: j.b('created'),
        warnings: j.l('warnings').map((w) => w.str('message')).toList(),
      );

  @override
  Future<SaveResult> quickAdd(Map<String, dynamic> body, {required String idempotencyKey}) async =>
      _save(await _api.post<Json>('/items', body: body, idempotencyKey: idempotencyKey));

  @override
  Future<SaveResult> savePurchase(Map<String, dynamic> body, {required String idempotencyKey}) async =>
      _save(await _api.post<Json>('/purchases', body: body, idempotencyKey: idempotencyKey));

  @override
  Future<void> update(String id, Map<String, dynamic> patch, {int? version}) => _api.patch<Json>('/items/$id', body: patch, ifMatchVersion: version);

  @override
  Future<void> delete(String id) => _api.delete<dynamic>('/items/$id');

  @override
  Future<Map<String, dynamic>> suggestions(String id) => _api.get<Json>('/items/$id/coverage-suggestions');

  @override
  Future<List<Category>> categories() async {
    final rows = await _api.get<List<dynamic>>('/reference/categories');
    return rows.whereType<Map>().map((r) => Category(r['id'].toString(), r['slug'].toString(), r['name'].toString())).toList();
  }

  @override
  Future<void> addWarranty(String itemId, Map<String, dynamic> body) => _api.post<Json>('/items/$itemId/warranties', body: body);
  @override
  Future<void> updateWarranty(String id, Map<String, dynamic> patch, {int? version}) => _api.patch<Json>('/warranties/$id', body: patch, ifMatchVersion: version);
  @override
  Future<void> deleteWarranty(String id) => _api.delete<dynamic>('/warranties/$id');
  @override
  Future<void> addReturnWindow(String itemId, Map<String, dynamic> body) => _api.post<Json>('/items/$itemId/return-windows', body: body);
  @override
  Future<void> updateReturnWindow(String id, Map<String, dynamic> patch, {int? version}) =>
      _api.patch<Json>('/return-windows/$id', body: patch, ifMatchVersion: version);
  @override
  Future<void> addRegistration(String itemId, Map<String, dynamic> body) => _api.post<Json>('/items/$itemId/registrations', body: body);
  @override
  Future<void> updateRegistration(String id, Map<String, dynamic> patch, {int? version}) =>
      _api.patch<Json>('/registrations/$id', body: patch, ifMatchVersion: version);
}

ItemSummary itemSummaryFromJson(Json j) => ItemSummary(
      id: j.str('id'),
      name: j.str('name'),
      brand: j.s('brand'),
      model: j.s('model_number'),
      retailer: j.s('retailer_name'),
      purchaseDate: j.s('purchase_date'),
      price: j.s('purchase_price'),
      currency: j.str('currency', 'USD'),
      categorySlug: j.s('category_slug'),
      lifecycle: j.str('lifecycle_state', 'owned'),
      archived: j.b('archived'),
      nearestCoverageEnd: j.s('nearest_coverage_end'),
      coverageCount: j.i('coverage_count') ?? 0,
      hasUnconfirmedCoverage: j.b('has_unconfirmed_coverage'),
      nextReturnDeadline: j.s('next_return_deadline'),
      nextRegistrationDeadline: j.s('next_registration_deadline'),
      registrationPending: j.b('registration_pending'),
      documentCount: j.i('document_count') ?? 0,
      hasReceipt: j.b('has_receipt'),
      createdAt: j.s('created_at'),
    );

Warranty warrantyFromJson(Json w) => Warranty(
      id: w.str('id'),
      coverageType: w.str('coverage_type', 'other'),
      provider: w.s('provider_name'),
      termKind: w.str('term_kind', 'unknown'),
      certainty: w.str('date_certainty', 'unknown'),
      startAnchor: w.s('start_anchor'),
      startDate: w.s('start_date'),
      endDate: w.s('end_date'),
      durationMonths: w.i('duration_months'),
      conditions: w.s('conditional_terms'),
      estimateAccepted: w['estimate_accepted_at'] != null,
      contractState: w.str('contract_state', 'active'),
      timeStatus: w.m('status').s('time_status'),
      daysRemaining: w.m('status').i('days_remaining'),
      disclosure: w.m('status').s('disclosure'),
      policyNumber: w.s('policy_number'),
      termsUrl: w.s('terms_url'),
      notes: w.s('notes'),
      version: w.i('version') ?? 1,
      alertsEnabled: w.m('labels').b('alerts_enabled'),
    );

ReturnWindow returnFromJson(Json r) => ReturnWindow(
      id: r.str('id'),
      retailer: r.s('retailer_name'),
      termsState: r.str('terms_state', 'unknown'),
      anchor: r.str('policy_anchor', 'unknown'),
      anchorDate: r.s('anchor_date'),
      windowDays: r.i('window_days'),
      deadline: r.s('return_deadline'),
      deadlineBasis: r.str('deadline_basis', 'unknown'),
      certainty: r.str('date_certainty', 'unknown'),
      estimateAccepted: r['estimate_accepted_at'] != null,
      state: r.str('return_state', 'not_started'),
      returnQuantity: r.i('return_quantity'),
      rma: r.s('rma_number'),
      tracking: r.s('tracking_reference'),
      initiatedAt: r.s('initiated_at'),
      shippedAt: r.s('shipped_at'),
      receivedAt: r.s('merchant_received_at'),
      refundedAt: r.s('refunded_at'),
      refundAmount: r.s('refund_amount'),
      dismissed: r.b('dismissed'),
      version: r.i('version') ?? 1,
      meaningLabel: r.m('labels').s('deadline_meaning'),
    );

Registration registrationFromJson(Json g) => Registration(
      id: g.str('id'),
      requirement: g.str('requirement_state', 'unknown'),
      provider: g.s('provider_name'),
      url: g.s('registration_url'),
      deadline: g.s('deadline'),
      certainty: g.str('deadline_certainty', 'unknown'),
      status: g.str('status', 'not_started'),
      completedAt: g.s('completed_at'),
      reference: g.s('confirmation_reference'),
      benefit: g.s('benefit_description'),
      version: g.i('version') ?? 1,
    );

ItemDetail itemDetailFromJson(Json j) {
  final cov = j.m('coverage');
  return ItemDetail(
    summary: itemSummaryFromJson(j),
    serial: j.s('serial_number'),
    sku: j.s('sku'),
    orderNumber: j.s('order_number'),
    deliveryDate: j.s('delivery_date'),
    priceIsEstimated: j.b('price_is_estimated'),
    condition: j.str('condition_at_purchase', 'unknown'),
    notes: j.s('notes'),
    categoryId: j.s('category_id'),
    purchaseGroupId: j.s('purchase_group_id'),
    paymentCardId: j.s('payment_card_id'),
    quantity: j.i('quantity') ?? 1,
    version: j.i('version') ?? 1,
    warranties: cov.l('warranties').map(warrantyFromJson).toList(),
    returns: cov.l('return_windows').map(returnFromJson).toList(),
    registrations: cov.l('registrations').map(registrationFromJson).toList(),
    documents: j.l('documents').map((d) {
      final a = d.m('attachments');
      return ItemDoc(
        attachmentId: a.str('id'),
        fileType: a.str('file_type', 'other'),
        filename: a.s('original_filename'),
        mime: a.s('verified_mime_type'),
        pages: a.i('page_count'),
        role: d.str('role', 'document'),
        state: a.s('processing_state'),
        createdAt: a.s('created_at'),
      );
    }).where((d) => d.attachmentId.isNotEmpty).toList(),
    claims: j.l('claims').map((c) => ClaimRef(id: c.str('id'), status: c.str('status'), kind: c.str('claim_kind'), provider: c.s('provider_name'))).toList(),
    timeline: j.l('timeline').map((t) => TimelineEvent(date: t.s('event_date'), kind: t.str('event_kind'), label: t.str('label'), certainty: t.s('certainty'))).toList(),
  );
}
