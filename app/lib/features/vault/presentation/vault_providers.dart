import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../auth/presentation/session_controller.dart';
import '../data/vault_repository_impl.dart';
import '../domain/vault.dart';

final vaultRepositoryProvider = Provider<VaultRepository>((ref) => VaultRepositoryImpl(ref.watch(apiClientProvider)));

final vaultFilterProvider = NotifierProvider<VaultFilter, String?>(VaultFilter.new);

class VaultFilter extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? v) => state = v;
}

final vaultProvider = FutureProvider<List<VaultDoc>>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(vaultRepositoryProvider).list(fileType: ref.watch(vaultFilterProvider));
});

final vaultDocProvider = FutureProvider.family<VaultDoc, String>((ref, id) {
  ref.watch(sessionEpochProvider);
  return ref.watch(vaultRepositoryProvider).get(id);
});

/// Short-lived signed preview URL (re-fetched whenever the viewer opens).
final docPreviewUrlProvider = FutureProvider.autoDispose.family<String, String>((ref, id) => ref.watch(vaultRepositoryProvider).url(id, previewWidth: 1400));

final docImpactProvider = FutureProvider.autoDispose.family<DocImpact, String>((ref, id) => ref.watch(vaultRepositoryProvider).impact(id));
