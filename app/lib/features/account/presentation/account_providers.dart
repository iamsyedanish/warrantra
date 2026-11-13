import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../auth/presentation/session_controller.dart';
import '../data/account_repository_impl.dart';
import '../domain/account.dart';

final accountRepositoryProvider = Provider<AccountRepository>((ref) => AccountRepositoryImpl(ref.watch(apiClientProvider)));

/// The signed-in user's profile, plan and usage. Rebuilt on every session change.
final meProvider = FutureProvider<Me>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(accountRepositoryProvider).me();
});

final offerProvider = FutureProvider<PriceOffer>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(accountRepositoryProvider).offer();
});

/// Human-readable plan usage lines shared by Settings, Plan and Items.
extension UsageText on Me {
  String get itemsLine => '${usage.itemsUsed} of ${usage.itemsLimit} items';
  String get aiLine => usage.aiPeriod == 'lifetime'
      ? '${usage.aiLeft} of ${usage.aiLimit} trial AI reads left'
      : '${usage.aiUsed} of ${usage.aiLimit} AI actions this month';
}
