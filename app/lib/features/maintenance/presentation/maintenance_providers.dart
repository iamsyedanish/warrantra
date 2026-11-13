import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../auth/presentation/session_controller.dart';
import '../data/maintenance_repository_impl.dart';
import '../domain/maintenance.dart';

final maintenanceRepositoryProvider = Provider<MaintenanceRepository>((ref) => MaintenanceRepositoryImpl(ref.watch(apiClientProvider)));

final tasksProvider = FutureProvider.family<List<MaintenanceTask>, String?>((ref, itemId) {
  ref.watch(sessionEpochProvider);
  return ref.watch(maintenanceRepositoryProvider).tasks(itemId: itemId);
});

final serviceRecordsProvider = FutureProvider.family<List<ServiceRecord>, String>((ref, itemId) {
  ref.watch(sessionEpochProvider);
  return ref.watch(maintenanceRepositoryProvider).records(itemId);
});
