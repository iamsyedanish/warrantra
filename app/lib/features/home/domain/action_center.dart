/// Action Center domain.
class ActionItem {
  const ActionItem({
    required this.kind,
    required this.priority,
    this.itemId,
    required this.itemName,
    this.sourceId,
    this.dueDate,
    this.daysLeft,
    required this.title,
    this.certainty,
    this.detail,
  });
  final String kind;
  final int priority;
  final String? itemId, sourceId, dueDate, certainty, detail;
  final String itemName, title;
  final int? daysLeft;

  bool get overdue => (daysLeft ?? 1) < 0;
  bool get urgent => priority == 0 || (daysLeft != null && daysLeft! <= 2);
}

class ActionCenter {
  const ActionCenter({required this.title, this.message, required this.empty, required this.actions, required this.missing});
  final String title;
  final String? message;
  final bool empty;
  final List<ActionItem> actions;
  final List<ActionItem> missing;
  bool get caughtUp => !empty && actions.isEmpty;
}

abstract interface class ActionCenterRepository {
  Future<ActionCenter> load({int horizonDays = 60});
}
