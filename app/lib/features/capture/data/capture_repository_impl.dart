import '../../../core/errors/failure.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/format.dart';
import '../domain/capture.dart';

class CaptureRepositoryImpl implements CaptureRepository {
  CaptureRepositoryImpl(this._api);
  final ApiClient _api;

  @override
  Future<UploadedFile> upload({required List<int> bytes, required String filename, required String mime, required String fileType, required String idempotencyKey}) async {
    final begin = await _api.post<Json>('/attachments',
        body: {'file_type': fileType, 'filename': filename, 'mime_type': mime, 'byte_size': bytes.length}, idempotencyKey: idempotencyKey);
    final att = begin.m('attachment');
    final id = att.str('id');
    final upload = begin['upload'];
    if (upload is Map && upload['signed_url'] != null) {
      await _api.uploadToSignedUrl(upload['signed_url'].toString(), bytes, mime);
    }
    final done = await _api.post<Json>('/attachments/$id/complete');
    final a = done.m('attachment');
    final state = a.s('processing_state') ?? a.s('state') ?? 'ready';
    final out = UploadedFile(
      attachmentId: id,
      state: state,
      duplicateOf: done.s('duplicate_of'),
      rejectionReason: done.s('rejection_reason'),
      filename: filename,
      mime: mime,
    );
    if (state == 'failed' || state == 'quarantined') {
      throw Failure('upload_rejected', _rejection(out.rejectionReason), details: {'attachment_id': id, 'reason': out.rejectionReason});
    }
    return out;
  }

  String _rejection(String? reason) => switch (reason) {
        'too_large' || 'file_too_large' => 'This file is larger than your plan allows (10 MB).',
        'too_many_pages' || 'pdf_too_many_pages' => 'This PDF has more pages than your plan allows.',
        'mime_mismatch' => "This file isn't what its name says. Upload a JPEG, PNG, HEIC or PDF.",
        'pdf_active_content' => 'This PDF contains scripts or embedded files, so it was not stored.',
        'encrypted_pdf' || 'pdf_encrypted' => 'This PDF is password-protected. Remove the password and try again.',
        _ => "This file couldn't be stored. Try another photo or a PDF.",
      };

  @override
  Future<void> linkToItem(String attachmentId, String itemId, {String role = 'document'}) =>
      _api.post<Json>('/attachments/$attachmentId/links', body: {'target': 'item', 'target_id': itemId, 'role': role});

  @override
  Future<ScanJob> startScan({String? attachmentId, String? ocrText, String feature = 'receipt_extraction', String? captureDraftId, required String idempotencyKey}) async {
    final j = await _api.post<Json>('/scans',
        body: {
          'feature': feature,
          'attachment_id': ?attachmentId,
          'ocr_text': ?ocrText,
          'capture_draft_id': ?captureDraftId,
        },
        idempotencyKey: idempotencyKey);
    return scanFromJson(j);
  }

  @override
  Future<ScanJob> scan(String id) async => scanFromJson(await _api.get<Json>('/scans/$id'));

  @override
  Future<void> discardScan(String id) => _api.post<Json>('/scans/$id/discard');

  @override
  Future<List<CaptureDraftSummary>> drafts() async {
    final rows = await _api.get<List<dynamic>>('/capture-drafts');
    return rows.whereType<Map>().map((r) => _draft(Map<String, dynamic>.from(r))).toList();
  }

  @override
  Future<CaptureDraftSummary> createDraft({required String source, required List<String> attachmentIds, String? title, bool autoScan = false}) async =>
      _draft(await _api.post<Json>('/capture-drafts', body: {'source': source, 'attachment_ids': attachmentIds, 'title': ?title, 'auto_scan': autoScan}));

  @override
  Future<void> discardDraft(String id) => _api.post<Json>('/capture-drafts/$id/discard');

  CaptureDraftSummary _draft(Json j) => CaptureDraftSummary(
        id: j.str('id'),
        source: j.str('source'),
        state: j.str('state'),
        title: j.s('title'),
        scanJobId: j.s('scan_job_id'),
        attachmentIds: (j['attachment_ids'] as List? ?? const []).map((e) => e.toString()).toList(),
        createdAt: j.s('created_at'),
      );
}

DraftField _field(Object? v) {
  if (v is! Map) return const DraftField();
  return DraftField(value: v['value']?.toString(), evidence: v['evidence']?.toString(), status: (v['status'] ?? 'missing').toString());
}

ScanJob scanFromJson(Json j) {
  final d = j['review_draft'];
  final feature = j.str('feature', 'receipt_extraction');
  ReceiptDraft? receipt;
  LabelDraft? label;
  if (d is Map) {
    final m = Map<String, dynamic>.from(d);
    if (feature == 'product_label_extraction') {
      final cat = m.m('category');
      label = LabelDraft(
        productName: _field(m['product_name']),
        category: cat.s('value'),
        brand: _field(m['brand']),
        model: _field(m['model_number']),
        serial: _field(m['serial_number']),
        manufactureDate: _field(m['manufacture_date']),
        warnings: (m['warnings'] as List? ?? const []).map((e) => e.toString()).toList(),
        suggestions: m.l('suggested_coverage').map((s) => SuggestedCoverage(raw: s, prompt: s.str('prompt'))).toList(),
        disclaimer: m.s('suggestion_disclaimer'),
        registrationUrl: m.m('brand_reference').s('registration_url'),
      );
    } else {
      List<DraftMention> mentions(String k) => m.m('suggestions').l(k).map((x) => DraftMention(x.str('text'), x.str('evidence'), x.str('label'))).toList();
      receipt = ReceiptDraft(
        merchant: _field(m['merchant']),
        purchaseDate: _field(m['purchase_date']),
        deliveryDate: _field(m['delivery_date']),
        orderNumber: _field(m['order_number']),
        currency: _field(m['currency']),
        subtotal: _field(m['subtotal']),
        tax: _field(m['tax']),
        shipping: _field(m['shipping']),
        discount: _field(m['discount']),
        total: _field(m['total_paid']),
        lines: m.l('lines').map((l) => DraftLine(
              index: l.i('line_index') ?? 0,
              description: l.s('description'),
              quantity: l['quantity'] is num ? l['quantity'] as num : null,
              unitAmount: l.s('unit_amount'),
              lineAmount: l.s('line_amount'),
              sku: l.s('sku'),
              evidence: l.s('evidence'),
            )).toList(),
        returnMentions: mentions('return_policy'),
        warrantyMentions: mentions('warranty'),
        warnings: (m['warnings'] as List? ?? const []).map((e) => e.toString()).toList(),
      );
    }
  }
  return ScanJob(
    id: j.str('id'),
    feature: feature,
    state: j.str('state', 'queued'),
    errorCode: j.s('error_code'),
    attachmentId: j.s('input_attachment_id'),
    purchaseGroupId: j.s('confirmed_purchase_group_id'),
    receipt: receipt,
    label: label,
  );
}
