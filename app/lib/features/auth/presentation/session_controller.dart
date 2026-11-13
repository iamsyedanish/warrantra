import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/storage/secure_store.dart';
import '../data/auth_repository_impl.dart';
import '../domain/auth_repository.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepositoryImpl(ref.watch(apiClientProvider), ref.watch(secureStoreProvider)),
);

enum SessionStatus { unknown, signedOut, signedIn }

/// App-wide session state. Every user-scoped provider watches [sessionEpochProvider],
/// so signing out or switching accounts drops all cached private data.
class SessionController extends Notifier<SessionStatus> {
  @override
  SessionStatus build() {
    ref.watch(apiClientProvider).onSessionExpired = _expired;
    _restore();
    return SessionStatus.unknown;
  }

  Future<void> _restore() async {
    final has = await ref.read(authRepositoryProvider).hasSession();
    state = has ? SessionStatus.signedIn : SessionStatus.signedOut;
  }

  void _expired() {
    if (state == SessionStatus.signedIn) _clearAndSignOut();
  }

  void markSignedIn() {
    ref.read(sessionEpochProvider.notifier).bump();
    state = SessionStatus.signedIn;
  }

  Future<void> signOut() async {
    await ref.read(authRepositoryProvider).signOut();
    _clearAndSignOut();
  }

  void _clearAndSignOut() {
    ref.read(sessionEpochProvider.notifier).bump();
    state = SessionStatus.signedOut;
  }
}

final sessionProvider = NotifierProvider<SessionController, SessionStatus>(SessionController.new);

/// Incremented on every sign-in/out so cached user data is rebuilt from scratch.
class SessionEpoch extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final sessionEpochProvider = NotifierProvider<SessionEpoch, int>(SessionEpoch.new);
