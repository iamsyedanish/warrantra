import '../../../core/network/api_client.dart';
import '../../../core/utils/format.dart';
import '../domain/maintenance.dart';

class MaintenanceRepositoryImpl implements MaintenanceRepository {
  MaintenanceRepositoryImpl(this._api);
  final ApiClient _api;
  List<Json> _rows(dynamic r) => (r is List ? r : const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

  @override
  Future<List<MaintenanceTask>> tasks({String? itemId}) async => _rows(await _api.get<dynamic>('/maintenance-tasks', query: {'item_id': ?itemId}))
      .map((j) => MaintenanceTask(
            id: j.str('id'),
            title: j.str('title'),
            itemId: j.s('item_id'),
            unit: j.s('recurrence_unit'),
            interval: j.i('recurrence_interval'),
            nextDue: j.s('next_due_on'),
            basis: j.str('requirement_basis', 'user_preference'),
            reminder: j['reminder_enabled'] != false,
            state: j.str('state', 'active'),
            lastDone: j.s('last_completed_on'),
            version: j.i('version') ?? 1,
          ))
      .toList();

  @override
  Future<void> addTask(Map<String, dynamic> body) => _api.post<dynamic>('/maintenance-tasks', body: body);
  @override
  Future<void> updateTask(String id, Map<String, dynamic> patch, {int? version}) => _api.patch<dynamic>('/maintenance-tasks/$id', body: patch, ifMatchVersion: version);
  @override
  Future<void> completeTask(String id, {required String date, String? notes}) => _api.post<dynamic>('/maintenance-tasks/$id/complete', body: {'service_date': date, 'notes': ?notes});
  @override
  Future<void> removeTask(String id) => _api.delete<dynamic>('/maintenance-tasks/$id');

  @override
  Future<List<ServiceRecord>> records(String itemId) async => _rows(await _api.get<dynamic>('/items/$itemId/service-records'))
      .map((j) => ServiceRecord(
            id: j.str('id'),
            date: j.str('service_date'),
            type: j.str('service_type', 'other'),
            provider: j.s('provider_name'),
            description: j.s('description'),
            cost: j.s('cost_amount'),
            currency: j.s('cost_currency'),
            attachments: j.l('service_record_attachments').length,
          ))
      .toList();

  @override
  Future<void> addRecord(Map<String, dynamic> body) => _api.post<dynamic>('/service-records', body: body);
  @override
  Future<void> removeRecord(String id) => _api.delete<dynamic>('/service-records/$id');
}
