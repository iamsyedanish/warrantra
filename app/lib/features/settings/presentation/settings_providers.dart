import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../auth/presentation/session_controller.dart';
import '../data/revenuecat_billing.dart';
import '../data/settings_repository_impl.dart';
import '../domain/billing.dart';
import '../domain/settings.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) => SettingsRepositoryImpl(ref.watch(apiClientProvider)));

final exportsProvider = FutureProvider<List<ExportJob>>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(settingsRepositoryProvider).exports();
});

final deletionStatusProvider = FutureProvider<List<DeletionStatus>>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(settingsRepositoryProvider).deletionStatus();
});

final annualProvider = FutureProvider.family<AnnualSummary, int>((ref, year) {
  ref.watch(sessionEpochProvider);
  return ref.watch(settingsRepositoryProvider).annual(year);
});

final ticketsProvider = FutureProvider<List<SupportTicket>>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(settingsRepositoryProvider).tickets();
});

final billingProvider = Provider<BillingGateway>((ref) => RevenueCatBilling());
