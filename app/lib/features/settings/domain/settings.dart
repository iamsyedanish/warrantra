/// Account-level operations: export, deletion, annual summary, support.
class ExportJob {
  const ExportJob({required this.id, required this.state, this.itemCount, this.fileCount, this.requestedAt, this.expiresAt});
  final String id, state;
  final int? itemCount, fileCount;
  final String? requestedAt, expiresAt;
  bool get ready => state == 'ready';
  bool get busy => state == 'queued' || state == 'running';
}

class ExportLinks {
  const ExportLinks({required this.state, this.dataUrl, this.manifestUrl});
  final String state;
  final String? dataUrl, manifestUrl;
}

class DeletionStatus {
  const DeletionStatus({required this.id, required this.state, this.createdAt});
  final String id, state;
  final String? createdAt;
  bool get pending => state == 'requested';
  bool get running => const ['confirmed', 'deleting_objects', 'deleting_records', 'verifying'].contains(state);
}

class AnnualSummary {
  const AnnualSummary(this.raw);
  final Map<String, dynamic> raw;
  int n(String k) => (raw[k] is num) ? (raw[k] as num).toInt() : 0;
}

class SupportTicket {
  const SupportTicket({required this.id, required this.subject, required this.status, this.reference, this.createdAt});
  final String id, subject, status;
  final String? reference, createdAt;
}

abstract interface class SettingsRepository {
  Future<List<ExportJob>> exports();
  Future<ExportJob> requestExport({bool includeFiles = true});
  Future<ExportLinks> exportLinks(String id);
  Future<List<DeletionStatus>> deletionStatus();
  Future<void> requestDeletion();
  Future<void> confirmDeletion();
  Future<void> cancelDeletion();
  Future<AnnualSummary> annual(int year);
  Future<List<SupportTicket>> tickets();
  Future<SupportTicket> openTicket({required String subject, required String category, required String message});
}
