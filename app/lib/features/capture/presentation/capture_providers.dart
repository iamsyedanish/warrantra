import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../auth/presentation/session_controller.dart';
import '../data/capture_repository_impl.dart';
import '../domain/capture.dart';

final captureRepositoryProvider = Provider<CaptureRepository>((ref) => CaptureRepositoryImpl(ref.watch(apiClientProvider)));

final scanProvider = FutureProvider.family<ScanJob, String>((ref, id) {
  ref.watch(sessionEpochProvider);
  return ref.watch(captureRepositoryProvider).scan(id);
});

final captureDraftsProvider = FutureProvider<List<CaptureDraftSummary>>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(captureRepositoryProvider).drafts();
});
