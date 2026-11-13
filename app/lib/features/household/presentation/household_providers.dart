import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../auth/presentation/session_controller.dart';
import '../data/household_repository_impl.dart';
import '../domain/household.dart';

final householdRepositoryProvider = Provider<HouseholdRepository>((ref) => HouseholdRepositoryImpl(ref.watch(apiClientProvider)));

final workspacesProvider = FutureProvider<List<Workspace>>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(householdRepositoryProvider).list();
});

final workspaceProvider = FutureProvider.family<Workspace, String>((ref, id) {
  ref.watch(sessionEpochProvider);
  return ref.watch(householdRepositoryProvider).get(id);
});

final forwardingProvider = FutureProvider<ForwardingAddress?>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(householdRepositoryProvider).forwardingAddress();
});

final inboundLogProvider = FutureProvider<List<InboundEmail>>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(householdRepositoryProvider).inboundLog();
});
