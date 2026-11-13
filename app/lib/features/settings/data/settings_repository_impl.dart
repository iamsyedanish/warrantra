import '../../../core/network/api_client.dart';
import '../../../core/utils/format.dart';
import '../domain/settings.dart';

class SettingsRepositoryImpl implements SettingsRepository {
  SettingsRepositoryImpl(this._api);
  final ApiClient _api;

  List<Json> _rows(dynamic r) => (r is List ? r : const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  ExportJob _job(Json j) => ExportJob(id: j.str('id'), state: j.str('state'), itemCount: j.i('item_count'), fileCount: j.i('file_count'), requestedAt: j.s('requested_at'), expiresAt: j.s('expires_at'));
  SupportTicket _ticket(Json j) => SupportTicket(id: j.str('id'), subject: j.str('subject'), status: j.str('status', 'open'), reference: j.s('reference') ?? j.s('ticket_number'), createdAt: j.s('created_at'));

  @override
  Future<List<ExportJob>> exports() async => _rows(await _api.get<dynamic>('/me/exports')).map(_job).toList();

  @override
  Future<ExportJob> requestExport({bool includeFiles = true}) async => _job(await _api.post<Json>('/me/exports', body: {'include_files': includeFiles}));

  @override
  Future<ExportLinks> exportLinks(String id) async {
    final j = await _api.get<Json>('/me/exports/$id');
    return ExportLinks(state: j.str('state'), dataUrl: j.s('data_url'), manifestUrl: j.s('files_manifest_url'));
  }

  @override
  Future<List<DeletionStatus>> deletionStatus() async =>
      _rows(await _api.get<dynamic>('/me/deletion')).map((j) => DeletionStatus(id: j.str('id'), state: j.str('state'), createdAt: j.s('created_at'))).toList();

  @override
  Future<void> requestDeletion() => _api.post<dynamic>('/me/deletion');

  @override
  Future<void> confirmDeletion() => _api.post<dynamic>('/me/deletion/confirm', body: {'confirm': 'DELETE MY ACCOUNT'});

  @override
  Future<void> cancelDeletion() => _api.post<dynamic>('/me/deletion/cancel');

  @override
  Future<AnnualSummary> annual(int year) async => AnnualSummary(await _api.get<Json>('/me/annual-summary', query: {'year': year}));

  @override
  Future<List<SupportTicket>> tickets() async => _rows(await _api.get<dynamic>('/support/tickets')).map(_ticket).toList();

  @override
  Future<SupportTicket> openTicket({required String subject, required String category, required String message}) async =>
      _ticket(await _api.post<Json>('/support/tickets', body: {'subject': subject, 'category': category, 'message': message}));
}
