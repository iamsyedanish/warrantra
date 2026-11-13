import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../auth/presentation/session_controller.dart';
import '../data/action_center_repository_impl.dart';
import '../domain/action_center.dart';

final actionCenterRepositoryProvider = Provider<ActionCenterRepository>((ref) => ActionCenterRepositoryImpl(ref.watch(apiClientProvider)));

final actionCenterProvider = FutureProvider<ActionCenter>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(actionCenterRepositoryProvider).load();
});
