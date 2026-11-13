/// Claims and the outcome ledger.
class ClaimDoc {
  const ClaimDoc({required this.attachmentId, required this.fileType, this.filename, this.includeInPack = true});
  final String attachmentId, fileType;
  final String? filename;
  final bool includeInPack;
}

class ClaimPack {
  const ClaimPack({required this.id, required this.format, required this.level, this.generatedAt});
  final String id, format, level;
  final String? generatedAt;
}

class StatusChange {
  const StatusChange(this.to, this.at, this.note);
  final String to;
  final String? at, note;
}

class Outcome {
  const Outcome({required this.id, required this.type, this.amount, this.currency, this.date, required this.evidence, this.helped, this.comment, this.claimId, this.returnWindowId});
  final String id, type, evidence;
  final String? amount, currency, date, helped, comment, claimId, returnWindowId;
}

class Claim {
  const Claim({
    required this.id,
    required this.itemId,
    required this.itemLabel,
    required this.kind,
    required this.status,
    required this.issue,
    this.issueStartedOn,
    this.providerName,
    this.providerContact = const {},
    this.claimNumber,
    this.followUpOn,
    this.submittedAt,
    this.warrantyId,
    this.returnWindowId,
    this.proposedFacts,
    this.reviewedFacts,
    this.snapshotReviewed = false,
    this.aiDraft,
    this.aiDraftReviewed = false,
    this.version = 1,
    this.createdAt,
    this.docs = const [],
    this.packs = const [],
    this.history = const [],
    this.outcome,
  });
  final String id, itemId, itemLabel, kind, status, issue;
  final String? issueStartedOn, providerName, claimNumber, followUpOn, submittedAt, warrantyId, returnWindowId, aiDraft, createdAt;
  final Map<String, dynamic> providerContact;
  final Map<String, dynamic>? proposedFacts, reviewedFacts;
  final bool snapshotReviewed, aiDraftReviewed;
  final int version;
  final List<ClaimDoc> docs;
  final List<ClaimPack> packs;
  final List<StatusChange> history;
  final Outcome? outcome;
  bool get sent => const ['submitted_by_user', 'in_review', 'info_requested', 'approved', 'denied', 'resolved'].contains(status);
  bool get closed => const ['resolved', 'denied', 'withdrawn'].contains(status);
}

class PackResult {
  const PackResult({required this.packId, required this.format, required this.level, this.text, this.url});
  final String packId, format, level;
  final String? text, url;
}

class OutcomeSummary {
  const OutcomeSummary({required this.byType, required this.refunds, required this.note});
  final Map<String, int> byType;
  final Map<String, num> refunds;
  final String note;
}

abstract interface class ClaimsRepository {
  Future<List<Claim>> list();
  Future<Claim> get(String id);
  Future<Claim> create(Map<String, dynamic> body);
  Future<void> update(String id, Map<String, dynamic> patch, {int? version});
  Future<void> reviewSnapshot(String id, Map<String, dynamic> facts);
  Future<PackResult> generatePack(String id, {String format = 'pdf'});
  Future<String> packUrl(String packId);
  Future<String> aiDraft(String id, {required String idempotencyKey});
  Future<void> delete(String id);
  Future<List<Outcome>> outcomes();
  Future<OutcomeSummary> outcomeSummary();
  Future<void> recordOutcome(Map<String, dynamic> body);
}
