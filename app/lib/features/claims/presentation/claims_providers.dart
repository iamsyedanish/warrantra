import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../auth/presentation/session_controller.dart';
import '../data/claims_repository_impl.dart';
import '../domain/claims.dart';

final claimsRepositoryProvider = Provider<ClaimsRepository>((ref) => ClaimsRepositoryImpl(ref.watch(apiClientProvider)));

final claimsProvider = FutureProvider<List<Claim>>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(claimsRepositoryProvider).list();
});

final claimProvider = FutureProvider.family<Claim, String>((ref, id) {
  ref.watch(sessionEpochProvider);
  return ref.watch(claimsRepositoryProvider).get(id);
});

final outcomesProvider = FutureProvider<List<Outcome>>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(claimsRepositoryProvider).outcomes();
});

final outcomeSummaryProvider = FutureProvider<OutcomeSummary>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(claimsRepositoryProvider).outcomeSummary();
});
