/// Recurring upkeep tasks and service history.
class MaintenanceTask {
  const MaintenanceTask({required this.id, required this.title, this.itemId, this.unit, this.interval, this.nextDue, this.basis = 'user_preference', this.reminder = true, this.state = 'active', this.lastDone, this.version = 1});
  final String id, title, basis, state;
  final String? itemId, unit, nextDue, lastDone;
  final int? interval;
  final bool reminder;
  final int version;
  String get every => unit == null ? 'One-off' : 'Every ${interval ?? 1} ${unit!}${(interval ?? 1) == 1 ? '' : 's'}';
}

class ServiceRecord {
  const ServiceRecord({required this.id, required this.date, required this.type, this.provider, this.description, this.cost, this.currency, this.attachments = 0});
  final String id, date, type;
  final String? provider, description, cost, currency;
  final int attachments;
}

abstract interface class MaintenanceRepository {
  Future<List<MaintenanceTask>> tasks({String? itemId});
  Future<void> addTask(Map<String, dynamic> body);
  Future<void> updateTask(String id, Map<String, dynamic> patch, {int? version});
  Future<void> completeTask(String id, {required String date, String? notes});
  Future<void> removeTask(String id);
  Future<List<ServiceRecord>> records(String itemId);
  Future<void> addRecord(Map<String, dynamic> body);
  Future<void> removeRecord(String id);
}
