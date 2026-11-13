/// Capture domain: uploads, AI scans and their review drafts.
class UploadedFile {
  const UploadedFile({required this.attachmentId, required this.state, this.duplicateOf, this.rejectionReason, this.filename, this.mime});
  final String attachmentId, state;
  final String? duplicateOf, rejectionReason, filename, mime;
  bool get ready => state == 'ready';
}

/// One extracted field: the value is only present when the document supports it.
class DraftField {
  const DraftField({this.value, this.evidence, this.status = 'missing'});
  final String? value, evidence;
  final String status; // extracted | missing | rejected | suggested
  bool get found => status == 'extracted' && value != null;
}

class DraftLine {
  const DraftLine({required this.index, this.description, this.quantity, this.unitAmount, this.lineAmount, this.sku, this.evidence});
  final int index;
  final String? description, unitAmount, lineAmount, sku, evidence;
  final num? quantity;
}

class DraftMention {
  const DraftMention(this.text, this.evidence, this.label);
  final String text, evidence, label;
}

class ReceiptDraft {
  const ReceiptDraft({
    required this.merchant,
    required this.purchaseDate,
    required this.deliveryDate,
    required this.orderNumber,
    required this.currency,
    required this.subtotal,
    required this.tax,
    required this.shipping,
    required this.discount,
    required this.total,
    required this.lines,
    required this.returnMentions,
    required this.warrantyMentions,
    required this.warnings,
  });
  final DraftField merchant, purchaseDate, deliveryDate, orderNumber, currency, subtotal, tax, shipping, discount, total;
  final List<DraftLine> lines;
  final List<DraftMention> returnMentions, warrantyMentions;
  final List<String> warnings;
}

class SuggestedCoverage {
  const SuggestedCoverage({required this.raw, required this.prompt});
  final Map<String, dynamic> raw;
  final String prompt;
}

class LabelDraft {
  const LabelDraft({
    required this.productName,
    this.category,
    required this.brand,
    required this.model,
    required this.serial,
    required this.manufactureDate,
    required this.warnings,
    this.suggestions = const [],
    this.disclaimer,
    this.registrationUrl,
  });
  final DraftField productName, brand, model, serial, manufactureDate;
  final String? category, disclaimer, registrationUrl;
  final List<String> warnings;
  final List<SuggestedCoverage> suggestions;
}

class ScanJob {
  const ScanJob({required this.id, required this.feature, required this.state, this.errorCode, this.receipt, this.label, this.attachmentId, this.purchaseGroupId});
  final String id, feature, state;
  final String? errorCode, attachmentId, purchaseGroupId;
  final ReceiptDraft? receipt;
  final LabelDraft? label;
  bool get done => state == 'succeeded' || state == 'failed' || state == 'rejected' || state == 'discarded';
}

class CaptureDraftSummary {
  const CaptureDraftSummary({required this.id, required this.source, required this.state, this.title, this.scanJobId, this.attachmentIds = const [], this.createdAt});
  final String id, source, state;
  final String? title, scanJobId, createdAt;
  final List<String> attachmentIds;
}

abstract interface class CaptureRepository {
  /// Begin → PUT bytes to the signed URL → complete. Safe to retry with the same key.
  Future<UploadedFile> upload({required List<int> bytes, required String filename, required String mime, required String fileType, required String idempotencyKey});
  Future<void> linkToItem(String attachmentId, String itemId, {String role = 'document'});
  Future<ScanJob> startScan({String? attachmentId, String? ocrText, String feature = 'receipt_extraction', String? captureDraftId, required String idempotencyKey});
  Future<ScanJob> scan(String id);
  Future<void> discardScan(String id);
  Future<List<CaptureDraftSummary>> drafts();
  Future<CaptureDraftSummary> createDraft({required String source, required List<String> attachmentIds, String? title, bool autoScan = false});
  Future<void> discardDraft(String id);
}
