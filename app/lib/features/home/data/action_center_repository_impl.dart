import '../../../core/network/api_client.dart';
import '../../../core/utils/format.dart';
import '../domain/action_center.dart';

class ActionCenterRepositoryImpl implements ActionCenterRepository {
  ActionCenterRepositoryImpl(this._api);
  final ApiClient _api;

  @override
  Future<ActionCenter> load({int horizonDays = 60}) async {
    final j = await _api.get<Json>('/action-center', query: {'horizon_days': horizonDays});
    ActionItem item(Json a) => ActionItem(
          kind: a.str('kind'),
          priority: a.i('priority') ?? 9,
          itemId: a.s('item_id'),
          itemName: a.str('item_name'),
          sourceId: a.s('source_id'),
          dueDate: a.s('due_date'),
          daysLeft: a.i('days_left'),
          title: a.str('title'),
          certainty: a.s('certainty'),
          detail: a.s('detail'),
        );
    return ActionCenter(
      title: j.m('summary').str('title'),
      message: j.m('summary').s('message'),
      empty: j.b('empty'),
      actions: j.l('actions').map(item).toList(),
      missing: j.l('missing_information').map(item).toList(),
    );
  }
}
