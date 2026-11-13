import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../account/presentation/account_providers.dart';
import '../../auth/presentation/session_controller.dart';
import '../../home/presentation/home_providers.dart';
import '../data/items_repository_impl.dart';
import '../domain/items.dart';

final itemsRepositoryProvider = Provider<ItemsRepository>((ref) => ItemsRepositoryImpl(ref.watch(apiClientProvider)));

final itemsQueryProvider = NotifierProvider<ItemsQueryController, ItemQuery>(ItemsQueryController.new);

class ItemsQueryController extends Notifier<ItemQuery> {
  @override
  ItemQuery build() => const ItemQuery();
  void set(ItemQuery q) => state = q;
}

final itemsListProvider = FutureProvider<List<ItemSummary>>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(itemsRepositoryProvider).list(ref.watch(itemsQueryProvider));
});

/// Recent purchases for Home (independent of the Items filters).
final recentItemsProvider = FutureProvider<List<ItemSummary>>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(itemsRepositoryProvider).list(const ItemQuery(sort: 'created_at'));
});

final itemDetailProvider = FutureProvider.family<ItemDetail, String>((ref, id) {
  ref.watch(sessionEpochProvider);
  return ref.watch(itemsRepositoryProvider).detail(id);
});

final categoriesProvider = FutureProvider<List<Category>>((ref) => ref.watch(itemsRepositoryProvider).categories());

final suggestionsProvider = FutureProvider.family<Map<String, dynamic>, String>((ref, id) => ref.watch(itemsRepositoryProvider).suggestions(id));

/// After any write, refresh everything that shows item data
/// (lists, detail, Action Center and plan usage).
extension RefreshItemData on WidgetRef {
  void refreshItems({String? itemId}) {
    invalidate(itemsListProvider);
    invalidate(recentItemsProvider);
    invalidate(actionCenterProvider);
    invalidate(meProvider);
    if (itemId != null) invalidate(itemDetailProvider(itemId));
  }
}
