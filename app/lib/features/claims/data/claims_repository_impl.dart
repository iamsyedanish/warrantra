import '../../../core/network/api_client.dart';
import '../../../core/utils/format.dart';
import '../domain/claims.dart';

class ClaimsRepositoryImpl implements ClaimsRepository {
  ClaimsRepositoryImpl(this._api);
  final ApiClient _api;

  Outcome _outcome(Json o) => Outcome(
        id: o.str('id'),
        type: o.str('outcome_type'),
        amount: o.s('amount'),
        currency: o.s('currency'),
        date: o.s('outcome_date'),
        evidence: o.str('evidence_level', 'user_reported'),
        helped: o.s('warrantra_helped'),
        comment: o.s('user_comment'),
        claimId: o.s('claim_id'),
        returnWindowId: o.s('return_window_id'),
      );

  Claim _claim(Json j) {
    final snap = j.m('snapshot');
    return Claim(
      id: j.str('id'),
      itemId: j.str('item_id'),
      itemLabel: j.str('item_label', 'Item'),
      kind: j.str('claim_kind', 'other'),
      status: j.str('status', 'draft'),
      issue: j.str('issue_description'),
      issueStartedOn: j.s('issue_started_on'),
      providerName: j.s('provider_name'),
      providerContact: j.m('provider_contact'),
      claimNumber: j.s('claim_number'),
      followUpOn: j.s('follow_up_on'),
      submittedAt: j.s('submitted_at'),
      warrantyId: j.s('warranty_id'),
      returnWindowId: j.s('return_window_id'),
      proposedFacts: snap['proposed'] is Map ? snap.m('proposed') : null,
      reviewedFacts: snap['reviewed'] is Map ? snap.m('reviewed') : null,
      snapshotReviewed: j['snapshot_reviewed_at'] != null,
      aiDraft: j.s('ai_draft_text'),
      aiDraftReviewed: j['ai_draft_reviewed_at'] != null,
      version: j.i('version') ?? 1,
      createdAt: j.s('created_at'),
      docs: j.l('attachments').map((a) {
        final at = a.m('attachments');
        return ClaimDoc(attachmentId: a.str('attachment_id'), fileType: at.str('file_type', 'other'), filename: at.s('original_filename'), includeInPack: a['include_in_pack'] != false);
      }).toList(),
      packs: j.l('packs').map((p) => ClaimPack(id: p.str('id'), format: p.str('format'), level: p.str('pack_level'), generatedAt: p.s('generated_at'))).toList(),
      history: j.l('history').map((h) => StatusChange(h.str('to_status'), h.s('created_at'), h.s('note'))).toList(),
      outcome: j['outcome'] is Map ? _outcome(j.m('outcome')) : null,
    );
  }

  List<Json> _rows(dynamic r) => (r is List ? r : const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

  @override
  Future<List<Claim>> list() async => _rows(await _api.get<dynamic>('/claims', query: {'limit': 100})).map(_claim).toList();

  @override
  Future<Claim> get(String id) async => _claim(await _api.get<Json>('/claims/$id'));

  @override
  Future<Claim> create(Map<String, dynamic> body) async => _claim(await _api.post<Json>('/claims', body: body));

  @override
  Future<void> update(String id, Map<String, dynamic> patch, {int? version}) => _api.patch<dynamic>('/claims/$id', body: patch, ifMatchVersion: version);

  @override
  Future<void> reviewSnapshot(String id, Map<String, dynamic> facts) => _api.put<dynamic>('/claims/$id/snapshot', body: {'facts': facts});

  @override
  Future<PackResult> generatePack(String id, {String format = 'pdf'}) async {
    final j = await _api.post<Json>('/claims/$id/packs', body: {'format': format});
    return PackResult(packId: j.str('pack_id'), format: j.str('format'), level: j.str('pack_level'), text: j.s('text'), url: j.s('url'));
  }

  @override
  Future<String> packUrl(String packId) async => (await _api.get<Json>('/claim-packs/$packId/url')).str('url');

  @override
  Future<String> aiDraft(String id, {required String idempotencyKey}) async =>
      (await _api.post<Json>('/claims/$id/ai-draft', idempotencyKey: idempotencyKey)).str('draft');

  @override
  Future<void> delete(String id) => _api.delete<dynamic>('/claims/$id');

  @override
  Future<List<Outcome>> outcomes() async => _rows(await _api.get<dynamic>('/outcomes')).map(_outcome).toList();

  @override
  Future<OutcomeSummary> outcomeSummary() async {
    final j = await _api.get<Json>('/outcomes/summary');
    return OutcomeSummary(
      byType: j.m('outcomes_by_type').map((k, v) => MapEntry(k, (v as num).toInt())),
      refunds: j.m('refunds_reported').map((k, v) => MapEntry(k, v as num)),
      note: j.str('note'),
    );
  }

  @override
  Future<void> recordOutcome(Map<String, dynamic> body) => _api.post<dynamic>('/outcomes', body: body);
}
